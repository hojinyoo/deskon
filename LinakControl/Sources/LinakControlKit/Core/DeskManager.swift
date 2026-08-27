// DeskManager.swift
// LinakControlKit — Central state coordinator for the LINAK DPG1C desk.

import Foundation

// MARK: - Constants

private let powerOnPollInterval: Duration = .milliseconds(100)

// MARK: - DeskManager

/// Actor that owns all desk state and orchestrates BLE operations.
///
/// Single source of truth per ADR-3. All state mutations occur inside the actor.
/// Observers receive a stream of `DeskState` snapshots via `stateStream`.
public actor DeskManager {

    // MARK: - Dependencies

    let bleController: any BLEControllerProtocol
    let configStore: ConfigStore
    let clock: any ClockProtocol

    // MARK: - State

    var state: DeskState
    private var heightNotificationTask: Task<Void, Never>?
    private var statusNotificationTask: Task<Void, Never>?
    var movementTask: Task<Void, Never>?
    var presetMoveTask: Task<Void, Never>?
    var reconnectionTask: Task<Void, Never>?
    var isUserInitiatedDisconnect: Bool = false

    /// Latest BLE hardware state, nil until CoreBluetooth reports one.
    private var bleState: BLEState?
    private var bleStateTask: Task<Void, Never>?

    // MARK: - State observation

    /// One continuation per active subscriber. A single `AsyncStream` delivers
    /// each element to only one consumer, so the UI and the notification
    /// observer must each get their own stream — otherwise they split the
    /// snapshots between them and the observer misses events (e.g. the
    /// needsReference edge → no notification).
    private var stateSubscribers: [UUID: AsyncStream<DeskState>.Continuation] = [:]

    /// A fresh, independent stream of `DeskState` snapshots for one subscriber.
    /// Each access registers a new subscriber (multicast) and immediately
    /// delivers the current snapshot. Every subscriber receives every update.
    public var stateStream: AsyncStream<DeskState> {
        let (stream, continuation) = AsyncStream<DeskState>.makeStream()
        let id = UUID()
        stateSubscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateSubscriber(id) }
        }
        return stream
    }

    private func removeStateSubscriber(_ id: UUID) {
        stateSubscribers[id] = nil
    }

    /// Fans the current state out to every active subscriber.
    private func yieldState() {
        for continuation in stateSubscribers.values {
            continuation.yield(state)
        }
    }

    // MARK: - Init

    public init(
        bleController: any BLEControllerProtocol,
        configStore: ConfigStore,
        clock: any ClockProtocol = SystemClock()
    ) {
        self.bleController = bleController
        self.configStore = configStore
        self.clock = clock
        self.state = DeskState()
    }

    // MARK: - State access

    /// Returns the current desk state snapshot.
    public var currentState: DeskState {
        state
    }

    // MARK: - BLE power state

    /// Suspends until CoreBluetooth reports the central manager is powered on.
    ///
    /// Connecting before then is wasted: `retrievePeripherals(withIdentifiers:)` returns
    /// nothing while the manager is still starting up, so an attempt made during the gap
    /// fails for a reason that has nothing to do with the desk.
    ///
    /// The wait is bounded: Bluetooth switched off is a state the user can fix at any
    /// time, and waiting on it forever leaves a caller suspended with nothing in the log
    /// to say why. Giving up instead lets the caller log it and lets the reconnection
    /// loop retry later.
    ///
    /// - Throws: `DeskError.bluetoothUnavailable` carrying the last state seen, both for
    ///   states no wait can fix (`.unauthorized`, `.unsupported`) and on timeout. The
    ///   payload is what separates the two.
    ///
    /// - Parameter timeout: Defaults to the 20 x 500ms bound this gate replaced.
    public func waitUntilPoweredOn(timeout: Duration = .seconds(10)) async throws {
        startBLEStateObserver()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            switch bleState {
            case .poweredOn:
                return
            case .unauthorized, .unsupported:
                throw DeskError.bluetoothUnavailable(bleState ?? .unknown)
            default:
                guard ContinuousClock.now < deadline else {
                    let last = bleState ?? .unknown
                    FileLog.debug("waitUntilPoweredOn: gave up, still \(last)", category: "core")
                    throw DeskError.bluetoothUnavailable(last)
                }
                // Real sleep, not `clock`: a TestClock never advances on its own, so
                // polling it here would hang every test that does not drive it.
                try await Task.sleep(for: powerOnPollInterval)
            }
        }
    }

    /// Records BLE hardware state from the controller's stream.
    ///
    /// Exactly one consumer: an `AsyncStream` hands each element to a single iterator, so
    /// a second reader would steal updates from this one.
    private func startBLEStateObserver() {
        guard bleStateTask == nil else { return }
        let stream = bleController.stateStream
        bleStateTask = Task { [weak self] in
            for await state in stream {
                guard let self else { return }
                await self.recordBLEState(state)
            }
        }
    }

    private func recordBLEState(_ state: BLEState) {
        bleState = state
    }

    deinit {
        bleStateTask?.cancel()
    }

    // MARK: - Config

    /// Re-reads the config values mirrored into `DeskState` and republishes it.
    ///
    /// `deskctl` writes config straight to disk, so without this a rename or a preset
    /// label reaches the CLI (which reloads per request) but not the menu bar, whose
    /// name and labels are otherwise only written at handshake time.
    public func reloadConfig() {
        let config = (try? configStore.load()) ?? .default
        state.deskName = config.resolvedDeskName
        for i in 0..<state.presets.count {
            state.presets[i].label = presetLabel(index: i + 1, config: config)
        }
        yieldState()
    }

    // MARK: - Connection lifecycle

    /// Scans for nearby LINAK desks and emits each discovered peripheral.
    ///
    /// Updates connection state to `.scanning` and delegates to the BLE controller.
    /// The returned stream terminates when the BLE controller finishes scanning.
    public func scan() -> AsyncStream<DiscoveredDesk> {
        updateState { $0.connectionState = .scanning }
        return bleController.scanForPeripherals()
    }

    /// Connects to a desk peripheral and performs the DPG1C handshake.
    ///
    /// State transitions: `.connecting` → `.connected` on success,
    /// `.connecting` → `.disconnected` on failure.
    ///
    /// - Parameter peripheralId: CoreBluetooth peripheral UUID from a scan result.
    /// - Throws: `BLEError` or `DeskError` on connection or handshake failure.
    public func connect(peripheralId: UUID) async throws {
        FileLog.debug("connect: starting for \(peripheralId)", category: "core")
        isUserInitiatedDisconnect = false
        updateState { $0.connectionState = .connecting }

        do {
            FileLog.debug("connect: BLE connect...", category: "core")
            try await bleController.connect(peripheralId: peripheralId)
            FileLog.debug("connect: BLE connected, sending wake-up...", category: "core")
            try? await bleController.write(data: DeskCommand.wakeUp, to: DeskUUID.command, type: .withoutResponse)
            FileLog.debug("connect: starting handshake...", category: "core")
            let result = try await performHandshake(using: bleController)
            FileLog.debug("connect: handshake complete, applying result", category: "core")
            let peripheralName = await bleController.connectedPeripheralName()
            applyHandshakeResult(result, peripheralId: peripheralId, peripheralName: peripheralName)
            startHeightNotificationListener()
            startStatusNotificationListener()
            FileLog.debug("connect: DONE -- state=connected", category: "core")
        } catch {
            FileLog.debug("connect: FAILED -- \(error)", category: "core")
            updateState { $0.connectionState = .disconnected }
            throw error
        }
    }

    /// Disconnects from the desk and resets state.
    ///
    /// Cancels the height notification listener and any pending reconnection.
    /// Preset labels from config are preserved.
    public func disconnect() async {
        isUserInitiatedDisconnect = true
        cancelConnectionTasks()
        bleController.disconnect()
        resetToDisconnected()
    }

    /// Stands the app down after a desk fault so the desk can be manually
    /// initialised without BLE interference. Like `disconnect()` (releases BLE
    /// and suppresses auto-reconnect), but PRESERVES `needsReference`/`faultCode`
    /// so the UI keeps showing why — a plain `disconnect()` would wipe them via
    /// `resetToDisconnected()`. Triggered on the needsReference rising edge by
    /// `ConnectionStateObserver`.
    public func standDown() async {
        guard state.connectionState == .connected else { return }
        isUserInitiatedDisconnect = true
        cancelConnectionTasks()
        bleController.disconnect()
        updateState {
            $0.connectionState = .disconnected
            $0.isMoving = false
            $0.moveDirection = nil
            $0.speedMMS = 0
            // needsReference / faultCode intentionally preserved.
        }
    }

    /// Cancels the background tasks tied to an active connection.
    private func cancelConnectionTasks() {
        heightNotificationTask?.cancel()
        heightNotificationTask = nil
        statusNotificationTask?.cancel()
        statusNotificationTask = nil
        reconnectionTask?.cancel()
        reconnectionTask = nil
    }

    // MARK: - Movement (implementation in DeskManager+Movement.swift)

    /// Moves the desk upward using the given run mode.
    ///
    /// - Throws: `DeskError.notConnected` if not currently connected.
    public func moveUp(mode: RunMode) async throws {
        try await startMovement(.up, mode: mode)
    }

    /// Moves the desk downward using the given run mode.
    ///
    /// - Throws: `DeskError.notConnected` if not currently connected.
    public func moveDown(mode: RunMode) async throws {
        try await startMovement(.down, mode: mode)
    }

    /// Stops all desk movement.
    ///
    /// Cancels any active manual movement or preset move, writes stop, and clears movement state.
    ///
    /// - Throws: `DeskError.notConnected` if not currently connected.
    public func stop() async throws {
        try requireConnected()
        await cancelMovementTask()
        await cancelPresetMoveTask()
        try await writeStopCommand()
        updateState {
            $0.isMoving = false
            $0.moveDirection = nil
            $0.targetPreset = nil
        }
    }

    // MARK: - Presets (implementation in DeskManager+Presets.swift)

    /// Moves the desk to the position stored in a preset slot.
    ///
    /// - Parameter index: Preset slot number (1–4).
    /// - Throws: `DeskError.notConnected`, `DeskError.presetNotSet`, or `DeskError.targetOutOfRange`.
    public func goToPreset(index: Int) async throws {
        try await executeGoToPreset(index: index)
    }

    /// Moves the desk to an absolute raw height.
    ///
    /// - Parameter mm: Target in raw desk millimetres, offset already removed.
    /// - Throws: `DeskError.notConnected` or `DeskError.targetOutOfRange`.
    public func moveToHeight(mm: Int) async throws {
        try await executeMoveToHeight(mm)
    }

    /// Saves the current desk height to a preset slot.
    ///
    /// - Parameter index: Preset slot number (1–4).
    /// - Throws: `DeskError.notConnected` if not connected; `DeskError.presetNotSet`
    ///   if the index is out of range or no current height is known.
    public func savePreset(index: Int) async throws {
        try requireConnected()
        try await executeSavePreset(index: index)
    }

    // MARK: - Settings

    /// Applies updated app configuration, saving it to disk.
    ///
    /// Preset labels are refreshed in the current state immediately.
    ///
    /// - Throws: Errors from `ConfigStore.save(_:)`.
    public func updateSettings(_ config: AppConfig) throws {
        try configStore.save(config)
        applyPresetLabels(from: config)
        yieldState()
    }
}

