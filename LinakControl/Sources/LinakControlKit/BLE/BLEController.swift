// BLEController.swift
// LinakControlKit — CoreBluetooth implementation of BLEControllerProtocol.

import CoreBluetooth
import Foundation

// MARK: - BLEController

/// Wraps `CBCentralManager` and bridges CoreBluetooth delegate callbacks to async/await.
///
/// Thread safety is enforced via a dedicated serial `DispatchQueue`.
/// The class is marked `@unchecked Sendable` because mutating state is always
/// accessed on `bleQueue`, not through Swift concurrency primitives.
public final class BLEController: NSObject, BLEControllerProtocol, @unchecked Sendable {

    // MARK: - Private state

    private let bleQueue = DispatchQueue(label: "com.linakcontrol.ble", qos: .userInitiated)

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var discoveredCharacteristics: [CBUUID: CBCharacteristic] = [:]

    // Scan stream
    private var scanContinuation: AsyncStream<DiscoveredDesk>.Continuation?

    // State stream
    private var stateContinuation: AsyncStream<BLEState>.Continuation?

    // Write continuations keyed by characteristic UUID
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    // Read continuations keyed by characteristic UUID
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]

    // Notify enable/disable continuations keyed by characteristic UUID
    private var notifyContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    // Notification value streams keyed by characteristic UUID
    private var notificationContinuations: [CBUUID: AsyncStream<Data>.Continuation] = [:]

    // Connect continuation — resolves after service+characteristic discovery
    private var connectContinuation: CheckedContinuation<Void, Error>?

    // MARK: - BLEControllerProtocol — stateStream

    public let stateStream: AsyncStream<BLEState>

    // MARK: - Init

    override public init() {
        var stateCont: AsyncStream<BLEState>.Continuation!
        stateStream = AsyncStream { continuation in
            stateCont = continuation
        }
        super.init()
        stateContinuation = stateCont
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - BLEControllerProtocol — scan

    public func scanForPeripherals() -> AsyncStream<DiscoveredDesk> {
        FileLog.debug("scanForPeripherals() called", category: "ble")
        return AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            bleQueue.async {
                self.scanContinuation?.finish()
                self.scanContinuation = continuation
                FileLog.debug("centralManager.scanForPeripherals starting", category: "ble")
                self.centralManager.scanForPeripherals(
                    withServices: [DeskUUID.controlService],
                    options: nil
                )
                // Auto-stop scan after 15 seconds to conserve radio/battery.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                    self?.stopScan()
                }
            }
        }
    }

    public func stopScan() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            centralManager.stopScan()
            scanContinuation?.finish()
            scanContinuation = nil
        }
    }

    // MARK: - BLEControllerProtocol — connect / disconnect

    public func connect(peripheralId: UUID) async throws {
        FileLog.debug("connect(peripheralId: \(peripheralId)) called", category: "ble")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bleQueue.async { [weak self] in
                guard let self else {
                    FileLog.debug("connect: self deallocated", category: "ble")
                    continuation.resume(throwing: BLEError.connectionFailed)
                    return
                }

                // Reject concurrent connect attempts.
                guard self.connectContinuation == nil else {
                    FileLog.debug("connect: rejected -- another connect in progress", category: "ble")
                    continuation.resume(throwing: BLEError.connectionFailed)
                    return
                }

                let peripherals = centralManager.retrievePeripherals(withIdentifiers: [peripheralId])
                FileLog.debug("connect: retrievePeripherals returned \(peripherals.count) result(s)", category: "ble")

                guard let peripheral = peripherals.first else {
                    FileLog.debug("connect: no peripheral found for UUID", category: "ble")
                    continuation.resume(throwing: BLEError.connectionFailed)
                    return
                }

                FileLog.debug("connect: calling centralManager.connect for '\(peripheral.name ?? "unknown")'", category: "ble")
                self.connectContinuation = continuation
                self.connectedPeripheral = peripheral
                peripheral.delegate = self
                self.centralManager.connect(peripheral, options: nil)
            }
        }
        FileLog.debug("connect: continuation resolved -- BLE connected + services discovered", category: "ble")
    }

    public func disconnect() {
        bleQueue.async { [weak self] in
            guard let self, let peripheral = connectedPeripheral else { return }
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    public func connectedPeripheralName() async -> String? {
        await withCheckedContinuation { continuation in
            bleQueue.async { [weak self] in
                continuation.resume(returning: self?.connectedPeripheral?.name)
            }
        }
    }

    // MARK: - BLEControllerProtocol — write

    public func write(
        data: Data,
        to characteristicUUID: CBUUID,
        type: CBCharacteristicWriteType
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }
                guard let peripheral = connectedPeripheral else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }
                guard let characteristic = discoveredCharacteristics[characteristicUUID] else {
                    continuation.resume(throwing: BLEError.characteristicNotFound(characteristicUUID))
                    return
                }

                #if DEBUG
                // Per-write hexdump fires at ~10 Hz during movement — trace-level
                // and DEBUG-only so it never floods the bounded release log.
                let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                let typeStr = type == .withResponse ? "withResponse" : "withoutResponse"
                let props = characteristic.properties
                FileLog.trace("write: [\(hex)] to \(characteristicUUID.uuidString) type=\(typeStr) props=\(props.rawValue)", category: "ble")
                #endif

                if type == .withResponse {
                    // Reject if a write is already in flight for this UUID.
                    if self.writeContinuations[characteristicUUID] != nil {
                        continuation.resume(throwing: BLEError.notConnected)
                        return
                    }
                    self.writeContinuations[characteristicUUID] = continuation
                } else {
                    // withoutResponse: fire-and-forget; resolve immediately
                    continuation.resume()
                }
                peripheral.writeValue(data, for: characteristic, type: type)
            }
        }
    }

    // MARK: - BLEControllerProtocol — read

    public func read(_ characteristicUUID: CBUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            bleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }
                guard let peripheral = connectedPeripheral else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }
                guard let characteristic = discoveredCharacteristics[characteristicUUID] else {
                    continuation.resume(throwing: BLEError.characteristicNotFound(characteristicUUID))
                    return
                }
                readContinuations[characteristicUUID] = continuation
                peripheral.readValue(for: characteristic)
            }
        }
    }

    // MARK: - BLEControllerProtocol — notifications

    public func notifications(for characteristicUUID: CBUUID) -> AsyncStream<Data> {
        AsyncStream { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            bleQueue.async {
                self.notificationContinuations[characteristicUUID]?.finish()
                self.notificationContinuations[characteristicUUID] = continuation
            }
        }
    }

    public func setNotifyValue(_ enabled: Bool, for characteristicUUID: CBUUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }
                guard let peripheral = connectedPeripheral else {
                    continuation.resume(throwing: BLEError.notConnected)
                    return
                }
                guard let characteristic = discoveredCharacteristics[characteristicUUID] else {
                    continuation.resume(throwing: BLEError.characteristicNotFound(characteristicUUID))
                    return
                }
                notifyContinuations[characteristicUUID] = continuation
                peripheral.setNotifyValue(enabled, for: characteristic)
            }
        }
    }

    // MARK: - Private helpers

    /// Atomically removes and returns the stored connect continuation.
    /// Prevents double-resume when disconnect and characteristic-discovery race.
    private func takeConnectContinuation() -> CheckedContinuation<Void, Error>? {
        defer { connectContinuation = nil }
        return connectContinuation
    }

    /// Atomically removes and returns a stored write continuation for a UUID.
    private func takeWriteContinuation(for uuid: CBUUID) -> CheckedContinuation<Void, Error>? {
        return writeContinuations.removeValue(forKey: uuid)
    }

    /// Atomically removes and returns a stored read continuation for a UUID.
    private func takeReadContinuation(for uuid: CBUUID) -> CheckedContinuation<Data, Error>? {
        return readContinuations.removeValue(forKey: uuid)
    }

    /// Atomically removes and returns a stored notify continuation for a UUID.
    private func takeNotifyContinuation(for uuid: CBUUID) -> CheckedContinuation<Void, Error>? {
        return notifyContinuations.removeValue(forKey: uuid)
    }

    private func cleanUpOnDisconnect() {
        connectedPeripheral = nil
        discoveredCharacteristics = [:]
        takeConnectContinuation()?.resume(throwing: BLEError.connectionFailed)
        for (_, cont) in writeContinuations { cont.resume(throwing: BLEError.notConnected) }
        writeContinuations = [:]
        for (_, cont) in readContinuations { cont.resume(throwing: BLEError.notConnected) }
        readContinuations = [:]
        for (_, cont) in notifyContinuations { cont.resume(throwing: BLEError.notConnected) }
        notifyContinuations = [:]
        for (_, cont) in notificationContinuations { cont.finish() }
        notificationContinuations = [:]
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEController: CBCentralManagerDelegate {

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state: BLEState
        switch central.state {
        case .unknown:       state = .unknown
        case .resetting:     state = .resetting
        case .unsupported:   state = .unsupported
        case .unauthorized:  state = .unauthorized
        case .poweredOff:    state = .poweredOff
        case .poweredOn:     state = .poweredOn
        @unknown default:    state = .unknown
        }
        FileLog.debug("centralManagerDidUpdateState: \(state)", category: "ble")
        stateContinuation?.yield(state)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = String((peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown").prefix(64))
        FileLog.debug("didDiscover: '\(name)' id=\(peripheral.identifier) rssi=\(RSSI)", category: "ble")
        let desk = DiscoveredDesk(
            peripheralId: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue
        )
        scanContinuation?.yield(desk)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        FileLog.debug("didConnect: '\(peripheral.name ?? "unknown")' -- discovering services", category: "ble")
        peripheral.discoverServices([
            DeskUUID.controlService,
            DeskUUID.dpgService,
            DeskUUID.referenceOutputService,
            DeskUUID.referenceInputService
        ])
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let err = error.map { BLEError.connectFailure($0) } ?? BLEError.connectionFailed
        FileLog.debug("didFailToConnect: \(error?.localizedDescription ?? "unknown")", category: "ble")
        takeConnectContinuation()?.resume(throwing: err)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        FileLog.debug("didDisconnect: '\(peripheral.name ?? "unknown")' error=\(error?.localizedDescription ?? "none")", category: "ble")
        cleanUpOnDisconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEController: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            FileLog.debug("didDiscoverServices: ERROR \(error.localizedDescription)", category: "ble")
            takeConnectContinuation()?.resume(throwing: BLEError.connectFailure(error))
            return
        }
        let serviceIDs = (peripheral.services ?? []).map { $0.uuid.uuidString }
        FileLog.debug("didDiscoverServices: \(serviceIDs)", category: "ble")
        guard let services = peripheral.services, !services.isEmpty else {
            FileLog.debug("didDiscoverServices: no services found", category: "ble")
            takeConnectContinuation()?.resume(throwing: BLEError.connectionFailed)
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            takeConnectContinuation()?.resume(throwing: BLEError.connectFailure(error))
            return
        }
        let charIDs = (service.characteristics ?? []).map { $0.uuid.uuidString }
        FileLog.debug("didDiscoverCharacteristics for \(service.uuid.uuidString): \(charIDs)", category: "ble")
        for characteristic in service.characteristics ?? [] {
            discoveredCharacteristics[characteristic.uuid] = characteristic
        }

        // Resolve connect when all expected services have reported their characteristics.
        let allServices = peripheral.services ?? []
        let allDiscovered = allServices.allSatisfy { $0.characteristics != nil }
        FileLog.debug("allServicesDiscovered=\(allDiscovered) (\(allServices.count) services) hasContinuation=\(connectContinuation != nil)", category: "ble")
        if allDiscovered {
            FileLog.debug("connect continuation resolving -- all characteristics discovered", category: "ble")
            takeConnectContinuation()?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let continuation = takeWriteContinuation(for: characteristic.uuid) else { return }
        if let error {
            continuation.resume(throwing: BLEError.writeFailure(error))
        } else {
            continuation.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Read continuation takes priority over notification stream
        if let readCont = takeReadContinuation(for: characteristic.uuid) {
            if let error {
                readCont.resume(throwing: BLEError.readFailure(error))
            } else {
                readCont.resume(returning: characteristic.value ?? Data())
            }
            return
        }

        // Feed notification stream
        if let data = characteristic.value {
            notificationContinuations[characteristic.uuid]?.yield(data)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let continuation = takeNotifyContinuation(for: characteristic.uuid) else { return }
        if let error {
            continuation.resume(throwing: BLEError.notifyFailure(error))
        } else {
            continuation.resume()
        }
    }
}
