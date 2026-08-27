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