// MARK: - Private helpers

extension DeskManager {

    /// Applies a mutation closure to `state` and yields the updated snapshot.
    func updateState(_ mutation: (inout DeskState) -> Void) {
        mutation(&state)
        yieldState()
    }

    /// Populates state from a handshake result and persists pairing info.
    private func applyHandshakeResult(_ result: HandshakeResult, peripheralId: UUID, peripheralName: String?) {
        let config = (try? configStore.load()) ?? .default

        for i in 0..<state.presets.count {
            state.presets[i].heightMM = result.presetHeights.count > i ? result.presetHeights[i] : nil
            state.presets[i].label = presetLabel(index: i + 1, config: config)
        }

        state.heightMM = result.currentHeight
        state.connectionState = .connected
        // A fresh connection is a clean slate — clear any fault preserved across
        // a stand-down so the warning does not linger after reconnecting.
        state.needsReference = false
        state.faultCode = nil

        // Use config offset if manually set; otherwise initialize from handshake
        // on first pair (or after config deletion). Persisted so it sticks.
        let offset: Int
        if config.deskOffsetMM != 0 {
            offset = config.deskOffsetMM
        } else if let handshakeOffset = result.deskOffsetMM, handshakeOffset > 0 {
            offset = handshakeOffset
        } else {
            offset = 0
        }
        state.deskOffsetMM = offset

        // Detect active preset from initial height reading.
        if let height = result.currentHeight {
            state.activePreset = activePreset(
                height: height,
                presets: state.presets,
                isMoving: false
            )
        }

        let persisted = persistPairingInfo(
            peripheralId: peripheralId,
            learnedName: peripheralName,
            existingConfig: config,
            deskOffsetMM: offset
        )
        state.deskName = persisted.resolvedDeskName
        yieldState()
    }

