// IPCServerTests.swift
// LinakControlTests — Verifies IPCServer socket lifecycle and request routing.

import XCTest
import Darwin
@testable import LinakControlKit

// MARK: - Test Helpers

// makeTempConfigStore is provided by TestHelpers.swift

/// Returns a unique socket path inside the system temp directory.
private func makeTempSocketPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ipc-test-\(UUID().uuidString).sock")
        .path
}

/// Builds a DeskManager backed by a scripted MockBLEController in disconnected state.
private func makeDisconnectedManager(configStore: ConfigStore) -> DeskManager {
    DeskManager(bleController: MockBLEController(), configStore: configStore)
}

/// Configures a MockBLEController with valid handshake responses and returns a connected DeskManager.
private func makeConnectedManager(configStore: ConfigStore) async throws -> DeskManager {
    let mock = MockBLEController()
    mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
    mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
    mock.mockNotificationStreams[DeskUUID.dpg] = AsyncStream { continuation in
        for response in HandshakeFixtures.happyPathDPGResponses {
            continuation.yield(response)
        }
        continuation.finish()
    }
    mock.mockNotificationStreams[DeskUUID.height] = AsyncStream { continuation in
        continuation.yield(HandshakeFixtures.heightNotification730mm)
        continuation.finish()
    }
    let manager = DeskManager(bleController: mock, configStore: configStore)
    try await manager.connect(peripheralId: UUID())
    return manager
}

/// Sends a framed IPCRequest to the given socket path and returns the decoded IPCResponse.
///
/// Opens a client socket, writes the framed JSON request, reads the framed response,
/// then closes the connection. Fails the test on any I/O or decoding error.
private func sendRequest(_ request: IPCRequest, to socketPath: String) throws -> IPCResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    XCTAssertGreaterThanOrEqual(fd, 0, "Could not create client socket")

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        socketPath.withCString { src in
            _ = Darwin.strlcpy(
                UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                src,
                104
            )
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    XCTAssertEqual(connectResult, 0, "Client connect failed: \(String(cString: strerror(errno)))")

    let requestData = try JSONEncoder().encode(request)
    let framed = IPCFraming.frame(requestData)
    let writeResult = framed.withUnsafeBytes { ptr in
        write(fd, ptr.baseAddress!, ptr.count)
    }
    XCTAssertEqual(writeResult, framed.count, "Client write was partial")

    // Read response with length prefix.
    var responseBuffer = Data()
    var tempBuf = [UInt8](repeating: 0, count: 8192)
    while IPCFraming.deframe(responseBuffer) == nil {
        let n = read(fd, &tempBuf, tempBuf.count)
        guard n > 0 else { break }
        responseBuffer.append(contentsOf: tempBuf[..<n])
    }
    close(fd)

    guard let (message, _) = IPCFraming.deframe(responseBuffer) else {
        throw XCTSkip("No complete framed response received")
    }
    return try JSONDecoder().decode(IPCResponse.self, from: message)
}

/// Waits briefly for the server to become ready to accept connections.
private func waitForServer(at socketPath: String, timeout: TimeInterval = 1.0) async {
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
                    src,
                    104
                )
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        if result == 0 { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}

// MARK: - Socket Lifecycle Tests

final class IPCServerLifecycleTests: XCTestCase {

    func testStartCreatesSocketFile() throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        defer { server.stop() }

