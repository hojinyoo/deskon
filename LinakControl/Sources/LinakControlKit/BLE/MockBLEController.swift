// MockBLEController.swift
// LinakControlKit — Test double for BLEControllerProtocol.

import CoreBluetooth
import Foundation

// MARK: - MockBLEController

/// A scripted mock for `BLEControllerProtocol` used in unit tests.
///
/// Configure `mockDesks`, `mockReadResponses`, and `mockNotificationStreams` before
/// exercising the system under test. Inspect `writtenData` to assert write behavior.
public final class MockBLEController: BLEControllerProtocol, @unchecked Sendable {

    // MARK: - Scripted inputs

    /// Desks emitted by ``scanForPeripherals()``. Yielded in order, then the stream terminates.
    public var mockDesks: [DiscoveredDesk] = []

    /// Data returned by ``read(_:)`` keyed by characteristic UUID.
    public var mockReadResponses: [CBUUID: Data] = [:]

    /// Streams returned by ``notifications(for:)`` keyed by characteristic UUID.
    public var mockNotificationStreams: [CBUUID: AsyncStream<Data>] = [:]

    /// Name returned by ``connectedPeripheralName()``. Nil mimics a peripheral with no name.
    public var mockConnectedName: String?

    // MARK: - Thread safety

    /// Protects mutable captured-output arrays from concurrent access.
    private let lock = NSLock()

    // MARK: - Captured outputs (lock-protected)

    /// Backing storage for ``writtenData``. Access via the computed property or ``getWrittenData()``.
    private var _writtenData: [(data: Data, characteristic: CBUUID)] = []

    /// All writes captured by ``write(data:to:type:)`` in call order.
    ///
    /// Thread-safe: reads and writes are protected by an internal lock.
    public var writtenData: [(data: Data, characteristic: CBUUID)] {
        get { lock.withLock { _writtenData } }
        set { lock.withLock { _writtenData = newValue } }
    }

    /// Backing storage for ``notifyValueCalls``.
    private var _notifyValueCalls: [(enabled: Bool, characteristic: CBUUID)] = []

    /// All setNotifyValue calls captured in call order.
    public var notifyValueCalls: [(enabled: Bool, characteristic: CBUUID)] {
        get { lock.withLock { _notifyValueCalls } }
        set { lock.withLock { _notifyValueCalls = newValue } }
    }

    /// Backing storage for ``connectCallCount``.
    private var _connectCallCount: Int = 0

    /// Number of times ``connect(peripheralId:)`` has been called.
    ///
    /// Thread-safe: reads and writes are protected by an internal lock.
    public var connectCallCount: Int {
        get { lock.withLock { _connectCallCount } }
        set { lock.withLock { _connectCallCount = newValue } }
    }

    // MARK: - Behaviour control

    /// When `true`, ``connect(peripheralId:)`` throws ``BLEError/connectionFailed``.
    public var shouldFailConnect: Bool = false

    /// Artificial delay injected into ``connect(peripheralId:)`` before resolving.
    public var connectDelay: Duration = .zero

    /// When `true`, ``write(data:to:type:)`` throws ``BLEError/notConnected`` —
    /// what a real write does once the link is gone.
    public var shouldFailWrite: Bool = false

    // MARK: - BLEControllerProtocol — stateStream

    public let stateStream: AsyncStream<BLEState>

    private let stateContinuation: AsyncStream<BLEState>.Continuation

    /// Inject a BLE state change into ``stateStream``.
    public func emitState(_ state: BLEState) {
        stateContinuation.yield(state)
    }

    // MARK: - BLEControllerProtocol — disconnections

    public let disconnections: AsyncStream<Void>

    private let disconnectContinuation: AsyncStream<Void>.Continuation

    /// Simulate the peripheral link dropping.
    public func emitDisconnection() {
        disconnectContinuation.yield()
    }

    // MARK: - Init

    public init() {
        var cont: AsyncStream<BLEState>.Continuation!
        stateStream = AsyncStream { continuation in
            cont = continuation
        }
        stateContinuation = cont
        var disconnectCont: AsyncStream<Void>.Continuation!
        disconnections = AsyncStream { continuation in
            disconnectCont = continuation
        }
        disconnectContinuation = disconnectCont
    }

    // MARK: - BLEControllerProtocol — scan

    public func scanForPeripherals() -> AsyncStream<DiscoveredDesk> {
        let desks = mockDesks
        return AsyncStream { continuation in
            for desk in desks {
                continuation.yield(desk)
            }
            continuation.finish()
        }
    }

    public func stopScan() {
        // No-op in mock: scan streams terminate immediately after yielding mockDesks.
    }

    // MARK: - BLEControllerProtocol — connect / disconnect

    public func connect(peripheralId: UUID) async throws {
        lock.withLock { _connectCallCount += 1 }
        if connectDelay > .zero {
            try await Task.sleep(for: connectDelay)
        }
        if shouldFailConnect {
            throw BLEError.connectionFailed
        }
    }

    public func disconnect() {
        // No-op in mock.
    }

    public func connectedPeripheralName() async -> String? {
        mockConnectedName
    }

    // MARK: - BLEControllerProtocol — write

    public func write(
        data: Data,
        to characteristic: CBUUID,
        type: CBCharacteristicWriteType
    ) async throws {
        if shouldFailWrite {
            throw BLEError.notConnected
        }
        lock.withLock {
            _writtenData.append((data: data, characteristic: characteristic))
        }
    }

    // MARK: - BLEControllerProtocol — read

    public func read(_ characteristic: CBUUID) async throws -> Data {
        guard let data = mockReadResponses[characteristic] else {
            throw BLEError.characteristicNotFound(characteristic)
        }
        return data
    }

    // MARK: - BLEControllerProtocol — notifications

    public func notifications(for characteristic: CBUUID) -> AsyncStream<Data> {
        if let stream = mockNotificationStreams[characteristic] {
            return stream
        }
        return AsyncStream { continuation in continuation.finish() }
    }

    public func setNotifyValue(_ enabled: Bool, for characteristic: CBUUID) async throws {
        lock.withLock {
            _notifyValueCalls.append((enabled: enabled, characteristic: characteristic))
        }
    }
}
