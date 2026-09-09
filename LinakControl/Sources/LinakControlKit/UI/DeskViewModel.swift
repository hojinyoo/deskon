// DeskViewModel.swift
// LinakControlKit — ObservableObject bridging DeskManager to SwiftUI.

import Foundation
import ServiceManagement

// MARK: - DeskViewModel

/// Main-actor view model that bridges `DeskManager` to SwiftUI.
///
/// Subscribes to `DeskManager.stateStream` and maps snapshots to `@Published`
/// properties. All action methods fire-and-forget into async tasks; errors are
/// silently swallowed because the UI has no meaningful recovery path beyond
/// retrying.
@MainActor
public final class DeskViewModel: ObservableObject {

    // MARK: - Published state

    @Published public var connectionState: ConnectionState = .disconnected
    @Published public var heightMM: Int?
    @Published public var heightDisplay: String = "—"
    @Published public var isMoving: Bool = false
    @Published public var moveDirection: MoveDirection?

    /// True when a movement stalled — the desk stopped responding and may need a
    /// manual reset on the control box (E16). Cleared on the next move attempt.
    @Published public var needsReference: Bool = false

    /// Raw fault code behind `needsReference` when the desk pushed one (else nil).
    @Published public var faultCode: UInt8?

    /// User-facing message for the current fault, specific to the code when known.
    public var faultMessage: String {
        DeskProtocol.faultSummary(code: faultCode)
    }
    @Published public var presets: [PresetPosition] = (1...4).map { PresetPosition(index: $0) }
    @Published public var activePreset: Int?
    @Published public var targetPreset: Int?
    @Published public var unit: HeightUnit = .cm
    @Published public var deskOffsetMM: Int = 0
    @Published public var autoRunUp: RunMode = .manual
    @Published public var autoRunDown: RunMode = .manual

    // MARK: - First-run state

    /// True when no desk has been paired yet (first-run scenario).
    @Published public var isFirstRun: Bool = false

    /// Desks discovered during an active BLE scan.
    @Published public var discoveredDesks: [DiscoveredDesk] = []

    /// Name of the currently connected desk, populated from `DeskState` snapshots.
    @Published public var deskName: String?

    // MARK: - Settings state

    /// True when the settings panel is visible inside the popover.
    @Published public var showSettings: Bool = false

    /// Mirrors `AppConfig.startAtLogin`; toggling this registers/unregisters the login item.
    @Published public var startAtLogin: Bool = false

    /// Mirrors `AppConfig.hotkeysEnabled`.
    @Published public var hotkeysEnabled: Bool = false

    /// Mirrors `AppConfig.showZone2`. Controls visibility of the preset menu bar item.
    @Published public var showZone2: Bool = true

    // MARK: - Dependencies

    private let deskManager: DeskManager
    private let configStore: ConfigStore
    private let loginItemManager: LoginItemManaging
    private var stateTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    /// Peripheral ID captured when the user selects a desk during first-run.
    private var selectedPeripheralId: UUID?

    /// Name of the desk selected during first-run scanning (before connection completes).
    ///
    /// Used by `FirstRunConnectingView` to show the desk name while the handshake runs.
    @Published public var selectedDeskName: String?

    // MARK: - Init

    public init(
        deskManager: DeskManager,
        configStore: ConfigStore,
        loginItemManager: LoginItemManaging = LoginItemManager()
    ) {
        self.deskManager = deskManager
        self.configStore = configStore
        self.loginItemManager = loginItemManager
        let config = (try? configStore.load()) ?? .default
        isFirstRun = config.pairedDeskUUID == nil
        unit = config.unit
        deskOffsetMM = config.deskOffsetMM
        autoRunUp = config.autoRunUp
        autoRunDown = config.autoRunDown
        startAtLogin = config.startAtLogin
        hotkeysEnabled = config.hotkeysEnabled
        showZone2 = config.showZone2
        startObservingStateStream()
    }

    deinit {
        stateTask?.cancel()
        scanTask?.cancel()
    }

    // MARK: - Actions

    public func goToPreset(index: Int) {
        FileLog.debug("goToPreset(\(index))", category: "ui")
        Task {
            do { try await deskManager.goToPreset(index: index) }
            catch { FileLog.debug("goToPreset FAILED: \(error)", category: "ui") }
        }
    }

    public func moveUp() {
        FileLog.debug("moveUp(mode: \(autoRunUp))", category: "ui")
        Task {
            do { try await deskManager.moveUp(mode: autoRunUp) }
            catch { FileLog.debug("moveUp FAILED: \(error)", category: "ui") }
        }
    }

    public func moveDown() {
        FileLog.debug("moveDown(mode: \(autoRunDown))", category: "ui")
        Task {
            do { try await deskManager.moveDown(mode: autoRunDown) }
            catch { FileLog.debug("moveDown FAILED: \(error)", category: "ui") }
        }
    }