    /// Saves paired desk UUID, name, and offset to config, returning the saved snapshot.
    ///
    /// `learnedName` overwrites any stored name rather than only filling a nil: pairing
    /// persists the scan-time name, which is a placeholder whenever CoreBluetooth withheld
    /// `peripheral.name` during the service-filtered scan.
    private func persistPairingInfo(
        peripheralId: UUID,
        learnedName: String?,
        existingConfig: AppConfig,
        deskOffsetMM: Int
    ) -> AppConfig {
        var updated = existingConfig
        updated.pairedDeskUUID = peripheralId.uuidString
        updated.deskOffsetMM = deskOffsetMM
        if let learnedName {
            updated.pairedDeskName = learnedName
        }
        try? configStore.save(updated)
        return updated
    }

    /// Starts the background task that listens to height characteristic notifications.
    private func startHeightNotificationListener() {
        let stream = bleController.notifications(for: DeskUUID.height)
        heightNotificationTask = Task { [weak self] in
            guard let self else { return }
            for await data in stream {
                guard !Task.isCancelled else { break }
                await self.handleHeightNotification(data)
            }
        }
    }

    /// Starts the background task that listens to the desk status characteristic
    /// (`99fa0003`). The desk reports fault/reference conditions here — including
    /// the state behind an E16 display error. The raw bytes are logged (they
    /// persist across app restarts) so an intermittent fault can be captured and
    /// the exact status encoding decoded later. See issue #1.
    private func startStatusNotificationListener() {
        let stream = bleController.notifications(for: DeskUUID.status)
        statusNotificationTask = Task { [weak self] in
            guard let self else { return }
            for await data in stream {
                guard !Task.isCancelled else { break }
                await self.handleStatusNotification(data)
            }
        }
    }

