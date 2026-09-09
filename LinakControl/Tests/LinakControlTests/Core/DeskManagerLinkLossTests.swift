// DeskManagerLinkLossTests.swift
// LinakControlTests - What happens to a move, and to the app, when the BLE link
// drops. Two things must hold: the drop reaches DeskManager at all, and a move
// caught by it is not reported as a desk fault.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Test Helpers

private struct LinkLossSetup {
    let manager: DeskManager
    let mock: MockBLEController
    let heightCont: AsyncStream<Data>.Continuation
    let clock: TestClock
    let deskUUID: UUID
}

/// A connected DeskManager with a paired desk in config (so the reconnection
/// loop has somewhere to go) and a TestClock driving the control loops.
private func makeLinkLossSetup() async throws -> LinkLossSetup {
    var heightCont: AsyncStream<Data>.Continuation!
    let heightStream = AsyncStream<Data> { cont in heightCont = cont }

    let mock = MockBLEController()
    mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
    mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
    mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(
        responses: HandshakeFixtures.happyPathDPGResponses
    )
    mock.mockNotificationStreams[DeskUUID.height] = heightStream

    let clock = TestClock()
    let deskUUID = UUID()
    let store = makeTempConfigStore(tag: "LinkLoss", pairedUUID: deskUUID)
    let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

    let connectTask = Task { try await manager.connect(peripheralId: deskUUID) }
    heightCont.yield(makeHeightPacket(mm: 730))
    try await connectTask.value

    return LinkLossSetup(
        manager: manager,
        mock: mock,
        heightCont: heightCont,
        clock: clock,
        deskUUID: deskUUID
    )
}

private func targetWriteCount(_ mock: MockBLEController) -> Int {
    mock.writtenData.filter { $0.characteristic == DeskUUID.targetHeartbeat }.count
}

/// Starts a preset recall and returns once its control loop is running.
private func startRecall(_ setup: LinkLossSetup) async throws {
    let goTask = Task { try? await setup.manager.goToPreset(index: 2) }
    try await Task.sleep(for: .milliseconds(50))
    setup.clock.advance(by: .milliseconds(120))   // release the preflight sleep
    _ = await goTask.value
    try await Task.sleep(for: .milliseconds(50))  // let the loop park at its sleep
}

// MARK: - A move caught by a dropped link

final class DeskManagerLinkLossTests: XCTestCase {

    func testDroppedLinkMidMoveIsNotADeskFault() async throws {
        let setup = try await makeLinkLossSetup()

        try await setup.manager.moveUp(mode: .manual)
        try await Task.sleep(for: .milliseconds(50))

        // The link goes away: writes fail and no more height arrives.
        setup.mock.shouldFailWrite = true
        setup.clock.advance(by: .milliseconds(100))
        await waitFor { await setup.manager.currentState.isMoving == false }

        let state = await setup.manager.currentState
        XCTAssertFalse(state.isMoving, "A dropped link must end the move")
        XCTAssertFalse(state.needsReference, "A dropped link is not a desk fault")

        // The loop is gone, so crossing the stall window changes nothing.
        setup.clock.advance(by: .milliseconds(2100))
        try await Task.sleep(for: .milliseconds(100))
        let later = await setup.manager.currentState
        XCTAssertFalse(later.needsReference, "The stall watchdog must not fire after the loop stopped")
    }

    func testDroppedLinkDuringRecallIsNotADeskFault() async throws {
        let setup = try await makeLinkLossSetup()
        try await startRecall(setup)

        setup.mock.shouldFailWrite = true
        setup.clock.advance(by: .milliseconds(100))
        await waitFor { await setup.manager.currentState.isMoving == false }

        let state = await setup.manager.currentState
        XCTAssertFalse(state.isMoving, "A dropped link must end the recall")
        XCTAssertFalse(state.needsReference, "A dropped link is not a desk fault")
        XCTAssertNil(state.targetPreset, "A dropped link must clear the target")

        setup.clock.advance(by: .milliseconds(2100))
        try await Task.sleep(for: .milliseconds(100))
        let later = await setup.manager.currentState
        XCTAssertFalse(later.needsReference, "The stall watchdog must not fire after the loop stopped")
    }

    // MARK: - The drop reaching DeskManager

    func testBLEDropReachesTheManagerAndStartsReconnecting() async throws {
        let setup = try await makeLinkLossSetup()
        setup.mock.shouldFailConnect = true          // keep it disconnected
        let connectsBefore = setup.mock.connectCallCount

        setup.mock.emitDisconnection()
        await waitFor { await setup.manager.currentState.connectionState == .disconnected }

        let state = await setup.manager.currentState
        XCTAssertEqual(state.connectionState, .disconnected, "A BLE drop must reach DeskManager")

        // First backoff window is 1s. Wait for the loop to park on it: advancing
        // before the sleep is registered leaves it at a deadline the advance
        // already passed, and the reconnect never fires. Safe to key on the
        // count here because the backoff is the only thing on this clock at
        // this point - no move is running.
        await waitFor { setup.clock.pendingSleepers >= 1 }
        setup.clock.advance(by: .seconds(1))
        await waitFor { setup.mock.connectCallCount > connectsBefore }
        XCTAssertGreaterThan(
            setup.mock.connectCallCount, connectsBefore,
            "A BLE drop must start the reconnection loop"
        )

        await setup.manager.disconnect()
    }

    func testBLEDropStopsARecallInFlight() async throws {
        let setup = try await makeLinkLossSetup()
        setup.mock.shouldFailConnect = true
        try await startRecall(setup)

        setup.mock.emitDisconnection()
        await waitFor { await setup.manager.currentState.connectionState == .disconnected }
        try await Task.sleep(for: .milliseconds(100))
        let writesAtDrop = targetWriteCount(setup.mock)

        // The mock still accepts writes, so only a cancelled loop stops writing.
        setup.clock.advance(by: .milliseconds(500))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(
            targetWriteCount(setup.mock), writesAtDrop,
            "A recall must not outlive the connection"
        )

        await setup.manager.disconnect()
    }
}