    public func stop() {
        FileLog.debug("stop()", category: "ui")
        Task {
            do { try await deskManager.stop() }
            catch { FileLog.debug("stop FAILED: \(error)", category: "ui") }
        }
    }

    public func savePreset(index: Int) {
        FileLog.debug("savePreset(\(index))", category: "ui")
        Task {
            do { try await deskManager.savePreset(index: index) }
            catch { FileLog.debug("savePreset FAILED: \(error)", category: "ui") }
        }
    }

    /// Starts a BLE scan and collects discovered desks into `discoveredDesks`.
    ///
    /// Clears any previously discovered desks before starting. Fire-and-forget;
    /// the published `discoveredDesks` array updates as desks are found.
    public func startScan() {
        scanTask?.cancel()
        discoveredDesks = []
        let manager = deskManager
        scanTask = Task { [weak self] in
            let stream = await manager.scan()
            for await desk in stream {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let self else { return }
                    // Deduplicate by peripheral ID — BLE may report the same desk multiple times.
                    if !self.discoveredDesks.contains(where: { $0.peripheralId == desk.peripheralId }) {
                        self.discoveredDesks.append(desk)
                    }
                }
            }
        }
    }

    /// Connects to a specific desk discovered during scanning.
    ///
    /// Captures the desk's peripheral ID and name for use in `completeFirstRun()`.
    /// Guards against duplicate calls (e.g. double-click). Connection state updates
    /// arrive via `stateStream`; errors are swallowed since the UI shows state changes.
    private var connectTask: Task<Void, Never>?

    /// Local guard against double-click races. The stateStream update to
    /// `.connecting` arrives asynchronously; without this flag a rapid second
    /// click slips through the connectionState guard and cancels the first
    /// BLE connect — leaving connectContinuation dangling in BLEController.
    private var isSelectingDesk = false

    public func selectDesk(_ desk: DiscoveredDesk) {
        guard !isSelectingDesk && connectionState != .connecting && connectionState != .connected else {
            FileLog.debug("selectDesk: ignored -- already selecting or \(connectionState)", category: "ui")
            return
        }
        isSelectingDesk = true
        selectedPeripheralId = desk.peripheralId
        selectedDeskName = desk.name
        // Persist name early so applyHandshakeResult finds it in config.
        persistConfig { $0.pairedDeskName = desk.name }
        scanTask?.cancel()
        connectTask?.cancel()
        FileLog.debug("selectDesk: connecting to '\(desk.name)'", category: "ui")
        connectTask = Task { [weak self] in
            try? await self?.deskManager.connect(peripheralId: desk.peripheralId)
            await MainActor.run { self?.isSelectingDesk = false }
        }
    }

    /// Finalises the first-run pairing flow.
    ///
    /// Persists the selected desk's UUID and name to `ConfigStore`, then sets
    /// `isFirstRun = false` so `PopoverView` transitions to the normal UI.
    public func completeFirstRun() {
        guard let peripheralId = selectedPeripheralId else { return }
        let scannedName = selectedDeskName
        Task {
            var config = (try? configStore.load()) ?? .default
            config.pairedDeskUUID = peripheralId.uuidString
            // Connecting already refreshed pairedDeskName from the peripheral; the
            // scan-time name only fills in when that never happened.
            config.pairedDeskName = config.pairedDeskName ?? scannedName
            try? configStore.save(config)
        }
        isFirstRun = false
    }

    /// Attempts to reconnect to the paired desk stored in config.
    ///
    /// Reads the paired desk UUID from `ConfigStore`. If no paired desk is
    /// configured, triggers a scan (first-run scenario).
    public func retryConnection() {
        guard connectionState != .connecting && connectionState != .connected else {
            FileLog.debug("retryConnection: ignored -- already \(connectionState)", category: "ui")
            return
        }
        Task {
            let config = try? configStore.load()
            guard let uuidString = config?.pairedDeskUUID,
                  let peripheralId = UUID(uuidString: uuidString) else {
                FileLog.debug("retryConnection: no paired desk UUID, starting scan", category: "ui")
                startScan()
                return
            }
            FileLog.debug("retryConnection: connecting to \(uuidString)", category: "ui")
            do {
                try await deskManager.connect(peripheralId: peripheralId)
            } catch {
                FileLog.debug("retryConnection: FAILED -- \(error)", category: "ui")
            }
        }
    }

    /// Manually disconnects from the desk (releases BLE, suppresses reconnect).
    /// Use to free the desk for manual operation; reconnect via `retryConnection()`
    /// or simply by triggering a movement (which auto-reconnects).
    public func disconnectFromDesk() {
        FileLog.debug("disconnectFromDesk", category: "ui")
        Task { await deskManager.disconnect() }
    }

    /// Persists the start-at-login preference and registers or unregisters the login item.
    ///
    /// Errors from SMAppService (e.g. duplicate registration) are silently ignored;
    /// the setting is still persisted so the UI stays in sync.
    public func setStartAtLogin(_ enabled: Bool) {
        startAtLogin = enabled
        if enabled {
            try? loginItemManager.register()
        } else {
            try? loginItemManager.unregister()
        }
        Task {
            var config = (try? configStore.load()) ?? .default
            config.startAtLogin = enabled
            try? configStore.save(config)
        }
    }

    // MARK: - Settings actions

    /// Updates the height display unit, recalculates `heightDisplay`, and persists to config.
    public func updateUnit(_ newUnit: HeightUnit) {
        unit = newUnit
        heightDisplay = heightMM.map { HeightConverter.display(mm: $0 + deskOffsetMM, unit: newUnit) } ?? "—"
        persistConfig { $0.unit = newUnit }
    }

    /// Updates the desk base offset and recalculates all displayed heights and presets.
    public func updateDeskOffset(_ mm: Int) {
        deskOffsetMM = mm
        persistConfig { $0.deskOffsetMM = mm }
        // Re-apply the full state snapshot with the new offset.
        let manager = deskManager
        Task { apply(await manager.currentState) }
    }

    /// Updates the up-movement run mode and persists to config.
    public func updateAutoRunUp(_ mode: RunMode) {
        autoRunUp = mode
        persistConfig { $0.autoRunUp = mode }
    }

    /// Updates the down-movement run mode and persists to config.
    public func updateAutoRunDown(_ mode: RunMode) {
        autoRunDown = mode
        persistConfig { $0.autoRunDown = mode }
    }

    /// Updates the start-at-login setting and persists to config (no SMAppService side-effect).
    ///
    /// Use `setStartAtLogin(_:)` when SMAppService registration is also required.
    public func updateStartAtLogin(_ enabled: Bool) {
        startAtLogin = enabled
        persistConfig { $0.startAtLogin = enabled }
    }

    /// Updates the global-hotkeys setting and persists to config.
    public func updateHotkeysEnabled(_ enabled: Bool) {
        hotkeysEnabled = enabled
        persistConfig { $0.hotkeysEnabled = enabled }
    }

    /// Updates the Zone 2 visibility setting and persists to config.
    public func updateShowZone2(_ visible: Bool) {
        showZone2 = visible
        persistConfig { $0.showZone2 = visible }
    }

    /// Clears pairing info, disconnects from the desk, and resets to first-run state.
    ///
    /// The user will be taken back through the scanning flow on next interaction.
    public func forgetAndRescan() {
        persistConfig {
            $0.pairedDeskUUID = nil
            $0.pairedDeskName = nil
            $0.userDeskName = nil
        }
        // Reset UI state immediately — the async disconnect state update
        // arrives too late, causing a brief "connected" flash.
        connectionState = .disconnected
        deskName = nil
        heightMM = nil
        heightDisplay = "—"
        isMoving = false
        Task { await deskManager.disconnect() }
        showSettings = false
        isFirstRun = true
    }

    // MARK: - Private

    /// Loads config, applies a mutation, and saves it back to disk synchronously.
    private func persistConfig(_ mutation: (inout AppConfig) -> Void) {
        var config = (try? configStore.load()) ?? .default
        mutation(&config)
        try? configStore.save(config)
    }

    private func startObservingStateStream() {
        // Capture manager strongly — the view model owns the subscription lifecycle.
        let manager = deskManager
        stateTask = Task { [weak self] in
            for await snapshot in await manager.stateStream {
                guard !Task.isCancelled else { break }
                // Task inherits @MainActor from DeskViewModel; apply is safe here.
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: DeskState) {
        FileLog.trace("apply: state=\(snapshot.connectionState) height=\(snapshot.heightMM.map(String.init) ?? "nil") moving=\(snapshot.isMoving) activePreset=\(snapshot.activePreset.map(String.init) ?? "nil")", category: "ui")
        connectionState = snapshot.connectionState
        heightMM = snapshot.heightMM

        // Pick up offset from state when it changes (e.g. auto-detected from
        // handshake on first pair). Manual adjustments via updateDeskOffset()
        // still work because they write to both config and trigger a state update.
        if snapshot.deskOffsetMM != 0 && snapshot.deskOffsetMM != deskOffsetMM {
            deskOffsetMM = snapshot.deskOffsetMM
        }

        let offset = deskOffsetMM
        heightDisplay = snapshot.heightMM.map {
            HeightConverter.display(mm: $0 + offset, unit: unit)
        } ?? "—"

        isMoving = snapshot.isMoving
        moveDirection = snapshot.moveDirection
        needsReference = snapshot.needsReference
        faultCode = snapshot.faultCode

        // Apply offset to preset heights for display.
        presets = snapshot.presets.map { preset in
            var adjusted = preset
            if let h = preset.heightMM {
                adjusted.heightMM = h + offset
            }
            return adjusted
        }

        activePreset = snapshot.activePreset
        targetPreset = snapshot.targetPreset
        deskName = snapshot.deskName
    }
}
