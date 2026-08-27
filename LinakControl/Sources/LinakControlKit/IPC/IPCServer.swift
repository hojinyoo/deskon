// IPCServer.swift
// LinakControl — Unix domain socket server that routes IPC requests to DeskManager.

import Foundation
import Darwin

// MARK: - IPCServerError

/// Errors thrown by `IPCServer.start()`.
public enum IPCServerError: Error, Sendable {
    /// Another daemon instance is already listening on the socket.
    case alreadyRunning(String)
    /// The socket could not be created or bound.
    case socketSetupFailed(String)
}

// MARK: - IPCServer

/// Unix domain socket server. Accepts client connections and routes
/// decoded `IPCRequest` messages to `DeskManager`.
///
/// Lifecycle:
/// - `start()` — creates the socket and begins accepting connections.
/// - `stop()` — tears down the accept loop and removes the socket file.
public final class IPCServer: @unchecked Sendable {

    // MARK: Dependencies

    private let deskManager: DeskManager
    private let configStore: ConfigStore
    private let socketPath: String

    // MARK: Socket state

    private var serverFileDescriptor: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.linakcontrol.ipc.accept")
    private let clientQueue = DispatchQueue(label: "com.linakcontrol.ipc.client", attributes: .concurrent)
    private var isAccepting = false

    // MARK: Connection limit

    private static let maxConcurrentConnections = 8
    private let connectionSemaphore = DispatchSemaphore(value: maxConcurrentConnections)

    // MARK: Init

    public init(deskManager: DeskManager, configStore: ConfigStore, socketPath: String? = nil) {
        self.deskManager = deskManager
        self.configStore = configStore
        self.socketPath = socketPath ?? IPCConstants.socketPath
    }

    // MARK: - Public API

    /// Creates the Unix domain socket, binds, listens, and begins accepting clients.
    ///
    /// Performs stale-socket detection before binding:
    /// - If a live server is found → throws `IPCServerError.alreadyRunning`.
    /// - If a stale socket exists → unlinks it and continues.
    ///
    /// - Throws: `IPCServerError` on setup failure.
    public func start() throws {
        try createSocketDirectory()
        try handleExistingSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCServerError.socketSetupFailed("socket() failed: \(String(cString: strerror(errno)))")
        }

        try bindAndListen(fd: fd)
        serverFileDescriptor = fd
        isAccepting = true

