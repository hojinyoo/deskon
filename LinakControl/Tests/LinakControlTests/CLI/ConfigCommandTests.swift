// ConfigCommandTests.swift
// LinakControlTests — Verifies deskctl config subcommand behavior.

import XCTest
@testable import LinakControlKit

// MARK: - Config Show Tests

final class ConfigShowTests: XCTestCase {

    func testConfigShowLoadsDefaultWhenEmpty() throws {
        let store = makeTempConfigStore()
        try store.save(.default)
        let config = try store.load()
        XCTAssertEqual(config.unit, .cm)
        XCTAssertNil(config.pairedDeskUUID)
        XCTAssertTrue(config.showZone2)
    }

    func testConfigShowLoadsExistingConfig() throws {
        let store = makeTempConfigStore()
        var config = AppConfig.default
        config.pairedDeskUUID = "TEST-UUID"
        config.deskOffsetMM = 660
        config.showZone2 = false
        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.pairedDeskUUID, "TEST-UUID")
        XCTAssertEqual(loaded.deskOffsetMM, 660)
        XCTAssertFalse(loaded.showZone2)
    }
}

// MARK: - Config Reset Tests

final class ConfigResetTests: XCTestCase {

    func testConfigResetClearsAllSettings() throws {
        let store = makeTempConfigStore()
        var config = AppConfig.default
        config.pairedDeskUUID = "TEST-UUID"
        config.deskOffsetMM = 660
        config.hotkeysEnabled = true
        config.showZone2 = false
        try store.save(config)

        // Reset
        try store.save(.default)

        let loaded = try store.load()
        XCTAssertNil(loaded.pairedDeskUUID)
        XCTAssertEqual(loaded.deskOffsetMM, 0)
        XCTAssertFalse(loaded.hotkeysEnabled)
        XCTAssertTrue(loaded.showZone2)
    }
}

// MARK: - Config Label Tests

final class ConfigLabelTests: XCTestCase {

    func testSetPresetLabel() throws {
        let store = makeTempConfigStore()
        try store.save(.default)

        var config = try store.load()
        config.presetLabels[0] = "Sitting"
        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.presetLabels[0], "Sitting")
        XCTAssertNil(loaded.presetLabels[1])
    }

    func testClearPresetLabel() throws {
        let store = makeTempConfigStore()
        var config = AppConfig.default
        config.presetLabels[1] = "Standing"
        try store.save(config)

        var loaded = try store.load()
        loaded.presetLabels[1] = nil
        try store.save(loaded)

        let final = try store.load()
        XCTAssertNil(final.presetLabels[1])
    }

    func testPresetLabelBoundsCheck() throws {
        let store = makeTempConfigStore()
        var config = AppConfig.default
        // Array should have exactly 4 slots
        XCTAssertEqual(config.presetLabels.count, 4)

        // Set all 4 labels
        for i in 0..<4 {
            config.presetLabels[i] = "Preset \(i + 1)"
        }
        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.presetLabels.count, 4)
        XCTAssertEqual(loaded.presetLabels[3], "Preset 4")
    }
}

// MARK: - Helpers

private func makeTempConfigStore() -> ConfigStore {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ConfigCommandTests-\(UUID().uuidString)")
    return ConfigStore(directoryURL: tempDir)
}

// MARK: - Stroke bound

final class MaxStrokeConfigTests: XCTestCase {

    func testDefaultsToTheAutoUpTarget() {
        XCTAssertEqual(AppConfig.default.maxStrokeMM, 650)
    }

    /// Configs written before the key existed must still load.
    func testAConfigWithoutTheKeyDecodesToTheDefault() throws {
        let json = Data(#"{"unit":"cm","desk_offset_mm":680}"#.utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: json)
        XCTAssertEqual(config.maxStrokeMM, 650)
        XCTAssertEqual(config.deskOffsetMM, 680)
    }

    func testTheKeyRoundTripsThroughTheStore() throws {
        let store = makeTempConfigStore()
        var config = AppConfig.default
        config.maxStrokeMM = 445
        try store.save(config)
        XCTAssertEqual(try store.load().maxStrokeMM, 445)
    }

    /// `deskctl config show` prints the config JSON, so the key has to be in it.
    func testTheKeyIsEncoded() throws {
        let data = try JSONEncoder().encode(AppConfig.default)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("max_stroke_mm"))
    }
}
