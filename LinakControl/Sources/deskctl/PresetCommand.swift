// PresetCommand.swift
// deskctl preset <index> [--save]

import ArgumentParser
import Foundation
import LinakControlKit

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset",
        abstract: "Move to or save a desk preset (1-4)."
    )

    @Argument(help: "Preset index (1-4).", transform: { rawValue throws -> Int in
        guard let index = Int(rawValue), (1...4).contains(index) else {
            throw ValidationError("Preset index must be 1, 2, 3, or 4.")
        }
        return index
    })
    var index: Int

    @Flag(name: .long, help: "Save current height to the specified preset.")
    var save = false

    func run() throws {
        if save {
            _ = try runIPC { try $0.savePreset(index: index) }
            print("Saved current height to preset \(index).")
        } else {
            let targetMM = try runIPC { try $0.goPreset(index: index) }
            let heightStr = targetMM.map { HeightConverter.display(mm: $0, unit: configuredUnit()) } ?? "unknown"
            print("Moving to preset \(index) (\(heightStr))...")
        }
    }
}
