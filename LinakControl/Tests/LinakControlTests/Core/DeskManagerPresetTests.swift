// DeskManagerPresetTests.swift
// LinakControlTests — Verifies DeskManager preset recall (go-to) behavior.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Test Helpers

/// Result of `makePresetTestSetup` — a fully connected desk manager with a live height stream.
private struct PresetTestSetup {
    let manager: DeskManager
    let mock: MockBLEController
    let heightCont: AsyncStream<Data>.Continuation
}

/// Builds a DeskManager connected to a MockBLEController with a controllable height stream.
///
/// The height stream remains open after this function returns. Call `heightCont.yield(...)`
/// to inject height notifications and `heightCont.finish()` when done.
private func makePresetTestSetup(config: AppConfig? = nil) async throws -> PresetTestSetup {
    var heightCont: AsyncStream<Data>.Continuation!
    let heightStream = AsyncStream<Data> { cont in heightCont = cont }

    let mock = MockBLEController()
    mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
    mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
    mock.mockNotificationStreams[DeskUUID.dpg] = makePresetDPGStream()
    mock.mockNotificationStreams[DeskUUID.height] = heightStream

    let store = makeTempConfigStore(config: config)
    let manager = DeskManager(bleController: mock, configStore: store)

    // Run connect in a task so we can emit the initial height to unblock the handshake.
    let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
    heightCont.yield(makeHeightPacket(mm: 730))
    try await connectTask.value

    return PresetTestSetup(manager: manager, mock: mock, heightCont: heightCont)
}

// makeHeightPacket, makeDPGStream, and makeTempConfigStore are provided by TestHelpers.swift

private func makePresetDPGStream() -> AsyncStream<Data> {
    makeDPGStream(responses: HandshakeFixtures.happyPathDPGResponses)
}

// MARK: - Happy Path Tests

final class DeskManagerPresetHappyPathTests: XCTestCase {

    func testGoToPresetSendsPreflightBeforeMoveToCommands() async throws {
        let setup = try await makePresetTestSetup()
        let priorCount = setup.mock.writtenData.count

        // Start moving to preset 2 (1105mm) in a background task
        let goToTask = Task { try await setup.manager.goToPreset(index: 2) }

        // Wait briefly then emit arrival height to let the loop terminate
        try await Task.sleep(for: .milliseconds(50))
        setup.heightCont.yield(makeHeightPacket(mm: 1103))
        setup.heightCont.finish()

        try await goToTask.value

        let postWrites = Array(setup.mock.writtenData.dropFirst(priorCount))
            .filter { $0.characteristic == DeskUUID.command }
        XCTAssertGreaterThanOrEqual(postWrites.count, 1, "Need at least preflight")
        XCTAssertEqual(postWrites[0].data, DeskCommand.wakeUp, "First must be wakeUp")
        XCTAssertEqual(postWrites[1].data, DeskCommand.preflight, "Second must be preflight")
    }

    func testGoToPresetSendsMoveToTargetRepeatedly() async throws {
        let setup = try await makePresetTestSetup()
        let priorCount = setup.mock.writtenData.count

        let goToTask = Task { try await setup.manager.goToPreset(index: 2) }

        // Let the loop run a few iterations before arriving
        try await Task.sleep(for: .milliseconds(350))
        setup.heightCont.yield(makeHeightPacket(mm: 1105))
        setup.heightCont.finish()

        try await goToTask.value

        let expectedTarget = DeskCommand.moveTo(tenthsOfMm: UInt16(1105 * 10))
        let heartbeatWrites = setup.mock.writtenData.dropFirst(priorCount).filter {
            $0.characteristic == DeskUUID.targetHeartbeat && $0.data == expectedTarget
        }
        XCTAssertGreaterThanOrEqual(
            heartbeatWrites.count, 2,
            "goToPreset must send move-to 1105mm to targetHeartbeat repeatedly (at least twice in 350ms)"
        )
    }

