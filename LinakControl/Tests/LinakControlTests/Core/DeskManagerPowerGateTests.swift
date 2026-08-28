// DeskManagerPowerGateTests.swift
// LinakControlTests — Verifies auto-connect waits for the central manager to power on.
// CoreBluetooth returns no peripherals until then, so an attempt made during the gap
// fails for a reason that has nothing to do with the desk.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

private func makeConnectableMock() -> MockBLEController {
    let mock = MockBLEController()
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


/// Polls the redirected test log for `needle`.
private func logContains(_ needle: String, within seconds: Double) async -> Bool {
    guard let url = FileLog.logURL else { return false }
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while ContinuousClock.now < deadline {
        if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
            return true
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

final class DeskManagerPowerGateTests: XCTestCase {

    /// A CoreBluetooth that never answers is the one failure the log could not
    /// show: the app waits, nothing happens, and there is no line to explain it.
    /// That is what an unauthorised build looks like from inside the app.
    func testASilentStackIsReportedAndTheWaitCarriesOn() async throws {
        let mock = makeConnectableMock()
        let clock = TestClock()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore(), clock: clock)

        let autoConnect = Task {
            try await manager.waitUntilPoweredOn()
            try await manager.connect(peripheralId: UUID())
        }
        try await Task.sleep(for: .milliseconds(50))

        clock.advance(by: powerOnReportDelay)
        let reported = await logContains("no state from CoreBluetooth", within: 2)
        XCTAssertTrue(reported, "a stack that says nothing must say so in the log")
        XCTAssertEqual(mock.connectCallCount, 0, "the report must not end the wait")

        mock.emitState(.poweredOn)
        try await autoConnect.value
        XCTAssertEqual(mock.connectCallCount, 1, "the connect still happens when the state arrives")
    }

    func testNoConnectAttemptIsSpentBeforePoweredOn() async throws {
        let mock = makeConnectableMock()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())

        let autoConnect = Task {
            try await manager.waitUntilPoweredOn()
            try await manager.connect(peripheralId: UUID())
        }
        mock.emitState(.poweredOff)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(mock.connectCallCount, 0, "no attempt may be spent while BLE is off")

        mock.emitState(.poweredOn)
        try await autoConnect.value

        XCTAssertEqual(mock.connectCallCount, 1, "the attempt is still available once BLE is up")
        let state = await manager.currentState
        XCTAssertEqual(state.connectionState, .connected)
    }

    func testPoweredOnReportedBeforeTheWaitStartsStillReleasesIt() async throws {
        let mock = makeConnectableMock()
        mock.emitState(.poweredOn)
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())

        try await manager.waitUntilPoweredOn()
    }

    func testUnauthorizedThrowsRatherThanWaitingForever() async {
        let mock = makeConnectableMock()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())
        mock.emitState(.unauthorized)

        do {
            try await manager.waitUntilPoweredOn()
            XCTFail("unauthorized must not be waited on")
        } catch DeskError.bluetoothUnavailable(let state) {
            XCTAssertEqual(state, .unauthorized)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// The failure this replaces: a cold stack reported poweredOn 13.2s after
    /// launch, past the 10s bound, and the app stayed disconnected with the desk
    /// in range. Nothing a warming stack reports may end the wait.
    func testColdStackTakingItsTimeStillConnects() async throws {
        let mock = makeConnectableMock()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())

        let autoConnect = Task {
            try await manager.waitUntilPoweredOn()
            try await manager.connect(peripheralId: UUID())
        }

        for state in [BLEState.unknown, .resetting, .poweredOff] {
            mock.emitState(state)
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(mock.connectCallCount, 0, "no attempt may be spent while the stack warms up")

        mock.emitState(.poweredOn)
        try await autoConnect.value

        XCTAssertEqual(mock.connectCallCount, 1, "the connect must still happen, however late poweredOn is")
        let state = await manager.currentState
        XCTAssertEqual(state.connectionState, .connected)
    }

    func testWaitIsCancellable() async throws {
        let mock = makeConnectableMock()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())
        mock.emitState(.poweredOff)

        let wait = Task { try await manager.waitUntilPoweredOn() }
        try await Task.sleep(for: .milliseconds(150))
        wait.cancel()

        do {
            try await wait.value
            XCTFail("a cancelled wait must not report success")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnsupportedThrowsRatherThanWaitingForever() async {
        let mock = makeConnectableMock()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())
        mock.emitState(.unsupported)

        do {
            try await manager.waitUntilPoweredOn()
            XCTFail("unsupported must not be waited on")
        } catch DeskError.bluetoothUnavailable(let state) {
            XCTAssertEqual(state, .unsupported)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
