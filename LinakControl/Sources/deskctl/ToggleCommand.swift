// ToggleCommand.swift
// deskctl toggle

import ArgumentParser
import Foundation
import LinakControlKit

struct ToggleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toggle",
        abstract: "Switch between preset 1 and preset 2.",
        discussion: """
        Moves to whichever of the two the desk is not currently at, so a repeated
        toggle alternates sitting and standing. Both presets must be set.
        """
    )

    func run() throws {
        let status = try runIPC { try $0.getStatus() }
        let target = try targetPreset(for: status)
        let reached = try runIPC { try $0.goPreset(index: target) }
        let unit = HeightUnit(rawValue: status.unit) ?? .cm
        let shown = reached.map { HeightConverter.display(mm: $0, unit: unit) } ?? "preset \(target)"
        print("Moving to \(shown)...")
    }

    private func targetPreset(for status: StatusResult) throws -> Int {
        let sit = try presetHeight(1, in: status)
        let stand = try presetHeight(2, in: status)
        guard let current = status.heightMM else {
            CLIFormatter.printError("Desk height is unknown. Is the desk connected?")
            throw ExitCode.failure
        }
        return toggleTarget(height: current, sitMM: sit, standMM: stand)
    }

    private func presetHeight(_ index: Int, in status: StatusResult) throws -> Int {
        guard let height = status.presets.first(where: { $0.index == index })?.heightMM else {
            CLIFormatter.printError(
                "Preset \(index) is not set. Save it with: deskctl preset \(index) --save"
            )
            throw ExitCode.failure
        }
        return height
    }
}
