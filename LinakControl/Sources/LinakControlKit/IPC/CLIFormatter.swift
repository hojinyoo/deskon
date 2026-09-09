// CLIFormatter.swift
// LinakControlKit — CLI error formatting and exit code mapping shared by deskctl commands.

import Foundation

// MARK: - CLIExitCode

public enum CLIExitCode: Int32, Sendable {
    case success = 0
    case general = 1
    case daemonNotRunning = 2
    case notConnected = 3
    case timeout = 5
}

// MARK: - CLIFormatter

public enum CLIFormatter {

    /// Format an IPCClientError into a user-facing message and exit code.
    public static func formatError(_ error: IPCClientError, json: Bool) -> (message: String, exitCode: CLIExitCode) {
        switch error {
        case .daemonNotRunning:
            let msg = json
                ? #"{"error": 2, "message": "daemon not running"}"#
                : "error: daemon not running — start Deskon.app first"
            return (msg, .daemonNotRunning)

        case .connectionFailed(let detail):
            let msg = json
                ? #"{"error": 1, "message": "connection failed: \#(detail)"}"#
                : "error: connection failed: \(detail)"
            return (msg, .general)

        case .invalidResponse:
            let msg = json
                ? #"{"error": 1, "message": "invalid response from daemon"}"#
                : "error: invalid response from daemon"
            return (msg, .general)

        case .serverError(let code, let message):
            let msg = json
                ? #"{"error": \#(code), "message": "\#(message)"}"#
                : "error: \(message)"
            return (msg, mapServerCode(code))
        }
    }

    /// Write a message to stderr followed by a newline.
    public static func printError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    // MARK: - Status Output

    /// Renders the `deskctl status` table.
    ///
    /// `heightDisplay` and every preset height already carry their unit from
    /// `HeightConverter.display` - nothing here appends one.
    public static func formatStatus(_ status: StatusResult) -> String {
        var lines = [
            "LinakControl Daemon",
            "  Connection: \(status.connected ? "connected" : "disconnected")",
            "  Desk:       \(status.deskName ?? "unknown")",
            "  Height:     \(formatHeight(status))",
        ]
        let presets = formatPresets(status.presets, active: status.activePreset, unit: unit(of: status))
        if !presets.isEmpty {
            lines.append("  Presets:    \(presets)")
        }
        if status.needsReference {
            lines.append("  Warning:    \(warningText(faultCode: status.faultCode))")
        }
        return lines.joined(separator: "\n")
    }

    /// The single line printed by `deskctl height`.
    public static func formatHeight(_ status: StatusResult) -> String {
        status.heightDisplay ?? "unknown"
    }

    // MARK: - Private

    private static func unit(of status: StatusResult) -> HeightUnit {
        HeightUnit(rawValue: status.unit) ?? .cm
    }

    private static func formatPresets(_ presets: [PresetInfo], active: Int?, unit: HeightUnit) -> String {
        presets.map { preset in
            let height = preset.heightMM.map { HeightConverter.display(mm: $0, unit: unit) } ?? "unset"
            let marker = (preset.index == active) ? "*" : ""
            let label = preset.label.map { " \($0)" } ?? ""
            return "\(preset.index)=\(height)\(marker)\(label)"
        }.joined(separator: "  ")
    }

    private static func warningText(faultCode: Int?) -> String {
        switch faultCode {
        case 0x1d: return "desk needs re-initialisation - hold DOWN until it reaches the bottom and resets (control box shows Initialise)"
        case 0x1e: return "desk needs a reset on the control box (E16, illegal key combination)"
        case 0x17: return "possible hardware fault in a desk leg - check the cables (E26, channel 4 missing)"
        default:   return "desk stopped moving - may need a manual reset on the control box"
        }
    }

    private static func mapServerCode(_ code: Int) -> CLIExitCode {
        switch code {
        case 2: return .daemonNotRunning
        case 3: return .notConnected
        case 5: return .timeout
        default: return .general
        }
    }
}
