// PerformanceTests.swift
// LinakControlTests — Performance verification tests for SDD quality requirements.
//
// Verifies:
//   - Height update latency (BLE → DeskViewModel.heightMM): < 100ms at 10 Hz
//   - Preset move start latency (goToPreset call → first BLE write): < 1 second
//   - State propagation throughput at 10 Hz (100 updates in ≤ 10 seconds)
//   - IPC round-trip latency (status query): < 500ms
//   - ConfigStore.load() performance: < 10ms

import XCTest
import Darwin
@testable import LinakControlKit

// MARK: - Shared Helpers

// makeTempConfigStore, makeHeightPacket, makeDPGStream, and waitFor are provided by TestHelpers.swift

private func makeTempSocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("perf-ipc-\(UUID().uuidString).sock")
        .path
}

/// Waits for the IPC server to accept connections, polling up to `timeout` seconds.
private func waitForServer(at socketPath: String, timeout: TimeInterval = 2.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { break }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    src, 104
                )
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        if result == 0 { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - Height Update Latency

/// Measures the time from a mock BLE notification emission to DeskViewModel.heightMM update.
///
/// SDD requirement: < 100ms.
@MainActor
final class HeightUpdateLatencyTests: XCTestCase {

    func testHeightUpdateLatency() async throws {
        var heightCont: AsyncStream<Data>.Continuation!
        let heightStream = AsyncStream<Data> { cont in heightCont = cont }

        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
        mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(responses: HandshakeFixtures.happyPathDPGResponses)
        mock.mockNotificationStreams[DeskUUID.height] = heightStream

        let store = makeTempConfigStore(tag: "HeightLatency")
        let manager = DeskManager(bleController: mock, configStore: store)
        let viewModel = DeskViewModel(deskManager: manager, configStore: store)

        let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 730))
        try await connectTask.value

        await waitFor { viewModel.heightMM == 730 }
        XCTAssertEqual(viewModel.heightMM, 730, "Precondition: initial height must be set")

        // Measure: emit notification → viewModel.heightMM reflects new value.
        // Use async await timing to avoid blocking the main actor during measurement,
        // which would prevent @MainActor state propagation from completing.
        let iterationCount = 10
        var totalSeconds: Double = 0
        for _ in 0..<iterationCount {
            let targetMM = 900
            let start = ContinuousClock.now
            heightCont.yield(makeHeightPacket(mm: targetMM))
            await waitFor(timeout: 1.0) { viewModel.heightMM == targetMM }
            let elapsed = ContinuousClock.now - start
            totalSeconds += Double(elapsed.components.seconds) +
                Double(elapsed.components.attoseconds) / 1e18

            // Reset for next iteration.
            heightCont.yield(makeHeightPacket(mm: 730))
            await waitFor(timeout: 1.0) { viewModel.heightMM == 730 }
        }

        let measuredSeconds = totalSeconds / Double(iterationCount)
        XCTAssertLessThan(
            measuredSeconds, 0.1,
            "Height update latency must be < 100ms, got \(measuredSeconds * 1000)ms"
        )
    }
}

// MARK: - Preset Move Start Latency

/// Measures time from goToPreset(index:) call to the first BLE write command.
///
/// SDD requirement: < 1 second.
final class PresetMoveStartLatencyTests: XCTestCase {

    func testPresetMoveStartLatency() async throws {
        var heightCont: AsyncStream<Data>.Continuation!
        let heightStream = AsyncStream<Data> { cont in heightCont = cont }

        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
        mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(responses: HandshakeFixtures.happyPathDPGResponses)
        mock.mockNotificationStreams[DeskUUID.height] = heightStream

        let store = makeTempConfigStore(tag: "PresetLatency")
        let manager = DeskManager(bleController: mock, configStore: store)

        let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 730))
        try await connectTask.value

        // Precondition: preset 2 = 1105mm is loaded from handshake fixtures.
        let preConnectWriteCount = mock.writtenData.count
        let start = ContinuousClock.now

        try await manager.goToPreset(index: 2)

        // goToPreset returns after the preflight write; measure to that point.
        let elapsed = ContinuousClock.now - start
        let elapsedSeconds = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1e18

        let newWriteCount = mock.writtenData.count - preConnectWriteCount
        XCTAssertGreaterThan(newWriteCount, 0, "At least one BLE write must occur")
        XCTAssertLessThan(
            elapsedSeconds, 1.0,
            "Preset move start must be < 1 second, got \(elapsedSeconds * 1000)ms"
        )
    }
}

// MARK: - State Propagation Throughput

/// Emits 100 height notifications and verifies all propagate to DeskViewModel within
/// the time budget that supports 10 Hz updates (100 updates ÷ 10 Hz = 10 seconds).
///
/// SDD requirement: support 10 Hz height updates end-to-end.
@MainActor
final class StatePropagationThroughputTests: XCTestCase {

