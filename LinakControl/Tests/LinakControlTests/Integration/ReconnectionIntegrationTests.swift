// ReconnectionIntegrationTests.swift
// LinakControlTests — Integration tests for reconnection logic, error recovery, and edge cases.
//
// Uses real DeskManager with MockBLEController to verify the full reconnection lifecycle
// including exponential backoff, movement state clearing, and multi-failure recovery.

import XCTest
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

// makeDPGStream is provided by TestHelpers.swift

private func makeFiniteHeightStream(values: [Data]) -> AsyncStream<Data> {
    makeDPGStream(responses: values)
}

// MARK: - Disconnect Triggers Reconnection with Backoff

final class ReconnectionBackoffIntegrationTests: XCTestCase {

    /// Verifies that an unexpected disconnect starts the reconnection loop and
    /// that attempts follow the exponential backoff schedule (1s, 2s, 4s).
    func testDisconnectTriggersReconnectionWithBackoff() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        // Put mock into fail-connect mode before triggering disconnect
        mock.shouldFailConnect = true
        let connectCountAtDisconnect = mock.connectCallCount

        await manager.handleDisconnection()

        // The loop must have parked its first backoff sleep before the clock
        // moves — an advance that lands earlier is simply lost, and the test
        // then hangs waiting for an attempt that will never fire.
        await waitFor { clock.pendingSleepers >= 1 }

        // Absence assertion: there is no condition to wait for, so this one
        // stays a wall-clock wait. A short wait here weakens the check rather
        // than making it flaky, which is the opposite trade-off to the rest.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            mock.connectCallCount, connectCountAtDisconnect,
            "No reconnect attempt should fire before the 1s backoff window"
        )

        // Advance 1s — first attempt fires
        clock.advance(by: .seconds(1))
        await waitFor { mock.connectCallCount == connectCountAtDisconnect + 1 }
        XCTAssertEqual(
            mock.connectCallCount, connectCountAtDisconnect + 1,
            "First reconnect attempt should fire after 1s"
        )

        // Advance 2s — second attempt fires
        await waitFor { clock.pendingSleepers >= 1 }
        clock.advance(by: .seconds(2))
        await waitFor { mock.connectCallCount == connectCountAtDisconnect + 2 }
        XCTAssertEqual(
            mock.connectCallCount, connectCountAtDisconnect + 2,
            "Second reconnect attempt should fire after additional 2s"
        )

        // Advance 4s — third attempt fires (backoff doubling: 4s)
        await waitFor { clock.pendingSleepers >= 1 }
        clock.advance(by: .seconds(4))
        await waitFor { mock.connectCallCount == connectCountAtDisconnect + 3 }
        XCTAssertEqual(
            mock.connectCallCount, connectCountAtDisconnect + 3,
            "Third reconnect attempt should fire after additional 4s"
        )

        // Allow mock to reconnect successfully
        mock.shouldFailConnect = false
        configureHappyPath(mock)

        await manager.disconnect()
    }

    /// Verifies that after a successful reconnect the manager transitions to .connected.
    func testDisconnectTransitionsThenReconnectsSuccessfully() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        // Disconnect — manager should go to .disconnected
        await manager.handleDisconnection()
        let stateAfterDisconnect = await manager.currentState
        XCTAssertEqual(
            stateAfterDisconnect.connectionState, .disconnected,
            "handleDisconnection should set connectionState to .disconnected"
        )

        await manager.disconnect()
    }
}

// MARK: - Disconnect During Movement Clears Movement State

final class ReconnectionDuringMovementIntegrationTests: XCTestCase {

    /// Verifies that an unexpected disconnect while moving clears isMoving and moveDirection,
    /// and that movement is NOT auto-resumed after reconnect.
    func testDisconnectDuringMovementClearsMovementState() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        // Wait for the single buffered stationary height notification (730mm,
        // speed 0) to be processed before moving — otherwise it can land after
        // moveUp and clear isMoving (the finite stream then emits nothing more).
        await waitFor { await manager.currentState.heightMM == 730 }

        // Start a manual move to put the manager into moving state
        try await manager.moveUp(mode: .manual)
        await waitFor { await manager.currentState.isMoving }

        let stateWhileMoving = await manager.currentState
        XCTAssertTrue(stateWhileMoving.isMoving, "Precondition: manager should be moving")
        XCTAssertEqual(stateWhileMoving.moveDirection, .up, "Precondition: direction should be up")