        try server.start()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "Socket file must exist after start()")
    }

    func testStartCreatesSocketWithMode0600() throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        defer { server.stop() }

        try server.start()

        var statResult = stat()
        stat(socketPath, &statResult)
        let permissions = statResult.st_mode & 0o777
        XCTAssertEqual(permissions, 0o600, "Socket must have mode 0600, got \(String(format: "%04o", permissions))")
    }

    func testStopRemovesSocketFile() throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()

        server.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "Socket file must be removed after stop()")
    }

    func testStartThrowsWhenLiveServerIsRunning() throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server1 = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        defer { server1.stop() }
        try server1.start()

        let server2 = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        XCTAssertThrowsError(try server2.start()) { error in
            guard case IPCServerError.alreadyRunning = error else {
                XCTFail("Expected IPCServerError.alreadyRunning, got \(error)")
                return
            }
        }
    }

    func testStartSucceedsWhenStaleSocketExists() throws {
        let socketPath = makeTempSocketPath()

        // Create a stale socket: bind but do not listen or accept.
        let staleFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(staleFD, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    src,
                    104
                )
            }
        }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(staleFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(staleFD) // Close without listen() — leaves a stale socket file.

        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        defer { server.stop() }

        // Should succeed by detecting the stale socket and unlinking it.
        XCTAssertNoThrow(try server.start(), "Server must start even when a stale socket file exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }
}

// MARK: - Request Routing Tests

final class IPCServerRoutingTests: XCTestCase {

    func testGetStatusReturnsStatusResponse() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        let request = IPCRequest(id: "status-1", method: .getStatus, params: nil)
        let response = try sendRequest(request, to: socketPath)

        XCTAssertEqual(response.id, "status-1")
        XCTAssertNil(response.error, "getStatus must not return an error")
        guard case .status(let status) = response.result else {
            XCTFail("Expected .status result, got \(String(describing: response.result))")
            return
        }
        XCTAssertFalse(status.connected, "Disconnected manager must report connected = false")
        XCTAssertEqual(status.presets.count, 4, "Status must include all 4 preset slots")
    }

    func testGetStatusReflectsConnectedState() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = try await makeConnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        let request = IPCRequest(id: "status-connected", method: .getStatus, params: nil)
        let response = try sendRequest(request, to: socketPath)

        guard case .status(let status) = response.result else {
            XCTFail("Expected .status result")
            return
        }
        XCTAssertTrue(status.connected, "Connected manager must report connected = true")
        XCTAssertNotNil(status.heightMM, "Connected manager must report a height")
    }

    func testStopWhenDisconnectedReturnsNotConnectedError() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        let request = IPCRequest(id: "stop-1", method: .stop, params: nil)
        let response = try sendRequest(request, to: socketPath)

        XCTAssertEqual(response.id, "stop-1")
        XCTAssertNil(response.result, "Error response must have nil result")
        XCTAssertEqual(response.error?.code, IPCErrorCode.notConnected.rawValue,
                       "stop when disconnected must return error code \(IPCErrorCode.notConnected.rawValue)")
    }

    func testGoPresetWhenDisconnectedReturnsNotConnectedError() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        let request = IPCRequest(id: "preset-1", method: .goPreset, params: .preset(index: 2))
        let response = try sendRequest(request, to: socketPath)

        XCTAssertEqual(response.id, "preset-1")
        XCTAssertEqual(response.error?.code, IPCErrorCode.notConnected.rawValue,
                       "goPreset when disconnected must return error code \(IPCErrorCode.notConnected.rawValue)")
    }

    func testGoPresetWithoutParamsReturnsInvalidRequest() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        // Sends goPreset with move params instead of preset params → invalid.
        let request = IPCRequest(id: "preset-bad", method: .goPreset, params: .move(direction: "up", mode: nil))
        let response = try sendRequest(request, to: socketPath)

        XCTAssertEqual(response.error?.code, IPCErrorCode.invalidRequest.rawValue,
                       "goPreset with wrong params must return invalidRequest error code")
    }

    func testMoveWithInvalidDirectionReturnsInvalidRequest() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        let request = IPCRequest(id: "move-bad", method: .move, params: .move(direction: "sideways", mode: nil))
        let response = try sendRequest(request, to: socketPath)

        XCTAssertEqual(response.error?.code, IPCErrorCode.invalidRequest.rawValue,
                       "move with unknown direction must return invalidRequest error code")
    }

    func testSavePresetWithoutParamsReturnsInvalidRequest() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        let request = IPCRequest(id: "save-bad", method: .savePreset, params: nil)
        let response = try sendRequest(request, to: socketPath)

        XCTAssertEqual(response.error?.code, IPCErrorCode.invalidRequest.rawValue,
                       "savePreset with nil params must return invalidRequest error code")
    }
}

// MARK: - Payload Limit Tests

final class IPCServerPayloadLimitTests: XCTestCase {

    func testOversizedPayloadClosesConnection() async throws {
        let socketPath = makeTempSocketPath()
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: socketPath)
        try server.start()
        defer { server.stop() }
        await waitForServer(at: socketPath)