        acceptQueue.async { [weak self] in
            self?.runAcceptLoop()
        }
    }

    /// Cancels the accept loop, closes the server socket, and removes the socket file.
    public func stop() {
        isAccepting = false

        if serverFileDescriptor >= 0 {
            close(serverFileDescriptor)
            serverFileDescriptor = -1
        }

        unlink(socketPath)
    }

    // MARK: - Socket Setup

    private func createSocketDirectory() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir) else { return }
        do {
            try fm.createDirectory(
                atPath: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw IPCServerError.socketSetupFailed("Cannot create socket directory '\(dir)': \(error)")
        }
    }

    private func handleExistingSocket() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }

        let probeFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else { return }
        defer { close(probeFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, 104)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(probeFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result == 0 {
            // Connected — another instance is live.
            throw IPCServerError.alreadyRunning("Another daemon is already listening on \(socketPath)")
        } else if errno == ECONNREFUSED {
            // Stale socket — safe to unlink.
            unlink(socketPath)
        }
        // ENOENT or any other error: proceed normally.
    }

    private func bindAndListen(fd: Int32) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, 104)
            }
        }

        // Set restrictive umask before bind to avoid TOCTOU race on socket permissions.
        // bind() creates the socket file with (0o777 & ~umask). Using 0o177 gives
        // rw------- (0o600) — no execute bit, owner-only read/write.
        let previousUmask = umask(0o177)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousUmask)

        guard bindResult == 0 else {
            close(fd)
            throw IPCServerError.socketSetupFailed("bind() failed: \(String(cString: strerror(errno)))")
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw IPCServerError.socketSetupFailed("listen() failed: \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Accept Loop

    /// Runs on `acceptQueue`. Calls blocking `accept()` on a dedicated thread,
    /// not the cooperative thread pool, to avoid starving Swift Concurrency.
    private func runAcceptLoop() {
        while isAccepting {
            let clientFD = accept(serverFileDescriptor, nil, nil)
            guard clientFD >= 0 else { break }

            // Enforce connection limit — reject when at capacity.
            guard connectionSemaphore.wait(timeout: .now()) == .success else {
                close(clientFD)
                continue
            }

            clientQueue.async { [weak self] in
                self?.handleClient(fd: clientFD)
            }
        }
    }

    // MARK: - Client Handling

    /// Runs on `clientQueue`. Blocking `read()` calls execute on a DispatchQueue
    /// thread, not the cooperative thread pool. Bridges to async for message processing.
    private func handleClient(fd: Int32) {
        defer {
            close(fd)
            connectionSemaphore.signal()
        }

        var buffer = Data()
        let chunkSize = 4096
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let bytesRead = read(fd, &chunk, chunkSize)
            if bytesRead <= 0 { break }

            buffer.append(contentsOf: chunk[..<bytesRead])

            if buffer.count > Int(IPCFraming.maxPayloadSize) + 4 {
                break
            }

            while let (message, remaining) = IPCFraming.deframe(buffer) {
                buffer = remaining
                let semaphore = DispatchSemaphore(value: 0)
                Task { [weak self] in
                    await self?.processMessage(message, fd: fd)
                    semaphore.signal()
                }
                semaphore.wait()
            }
        }
    }

    private func processMessage(_ message: Data, fd: Int32) async {
        let response: IPCResponse
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: message)
            response = await handleRequest(request)
        } catch {
            let errorPayload = IPCErrorPayload(code: IPCErrorCode.invalidRequest.rawValue, message: "Malformed request: \(error)")
            response = IPCResponse(id: "unknown", result: nil, error: errorPayload)
        }
        sendResponse(response, fd: fd)
    }

    private func sendResponse(_ response: IPCResponse, fd: Int32) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        let framed = IPCFraming.frame(data)
        framed.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, ptr.count)
        }
    }

    // MARK: - Request Routing

    func handleRequest(_ request: IPCRequest) async -> IPCResponse {
        switch request.method {
        case .getStatus:
            return await handleGetStatus(request)
        case .move:
            return await handleMove(request)
        case .stop:
            return await handleStop(request)
        case .goPreset:
            return await handleGoPreset(request)
        case .savePreset:
            return await handleSavePreset(request)
        }
    }

    private func handleGetStatus(_ request: IPCRequest) async -> IPCResponse {
        let state = await deskManager.currentState
        let config = (try? configStore.load()) ?? .default
        let statusResult = buildStatusResult(from: state, config: config)
        return IPCResponse(id: request.id, result: .status(statusResult), error: nil)
    }

    private func handleMove(_ request: IPCRequest) async -> IPCResponse {
        guard let params = request.params, case .move(let direction, let mode) = params else {
            return makeError(id: request.id, code: .invalidRequest, message: "missing direction")
        }
        let runMode: RunMode = (mode == "auto") ? .auto : .manual
        do {
            if direction == "up" {
                try await deskManager.moveUp(mode: runMode)
            } else if direction == "down" {
                try await deskManager.moveDown(mode: runMode)
            } else {
                return makeError(id: request.id, code: .invalidRequest, message: "unknown direction '\(direction)'")
            }
            return IPCResponse(id: request.id, result: .ok(targetMM: nil), error: nil)
        } catch {
            return deskErrorResponse(id: request.id, error: error)
        }
    }

    private func handleStop(_ request: IPCRequest) async -> IPCResponse {
        do {
            try await deskManager.stop()
            return IPCResponse(id: request.id, result: .ok(targetMM: nil), error: nil)
        } catch {
            return deskErrorResponse(id: request.id, error: error)
        }
    }

    private func handleGoPreset(_ request: IPCRequest) async -> IPCResponse {
        guard let params = request.params, case .preset(let index) = params else {
            return makeError(id: request.id, code: .invalidRequest, message: "missing preset index")
        }
        do {
            try await deskManager.goToPreset(index: index)
            let state = await deskManager.currentState
            let targetMM = state.presets.first(where: { $0.index == index })?.heightMM
            return IPCResponse(id: request.id, result: .ok(targetMM: targetMM), error: nil)
        } catch {
            return deskErrorResponse(id: request.id, error: error)
        }
    }

    private func handleSavePreset(_ request: IPCRequest) async -> IPCResponse {
        guard let params = request.params, case .preset(let index) = params else {
            return makeError(id: request.id, code: .invalidRequest, message: "missing preset index")
        }
        do {
            try await deskManager.savePreset(index: index)
            return IPCResponse(id: request.id, result: .ok(targetMM: nil), error: nil)
        } catch {
            return deskErrorResponse(id: request.id, error: error)
        }
    }

    // MARK: - Error Helpers

    private func makeError(id: String, code: IPCErrorCode, message: String) -> IPCResponse {
        IPCResponse(id: id, result: nil, error: IPCErrorPayload(code: code.rawValue, message: message))
    }

    private func deskErrorResponse(id: String, error: Error) -> IPCResponse {
        let code: IPCErrorCode
        switch error {
        case DeskError.notConnected:
            code = .notConnected
        case DeskError.presetNotSet(_):
            code = .general
        case DeskError.targetOutOfRange(_):
            code = .general
        default:
            code = .general
        }
        return makeError(id: id, code: code, message: error.localizedDescription)
    }
}

// MARK: - StatusResult Builder

extension IPCServer {

    func buildStatusResult(from state: DeskState, config: AppConfig) -> StatusResult {
        let offset = state.deskOffsetMM
        let heightDisplay = state.heightMM.map { HeightConverter.display(mm: $0 + offset, unit: config.unit) }
        let presets = state.presets.map { preset in
            PresetInfo(
                index: preset.index,
                heightMM: preset.heightMM.map { $0 + offset },
                label: preset.label
            )
        }
        return StatusResult(
            connected: state.connectionState == .connected,
            // Read the user-set name from config, not state: `deskctl config name`
            // writes it directly and the daemon has no reason to reconnect.
            deskName: config.userDeskName ?? state.deskName,
            heightMM: state.heightMM.map { $0 + offset },
            heightDisplay: heightDisplay,
            unit: config.unit.rawValue,
            presets: presets,
            activePreset: state.activePreset,
            needsReference: state.needsReference,
            faultCode: state.faultCode.map(Int.init)
        )
    }
}
