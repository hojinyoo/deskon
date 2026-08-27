// GotoCommand.swift
// deskctl goto <height>

import ArgumentParser
import Foundation
import LinakControlKit

struct GotoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "goto",
        abstract: "Move to an absolute height, in the configured unit.",
        discussion: """
        The height is read in the unit from `deskctl config show`, and is the
        height `deskctl status` reports, not the desk's raw value.

        Example:
          deskctl goto 110.5
        """
    )

    @Argument(help: "Target height in the configured unit.")
    var height: Double

    func run() throws {
        let unit = configuredUnit()
        let targetMM = HeightConverter.millimeters(from: height, unit: unit)
        let reached = try runIPC { try $0.goTo(heightMM: targetMM) }
        print("Moving to \(HeightConverter.display(mm: reached ?? targetMM, unit: unit))...")
    }
}