    func testStatePropagationThroughput() async throws {
        var heightCont: AsyncStream<Data>.Continuation!
        let heightStream = AsyncStream<Data> { cont in heightCont = cont }

        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
        mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(responses: HandshakeFixtures.happyPathDPGResponses)
        mock.mockNotificationStreams[DeskUUID.height] = heightStream

        let store = makeTempConfigStore(tag: "Throughput")
        let manager = DeskManager(bleController: mock, configStore: store)
        let viewModel = DeskViewModel(deskManager: manager, configStore: store)

        let connectTask = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 730))
        try await connectTask.value

        await waitFor { viewModel.heightMM == 730 }

        let updateCount = 100
        // Heights alternate between two values so each emission triggers a state
        // change, then end on a third the run never visits: the wait below is
        // only a "everything flushed" check if the value it waits for cannot
        // also be an intermediate one. Alternating to the end made it true on
        // the second emission, and the assertion afterwards then read whichever
        // of the two had landed by that point.
        let finalHeight = 735
        let heights = (0..<updateCount - 1).map { i in i % 2 == 0 ? 730 : 731 } + [finalHeight]

        let start = ContinuousClock.now
        for mm in heights {
            heightCont.yield(makeHeightPacket(mm: mm))
        }

        // Wait until the final height value propagates (verifies all updates flushed).
        await waitFor(timeout: 10.0) { viewModel.heightMM == finalHeight }

        let elapsed = ContinuousClock.now - start
        let elapsedSeconds = Double(elapsed.components.seconds) +
            Double(elapsed.components.attoseconds) / 1e18

        XCTAssertEqual(
            viewModel.heightMM, finalHeight,
            "All \(updateCount) updates must have propagated"
        )
        // 100 updates at 10 Hz = 10 seconds budget.
        XCTAssertLessThan(
            elapsedSeconds, 10.0,
            "100 height updates must propagate within 10 seconds (10 Hz), got \(elapsedSeconds)s"
        )
    }
}

// MARK: - IPC Round-Trip Latency

/// Starts a real IPCServer + IPCClient and measures the round-trip time for a status query.
///
/// SDD requirement: < 500ms.
final class IPCRoundTripLatencyTests: XCTestCase {

    func testIPCRoundTripLatency() async throws {
        let socketPath = makeTempSocketPath()
        let store = makeTempConfigStore(tag: "IPCRoundTrip")
        let mock = MockBLEController()
        let manager = DeskManager(bleController: mock, configStore: store)
        let server = IPCServer(deskManager: manager, configStore: store, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        await waitForServer(at: socketPath)

        let client = IPCClient(socketPath: socketPath)

        var measuredSeconds: Double = 0
        measure {
            let start = ContinuousClock.now
            _ = try? client.getStatus()
            let elapsed = ContinuousClock.now - start
            measuredSeconds = Double(elapsed.components.seconds) +
                Double(elapsed.components.attoseconds) / 1e18
        }

        XCTAssertLessThan(
            measuredSeconds, 0.5,
            "IPC round-trip must be < 500ms, got \(measuredSeconds * 1000)ms"
        )
    }
}

// MARK: - Config Load Performance

/// Measures ConfigStore.load() duration when no file exists and when a file exists.
///
/// SDD requirement: < 10ms.
final class ConfigLoadPerformanceTests: XCTestCase {

    func testConfigLoadPerformance_fileAbsent() {
        let store = makeTempConfigStore(tag: "ConfigLoadAbsent")

        var measuredSeconds: Double = 0
        measure {
            let start = ContinuousClock.now
            _ = try? store.load()
            let elapsed = ContinuousClock.now - start
            measuredSeconds = Double(elapsed.components.seconds) +
                Double(elapsed.components.attoseconds) / 1e18
        }

        XCTAssertLessThan(
            measuredSeconds, 0.01,
            "ConfigStore.load() (absent) must be < 10ms, got \(measuredSeconds * 1000)ms"
        )
    }

    func testConfigLoadPerformance_filePresent() throws {
        let store = makeTempConfigStore(tag: "ConfigLoadPresent")
        try store.save(.default)

        var measuredSeconds: Double = 0
        measure {
            let start = ContinuousClock.now
            _ = try? store.load()
            let elapsed = ContinuousClock.now - start
            measuredSeconds = Double(elapsed.components.seconds) +
                Double(elapsed.components.attoseconds) / 1e18
        }

        XCTAssertLessThan(
            measuredSeconds, 0.01,
            "ConfigStore.load() (present) must be < 10ms, got \(measuredSeconds * 1000)ms"
        )
    }
}
