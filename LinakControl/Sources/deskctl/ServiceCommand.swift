// ServiceCommand.swift
// deskctl service <status|stop|install>

import ArgumentParser
import Foundation
import Darwin
import LinakControlKit

struct ServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage the LinakControl daemon.",
        subcommands: [
            ServiceStatusCommand.self,
            ServiceStopCommand.self,
            ServiceInstallCommand.self,
        ]
    )
}

// MARK: - deskctl service status

struct ServiceStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon status."
    )

    func run() throws {
        let client = IPCClient()
        do {
            let status = try client.getStatus()
            let connectionLabel = status.connected ? "connected" : "disconnected"
            print("Daemon: running (\(connectionLabel))")
        } catch IPCClientError.daemonNotRunning {
            print("Daemon: not running")
        } catch let error as IPCClientError {
            let (msg, code) = CLIFormatter.formatError(error, json: false)
            CLIFormatter.printError(msg)
            throw ExitCode(code.rawValue)
        }
    }
}

// MARK: - deskctl service stop

struct ServiceStopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the LinakControl daemon."
    )

    func run() throws {
        guard let pid = findDaemonPID() else {
            print("Daemon: not running")
            return
        }
        if kill(pid, SIGTERM) == 0 {
            print("Sent SIGTERM to daemon (pid \(pid)).")
        } else {
            CLIFormatter.printError("error: failed to stop daemon (pid \(pid)): \(String(cString: strerror(errno)))")
            throw ExitCode(CLIExitCode.general.rawValue)
        }
    }

    private func findDaemonPID() -> pid_t? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-xo", "pid,comm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.components(separatedBy: "\n") {
            if line.contains("LinakControl") && !line.contains("deskctl") {
                let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
                if let pidStr = parts.first, let pid = pid_t(pidStr) {
                    return pid
                }
            }
        }
        return nil
    }
}

// MARK: - deskctl service install

struct ServiceInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Show instructions for enabling start-at-login."
    )

    func run() throws {
        print("""
        To start LinakControl automatically at login:

          1. Open Deskon.app
          2. Click the menu bar icon
          3. Open Settings
          4. Enable "Start at Login"

        The daemon will then start automatically each time you log in.
        """)
    }
}
