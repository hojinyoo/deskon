// DeskManager+Reconnection.swift
// LinakControlKit — Auto-reconnection, heartbeat, and wake-up logic for DeskManager.
//
// Reconnection: exponential backoff starting at 1s, doubling to max 60s.
// Heartbeat: writes 0x01 0x80 every 1s; pauses after 10 min of no user activity.
// Wake-up: sends FE 00 + FF 00 up to 3 times with 200ms delays.

import Foundation
import CoreBluetooth

// MARK: - Constants

private let heartbeatInterval: Duration = .seconds(1)
private let idleTimeoutBeforeHeartbeatPause: Duration = .seconds(600)   // 10 minutes
private let wakeUpMaxAttempts = 3
private let wakeUpCommandDelay: Duration = .milliseconds(200)
private let reconnectInitialDelay: Duration = .seconds(1)
private let reconnectMaxDelay: Duration = .seconds(60)

// MARK: - Unexpected Disconnection

extension DeskManager {

    /// Call this when BLE reports an unexpected peripheral disconnection.
    ///
    /// Sets state to `.disconnected` and starts the exponential-backoff
    /// reconnection loop — unless the disconnect was user-initiated.
    ///
    /// In production, call this from `centralManager(_:didDisconnectPeripheral:error:)`
    /// inside `BLEController`.
    public func handleDisconnection() {
        guard !isUserInitiatedDisconnect else { return }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        movementTask?.cancel()
        movementTask = nil
        updateState {
            $0.connectionState = .disconnected
            $0.isMoving = false
            $0.moveDirection = nil
        }
        startReconnectionLoop()
    }

    // MARK: - Reconnection Loop

    private func startReconnectionLoop() {
        reconnectionTask?.cancel()
        reconnectionTask = Task { [weak self] in
            guard let self else { return }
            await self.runReconnectionLoop()
        }
    }

    private func runReconnectionLoop() async {
        guard state.connectionState == .disconnected else { return }
        var delay = reconnectInitialDelay

        while !Task.isCancelled && !isUserInitiatedDisconnect {
            do {
                try await clock.sleep(for: delay)
            } catch {
                return  // cancelled during sleep
            }

            guard !Task.isCancelled && !isUserInitiatedDisconnect else { return }

            guard let uuidString = (try? configStore.load())?.pairedDeskUUID,
                  let peripheralId = UUID(uuidString: uuidString) else {
                return  // no paired desk UUID — cannot reconnect
            }

            do {
                try await connect(peripheralId: peripheralId)
                return  // success
            } catch {
                delay = min(delay * 2, reconnectMaxDelay)
            }
        }
    }
}

// MARK: - Wake Observer

extension DeskManager {

    /// Registers an observer for macOS wake-from-sleep notifications.
    ///
    /// When the system wakes, waits for BLE to become `.poweredOn` then reconnects.
    /// Call this once after actor setup (e.g., from the app delegate or menu bar controller).
    ///
    /// - Note: Has no effect in test targets that do not link AppKit.
    public func startWakeObserver() {
        Task { [weak self] in
            guard let self else { return }
            await self.observeWakeNotifications()
        }
    }

    private func observeWakeNotifications() async {
        #if canImport(AppKit)
        let notifications = NotificationCenter.default.notifications(
            named: NSNotification.Name("NSWorkspaceDidWakeNotification")
        )
        for await _ in notifications {
            guard !Task.isCancelled else { return }
            await handleSystemWake()
        }
        #endif
    }

    private func handleSystemWake() async {
        guard state.connectionState == .disconnected else { return }

        // CoreBluetooth needs time to resume after wake.
        guard (try? await waitUntilPoweredOn()) != nil else { return }

        guard !isUserInitiatedDisconnect else { return }

        guard let uuidString = (try? configStore.load())?.pairedDeskUUID,
              let peripheralId = UUID(uuidString: uuidString) else { return }

        try? await connect(peripheralId: peripheralId)
    }
}

