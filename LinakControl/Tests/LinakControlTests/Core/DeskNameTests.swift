// DeskNameTests.swift
// LinakControlTests — Verifies the paired desk name is refreshed from the connected
// peripheral. CoreBluetooth withholds peripheral.name during a service-filtered scan,
// so pairing can persist a placeholder that only the post-connect refresh can correct.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

private func makeHandshakeMock(connectedName: String?) -> MockBLEController {
    let mock = MockBLEController()
    mock.mockConnectedName = connectedName
    mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
    mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
    mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(
        responses: HandshakeFixtures.happyPathDPGResponses
    )
    mock.mockNotificationStreams[DeskUUID.height] = makeDPGStream(
        responses: [HandshakeFixtures.heightNotification730mm]
    )
    return mock
}

final class DeskNameRefreshTests: XCTestCase {

    func testConnectOverwritesPersistedPlaceholderName() async throws {
        let mock = makeHandshakeMock(connectedName: "DESK 3424")
        let store = makeTempConfigStore(config: AppConfig(pairedDeskName: "Unknown"))
        let manager = DeskManager(bleController: mock, configStore: store)

        try await manager.connect(peripheralId: UUID())

        let state = await manager.currentState
        XCTAssertEqual(state.deskName, "DESK 3424")
        XCTAssertEqual(try store.load().pairedDeskName, "DESK 3424")
    }

    func testConnectKeepsPersistedNameWhenPeripheralHasNone() async throws {
        let mock = makeHandshakeMock(connectedName: nil)
        let store = makeTempConfigStore(config: AppConfig(pairedDeskName: "Unknown"))
        let manager = DeskManager(bleController: mock, configStore: store)

        try await manager.connect(peripheralId: UUID())

        let state = await manager.currentState
        XCTAssertEqual(state.deskName, "Unknown")
        XCTAssertEqual(try store.load().pairedDeskName, "Unknown")
    }

    func testRefreshedNameReachesStatusOutput() async throws {
        let mock = makeHandshakeMock(connectedName: "DESK 3424")
        let store = makeTempConfigStore(config: AppConfig(pairedDeskName: "Unknown"))
        let manager = DeskManager(bleController: mock, configStore: store)

        try await manager.connect(peripheralId: UUID())

        let server = IPCServer(deskManager: manager, configStore: store)
        let status = await server.buildStatusResult(from: manager.currentState, config: try store.load())
        XCTAssertTrue(
            CLIFormatter.formatStatus(status).contains("  Desk:       DESK 3424"),
            "status should name the connected desk"
        )
    }
}

// MARK: - User-set name

final class UserDeskNameTests: XCTestCase {

    func testUserNameWinsOverLearnedName() async throws {
        let mock = makeHandshakeMock(connectedName: "DESK 3424")
        var config = AppConfig(pairedDeskName: "Unknown")
        config.setUserDeskName("Standing Desk")
        let store = makeTempConfigStore(config: config)
        let manager = DeskManager(bleController: mock, configStore: store)

        try await manager.connect(peripheralId: UUID())

        let saved = try store.load()
        XCTAssertEqual(saved.userDeskName, "Standing Desk")
        XCTAssertEqual(saved.pairedDeskName, "DESK 3424", "the learned name is still refreshed")
        let state = await manager.currentState
        XCTAssertEqual(state.deskName, "Standing Desk")
    }

    func testClearedUserNameFallsBackToLearnedName() {
        var config = AppConfig(pairedDeskName: "DESK 3424")
        config.setUserDeskName("Standing Desk")

        config.setUserDeskName(nil)

        XCTAssertNil(config.userDeskName)
        XCTAssertEqual(config.resolvedDeskName, "DESK 3424")
    }

    func testBlankUserNameClearsRatherThanNamingTheDeskEmpty() {
        var config = AppConfig(pairedDeskName: "DESK 3424")

        config.setUserDeskName("   ")

        XCTAssertNil(config.userDeskName)
        XCTAssertEqual(config.resolvedDeskName, "DESK 3424")
    }

    func testUserNameSurvivesAConfigRoundTrip() throws {
        var config = AppConfig(pairedDeskName: "DESK 3424")
        config.setUserDeskName("Standing Desk")
        let store = makeTempConfigStore()

        try store.save(config)

        let loaded = try store.load()
        XCTAssertEqual(loaded.userDeskName, "Standing Desk")
        XCTAssertEqual(loaded.pairedDeskName, "DESK 3424")
    }

    func testUserNameReachesStatusOutputWithoutReconnecting() async throws {
        let mock = makeHandshakeMock(connectedName: "DESK 3424")
        let store = makeTempConfigStore(config: AppConfig(pairedDeskName: "Unknown"))
        let manager = DeskManager(bleController: mock, configStore: store)
        try await manager.connect(peripheralId: UUID())

        var renamed = try store.load()
        renamed.setUserDeskName("Standing Desk")
        try store.save(renamed)

        let server = IPCServer(deskManager: manager, configStore: store)
        let status = await server.buildStatusResult(from: manager.currentState, config: try store.load())
        XCTAssertTrue(
            CLIFormatter.formatStatus(status).contains("  Desk:       Standing Desk"),
            "status should use the user-set name"
        )
    }
}
