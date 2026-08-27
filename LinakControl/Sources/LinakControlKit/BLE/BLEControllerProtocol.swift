// BLEControllerProtocol.swift
// LinakControlKit — Async BLE interface protocol enabling real and mock implementations.

import CoreBluetooth

// MARK: - DiscoveredDesk

/// A desk peripheral discovered during a BLE scan.
public struct DiscoveredDesk: Sendable {
    public let peripheralId: UUID
    public let name: String
    public let rssi: Int

    public init(peripheralId: UUID, name: String, rssi: Int) {
        self.peripheralId = peripheralId
        self.name = name
        self.rssi = rssi
    }
}

// MARK: - BLEState

/// The current state of the Bluetooth hardware.
public enum BLEState: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

// MARK: - BLEError

/// Errors surfaced by BLE operations.
public enum BLEError: Error, @unchecked Sendable {
    case notConnected
    case characteristicNotFound(CBUUID)
    case writeFailure(Error)
    case readFailure(Error)
    case connectFailure(Error)
    case notifyFailure(Error)
    case connectionFailed
}

// MARK: - BLEControllerProtocol

/// Async BLE interface for the LINAK DPG1C desk.
///
/// Conforming types bridge CoreBluetooth delegate callbacks to structured concurrency.
/// All methods must be safe to call from any actor context.
public protocol BLEControllerProtocol: AnyObject, Sendable {

    /// Emits BLE hardware state changes.
    var stateStream: AsyncStream<BLEState> { get }

    /// Scans for peripherals advertising ``DeskUUID/controlService``.
    ///
    /// The stream terminates when ``stopScan()`` is called.
    func scanForPeripherals() -> AsyncStream<DiscoveredDesk>

    /// Stops an active peripheral scan.
    func stopScan()

    /// Connects to the peripheral with the given ID and discovers its services.
    func connect(peripheralId: UUID) async throws

    /// Disconnects the current peripheral and cleans up state.
    func disconnect()

    /// Name reported by the currently connected peripheral, or nil when it has none.
    ///
    /// Only trustworthy once connected: CoreBluetooth leaves `peripheral.name` nil during
    /// a service-filtered scan, so ``DiscoveredDesk/name`` can be a placeholder.
    func connectedPeripheralName() async -> String?

    /// Writes data to a characteristic on the connected peripheral.
    func write(data: Data, to characteristic: CBUUID, type: CBCharacteristicWriteType) async throws

    /// Reads the current value of a characteristic from the connected peripheral.
    func read(_ characteristic: CBUUID) async throws -> Data

    /// Returns a stream of notification values for the given characteristic.
    func notifications(for characteristic: CBUUID) -> AsyncStream<Data>

    /// Subscribes or unsubscribes from notifications on the given characteristic.
    func setNotifyValue(_ enabled: Bool, for characteristic: CBUUID) async throws
}
