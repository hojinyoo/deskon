// DeskManager+Movement.swift
// LinakControlKit — Movement control implementation for DeskManager.
//
// Manual mode: repeats move command every 100ms until stop() is called.
// Auto mode: sends preflight then repeats move-to target every 100ms until stop() is called.

import CoreBluetooth
import Foundation

// MARK: - Movement constants

private let movementInterval: Duration = .milliseconds(100)

/// How long the desk height may stay unchanged while a movement is commanded
/// before the loop concludes the desk is not responding and stops. Wide enough
/// to absorb wake-up, preflight, and acceleration latency at the start of a move.
/// Shared by the movement and preset loops (see `StallTracker`).
let stallTimeout: Duration = .seconds(2)
// Auto targets defined in DeskLimits (DeskProtocol.swift) — single source of truth.

// MARK: - StallTracker

/// Detects a stalled move: the desk height not changing for `timeout` while a
/// repeating move command is being sent. Used by both the manual/auto movement
/// loop and the preset-recall loop so they share one definition of "stalled".
struct StallTracker {
    private var lastHeight: Int?
    private var lastProgressAt: ContinuousClock.Instant
    private let timeout: Duration

    init(height: Int?, now: ContinuousClock.Instant, timeout: Duration = stallTimeout) {
        self.lastHeight = height
        self.lastProgressAt = now
        self.timeout = timeout
    }

    /// Feeds the latest observed height and current time; returns true once the
    /// height has not changed for `timeout`. Any height change resets the window.
    mutating func isStalled(height: Int?, now: ContinuousClock.Instant) -> Bool {
        if height != lastHeight {
            lastHeight = height
            lastProgressAt = now
            return false
        }
        return lastProgressAt.duration(to: now) >= timeout
    }
}

// MARK: - DeskManager movement extension

extension DeskManager {

    // MARK: - Internal entry points (called from DeskManager.swift public methods)

    /// Validates connection, cancels any prior movement, then starts a new movement task.
    func startMovement(_ direction: MoveDirection, mode: RunMode) async throws {
        FileLog.debug("startMovement(\(direction), mode: \(mode))", category: "core")
        try await ensureConnectedForAction()
        await cancelMovementTask()

        // Wake the desk before sending movement commands.
        try? await bleController.write(data: DeskCommand.wakeUp, to: DeskUUID.command, type: .withoutResponse)

        updateState {
            $0.isMoving = true
            $0.moveDirection = direction
            $0.targetPreset = nil
            // Optimistic: a fresh move attempt clears any prior stall flag. The
            // watchdog / status listener re-raises it if the desk still fails.
            $0.needsReference = false
            $0.faultCode = nil
        }

        switch mode {
        case .manual:
            startManualMovementTask(direction: direction)
        case .auto:
            try await startAutoMovementTask(direction: direction)
        }
    }

    /// Cancels the active movement task and waits for it to drain.
    func cancelMovementTask() async {
        movementTask?.cancel()
        await movementTask?.value
        movementTask = nil
    }

    /// Writes one control-loop command. Returns false when the write failed,
    /// which is the link telling the loop it is gone: every write from here on
    /// goes nowhere, and the height stops arriving. A loop that carried on would
    /// hand `StallTracker` a frozen height and raise `needsReference` - a desk
    /// fault the desk never reported.
    func writeLoopCommand(_ data: Data, to characteristic: CBUUID) async -> Bool {
        do {
            try await bleController.write(data: data, to: characteristic, type: .withoutResponse)
            return true
        } catch {
            FileLog.debug("move write failed (\(error)): link gone, stopping the loop", category: "movement")
            return false
        }
    }

    /// Clears movement state after the link dropped mid-move.
    ///
    /// Deliberately leaves `needsReference` alone: nothing is known to be wrong
    /// with the desk. Raising it would post a fault notification and stand the
    /// app down, which sets `isUserInitiatedDisconnect` and so cancels the very
    /// reconnection this needs. `handleDisconnection()` owns the connection state.
    func handleLinkLoss() {
        updateState {
            $0.isMoving = false
            $0.moveDirection = nil
            $0.speedMMS = 0
            $0.targetPreset = nil
        }
    }

    /// Writes the stop command twice then resets movement state.
    func writeStopCommand() async throws {
        try await bleController.write(
            data: DeskCommand.stop,
            to: DeskUUID.command,
            type: .withoutResponse
        )
        try await bleController.write(
            data: DeskCommand.stop,
            to: DeskUUID.command,
            type: .withoutResponse
        )
    }

    // MARK: - Private movement task builders

    /// Starts the watchdog loop that writes the manual move command every 100ms
    /// until cancelled or the desk stalls.
    private func startManualMovementTask(direction: MoveDirection) {
        let command = manualCommand(for: direction)
        movementTask = Task { [weak self] in
            await self?.runMovementLoop(command: command, characteristic: DeskUUID.command)
        }
    }

    /// Sends preflight then starts the watchdog loop that writes the move-to
    /// target every 100ms until cancelled or the desk stalls.
    private func startAutoMovementTask(direction: MoveDirection) async throws {
        try await bleController.write(
            data: DeskCommand.preflight,
            to: DeskUUID.command,
            type: .withoutResponse
        )

        let target = autoTarget(for: direction)
        movementTask = Task { [weak self] in
            await self?.runMovementLoop(command: target, characteristic: DeskUUID.targetHeartbeat)
        }
    }

    // MARK: - Watchdog loop

    /// Actor-isolated movement loop: writes `command` to `characteristic` every
    /// 100ms while observing desk height. If the height does not change for
    /// `stallTimeout` the desk is treated as not responding — the loop stops
    /// hammering it (per issue #1) and raises `needsReference`.
    ///
    /// Mirrors `runPresetLoop` (DeskManager+Presets.swift), which already
    /// terminates a repeating move loop on a height/time condition.
    private func runMovementLoop(command: Data, characteristic: CBUUID) async {
        var tracker = StallTracker(height: state.heightMM, now: clock.now())

        while !Task.isCancelled {
            guard await writeLoopCommand(command, to: characteristic) else {
                handleLinkLoss()
                return
            }
            try? await clock.sleep(for: movementInterval)

            if tracker.isStalled(height: state.heightMM, now: clock.now()) {
                await handleStall()
                break
            }
        }
    }

    /// Stops the desk and flags a stall after the height failed to change while
    /// moving. This is the timing backstop — the desk may be at a physical
    /// end-stop, or the control module may be blocked without pushing a status
    /// fault. When the desk does push a fault code, `handleModuleFault` sets a
    /// precise `faultCode`; here it is left nil (generic stall).
    private func handleStall() async {
        FileLog.debug(
            "movement stall: height unchanged for \(stallTimeout) while moving — stopping; desk may need a reset",
            category: "movement"
        )
        try? await writeStopCommand()
        updateState {
            $0.isMoving = false
            $0.moveDirection = nil
            $0.speedMMS = 0
            $0.needsReference = true
        }
    }

    // MARK: - Command helpers

    private func manualCommand(for direction: MoveDirection) -> Data {
        switch direction {
        case .up:   return DeskCommand.moveUp
        case .down: return DeskCommand.moveDown
        }
    }

    private func autoTarget(for direction: MoveDirection) -> Data {
        switch direction {
        case .up:   return DeskCommand.moveTo(tenthsOfMm: DeskLimits.autoUpTargetTenths)
        case .down: return DeskCommand.moveTo(tenthsOfMm: DeskLimits.autoDownTargetTenths)
        }
    }
}
