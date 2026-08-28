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

        A target the desk cannot reach is refused before anything is sent. The
        desk reports its lowest position but not its travel, so the top of the
        range is `desk_offset_mm + max_stroke_mm`. max_stroke_mm defaults to
        650, the raw height the up button already drives to; set it to your
        desk's own travel to tighten the check.

        Example:
          deskctl goto 110.5
        """
    )

    @Argument(help: "Target height in the configured unit.")
    var height: Double

    func run() throws {
        let unit = configuredUnit()
        guard let targetMM = HeightConverter.millimeters(from: height, unit: unit), targetMM >= 0 else {
            CLIFormatter.printError(negativeHeightMessage("\(height)"))
            throw ExitCode.validationFailure
        }
        let reached = try runIPC { try $0.goTo(heightMM: targetMM) }
        print("Moving to \(HeightConverter.display(mm: reached ?? targetMM, unit: unit))...")
    }
}