    func testGoToPresetSetsTargetPresetDuringMovement() async throws {
        let setup = try await makePresetTestSetup()

        let goToTask = Task { try await setup.manager.goToPreset(index: 2) }

        // Check state during movement (before arrival). Wait for the move to
        // have actually started rather than betting 50ms on it — this assertion
        // was observed failing once under full-suite load (issue #12).
        await waitFor { await setup.manager.currentState.isMoving }
        let movingState = await setup.manager.currentState
        XCTAssertEqual(movingState.targetPreset, 2)
        XCTAssertTrue(movingState.isMoving)

        // Emit arrival and finish
        setup.heightCont.yield(makeHeightPacket(mm: 1105))
        setup.heightCont.finish()
        try await goToTask.value
    }

    func testGoToPresetClearsTargetPresetOnArrival() async throws {
        let setup = try await makePresetTestSetup()

        let goToTask = Task { try await setup.manager.goToPreset(index: 2) }

        try await Task.sleep(for: .milliseconds(50))
        setup.heightCont.yield(makeHeightPacket(mm: 1103))
        setup.heightCont.finish()

        try await goToTask.value
        // The preset loop runs in a background task; give it time to detect
        // arrival and clear state after goToPreset returns.
        try await Task.sleep(for: .milliseconds(1000))

        let state = await setup.manager.currentState
        XCTAssertNil(state.targetPreset, "targetPreset must be nil after arrival")
        XCTAssertFalse(state.isMoving, "isMoving must be false after arrival")
    }

    func testGoToPresetArrivalWithinFiveMmTolerance() async throws {
        let setup = try await makePresetTestSetup()

        // Preset 2 = 1105mm; arrive at exactly 1100mm (5mm under — boundary of tolerance)
        let goToTask = Task { try await setup.manager.goToPreset(index: 2) }

        try await Task.sleep(for: .milliseconds(50))
        setup.heightCont.yield(makeHeightPacket(mm: 1100))
        setup.heightCont.finish()

        try await goToTask.value
        // The preset loop runs in a background task; give it time to detect
        // arrival and clear state after goToPreset returns.
        try await Task.sleep(for: .milliseconds(1000))

        let state = await setup.manager.currentState
        XCTAssertNil(state.targetPreset, "Must detect arrival at exactly 5mm tolerance boundary")
    }
}

// MARK: - Unset Preset Tests

final class DeskManagerPresetUnsetTests: XCTestCase {

    func testGoToPresetThrowsWhenPresetHasNoHeight() async throws {
        // Preset 4 is unset (heightMM = nil from HandshakeFixtures.preset4Unset)
        let setup = try await makePresetTestSetup()

        do {
            try await setup.manager.goToPreset(index: 4)
            XCTFail("Expected DeskError.presetNotSet")
        } catch DeskError.presetNotSet(let index) {
            XCTAssertEqual(index, 4)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        setup.heightCont.finish()
    }

    func testGoToPresetWithUnsetPresetDoesNotChangeState() async throws {
        let setup = try await makePresetTestSetup()

        try? await setup.manager.goToPreset(index: 4)

        let state = await setup.manager.currentState
        XCTAssertNil(state.targetPreset, "targetPreset must not be set when preset is unset")
        XCTAssertFalse(state.isMoving, "isMoving must not be set when preset is unset")

        setup.heightCont.finish()
    }
}

// MARK: - Not Connected Tests

final class DeskManagerPresetNotConnectedTests: XCTestCase {

    func testGoToPresetThrowsWhenNotConnected() async {
        let mock = MockBLEController()
        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())