    /// Decodes a status packet from characteristic 99fa0003. The raw bytes are
    /// always logged; a decoded fault (E16/E26 and friends) stops any active
    /// movement and raises `needsReference` with the code. The desk clears the
    /// pulse to empty shortly after, so `.ok` is intentionally not acted on —
    /// `needsReference` is cleared optimistically on the next move attempt.
    private func handleStatusNotification(_ data: Data) async {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        FileLog.debug("status: [\(hex)]", category: "status")

        if case .fault(let code) = DeskProtocol.parseDeskStatus(data) {
            await handleModuleFault(code: code)
        }
    }

    /// Stops all movement and flags a decoded desk fault. Shared by the status
    /// listener (fast path — the desk pushed a fault) and reachable state so the
    /// UI/IPC can surface the specific code.
    func handleModuleFault(code: UInt8) async {
        FileLog.debug("status fault: \(DeskProtocol.describeFault(code: code))", category: "status")
        await cancelMovementTask()
        await cancelPresetMoveTask()
        try? await writeStopCommand()
        updateState {
            $0.isMoving = false
            $0.moveDirection = nil
            $0.speedMMS = 0
            $0.targetPreset = nil
            $0.needsReference = true
            $0.faultCode = code
        }
    }

    /// Processes a single height notification packet.
    ///
    /// Speed values close to zero (abs < 5) are treated as stationary to avoid
    /// stale movement flags from deceleration notifications after a stop command.
    private static let speedThreshold = 5

