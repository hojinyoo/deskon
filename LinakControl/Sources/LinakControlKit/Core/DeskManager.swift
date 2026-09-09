// DeskManager.swift
// LinakControlKit — Central state coordinator for the LINAK DPG1C desk.

import Foundation

// MARK: - Constants

/// How long CoreBluetooth may say nothing before the wait says so in the log.
/// Reporting only. The wait carries on: a cold stack has taken 13.2s to answer,
/// and Bluetooth switched off is the user's to fix whenever they get to it.
let powerOnReportDelay: Duration = .seconds(10)

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
    var bleState: BLEState?
    private var bleStateTask: Task<Void, Never>?
    private var disconnectTask: Task<Void, Never>?

    /// Callers suspended in `waitUntilPoweredOn()`, keyed so a cancelled one can
    /// be pulled out without disturbing the others.
    private var powerOnWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    private var nextPowerOnWaiterID = 0

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
    /// No deadline, deliberately. A cold CoreBluetooth stack reported `.poweredOn` 13.2s
    /// after launch and the 10s bound that preceded this left the app sitting disconnected
    /// with the desk in range. `.unknown` and `.resetting` are what a cold stack reports on
    /// its way up, and `.poweredOff` is a switch the user can flip at any time; none of the
    /// three is a reason to abandon the connect.
    ///
    /// - Throws: `DeskError.bluetoothUnavailable` for `.unauthorized` and `.unsupported`,
    ///   the two states no amount of waiting fixes, or `CancellationError`.
    public func waitUntilPoweredOn() async throws {
        startBLEStateObserver()
        switch bleState {
        case .poweredOn:
            return
        case .unauthorized, .unsupported:
            throw DeskError.bluetoothUnavailable(bleState ?? .unknown)
        default:
            break
        }

        let reporter = startSilentStackReport()
        defer { reporter.cancel() }

        let id = nextPowerOnWaiterID
        nextPowerOnWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Runs synchronously on the actor, so no state change can slip
                // between this check and the store.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    powerOnWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelPowerOnWaiter(id) }
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
        switch state {
        case .poweredOn:
            releasePowerOnWaiters(throwing: nil)
        case .unauthorized, .unsupported:
            releasePowerOnWaiters(throwing: DeskError.bluetoothUnavailable(state))
        case .unknown, .resetting, .poweredOff:
            break
        }
    }

    private func releasePowerOnWaiters(throwing error: Error?) {
        let waiting = powerOnWaiters.values
        powerOnWaiters = [:]
        for continuation in waiting {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    /// Logs once if CoreBluetooth has still said nothing after `powerOnReportDelay`.
    /// A stack that never answers leaves no other trace: the app simply waits, and
    /// an app that waits with nothing in the log reads as an app that is broken.
    private func startSilentStackReport() -> Task<Void, Never> {
        let clock = self.clock
        return Task { [weak self] in
            guard (try? await clock.sleep(for: powerOnReportDelay)) != nil else { return }
            await self?.reportSilentStack()
        }
    }

    private func reportSilentStack() {
        FileLog.debug(
            "waitUntilPoweredOn: no state from CoreBluetooth after \(powerOnReportDelay), last state \(bleState.map(String.init(describing:)) ?? "none"); still waiting. If it never arrives, check that this build is allowed Bluetooth in System Settings > Privacy and Security.",
            category: "core"
        )
    }

    private func cancelPowerOnWaiter(_ id: Int) {
        powerOnWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    deinit {
        bleStateTask?.cancel()
        disconnectTask?.cancel()
    }

    // MARK: - Link drops

    /// Routes peripheral link drops to `handleDisconnection()`.
    ///
    /// Started at the first connect and left running: the controller's stream
    /// lives as long as the controller, and one iterator is all it can feed.
    private func startDisconnectObserver() {
        guard disconnectTask == nil else { return }
        let stream = bleController.disconnections
        disconnectTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.handleDisconnection()
            }
        }
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
        startDisconnectObserver()
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
        cancelMoveTasks()
    }

    /// Cancels any in-flight move loop, without awaiting it to drain.
    ///
    /// Every path that ends a connection goes through here. A loop left running
    /// writes into a dead link, sees the height stop changing, and its stall
    /// watchdog reports a desk that needs a manual reference - blaming the desk
    /// for a connection that went away.
    func cancelMoveTasks() {
        movementTask?.cancel()
        movementTask = nil
        presetMoveTask?.cancel()
        presetMoveTask = nil
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

    /// How long to keep listening for a desk-pushed fault code after a timing
    /// stall raised `needsReference` without one (issue #19).
    static let faultCodeGraceWindow: Duration = .milliseconds(500)

    /// Waits briefly for the desk to report *why* it stopped, then returns
    /// whatever code is known.
    ///
    /// The 2 s stall watchdog regularly beats the control box to the punch: both
    /// stalls observed on hardware logged `faultCode: none`, yet the desk needed
    /// a manual re-reference afterwards — so the one thing that would have
    /// explained the failure was never captured. `standDown()` cancels
    /// `statusNotificationTask` and drops the link, after which a late E16 or
    /// Initialise push is lost for good, so the wait has to happen before it.
    ///
    /// Returns immediately when the desk pushed a fault first — that path,
    /// where `handleModuleFault` has already set the code, is unaffected.
    ///
    /// Writes nothing: by this point the movement loop has stopped and sent stop
    /// twice, so the window does not meaningfully delay freeing the desk for the
    /// manual initialisation `standDown()` exists to allow.
    ///
    /// - Returns: the fault code, or nil if none arrived within `window`.
    func awaitFaultCode(within window: Duration = faultCodeGraceWindow) async -> UInt8? {
        if let code = state.faultCode { return code }

        // Waiting is not enough: three stalls observed on hardware pushed no
        // status packet at all, even with the full window listening (#24). Ask
        // the desk directly before falling back to waiting.
        if let code = await readStatusFault() { return code }

        try? await clock.sleep(for: window)
        if let code = state.faultCode { return code }

        // Last chance while the link is still up — standDown() is next.
        return await readStatusFault()
    }

    /// Reads the status characteristic directly rather than waiting for a push,
    /// and records any decoded fault on the state.
    ///
    /// `99fa0003` is Read/Notify, but the app only ever subscribed to it. When
    /// this control box refuses a move it goes silent instead of announcing a
    /// reason, so asking is the one question left before `standDown()` drops the
    /// link (issue #24).
    ///
    /// This is a **read**, not a write. The concern behind #1 and #14 was
    /// writing to a desk that wants to be left alone; reads already happen
    /// freely during the handshake.
    ///
    /// The raw bytes are logged whatever they are — "we asked and the desk
    /// reported nothing wrong" separates a content desk from a wedged one, and
    /// that distinction is exactly what the log has been missing.
    ///
    /// - Returns: the decoded fault code, or nil if the read failed or the desk
    ///   reported no fault.
    private func readStatusFault() async -> UInt8? {
        guard let data = try? await bleController.read(DeskUUID.status) else {
            FileLog.debug("status read: no response (link down or unsupported)", category: "status")
            return nil
        }

        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        FileLog.debug("status read: [\(hex)]", category: "status")

        guard case .fault(let code) = DeskProtocol.parseDeskStatus(data) else { return nil }

        FileLog.debug("status read fault: \(DeskProtocol.describeFault(code: code))", category: "status")
        // Record it so the popover banner and `deskctl status --json` carry the
        // specific code too, not just the notification body.
        updateState { $0.faultCode = code }
        return code
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