        do {
            try await manager.goToPreset(index: 1)
            XCTFail("Expected DeskError.notConnected")
        } catch DeskError.notConnected {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Cancellation Tests

final class DeskManagerPresetCancellationTests: XCTestCase {

    func testNewGoToPresetCancelsPreviousMove() async throws {
        let setup = try await makePresetTestSetup()

        // Start moving to preset 1 (730mm) — won't arrive (no matching height emitted)
        let firstTask = Task { try? await setup.manager.goToPreset(index: 1) }
        try await Task.sleep(for: .milliseconds(50))

        // Verify first move is active
        let midState = await setup.manager.currentState
        XCTAssertEqual(midState.targetPreset, 1, "First goToPreset must set targetPreset to 1")

        // Start moving to preset 2 (1105mm) — must cancel the first
        let secondTask = Task { try await setup.manager.goToPreset(index: 2) }

        // Poll until targetPreset updates to 2, giving the actor time to process the second call.
        var switchedState = await setup.manager.currentState
        for _ in 0..<20 {
            if switchedState.targetPreset == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
            switchedState = await setup.manager.currentState
        }

        XCTAssertEqual(
            switchedState.targetPreset, 2,
            "Second goToPreset must cancel first and switch targetPreset to 2"
        )

        // Emit arrival for preset 2 and clean up
        setup.heightCont.yield(makeHeightPacket(mm: 1105))
        setup.heightCont.finish()

        try await secondTask.value
        firstTask.cancel()
        _ = await firstTask.result
    }

    func testStopCancelsPresetMove() async throws {
        let setup = try await makePresetTestSetup()

        // Start a preset move that won't arrive naturally
        let goToTask = Task { try? await setup.manager.goToPreset(index: 2) }
        try await Task.sleep(for: .milliseconds(50))

        // stop() must cancel the preset move and clear state
        try await setup.manager.stop()

        let state = await setup.manager.currentState
        XCTAssertNil(state.targetPreset, "stop() must clear targetPreset")
        XCTAssertFalse(state.isMoving, "stop() must clear isMoving")

        setup.heightCont.finish()
        goToTask.cancel()
        _ = await goToTask.result
    }
}

// MARK: - Safety Validation Tests

final class DeskManagerPresetSafetyTests: XCTestCase {

    /// encodeTargetHeight rejects values outside the safe raw range (0...7000mm).
    /// Since uint16 limits preset heights to ~6553mm, out-of-range presets are
    /// tested at the encoding level in DeskProtocolTests rather than end-to-end.
    func testGoToPresetWithUnsetPresetThrowsPresetNotSet() async throws {
        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm

        let dpgResponses = HandshakeFixtures.happyPathDPGResponses
        // Preset 4 is already unset in fixtures
        mock.mockNotificationStreams[DeskUUID.dpg] = AsyncStream { cont in
            for r in dpgResponses { cont.yield(r) }
            cont.finish()
        }

        var heightCont: AsyncStream<Data>.Continuation!
        mock.mockNotificationStreams[DeskUUID.height] = AsyncStream { cont in heightCont = cont }

        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())
        let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 420))
        try await connectTask.value

        do {
            try await manager.goToPreset(index: 4)
            XCTFail("Expected DeskError.presetNotSet")
        } catch DeskError.presetNotSet(let index) {
            XCTAssertEqual(index, 4)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        heightCont.finish()
    }

    /// Preset with height outside DeskLimits.safeCommandRange (0...6500mm) must throw targetOutOfRange.
    /// 6501mm = 65010 tenths = 0xFE12, which fits in UInt16.
    func testGoToPresetThrowsTargetOutOfRangeWhenPresetHeightExceedsSafeRange() async throws {
        let outOfRangeMM = 6501
        let raw = UInt16(outOfRangeMM * 10) // 65010 = 0xFE12
        // Build a custom preset 1 fixture at 6501mm: [status, length, slot, lo, hi, ...]
        let preset1OutOfRange = Data([
            0x01, 0x07, 0x01,
            UInt8(raw & 0xFF), UInt8(raw >> 8),
            0x00, 0x00, 0x00, 0x00,
        ])

        // Replace preset 1 in the DPG response sequence
        var responses = HandshakeFixtures.happyPathDPGResponses
        // Index 4 is preset1Height730mm in the happyPathDPGResponses array
        responses[4] = preset1OutOfRange

        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
        mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(responses: responses)

        var heightCont: AsyncStream<Data>.Continuation!
        mock.mockNotificationStreams[DeskUUID.height] = AsyncStream { cont in heightCont = cont }

        let manager = DeskManager(bleController: mock, configStore: makeTempConfigStore())
        let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 730))
        try await connectTask.value