        // Simulate unexpected disconnect mid-movement
        await manager.handleDisconnection()
        await waitFor { await manager.currentState.isMoving == false }

        let stateAfterDisconnect = await manager.currentState
        XCTAssertFalse(
            stateAfterDisconnect.isMoving,
            "isMoving must be false after unexpected disconnect"
        )
        XCTAssertNil(
            stateAfterDisconnect.moveDirection,
            "moveDirection must be nil after unexpected disconnect"
        )

        // Allow reconnect to succeed
        configureHappyPath(mock)
        await waitFor { clock.pendingSleepers >= 1 }
        clock.advance(by: .seconds(1))
        await waitFor { await manager.currentState.connectionState == .connected }

        let stateAfterReconnect = await manager.currentState
        XCTAssertEqual(
            stateAfterReconnect.connectionState, .connected,
            "Manager should reconnect successfully"
        )
        XCTAssertFalse(
            stateAfterReconnect.isMoving,
            "Movement must NOT be auto-resumed after reconnect"
        )
        XCTAssertNil(
            stateAfterReconnect.moveDirection,
            "moveDirection must remain nil after reconnect — movement is not auto-resumed"
        )

        await manager.disconnect()
    }
}

// MARK: - Desk Busy State Handling

final class ReconnectionBusyStateIntegrationTests: XCTestCase {

    /// Verifies that a connection failure (simulating a busy or timed-out desk)
    /// leaves the manager in .disconnected state.
    func testDeskBusyStateHandling() async throws {
        let clock = TestClock()
        let mock = MockBLEController()

        // Configure mock to always fail connect — simulates desk busy / timeout
        mock.shouldFailConnect = true

        let store = makeTempConfigStore(pairedUUID: pairedDeskUUID)
        let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

        do {
            try await manager.connect(peripheralId: pairedDeskUUID)
            XCTFail("connect() should throw when mock is configured to fail")
        } catch {
            // Any error is acceptable — connection failed
        }

        let state = await manager.currentState
        XCTAssertEqual(
            state.connectionState, .disconnected,
            "Manager should be .disconnected after a failed connection attempt"
        )
        XCTAssertFalse(
            state.isMoving,
            "isMoving must be false when not connected"
        )
    }
}

// MARK: - Reconnect Success After Multiple Failures

final class ReconnectionMultipleFailuresIntegrationTests: XCTestCase {

    /// Verifies that after two failed reconnect attempts the manager eventually
    /// connects when the mock allows it, following the exponential backoff schedule.
    func testReconnectSuccessAfterMultipleFailures() async throws {
        let clock = TestClock()
        let mock = MockBLEController()
        let manager = try await makeConnectedManager(mock: mock, clock: clock)

        mock.shouldFailConnect = true
        let baseCount = mock.connectCallCount

        await manager.handleDisconnection()

        // Wait for the reconnection task to register its first clock.sleep —
        // this is the state the old 50ms guess was betting on.
        await waitFor { clock.pendingSleepers >= 1 }

        // Fail attempt 1 — backoff 1s
        clock.advance(by: .seconds(1))
        await waitFor { mock.connectCallCount == baseCount + 1 }
        XCTAssertEqual(mock.connectCallCount, baseCount + 1, "First attempt should have fired")

        // Fail attempt 2 — backoff 2s
        await waitFor { clock.pendingSleepers >= 1 }
        clock.advance(by: .seconds(2))
        await waitFor { mock.connectCallCount == baseCount + 2 }
        XCTAssertEqual(mock.connectCallCount, baseCount + 2, "Second attempt should have fired")

        // Allow the third attempt to succeed
        mock.shouldFailConnect = false
        configureHappyPath(mock)

        // Advance 4s — third attempt fires and succeeds
        await waitFor { clock.pendingSleepers >= 1 }
        clock.advance(by: .seconds(4))
        await waitFor { mock.connectCallCount == baseCount + 3 }

        XCTAssertEqual(
            mock.connectCallCount, baseCount + 3,
            "Third attempt should have fired after 4s backoff"
        )

        let state = await manager.currentState
        XCTAssertEqual(
            state.connectionState, .connected,
            "Manager should be .connected after successful reconnect on the third attempt"
        )
    }
}
