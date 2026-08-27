// DeskManagerReconnectionTests.swift
// LinakControlTests - Tests for reconnection and wake-up behavior.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Shared Fixtures

private let pairedDeskUUID = UUID()

// MARK: - Test Factories

// makeTempConfigStore is provided by TestHelpers.swift (with pairedUUID: parameter)

private func makeManager(
    mock: MockBLEController,
    clock: TestClock,
    pairedUUID: UUID = pairedDeskUUID
) -> DeskManager {
    let store = makeTempConfigStore(pairedUUID: pairedUUID)
    return DeskManager(bleController: mock, configStore: store, clock: clock)
}

private func makeConnectedManager(
    mock: MockBLEController,
    clock: TestClock,
    pairedUUID: UUID = pairedDeskUUID
) async throws -> DeskManager {
    configureHappyPath(mock)
    let manager = makeManager(mock: mock, clock: clock, pairedUUID: pairedUUID)
    try await manager.connect(peripheralId: pairedUUID)
    return manager
}

private func configureHappyPath(_ mock: MockBLEController) {
    mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
    mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
    mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(
        responses: HandshakeFixtures.happyPathDPGResponses
    )
    mock.mockNotificationStreams[DeskUUID.height] = makeFiniteHeightStream(
        values: [HandshakeFixtures.heightNotification730mm]
    )
}

// makeDPGStream is provided by TestHelpers.swift

private func makeFiniteHeightStream(values: [Data]) -> AsyncStream<Data> {
    makeDPGStream(responses: values)
}

// MARK: - Reconnection Backoff Tests

final class DeskManagerReconnectionBackoffTests: XCTestCase {

    func testReconnectionStartsAfterFirstBackoffWindow() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.shouldFailConnect = true
        let countBeforeDisconnect = mock.connectCallCount

        await manager.handleDisconnection()

        // Before 1s — no reconnection attempt
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.connectCallCount, countBeforeDisconnect,
            "Should not reconnect before the 1s window")

        // Advance 1s — first attempt fires
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mock.connectCallCount, countBeforeDisconnect + 1,
            "Should attempt reconnect after 1s")

        await manager.disconnect()
    }

    func testReconnectionBackoffDoublesOnEachFailure() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.shouldFailConnect = true
        let base = mock.connectCallCount

        await manager.handleDisconnection()

        // Allow the reconnection task to start and register its first clock.sleep.
        try await Task.sleep(for: .milliseconds(50))

        // Attempt 1 — after 1s
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.connectCallCount, base + 1)

        // Attempt 2 — after another 2s
        clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.connectCallCount, base + 2)

        // Attempt 3 — after another 4s
        clock.advance(by: .seconds(4))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.connectCallCount, base + 3)

        // Attempt 4 — after another 8s
        clock.advance(by: .seconds(8))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(mock.connectCallCount, base + 4)

        await manager.disconnect()
    }

    func testBackoffIsCappedAt60Seconds() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.shouldFailConnect = true
        await manager.handleDisconnection()

        // Drive through 6 failures using actual backoff: 1, 2, 4, 8, 16, 32
        for i in 0..<6 {
            let delay = 1 << i  // 1, 2, 4, 8, 16, 32
            clock.advance(by: .seconds(delay))
            try await Task.sleep(for: .milliseconds(50))
        }

        let attemptsAfterSixFailures = mock.connectCallCount

        // 7th attempt should fire after 60s (capped from 64)
        clock.advance(by: .seconds(60))
        try await Task.sleep(for: .milliseconds(50))

        // 8th attempt also after 60s
        clock.advance(by: .seconds(60))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mock.connectCallCount, attemptsAfterSixFailures + 2,
            "After cap, each 60s window produces exactly one attempt")

        await manager.disconnect()
    }

    func testReconnectSuccessAfterTwoFailures() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.shouldFailConnect = true
        await manager.handleDisconnection()

        // Fail attempt 1
        clock.advance(by: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))

        // Fail attempt 2
        clock.advance(by: .seconds(2))
        try await Task.sleep(for: .milliseconds(50))

        // Configure success for attempt 3
        mock.shouldFailConnect = false
        configureHappyPath(mock)

        clock.advance(by: .seconds(4))
        try await Task.sleep(for: .milliseconds(100))

        let state = await manager.currentState
        XCTAssertEqual(state.connectionState, .connected,
            "Should be connected after successful reconnect on attempt 3")
    }

    func testUserDisconnectCancelsReconnection() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.shouldFailConnect = true
        await manager.handleDisconnection()

        // User disconnects before any retry fires
        await manager.disconnect()
        let countAfterUserDisconnect = mock.connectCallCount

        // Advance past the backoff window
        clock.advance(by: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mock.connectCallCount, countAfterUserDisconnect,
            "Reconnection task should be cancelled when user disconnects")
    }
}

// MARK: - Wake-Up Sequence Tests

final class DeskManagerWakeUpTests: XCTestCase {

    func testWakeUpWritesFE00ThenFF00() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        // Height read succeeds so desk "responds" on first attempt
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm

        let store = makeTempConfigStore()
        let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

        try await manager.wakeUpDesk()

        let commandWrites = mock.writtenData.filter { $0.characteristic == DeskUUID.command }
        XCTAssertGreaterThanOrEqual(commandWrites.count, 2,
            "Should write at least wakeUp + stop")
        XCTAssertEqual(commandWrites[0].data, DeskCommand.wakeUp, "First write must be FE 00")
        XCTAssertEqual(commandWrites[1].data, DeskCommand.stop, "Second write must be FF 00")
    }

    func testWakeUpSucceedsWhenDeskRespondsOnFirstAttempt() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm

        let store = makeTempConfigStore()
        let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

        // Should not throw
        try await manager.wakeUpDesk()
    }

    func testWakeUpThrowsWakeUpFailedWhenDeskNeverResponds() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        // No height read response — deskIsResponding() returns false every time

        let store = makeTempConfigStore()
        let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

        do {
            try await manager.wakeUpDesk()
            XCTFail("Expected DeskError.wakeUpFailed")
        } catch DeskError.wakeUpFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWakeUpSendsThreeAttemptsBeforeGivingUp() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        // No height read response — all 3 attempts will fail

        let store = makeTempConfigStore()
        let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

        try? await manager.wakeUpDesk()

        let wakeWrites = mock.writtenData.filter {
            $0.characteristic == DeskUUID.command && $0.data == DeskCommand.wakeUp
        }
        let stopWrites = mock.writtenData.filter {
            $0.characteristic == DeskUUID.command && $0.data == DeskCommand.stop
        }

        XCTAssertEqual(wakeWrites.count, 3, "Should send FE 00 exactly three times")
        XCTAssertEqual(stopWrites.count, 3, "Should send FF 00 exactly three times")
    }
}

// MARK: - Idle Silence

final class DeskManagerIdleSilenceTests: XCTestCase {

    /// Writing reference input on a timer tells the desk it is being driven remotely, and
    /// it locks out its own panel for as long as that continues. A connected app that is
    /// not moving the desk must therefore write nothing at all.
    func testConnectedAndIdleWritesNothing() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.writtenData.removeAll()
        clock.advance(by: .seconds(600))
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            mock.writtenData.map(\.characteristic), [],
            "an idle connection must leave the desk panel alone"
        )

        await manager.disconnect()
    }
}
