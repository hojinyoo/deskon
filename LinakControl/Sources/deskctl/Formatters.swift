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
