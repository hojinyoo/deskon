// DeskManagerFaultCodeGraceTests.swift
// LinakControlTests — Verifies the grace window before stand-down (issue #19).
//
// The 2s stall watchdog regularly beats the control box to the punch: both
// stalls observed on real hardware logged `faultCode: none`, yet the desk needed
// a manual re-reference afterwards. standDown() cancels the status listener, so
// a fault code arriving even slightly later used to be lost for good — leaving
// the recurring "the desk sometimes refuses to move" problem with no cause
// attached to it.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Helpers

private struct GraceTestSetup {
    let manager: DeskManager
    let clock: TestClock
    let poster: MockNotificationPoster
    let heightCont: AsyncStream<Data>.Continuation
    let statusCont: AsyncStream<Data>.Continuation
    let observerTask: Task<Void, Never>
}

/// Connected manager on a TestClock, with a live status stream so a fault pulse
/// can be pushed after the stall, and an observer wired to a mock poster.
private func makeGraceTestSetup() async throws -> GraceTestSetup {
    var heightCont: AsyncStream<Data>.Continuation!
    let heightStream = AsyncStream<Data> { heightCont = $0 }
    var statusCont: AsyncStream<Data>.Continuation!
    let statusStream = AsyncStream<Data> { statusCont = $0 }

    let mock = MockBLEController()
    mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
    mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
    mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(responses: HandshakeFixtures.happyPathDPGResponses)
    mock.mockNotificationStreams[DeskUUID.height] = heightStream
    mock.mockNotificationStreams[DeskUUID.status] = statusStream

    let clock = TestClock()
    let store = makeTempConfigStore()
    let manager = DeskManager(bleController: mock, configStore: store, clock: clock)
    let poster = MockNotificationPoster()
    let observerTask = ConnectionStateObserver(deskManager: manager, notificationPoster: poster).start()

    let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
    heightCont.yield(makeHeightPacket(mm: 730))
    try await connectTask.value

    return GraceTestSetup(
        manager: manager, clock: clock, poster: poster,
        heightCont: heightCont, statusCont: statusCont, observerTask: observerTask
    )
}

/// Drives the clock until `predicate` holds. The observer registers its grace
/// sleep at a moment the test cannot observe, so advancing repeatedly is what
/// makes this deterministic without reaching into TestClock's internals.
private func advanceUntil(
    _ clock: TestClock,
    by step: Duration = .milliseconds(600),
    predicate: @escaping () async -> Bool
) async {
    await waitFor(timeout: 3.0) {
        if await predicate() { return true }
        clock.advance(by: step)
        return await predicate()
    }
}

// MARK: - Tests

final class DeskManagerFaultCodeGraceTests: XCTestCase {

    /// The point of #19: a code arriving after the stall still reaches the user.
    func testFaultCodeArrivingAfterTheStallStillReachesTheNotification() async throws {
        let setup = try await makeGraceTestSetup()
        defer { setup.observerTask.cancel() }

        try await setup.manager.moveUp(mode: .manual)
        try await Task.sleep(for: .milliseconds(50))

        // Height never changes → the watchdog stalls with no code yet.
        setup.clock.advance(by: .milliseconds(2100))
        await waitFor { await setup.manager.currentState.needsReference }
        let atStall = await setup.manager.currentState.faultCode
        XCTAssertNil(atStall, "Precondition: the stall itself carries no fault code")

        // Only now does the control box get around to saying why.
        setup.statusCont.yield(Data([0x01, 0x00, 0x1e]))
        await waitFor { await setup.manager.currentState.faultCode == 0x1e }

        await advanceUntil(setup.clock) { setup.poster.needsReferenceCount >= 1 }

        XCTAssertEqual(setup.poster.needsReferenceCount, 1, "Exactly one notification per stall")
        XCTAssertTrue(
            setup.poster.lastNeedsReferenceBody?.contains("E16") ?? false,
            "The late fault code must reach the notification body — got: \(setup.poster.lastNeedsReferenceBody ?? "nil")"
        )
    }

    /// The window must not hang when the desk stays silent, which is what makes
    /// it safe to sit in front of standDown().
    func testSilentDeskStillNotifiesAndStandsDownAfterTheWindow() async throws {
        let setup = try await makeGraceTestSetup()
        defer { setup.observerTask.cancel() }

        try await setup.manager.moveUp(mode: .manual)
        try await Task.sleep(for: .milliseconds(50))

        setup.clock.advance(by: .milliseconds(2100))
        await waitFor { await setup.manager.currentState.needsReference }

        // No status pulse at all — the window has to expire on its own.
        await advanceUntil(setup.clock) { setup.poster.needsReferenceCount >= 1 }

        XCTAssertEqual(setup.poster.needsReferenceCount, 1)

        await waitFor { await setup.manager.currentState.connectionState == .disconnected }
        let state = await setup.manager.currentState
        XCTAssertEqual(state.connectionState, .disconnected, "Stand-down must still happen")
        XCTAssertTrue(state.needsReference, "Stand-down preserves the flag")
        XCTAssertNil(state.faultCode, "A silent desk yields no code — the generic summary stands")
    }
}
