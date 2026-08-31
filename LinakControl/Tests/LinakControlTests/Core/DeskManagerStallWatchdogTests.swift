// DeskManagerStallWatchdogTests.swift
// LinakControlTests — Verifies the movement stall watchdog (issue #1): when the
// desk stops responding to move commands, the loop stops hammering it and raises
// needsReference instead of writing forever.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Test Helpers

/// A connected DeskManager driven by a TestClock and a controllable height stream.
private struct StallTestSetup {
    let manager: DeskManager
    let mock: MockBLEController
    let heightCont: AsyncStream<Data>.Continuation
    let clock: TestClock
}

/// Builds a connected DeskManager whose movement-loop timing is driven by a
/// TestClock, so the stall timeout can be crossed deterministically by advancing
/// the clock rather than sleeping in real time.
private func makeStallTestSetup() async throws -> StallTestSetup {
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
    let store = makeTempConfigStore()
    let manager = DeskManager(bleController: mock, configStore: store, clock: clock)

    // Emit the initial height so the handshake completes, then wait for connect.
    let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
    heightCont.yield(makeHeightPacket(mm: 730))
    try await connectTask.value

    return StallTestSetup(manager: manager, mock: mock, heightCont: heightCont, clock: clock)
}

private func moveUpCount(_ mock: MockBLEController) -> Int {
    mock.writtenData.filter {
        $0.characteristic == DeskUUID.command && $0.data == DeskCommand.moveUp
    }.count
}

private func stopCount(_ mock: MockBLEController) -> Int {
    mock.writtenData.filter {
        $0.characteristic == DeskUUID.command && $0.data == DeskCommand.stop
    }.count
}

// MARK: - Stall Detection Tests

final class DeskManagerStallWatchdogTests: XCTestCase {

    func testManualMoveStallSetsNeedsReferenceAndStops() async throws {
        let setup = try await makeStallTestSetup()

        try await setup.manager.moveUp(mode: .manual)
        // Let the loop write once and park at its clock.sleep waiter.
        try await Task.sleep(for: .milliseconds(50))
        let movesBefore = moveUpCount(setup.mock)

        // Height never changes → cross the stall timeout in one advance.
        setup.clock.advance(by: .milliseconds(2100))
        await waitFor { await setup.manager.currentState.needsReference }

        let state = await setup.manager.currentState
        XCTAssertTrue(state.needsReference, "Stall must set needsReference")
        XCTAssertFalse(state.isMoving, "Stall must clear isMoving")

        // Stall must send stop twice (stop hammering the blocked module).
        XCTAssertGreaterThanOrEqual(stopCount(setup.mock), 2, "Stall must send stop twice")

        // The loop must not keep writing move commands after the stall.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertLessThanOrEqual(
            moveUpCount(setup.mock) - movesBefore, 1,
            "Movement loop must stop after a stall"
        )
    }

    func testContinuousProgressDoesNotStall() async throws {
        let setup = try await makeStallTestSetup()

        try await setup.manager.moveUp(mode: .manual)
        try await Task.sleep(for: .milliseconds(50))

        // Feed a changing height every 900ms — under the 2s window — across a
        // total span exceeding the stall timeout. Each observed change resets the
        // watchdog, so no stall must fire.
        var height = 730
        for _ in 0..<4 {
            height += 5
            setup.heightCont.yield(makeHeightPacket(mm: height, speedMMS: 20))
            await waitFor { await setup.manager.currentState.heightMM == height }
            setup.clock.advance(by: .milliseconds(900))
            try await Task.sleep(for: .milliseconds(30))
        }

        let state = await setup.manager.currentState
        XCTAssertFalse(state.needsReference, "Continuous height progress must not trigger a stall")

        try await setup.manager.stop()
    }

    func testNextMoveClearsNeedsReference() async throws {
        let setup = try await makeStallTestSetup()

        // Force a stall first.
        try await setup.manager.moveUp(mode: .manual)
        try await Task.sleep(for: .milliseconds(50))
        setup.clock.advance(by: .milliseconds(2100))
        await waitFor { await setup.manager.currentState.needsReference }
        let stalled = await setup.manager.currentState.needsReference
        XCTAssertTrue(stalled)

        // The next move attempt clears the flag optimistically.
        try await setup.manager.moveDown(mode: .manual)
        try await Task.sleep(for: .milliseconds(30))
        let cleared = await setup.manager.currentState.needsReference
        XCTAssertFalse(cleared, "A new move attempt must clear needsReference")

        try await setup.manager.stop()
    }

    /// Issue #8: an auto move targets the physical end-stop by design, so a
    /// *completed* auto move looks exactly like a stall — the desk arrives and
    /// stops sending height notifications. Arrival must not be reported as a
    /// fault, because `needsReference` now also stands the connection down.
    func testAutoMoveArrivalDoesNotSetNeedsReference() async throws {
        let setup = try await makeStallTestSetup()

        try await setup.manager.moveUp(mode: .auto)
        // Let the loop write once and park at its clock.sleep waiter.
        try await Task.sleep(for: .milliseconds(50))

        // The desk climbs toward its end-stop, well inside the 2s window.
        var height = 730
        for _ in 0..<4 {
            height += 5
            setup.heightCont.yield(makeHeightPacket(mm: height, speedMMS: 20))
            await waitFor { await setup.manager.currentState.heightMM == height }
            setup.clock.advance(by: .milliseconds(500))
            try await Task.sleep(for: .milliseconds(30))
        }

        // Then it arrives and goes quiet, as a desk at its end-stop does.
        setup.clock.advance(by: .milliseconds(2100))
        await waitFor { stopCount(setup.mock) >= 2 }

        let state = await setup.manager.currentState
        XCTAssertFalse(
            state.needsReference,
            "Reaching the auto target / end-stop is not a fault"
        )
        XCTAssertNil(state.faultCode, "Arrival carries no fault code")
        XCTAssertFalse(state.isMoving, "Arrival must clear isMoving")
        XCTAssertGreaterThanOrEqual(
            stopCount(setup.mock), 2,
            "Arrival must still stop the desk and end the write loop"
        )
    }

    func testPresetRecallStallSetsNeedsReference() async throws {
        let setup = try await makeStallTestSetup()

        // goToPreset blocks on the preflight clock.sleep until the clock advances.
        let goTask = Task { try? await setup.manager.goToPreset(index: 2) }
        try await Task.sleep(for: .milliseconds(50))
        setup.clock.advance(by: .milliseconds(120))   // release preflight → loop starts
        _ = await goTask.value
        try await Task.sleep(for: .milliseconds(50))   // let the loop park at its sleep

        // Height never changes → the preset loop must stall well before the 30s timeout.
        setup.clock.advance(by: .milliseconds(2100))
        await waitFor { await setup.manager.currentState.needsReference }

        let state = await setup.manager.currentState
        XCTAssertTrue(state.needsReference, "Preset recall stall must raise needsReference")
        XCTAssertFalse(state.isMoving, "Preset stall must clear isMoving immediately, not via the delayed settle")
        XCTAssertNil(state.targetPreset, "Preset stall must clear the target")
        XCTAssertNil(state.faultCode, "A timing stall carries no fault code")

        // Let clearPresetMoveState's settle sleep finish.
        setup.clock.advance(by: .milliseconds(600))
    }
}
