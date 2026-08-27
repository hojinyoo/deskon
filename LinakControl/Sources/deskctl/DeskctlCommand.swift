// DeskctlCommand.swift
// deskctl — Root command definition with all subcommands registered.

import ArgumentParser
import Foundation
import LinakControlKit

@main
struct DeskctlCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deskctl",
        abstract: "Control your LINAK standing desk from the terminal.",
        version: "1.0.0",
        subcommands: [
            StatusCommand.self,
            HeightCommand.self,
            UpCommand.self,
            DownCommand.self,
            StopCommand.self,
            PresetCommand.self,
            GotoCommand.self,
            ToggleCommand.self,
            ConfigCommand.self,
            ServiceCommand.self,
        ]
    )

    static func main() {
        rejectNegativeHeight()
        Self.main(nil)
    }

    /// argument-parser reads any leading-dash token as an option, so a typed negative
    /// height dies as "Unknown option '-5'" before GotoCommand ever sees it.
    private static func rejectNegativeHeight() {
        let args = CommandLine.arguments.dropFirst()
        guard args.first == "goto", args.count == 2,
              let last = args.last, let value = Double(last), value < 0 else { return }
        CLIFormatter.printError("Height must be above 0, and \(last) is not.")
        Foundation.exit(ExitCode.validationFailure.rawValue)
    }
}