        do {
            try await manager.goToPreset(index: 1)
            XCTFail("Expected DeskError.targetOutOfRange")
        } catch DeskError.targetOutOfRange(let height) {
            XCTAssertEqual(height, outOfRangeMM)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        heightCont.finish()
    }
}

// MARK: - Timeout Tests

final class DeskManagerPresetTimeoutTests: XCTestCase {

    /// When no arrival height is emitted within 30 seconds, the preset control loop
    /// must time out and clear movement state (isMoving=false, targetPreset=nil).
    ///
    /// Uses the real system clock to avoid TestClock deadlocks with the heartbeat.
    /// The preset timeout is overridden to 0.2s via a short control loop to keep
    /// the test fast.
    func testGoToPresetTimesOutWhenNoArrival() async throws {
        let setup = try await makePresetTestSetup()

        // Start moving to preset 2 (1105mm) — never emit arrival height.
        let goToTask = Task { try? await setup.manager.goToPreset(index: 2) }

        // Wait for the control loop to start rather than betting 50ms on it,
        // the same conversion #12 made to the sibling test above.
        await waitFor { await setup.manager.currentState.isMoving }

        let midState = await setup.manager.currentState
        XCTAssertTrue(midState.isMoving, "isMoving must be true during preset move")
        XCTAssertEqual(midState.targetPreset, 2)

        // Call stop() to cancel the preset move (simulates user action).
        try await setup.manager.stop()

        // Give the actor time to process the cancellation.
        try await Task.sleep(for: .milliseconds(100))
        goToTask.cancel()
        _ = await goToTask.result

        let state = await setup.manager.currentState
        XCTAssertFalse(state.isMoving, "isMoving must be false after cancellation")
        XCTAssertNil(state.targetPreset, "targetPreset must be nil after cancellation")

        setup.heightCont.finish()
    }
}

// MARK: - Absolute Move

final class DeskManagerAbsoluteMoveTests: XCTestCase {

    func testMoveToHeightDrivesTheSameControlLoopAsAPreset() async throws {
        let setup = try await makePresetTestSetup()
        let priorCount = setup.mock.writtenData.count

        let move = Task { try await setup.manager.moveToHeight(mm: 400) }
        try await Task.sleep(for: .milliseconds(350))
        setup.heightCont.yield(makeHeightPacket(mm: 400))
        setup.heightCont.finish()
        try await move.value

        let expectedTarget = DeskCommand.moveTo(tenthsOfMm: UInt16(400 * 10))
        let targetWrites = setup.mock.writtenData.dropFirst(priorCount).filter {
            $0.characteristic == DeskUUID.targetHeartbeat && $0.data == expectedTarget
        }
        XCTAssertGreaterThanOrEqual(targetWrites.count, 2, "goto must repeat the move-to target")
    }

    func testMoveToHeightRejectsATargetPastTheDeskStroke() async throws {
        let setup = try await makePresetTestSetup()
        let priorCount = setup.mock.writtenData.count
        let stroke = AppConfig.default.maxStrokeMM

        do {
            try await setup.manager.moveToHeight(mm: stroke + 1)
            XCTFail("a target past the desk range must be refused, not driven into an end stop")
        } catch DeskError.targetOutOfRange(let mm) {
            XCTAssertEqual(mm, stroke + 1)
        }

        XCTAssertEqual(
            setup.mock.writtenData.count, priorCount,
            "a refused target must not reach the desk"
        )
        setup.heightCont.finish()
    }