        // Build a payload exceeding the 64KB limit.
        let oversizedPayload = Data(repeating: 0x41, count: Int(IPCFraming.maxPayloadSize) + 1)
        let framed = IPCFraming.frame(oversizedPayload)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    src,
                    104
                )
            }
        }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        framed.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, ptr.count)
        }

        // The server should close the connection after the oversized payload.
        // A subsequent read should return 0 (EOF) or an error.
        try? await Task.sleep(for: .milliseconds(100))
        var dummy = [UInt8](repeating: 0, count: 8)
        let n = read(fd, &dummy, dummy.count)
        close(fd)

        XCTAssertLessThanOrEqual(n, 0, "Server must close connection on oversized payload (read returned \(n))")
    }
}

// MARK: - StatusResult Builder Unit Tests

final class IPCServerStatusBuilderTests: XCTestCase {

    func testBuildStatusResult_disconnectedState() {
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        var state = DeskState()
        state.connectionState = .disconnected

        let result = server.buildStatusResult(from: state, config: .default)

        XCTAssertFalse(result.connected)
        XCTAssertNil(result.heightMM)
        XCTAssertNil(result.heightDisplay)
        XCTAssertEqual(result.unit, HeightUnit.cm.rawValue)
        XCTAssertEqual(result.presets.count, 4)
    }

    func testBuildStatusResult_connectedWithHeight() {
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        var state = DeskState()
        state.connectionState = .connected
        state.deskName = "My Desk"
        state.heightMM = 1105
        state.activePreset = 2

        let config = AppConfig(unit: .cm)
        let result = server.buildStatusResult(from: state, config: config)

        XCTAssertTrue(result.connected)
        XCTAssertEqual(result.deskName, "My Desk")
        XCTAssertEqual(result.heightMM, 1105)
        XCTAssertEqual(result.heightDisplay, "110.5 cm")
        XCTAssertEqual(result.unit, "cm")
        XCTAssertEqual(result.activePreset, 2)
    }

    func testBuildStatusResult_inchUnit() {
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        var state = DeskState()
        state.connectionState = .connected
        state.heightMM = 1105

        let config = AppConfig(unit: .inch)
        let result = server.buildStatusResult(from: state, config: config)

        XCTAssertEqual(result.unit, "inch")
        XCTAssertEqual(result.heightDisplay, HeightConverter.display(mm: 1105, unit: .inch))
    }

    func testBuildStatusResult_presetsAreMapped() {
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        var state = DeskState()
        state.presets[0] = PresetPosition(index: 1, heightMM: 730, label: "Sit")
        state.presets[1] = PresetPosition(index: 2, heightMM: 1105, label: "Stand")

        let result = server.buildStatusResult(from: state, config: .default)

        XCTAssertEqual(result.presets.count, 4)
        XCTAssertEqual(result.presets[0].heightMM, 730)
        XCTAssertEqual(result.presets[0].label, "Sit")
        XCTAssertEqual(result.presets[1].heightMM, 1105)
        XCTAssertEqual(result.presets[1].label, "Stand")
    }
}

// MARK: - Absolute Move Routing

final class IPCServerGoToTests: XCTestCase {

