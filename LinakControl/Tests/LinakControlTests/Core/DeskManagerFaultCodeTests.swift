// DeskManagerFaultCodeTests.swift
// LinakControlTests — Covers awaitFaultCode(), the whole path between a stall
// and the stand-down that follows it (issues #19 and #24).
//
// The 2s watchdog regularly beats the control box to the punch, and standDown()
// cancels the status listener, so anything the desk says afterwards is lost.
// Two mechanisms sit in front of it: a direct read of 99fa0003, because three
// hardware stalls pushed no status packet at all, and a grace window, because a
// packet that does arrive late must still reach the user.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Helpers

private struct FaultCodeSetup {
    let manager: DeskManager
    let clock: TestClock
    let poster: MockNotificationPoster
    let statusCont: AsyncStream<Data>.Continuation
    /// Held only to keep the height stream open for the manager's listener.
    let heightCont: AsyncStream<Data>.Continuation
    let observerTask: Task<Void, Never>
}

/// Connected manager on a TestClock with an observer attached. The status
/// notification stream stays silent unless a test pushes to it; `statusRead` is
/// what a direct read of 99fa0003 answers, or nil to make the read throw, which
/// is what a dropped link looks like.
private func makeFaultCodeSetup(statusRead: Data? = nil) async throws -> FaultCodeSetup {
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
    let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore(), clock: clock)
    let poster = MockNotificationPoster()
    let observerTask = ConnectionStateObserver(deskManager: manager, notificationPoster: poster).start()

    let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
    heightCont.yield(makeHeightPacket(mm: 730))
    try await connectTask.value

    // Only after the handshake, so the read cannot influence connect.
    if let statusRead {
        mock.mockReadResponses[DeskUUID.status] = statusRead
    }

    return FaultCodeSetup(
        manager: manager, clock: clock, poster: poster, statusCont: statusCont,
        heightCont: heightCont, observerTask: observerTask
    )
}

/// Stalls a manual move: the height never changes, so the watchdog fires.
private func stallAMove(_ setup: FaultCodeSetup) async throws {
    try await setup.manager.moveUp(mode: .manual)
    await waitFor { setup.clock.pendingSleepers >= 1 }   // loop parked at its interval
    setup.clock.advance(by: .milliseconds(2100))
    await waitFor { await setup.manager.currentState.needsReference }
}

/// Runs out the grace window. The observer only sleeps when neither a pushed
/// code nor the first read produced one, so a test calls this exactly when it
/// expects that path.
private func expireGraceWindow(_ setup: FaultCodeSetup) async {
    await waitFor { setup.clock.pendingSleepers >= 1 }
    setup.clock.advance(by: DeskManager.faultCodeGraceWindow)
}

// MARK: - Reading the desk (issue #24)

final class DeskManagerFaultCodeReadTests: XCTestCase {

    /// The point of #24: the desk never pushes, but answers when asked.
    func testSilentDeskYieldsFaultCodeWhenReadDirectly() async throws {
        let setup = try await makeFaultCodeSetup(statusRead: Data([0x01, 0x00, 0x1e]))
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await waitFor { setup.poster.needsReferenceCount >= 1 }

        XCTAssertTrue(
            setup.poster.lastNeedsReferenceBody?.contains("E16") ?? false,
            "A read-only fault must still reach the notification — got: \(setup.poster.lastNeedsReferenceBody ?? "nil")"
        )

        let code = await setup.manager.currentState.faultCode
        XCTAssertEqual(
            code, 0x1e,
            "The code must be recorded on state so the popover and deskctl status show it too"
        )
    }

    /// A desk that reports all-clear must not be dressed up as a specific fault.
    func testAllClearReadLeavesTheGenericSummary() async throws {
        let setup = try await makeFaultCodeSetup(statusRead: Data([0x01, 0x00, 0x00]))
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await expireGraceWindow(setup)
        await waitFor { setup.poster.needsReferenceCount >= 1 }

        let code = await setup.manager.currentState.faultCode
        XCTAssertNil(code, "An all-clear read carries no fault code")
        XCTAssertEqual(setup.poster.needsReferenceCount, 1, "The stall is still reported")
    }

