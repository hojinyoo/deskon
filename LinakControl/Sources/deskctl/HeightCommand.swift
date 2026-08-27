// HeightCommand.swift
// deskctl height [--json]

import ArgumentParser
import Foundation
import LinakControlKit

struct HeightCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "height",
        abstract: "Print the current desk height."
    )

    @Flag(name: .long, help: "Output as JSON.")
    var json = false

    func run() throws {
        let status = try runIPC(json: json) { try $0.getStatus() }
        if json {
            printJSON(status)
        } else {
            printPlain(status)
        }
    }

    // MARK: - Formatters

    private func printPlain(_ status: StatusResult) {
        print(OutputFormatter.formatHeight(status))
    }

    private func printJSON(_ status: StatusResult) {
        let heightMM = status.heightMM ?? 0
        let display = status.heightDisplay ?? "0.0"
        let unit = status.unit
        print(#"{"height_mm": \#(heightMM), "height_display": "\#(display)", "unit": "\#(unit)"}"#)
    }
}
