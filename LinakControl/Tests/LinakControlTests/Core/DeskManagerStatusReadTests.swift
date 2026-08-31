// DeskManagerStatusReadTests.swift
// LinakControlTests — Verifies that a stall asks the desk directly (issue #24).
//
// #19 assumed the fault code merely arrives late. Hardware disproved it: three
// stalls pushed no status packet at all, even with the grace window listening.
// 99fa0003 is Read/Notify and the app only ever subscribed, so the remaining
// way to learn why the desk stopped is to read it before standing down.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Helpers

private struct StatusReadSetup {
    let manager: DeskManager
    let mock: MockBLEController
    let clock: TestClock
    let poster: MockNotificationPoster
    let heightCont: AsyncStream<Data>.Continuation
    let statusCont: AsyncStream<Data>.Continuation
    let observerTask: Task<Void, Never>
}

/// Connected manager on a TestClock with an observer attached. The status
/// notification stream stays deliberately silent — this file is about the read
/// path, so nothing is ever pushed.
private func makeStatusReadSetup(
    statusReadResponse: Data?
) async throws -> StatusReadSetup {
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

    // Configure the status read only after the handshake, so it cannot
    // influence connect.
    if let response = statusReadResponse {
        mock.mockReadResponses[DeskUUID.status] = response
    }

    return StatusReadSetup(
        manager: manager, mock: mock, clock: clock, poster: poster,
        heightCont: heightCont, statusCont: statusCont, observerTask: observerTask
    )
}

/// Drives the clock until `predicate` holds — the observer registers its grace
/// sleep at a moment the test cannot observe.
private func advanceUntil(
    _ clock: TestClock,
    predicate: @escaping () async -> Bool
) async {
    await waitFor(timeout: 3.0) {
        if await predicate() { return true }
        clock.advance(by: .milliseconds(600))
        return await predicate()
    }
}

/// Stalls a manual move: the height never changes, so the watchdog fires.
private func stallAMove(_ setup: StatusReadSetup) async throws {
    try await setup.manager.moveUp(mode: .manual)
    try await Task.sleep(for: .milliseconds(50))
    setup.clock.advance(by: .milliseconds(2100))
    await waitFor { await setup.manager.currentState.needsReference }
}

// MARK: - Tests

final class DeskManagerStatusReadTests: XCTestCase {

    /// The point of #24: the desk never pushes, but answers when asked.
    func testSilentDeskYieldsFaultCodeWhenReadDirectly() async throws {
        let setup = try await makeStatusReadSetup(statusReadResponse: Data([0x01, 0x00, 0x1e]))
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await advanceUntil(setup.clock) { setup.poster.needsReferenceCount >= 1 }

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
        let setup = try await makeStatusReadSetup(statusReadResponse: Data([0x01, 0x00, 0x00]))
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await advanceUntil(setup.clock) { setup.poster.needsReferenceCount >= 1 }

        let code = await setup.manager.currentState.faultCode
        XCTAssertNil(code, "An all-clear read carries no fault code")
        XCTAssertEqual(setup.poster.needsReferenceCount, 1, "The stall is still reported")
    }

    /// The read must never be load-bearing: no mock response is configured, so
    /// `read` throws — which is what a dropped link looks like.
    func testFailedReadFallsBackToTheExistingBehaviour() async throws {
        let setup = try await makeStatusReadSetup(statusReadResponse: nil)
        defer { setup.observerTask.cancel() }

        try await stallAMove(setup)
        await advanceUntil(setup.clock) { setup.poster.needsReferenceCount >= 1 }

        let state = await setup.manager.currentState
        XCTAssertNil(state.faultCode, "A failed read yields no code")
        XCTAssertTrue(state.needsReference, "The stall still stands")
        XCTAssertEqual(setup.poster.needsReferenceCount, 1, "and is still reported exactly once")
    }

    /// A code the desk pushed must win without a read round-trip being needed —
    /// the fast path from #4 stays untouched.
    func testPushedFaultStillTakesPrecedence() async throws {
        let setup = try await makeStatusReadSetup(statusReadResponse: Data([0x01, 0x00, 0x17]))
        defer { setup.observerTask.cancel() }

        try await setup.manager.moveUp(mode: .manual)
        try await Task.sleep(for: .milliseconds(50))

        // Desk pushes E16 on its own before any stall.
        setup.statusCont.yield(Data([0x01, 0x00, 0x1e]))
        await waitFor { await setup.manager.currentState.faultCode == 0x1e }
        await advanceUntil(setup.clock) { setup.poster.needsReferenceCount >= 1 }

        let code = await setup.manager.currentState.faultCode
        XCTAssertEqual(code, 0x1e, "The pushed code must not be overwritten by the read (which returns E26 here)")
        XCTAssertTrue(setup.poster.lastNeedsReferenceBody?.contains("E16") ?? false)
    }
}