    /// The read must never be load-bearing: no mock response, so `read` throws,
    /// which is what a dropped link looks like.
    func testFailedReadFallsBackToTheExistingBehaviour() async throws {
        let setup = try await makeFaultCodeSetup()
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await expireGraceWindow(setup)
        await waitFor { setup.poster.needsReferenceCount >= 1 }

        let state = await setup.manager.currentState
        XCTAssertNil(state.faultCode, "A failed read yields no code")
        XCTAssertTrue(state.needsReference, "The stall still stands")
        XCTAssertEqual(setup.poster.needsReferenceCount, 1, "and is still reported exactly once")
    }

    /// A code the desk pushed must win without a read round-trip — the fast path
    /// from #4 stays untouched.
    func testPushedFaultStillTakesPrecedence() async throws {
        let setup = try await makeFaultCodeSetup(statusRead: Data([0x01, 0x00, 0x17]))
        defer { setup.observerTask.cancel() }

        try await setup.manager.moveUp(mode: .manual)
        await waitFor { setup.clock.pendingSleepers >= 1 }

        // Desk pushes E16 on its own before any stall.
        setup.statusCont.yield(Data([0x01, 0x00, 0x1e]))
        await waitFor { setup.poster.needsReferenceCount >= 1 }

        let code = await setup.manager.currentState.faultCode
        XCTAssertEqual(code, 0x1e, "The pushed code must not be overwritten by the read (which returns E26 here)")
        XCTAssertTrue(setup.poster.lastNeedsReferenceBody?.contains("E16") ?? false)
    }
}

// MARK: - The grace window (issue #19)

final class DeskManagerFaultCodeGraceTests: XCTestCase {

    /// The point of #19: a code arriving after the stall still reaches the user.
    func testFaultCodeArrivingAfterTheStallStillReachesTheNotification() async throws {
        let setup = try await makeFaultCodeSetup()
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        let atStall = await setup.manager.currentState.faultCode
        XCTAssertNil(atStall, "Precondition: the stall itself carries no fault code")

        // Only once the observer is parked in the window does the control box
        // get around to saying why.
        await waitFor { setup.clock.pendingSleepers >= 1 }
        setup.statusCont.yield(Data([0x01, 0x00, 0x1e]))
        await waitFor { await setup.manager.currentState.faultCode == 0x1e }
        setup.clock.advance(by: DeskManager.faultCodeGraceWindow)

        await waitFor { setup.poster.needsReferenceCount >= 1 }
        XCTAssertEqual(setup.poster.needsReferenceCount, 1, "Exactly one notification per stall")
        XCTAssertTrue(
            setup.poster.lastNeedsReferenceBody?.contains("E16") ?? false,
            "The late fault code must reach the notification body — got: \(setup.poster.lastNeedsReferenceBody ?? "nil")"
        )
    }

    /// The window must not hang when the desk stays silent, which is what makes
    /// it safe to sit in front of standDown().
    func testSilentDeskStillNotifiesAndStandsDownAfterTheWindow() async throws {
        let setup = try await makeFaultCodeSetup()
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await expireGraceWindow(setup)
        await waitFor { setup.poster.needsReferenceCount >= 1 }

        XCTAssertEqual(setup.poster.needsReferenceCount, 1)

        await waitFor { await setup.manager.currentState.connectionState == .disconnected }
        let state = await setup.manager.currentState
        XCTAssertEqual(state.connectionState, .disconnected, "Stand-down must still happen")
        XCTAssertTrue(state.needsReference, "Stand-down preserves the flag")
        XCTAssertNil(state.faultCode, "A silent desk yields no code — the generic summary stands")
    }
}
