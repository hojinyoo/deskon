// StatusCommand.swift
// deskctl status [--json]

import ArgumentParser
import Foundation
import LinakControlKit

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show desk and daemon status."
    )

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    func run() throws {
        let status = try runIPC(json: json) { try $0.getStatus() }
        if json {
            printJSON(status)
        } else {
            print(OutputFormatter.formatStatus(status))
        }
    }

    // MARK: - Formatters

    private func printJSON(_ status: StatusResult) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(status),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }
}