// MARK: - Wake-Up Sequence

extension DeskManager {

    /// Sends the desk wake-up sequence (FE 00 then FF 00) up to 3 times.
    ///
    /// Each attempt writes `DeskCommand.wakeUp`, waits 200ms, then writes
    /// `DeskCommand.stop`, and checks if the desk responds.
    ///
    /// - Throws: `DeskError.wakeUpFailed` after exhausting all attempts.
    public func wakeUpDesk() async throws {
        for attempt in 1...wakeUpMaxAttempts {
            try await writeWakeUpPair()
            if await deskIsResponding() { return }
            if attempt < wakeUpMaxAttempts {
                // Use real Task.sleep for sub-second command timing — short enough for tests.
                try? await Task.sleep(for: wakeUpCommandDelay)
            }
        }
        throw DeskError.wakeUpFailed
    }

    private func writeWakeUpPair() async throws {
        try await bleController.write(
            data: DeskCommand.wakeUp,
            to: DeskUUID.command,
            type: .withoutResponse
        )
        // Use real Task.sleep for sub-second command timing.
        try? await Task.sleep(for: wakeUpCommandDelay)
        try await bleController.write(
            data: DeskCommand.stop,
            to: DeskUUID.command,
            type: .withoutResponse
        )
    }

    /// Returns true when the desk responds to a height read — confirming it is awake.
    private func deskIsResponding() async -> Bool {
        let data = try? await bleController.read(DeskUUID.height)
        return data != nil
    }

    // MARK: - Transparent Wake-Up

    /// Ensures the desk is awake before a command if the heartbeat has been idle too long.
    ///
    /// Called internally before user commands when the desk may be sleeping.
    func ensureAwake() async throws {
        guard isHeartbeatSuppressed() else { return }
        try await wakeUpDesk()
    }

    private func isHeartbeatSuppressed() -> Bool {
        guard let last = lastUserAction else { return false }
        return clock.now() - last >= idleTimeoutBeforeHeartbeatPause
    }
}

// MARK: - Testing Hooks

extension DeskManager {

    /// Sets `lastUserAction` to the given instant.
    ///
    /// Exposed for unit tests that need to simulate elapsed idle time
    /// without running real tasks. Not intended for production use.
    func setLastUserActionForTesting(_ instant: ContinuousClock.Instant) {
        lastUserAction = instant
    }
}

// MARK: - Heartbeat

extension DeskManager {

    /// Starts the 1-second heartbeat background task.
    ///
    /// Writes `DeskCommand.heartbeat` (01 80) to `DeskUUID.targetHeartbeat` every second.
    /// Skips writes when the desk has been idle for more than 10 minutes, allowing the
    /// desk to enter its natural sleep state.
    func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await self.runHeartbeat()
        }
    }

    private func runHeartbeat() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: heartbeatInterval)
            } catch {
                return  // cancelled
            }

            guard state.connectionState == .connected else { return }

            if shouldSendHeartbeat() {
                try? await bleController.write(
                    data: DeskCommand.heartbeat,
                    to: DeskUUID.targetHeartbeat,
                    type: .withoutResponse
                )
            }
        }
    }

    private func shouldSendHeartbeat() -> Bool {
        // Suppress heartbeat during movement — the movement loop and preset
        // control loop already write to the same characteristic (0x0031).
        // Interleaving heartbeats disrupts the move-to target.
        guard !state.isMoving else { return false }

        guard let last = lastUserAction else {
            return true  // no action yet — keep desk awake by default
        }
        return clock.now() - last < idleTimeoutBeforeHeartbeatPause
    }

    // MARK: - User Action Tracking

    /// Records the current instant as the most recent user action and wakes the desk if needed.
    ///
    /// Call from moveUp, moveDown, stop, goToPreset, and savePreset.
    func recordUserAction() async throws {
        lastUserAction = clock.now()
        try await ensureAwake()
    }
}
