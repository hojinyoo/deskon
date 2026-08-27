// ConfigCommand.swift
// deskctl config <show|reset|label|name>

import ArgumentParser
import Foundation
import LinakControlKit

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Manage LinakControl configuration.",
        subcommands: [
            ConfigShowCommand.self,
            ConfigResetCommand.self,
            ConfigLabelCommand.self,
            ConfigNameCommand.self,
        ]
    )
}

// MARK: - deskctl config show

struct ConfigShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the current configuration."
    )

    func run() throws {
        let store = ConfigStore()
        let config = try store.load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

// MARK: - deskctl config reset

struct ConfigResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset configuration to defaults (clears pairing, offset, and all settings)."
    )

    @Flag(name: .long, help: "Skip confirmation prompt.")
    var force: Bool = false

    func run() throws {
        if !force {
            print("This will reset all settings including pairing info.")
            print("The app will need to re-pair with the desk on next launch.")
            print("Continue? [y/N] ", terminator: "")
            guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
                print("Aborted.")
                return
            }
        }

        let store = ConfigStore()
        try store.save(.default)
        print("Configuration reset to defaults.")
    }
}

// MARK: - deskctl config label

struct ConfigLabelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "label",
        abstract: "Set or clear a preset label.",
        discussion: """
        Examples:
          deskctl config label 1 Sitting
          deskctl config label 2 Standing
          deskctl config label 3 --clear
        """
    )

    @Argument(help: "Preset index (1-4).")
    var index: Int

    @Argument(help: "Label text. Omit to show current label.")
    var text: String?

    @Flag(name: .long, help: "Remove the label for this preset.")
    var clear: Bool = false

    func run() throws {
        guard (1...4).contains(index) else {
            print("Error: preset index must be 1-4.")
            throw ExitCode.failure
        }

        let store = ConfigStore()
        var config = (try? store.load()) ?? .default

        if clear {
            config.presetLabels[index - 1] = nil
            try store.save(config)
            print("Preset \(index) label cleared.")
        } else if let text {
            config.presetLabels[index - 1] = text
            try store.save(config)
            print("Preset \(index) label set to \"\(text)\".")
        } else {
            let label = config.presetLabels[index - 1] ?? "(none)"
            print("Preset \(index): \(label)")
        }
    }
}

// MARK: - deskctl config name

struct ConfigNameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "name",
        abstract: "Set or clear the desk name.",
        discussion: """
        The name set here wins over the name learned from the desk over BLE;
        clearing it falls back to that learned name.

        Examples:
          deskctl config name "Standing Desk"
          deskctl config name --clear
        """
    )

    @Argument(help: "Desk name. Omit to show the current name.")
    var text: String?

    @Flag(name: .long, help: "Remove the name you set and fall back to the learned one.")
    var clear: Bool = false

    func run() throws {
        let store = ConfigStore()
        var config = (try? store.load()) ?? .default

        guard clear || text != nil else {
            print("Desk: \(config.resolvedDeskName ?? "(none)")")
            return
        }

        config.setUserDeskName(clear ? nil : text)
        try store.save(config)

        if let name = config.userDeskName {
            print("Desk name set to \"\(name)\".")
        } else {
            print("Desk name cleared. Using \(config.pairedDeskName ?? "the name learned over BLE").")
        }
    }
}