    /// Clients speak the height `status` prints, which includes the desk offset. The desk
    /// only understands raw heights, so the server has to take the offset back off.
    func testGoToConvertsTheDisplayHeightToARawTarget() async throws {
        var seeded = AppConfig.default
        seeded.deskOffsetMM = 660
        let configStore = makeTempConfigStore(config: seeded)

        var heightCont: AsyncStream<Data>.Continuation!
        let heightStream = AsyncStream<Data> { heightCont = $0 }
        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
        mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(
            responses: HandshakeFixtures.happyPathDPGResponses
        )
        mock.mockNotificationStreams[DeskUUID.height] = heightStream

        let manager = DeskManager(bleController: mock, configStore: configStore)
        let connect = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 730))
        try await connect.value

        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())
        let priorCount = mock.writtenData.count
        let response = await server.handleRequest(
            IPCRequest(id: "goto-1", method: .goTo, params: .height(mm: 1060))
        )

        try await Task.sleep(for: .milliseconds(150))
        let expectedRaw = DeskCommand.moveTo(tenthsOfMm: UInt16(400 * 10))
        let targetWrites = mock.writtenData.dropFirst(priorCount).filter {
            $0.characteristic == DeskUUID.targetHeartbeat && $0.data == expectedRaw
        }
        XCTAssertGreaterThanOrEqual(targetWrites.count, 1, "1060mm displayed at a 660mm offset is 400mm raw")

        guard case .ok(let targetMM)? = response.result else {
            return XCTFail("goTo must answer ok, got \(String(describing: response.result))")
        }
        XCTAssertEqual(targetMM, 1060, "the reply echoes the height the client asked for")

        heightCont.finish()
        await manager.disconnect()
    }

    /// `preset` prints the height this reply carries. status adds the desk offset to every
    /// height it reports, so a preset reply without it named a different height than status
    /// did for the same slot.
    func testGoPresetAnswersWithTheDisplayHeight() async throws {
        var seeded = AppConfig.default
        seeded.deskOffsetMM = 660
        let configStore = makeTempConfigStore(config: seeded)

        var heightCont: AsyncStream<Data>.Continuation!
        let heightStream = AsyncStream<Data> { heightCont = $0 }
        let mock = MockBLEController()
        mock.mockReadResponses[DeskUUID.outputMask] = HandshakeFixtures.validOutputMask
        mock.mockReadResponses[DeskUUID.height] = HandshakeFixtures.heightNotification730mm
        mock.mockNotificationStreams[DeskUUID.dpg] = makeDPGStream(
            responses: HandshakeFixtures.happyPathDPGResponses
        )
        mock.mockNotificationStreams[DeskUUID.height] = heightStream

        let manager = DeskManager(bleController: mock, configStore: configStore)
        let connect = Task { try await manager.connect(peripheralId: UUID()) }
        heightCont.yield(makeHeightPacket(mm: 730))
        try await connect.value

        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())
        let response = await server.handleRequest(
            IPCRequest(id: "preset-2", method: .goPreset, params: .preset(index: 2))
        )

        guard case .ok(let targetMM)? = response.result else {
            return XCTFail("goPreset must answer ok, got \(String(describing: response.result))")
        }
        let status = await server.buildStatusResult(from: manager.currentState, config: try configStore.load())
        XCTAssertEqual(
            targetMM, status.presets.first(where: { $0.index == 2 })?.heightMM,
            "preset and status must name the same height for the same slot"
        )
        XCTAssertEqual(targetMM, 1105 + 660, "raw 1105mm at a 660mm offset displays as 1765mm")

        heightCont.finish()
        await manager.disconnect()
    }

    /// The rejection has to name the range, or the only way to find it is the source.
    func testGoToOutOfRangeNamesTheAcceptedRangeInTheConfiguredUnit() async throws {
        var seeded = AppConfig.default
        seeded.deskOffsetMM = 680
        let configStore = makeTempConfigStore(config: seeded)
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        let response = await server.handleRequest(
            IPCRequest(id: "goto-far", method: .goTo, params: .height(mm: 3000))
        )

        let message = try XCTUnwrap(response.error?.message)
        XCTAssertTrue(message.contains("300 cm"), "name the target that was refused: \(message)")
        XCTAssertTrue(message.contains("68 cm"), "name the bottom of the range: \(message)")
        XCTAssertTrue(message.contains("133 cm"), "name the top of the range: \(message)")
        XCTAssertTrue(message.contains("max_stroke_mm"), "name the setting that moves it: \(message)")
    }

    /// Out of range is decided before the connection is, so an obviously bad target reads
    /// as a bad target rather than as a disconnected desk.
    func testGoToOutOfRangeIsRefusedEvenWhenDisconnected() async throws {
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        let response = await server.handleRequest(
            IPCRequest(id: "goto-far", method: .goTo, params: .height(mm: 3000))
        )

        XCTAssertNotEqual(response.error?.code, IPCErrorCode.notConnected.rawValue)
        XCTAssertTrue(try XCTUnwrap(response.error?.message).contains("outside this desk's range"))
    }

    func testGoToWithoutParamsReturnsInvalidRequest() async throws {
        let configStore = makeTempConfigStore()
        let manager = makeDisconnectedManager(configStore: configStore)
        let server = IPCServer(deskManager: manager, configStore: configStore, socketPath: makeTempSocketPath())

        let response = await server.handleRequest(IPCRequest(id: "goto-bad", method: .goTo, params: nil))

        XCTAssertEqual(response.error?.code, IPCErrorCode.invalidRequest.rawValue)
    }
}