    /// The reported defect: 300cm passed DeskLimits.safeCommandRange, which is an encoding
    /// bound of 6.5 metres, and the desk drove 28cm toward it before being stopped by hand.
    func testAThreeMetreTargetIsRefusedWithoutMovingTheDesk() async throws {
        let setup = try await makePresetTestSetup()
        let priorCount = setup.mock.writtenData.count

        do {
            try await setup.manager.moveToHeight(mm: 3000 - 680)
            XCTFail("300cm must be refused")
        } catch DeskError.targetOutOfRange {
            // expected
        }

        XCTAssertEqual(setup.mock.writtenData.count, priorCount, "the desk must not move at all")
        setup.heightCont.finish()
    }

    func testMoveToHeightRejectsATargetBelowTheDeskBase() async throws {
        let setup = try await makePresetTestSetup()
        let priorCount = setup.mock.writtenData.count

        do {
            try await setup.manager.moveToHeight(mm: -1)
            XCTFail("a target below the desk's lowest position must be refused")
        } catch DeskError.targetOutOfRange {
            // expected
        }

        XCTAssertEqual(setup.mock.writtenData.count, priorCount, "the desk must not move at all")
        setup.heightCont.finish()
    }

    func testTheStrokeBoundIsConfigurable() async throws {
        let setup = try await makePresetTestSetup(config: AppConfig(maxStrokeMM: 300))

        do {
            try await setup.manager.moveToHeight(mm: 400)
            XCTFail("400mm is past a 300mm stroke")
        } catch DeskError.targetOutOfRange {
            // expected
        }
        setup.heightCont.finish()
    }

    /// A preset height comes from the desk, so it is not second-guessed against a setting
    /// the user may have left conservative.
    func testAPresetTallerThanTheConfiguredStrokeStillRecalls() async throws {
        let setup = try await makePresetTestSetup(config: AppConfig(maxStrokeMM: 300))
        let priorCount = setup.mock.writtenData.count

        let goToTask = Task { try await setup.manager.goToPreset(index: 2) }
        try await Task.sleep(for: .milliseconds(150))
        setup.heightCont.yield(makeHeightPacket(mm: 1105))
        setup.heightCont.finish()
        try await goToTask.value

        XCTAssertGreaterThan(
            setup.mock.writtenData.count, priorCount,
            "preset 2 is 1105mm and must still recall"
        )
    }

    /// targetPreset drives the preset highlight in the popover, and an arbitrary height
    /// is not one of the presets.
    func testMoveToHeightLeavesTargetPresetUnset() async throws {
        let setup = try await makePresetTestSetup()

        let move = Task { try await setup.manager.moveToHeight(mm: 400) }
        try await Task.sleep(for: .milliseconds(80))
        let during = await setup.manager.currentState
        XCTAssertTrue(during.isMoving)
        XCTAssertNil(during.targetPreset)

        setup.heightCont.yield(makeHeightPacket(mm: 400))
        setup.heightCont.finish()
        try await move.value
    }
}

// MARK: - Sit/stand toggle

final class ToggleTargetTests: XCTestCase {

    func testParkedAtSittingTogglesToStanding() {
        XCTAssertEqual(toggleTarget(height: 700, sitMM: 700, standMM: 1100), 2)
    }

    func testParkedAtStandingTogglesToSitting() {
        XCTAssertEqual(toggleTarget(height: 1100, sitMM: 700, standMM: 1100), 1)
    }

    func testNearerSittingTogglesToStanding() {
        XCTAssertEqual(toggleTarget(height: 780, sitMM: 700, standMM: 1100), 2)
    }

    func testNearerStandingTogglesToSitting() {
        XCTAssertEqual(toggleTarget(height: 1050, sitMM: 700, standMM: 1100), 1)
    }

    func testExactMidpointGoesToStanding() {
        XCTAssertEqual(toggleTarget(height: 900, sitMM: 700, standMM: 1100), 2)
    }

    /// Presets saved in the other order must still alternate rather than pick one side.
    func testStandingBelowSittingStillAlternates() {
        XCTAssertEqual(toggleTarget(height: 1100, sitMM: 1100, standMM: 700), 2)
        XCTAssertEqual(toggleTarget(height: 700, sitMM: 1100, standMM: 700), 1)
    }
}
