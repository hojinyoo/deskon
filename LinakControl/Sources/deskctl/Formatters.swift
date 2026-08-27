// Formatters.swift
// deskctl — CLI-side IPC helper that wraps CLIFormatter from LinakControlKit.

import ArgumentParser
import Foundation
import LinakControlKit

// MARK: - OutputFormatter (deskctl alias)

/// Convenience alias — deskctl commands use this; logic lives in LinakControlKit.CLIFormatter.
typealias OutputFormatter = CLIFormatter

// MARK: - IPC Helper

/// Run an IPC call, format any error to stderr, and exit with the mapped code.
func runIPC<T>(json: Bool = false, _ call: (IPCClient) throws -> T) throws -> T {
    let client = IPCClient()
    do {
        return try call(client)
    } catch let error as IPCClientError {
        let (msg, code) = CLIFormatter.formatError(error, json: json)
        CLIFormatter.printError(msg)
        throw ExitCode(code.rawValue)
    }
}

// MARK: - Unit

/// The unit heights are printed in, for commands whose reply carries a bare height.
func configuredUnit() -> HeightUnit {
    ((try? ConfigStore().load()) ?? .default).unit
}

// MARK: - Height input

/// One message for a typed height that cannot be a height, whether it was caught before
/// parsing (`goto -5`, which argument-parser reads as an option) or after (`goto inf`,
/// which parses as a Double and would trap on the way to Int).
func negativeHeightMessage(_ typed: String) -> String {
    "Height must be a number above 0, and \(typed) is not."
}
