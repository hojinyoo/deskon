// DeskManager+Reconnection.swift
// LinakControlKit - Auto-reconnection and wake-up logic for DeskManager.
//
// Reconnection: exponential backoff starting at 1s, doubling to max 60s.
// Wake-up: sends FE 00 + FF 00 up to 3 times with 200ms delays.

import Foundation
import CoreBluetooth

// MARK: - Constants

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

        cancelMoveTasks()
        updateState {
            $0.connectionState = .disconnected
            $0.isMoving = false
            $0.moveDirection = nil
            $0.speedMMS = 0
            $0.targetPreset = nil
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
}