    private func handleHeightNotification(_ data: Data) {
        guard let (heightMM, speedMMS) = DeskProtocol.parseHeightNotification(data) else { return }
        let previousHeight = state.heightMM
        state.heightMM = heightMM
        state.speedMMS = speedMMS
        let isActuallyMoving = abs(speedMMS) >= Self.speedThreshold

        // Only treat as moving if the height is actually changing. The desk
        // sometimes reports non-zero speed at a constant height (settling after
        // connect or deceleration rounding) which would clear activePreset.
        let heightChanged = previousHeight != heightMM
        if isActuallyMoving && heightChanged {
            state.isMoving = true
            state.moveDirection = moveDirection(for: speedMMS)
        } else if !isActuallyMoving {
            state.isMoving = false
            state.moveDirection = nil
        }

        state.activePreset = activePreset(
            height: heightMM,
            presets: state.presets,
            isMoving: state.isMoving
        )
        yieldState()
    }

    /// Maps a speed value to a move direction, or nil when stationary.
    private func moveDirection(for speedMMS: Int) -> MoveDirection? {
        if speedMMS > 0 { return .up }
        if speedMMS < 0 { return .down }
        return nil
    }

    /// Resets state to disconnected, preserving preset labels from config.
    private func resetToDisconnected() {
        let config = (try? configStore.load()) ?? .default
        var fresh = DeskState()
        for i in 0..<fresh.presets.count {
            fresh.presets[i].label = presetLabel(index: i + 1, config: config)
        }
        state = fresh
        yieldState()
    }

    /// Refreshes preset labels in the current state from a config snapshot.
    private func applyPresetLabels(from config: AppConfig) {
        for i in 0..<state.presets.count {
            state.presets[i].label = presetLabel(index: i + 1, config: config)
        }
    }

    /// Returns the configured label for a preset slot (1-based index).
    private func presetLabel(index: Int, config: AppConfig) -> String? {
        let arrayIndex = index - 1
        guard arrayIndex >= 0 && arrayIndex < config.presetLabels.count else { return nil }
        return config.presetLabels[arrayIndex]
    }

    /// Throws `DeskError.notConnected` unless the desk is currently connected.
    func requireConnected() throws {
        guard state.connectionState == .connected else {
            throw DeskError.notConnected
        }
    }

    /// Ensures a connection for a user-triggered movement. If already connected,
    /// returns immediately; otherwise reconnects to the paired desk first (this
    /// is how a move recovers from a fault stand-down). Throws
    /// `DeskError.notConnected` if no desk is paired.
    func ensureConnectedForAction() async throws {
        if state.connectionState == .connected { return }
        guard let uuidString = (try? configStore.load())?.pairedDeskUUID,
              let peripheralId = UUID(uuidString: uuidString) else {
            throw DeskError.notConnected
        }
        try await connect(peripheralId: peripheralId)
    }
}
