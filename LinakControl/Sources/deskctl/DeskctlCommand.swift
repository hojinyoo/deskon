// DeskctlCommand.swift
// deskctl — Root command definition with all subcommands registered.

import ArgumentParser
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
}
