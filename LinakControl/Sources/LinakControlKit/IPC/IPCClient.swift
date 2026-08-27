// IPCClient.swift
// LinakControlKit — Unix domain socket client used by the deskctl CLI.

import Foundation
import Darwin

// MARK: - IPCClientError

/// Errors specific to the CLI's IPC communication.
public enum IPCClientError: Error, Equatable {
    case daemonNotRunning
    case connectionFailed(String)
    case invalidResponse
    case serverError(code: Int, message: String)

    public static func == (lhs: IPCClientError, rhs: IPCClientError) -> Bool {
        switch (lhs, rhs) {
        case (.daemonNotRunning, .daemonNotRunning): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.connectionFailed(let l), .connectionFailed(let r)): return l == r
        case (.serverError(let lc, let lm), .serverError(let rc, let rm)): return lc == rc && lm == rm
        default: return false
        }
    }
}

// MARK: - IPCClient

/// Synchronous Unix domain socket client for the deskctl CLI.
public final class IPCClient {
    private let socketPath: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(socketPath: String = IPCConstants.socketPath) {
        self.socketPath = socketPath
    }

    // MARK: - Public Interface

    /// Send a request and wait for the response.
    public func send(_ request: IPCRequest) throws -> IPCResponse {
        let fd = try openConnection()
        defer { close(fd) }

        try writeRequest(request, to: fd)
        return try readResponse(from: fd)
    }

    public func getStatus() throws -> StatusResult {
        let request = IPCRequest(id: UUID().uuidString, method: .getStatus, params: nil)
        let response = try send(request)
        guard let result = response.result, case .status(let status) = result else {
            throw IPCClientError.invalidResponse
        }
        return status
    }

    public func move(direction: String, mode: String?) throws {
        let request = IPCRequest(id: UUID().uuidString, method: .move, params: .move(direction: direction, mode: mode))
        let response = try send(request)
        try assertOkResult(response)
    }

    public func stop() throws {
        let request = IPCRequest(id: UUID().uuidString, method: .stop, params: nil)
        let response = try send(request)
        try assertOkResult(response)
    }

    public func goPreset(index: Int) throws -> Int? {
        let request = IPCRequest(id: UUID().uuidString, method: .goPreset, params: .preset(index: index))
        let response = try send(request)
        return try extractTargetMM(response)
    }

    public func savePreset(index: Int) throws -> Int? {
        let request = IPCRequest(id: UUID().uuidString, method: .savePreset, params: .preset(index: index))
        let response = try send(request)
        return try extractTargetMM(response)
    }

    /// Tells a running daemon to re-read config. Callers that only changed a stored
    /// value can ignore the failure: with no daemon there is no stale state to fix.
    public func reloadConfig() throws {
        let request = IPCRequest(id: UUID().uuidString, method: .reloadConfig, params: nil)
        let response = try send(request)
        try assertOkResult(response)
    }

    // MARK: - Connection

    private func openConnection() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCClientError.connectionFailed("socket() failed: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, 104)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, addrLen)
            }
        }

        if result != 0 {
            let err = errno
            close(fd)
            if err == ENOENT || err == ECONNREFUSED {
                throw IPCClientError.daemonNotRunning
            }
            throw IPCClientError.connectionFailed("connect() failed: \(String(cString: strerror(err)))")
        }

        return fd
    }

    // MARK: - Write

    private func writeRequest(_ request: IPCRequest, to fd: Int32) throws {
        let payload: Data
        do {
            payload = try encoder.encode(request)
        } catch {
            throw IPCClientError.connectionFailed("encoding failed: \(error.localizedDescription)")
        }

        let framed = IPCFraming.frame(payload)
        try writeAll(framed, to: fd)
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, ptr.count)
            }
            if written < 0 {
                throw IPCClientError.connectionFailed("write() failed: \(String(cString: strerror(errno)))")
            }
            remaining = remaining.dropFirst(written)
        }
    }

    // MARK: - Read

    private func readResponse(from fd: Int32) throws -> IPCResponse {
        var buffer = Data()
        let chunkSize = 4096

        while true {
            var chunk = Data(count: chunkSize)
            let bytesRead = chunk.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!, chunkSize)
            }

            if bytesRead < 0 {
                throw IPCClientError.connectionFailed("read() failed: \(String(cString: strerror(errno)))")
            }
            if bytesRead == 0 && buffer.isEmpty {
                throw IPCClientError.invalidResponse
            }

            buffer.append(chunk.prefix(bytesRead))

            if let (message, _) = IPCFraming.deframe(buffer) {
                return try decodeResponse(message)
            }

            if bytesRead == 0 {
                throw IPCClientError.invalidResponse
            }
        }
    }

    private func decodeResponse(_ data: Data) throws -> IPCResponse {
        let response: IPCResponse
        do {
            response = try decoder.decode(IPCResponse.self, from: data)
        } catch {
            throw IPCClientError.invalidResponse
        }

        if let err = response.error {
            throw IPCClientError.serverError(code: err.code, message: err.message)
        }

        return response
    }

    // MARK: - Result Extraction

    private func assertOkResult(_ response: IPCResponse) throws {
        guard let result = response.result, case .ok = result else {
            throw IPCClientError.invalidResponse
        }
    }

    private func extractTargetMM(_ response: IPCResponse) throws -> Int? {
        guard let result = response.result, case .ok(let targetMM) = result else {
            throw IPCClientError.invalidResponse
        }
        return targetMM
    }
}
