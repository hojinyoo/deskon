// DeskManager+Presets.swift
// LinakControlKit — Preset recall (go-to) implementation for DeskManager.
//
// Control loop: writes target position every 100ms to DeskUUID.targetHeartbeat
// until the desk reports height within 5mm of target, or 30 seconds elapse.

import CoreBluetooth
import Foundation

// MARK: - Preset constants

private let presetArrivalToleranceMM = 5
private let presetTimeout: Duration = .seconds(30)
private let presetLoopInterval: Duration = .milliseconds(100)
private let presetPreflightDelay: Duration = .milliseconds(100)
// Range constants are defined in DeskLimits (DeskProtocol.swift) — single source of truth.

// MARK: - DeskManager preset extension

extension DeskManager {

    // MARK: - Entry point (called from DeskManager.swift public goToPreset)

    /// Validates preconditions, cancels any prior move, and starts the control loop.
    func executeGoToPreset(index: Int) async throws {
        FileLog.debug("executeGoToPreset(\(index))", category: "core")
        try await ensureConnectedForAction()
        let targetMM = try resolvePresetHeight(index)
        try await startMoveToHeight(targetMM, preset: index)
    }

    /// Same control loop as a preset recall, for a target the caller supplies.
    ///
    /// Unlike a preset, this target did not come from the desk, so it is checked against
    /// the desk's travel before anything reaches BLE. `DeskLimits.safeCommandRange` is not
    /// that check: at `UInt16(mm * 10)` it is an encoding bound, and 6500mm is 6.5 metres.
    func executeMoveToHeight(_ targetMM: Int) async throws {
        FileLog.debug("executeMoveToHeight(\(targetMM))", category: "core")
        let stroke = ((try? configStore.load()) ?? .default).maxStrokeMM
        guard (0...stroke).contains(targetMM) else {
            throw DeskError.targetOutOfRange(targetMM)
        }
        try await ensureConnectedForAction()
        try await startMoveToHeight(targetMM, preset: nil)
    }

    private func startMoveToHeight(_ targetMM: Int, preset: Int?) async throws {
        try guardHeightInRange(targetMM)

        await cancelPresetMoveTask()
        await cancelMovementTask()

        // Wake the desk before sending preset commands.
        try? await bleController.write(data: DeskCommand.wakeUp, to: DeskUUID.command, type: .withoutResponse)

        updateState {
            $0.targetPreset = preset
            $0.isMoving = true
            // Optimistic: a fresh recall clears any prior stall/fault flag.
            $0.needsReference = false
            $0.faultCode = nil
        }

        try await sendPreflight()
        startPresetControlLoop(targetMM: targetMM)
    }

    /// Cancels the active preset move task and waits for it to drain.
    func cancelPresetMoveTask() async {
        presetMoveTask?.cancel()
        await presetMoveTask?.value
        presetMoveTask = nil
    }

    // MARK: - Private implementation

    /// Returns the stored height for the given preset index, or throws if unset.
    private func resolvePresetHeight(_ index: Int) throws -> Int {
        guard index >= 1 && index <= state.presets.count else {
            throw DeskError.presetNotSet(index: index)
        }
        guard let heightMM = state.presets[index - 1].heightMM else {
            throw DeskError.presetNotSet(index: index)
        }
        return heightMM
    }

    /// Throws `DeskError.targetOutOfRange` if target falls outside the safe raw range.
    private func guardHeightInRange(_ heightMM: Int) throws {
        guard DeskLimits.safeCommandRange.contains(heightMM) else {
            throw DeskError.targetOutOfRange(heightMM)
        }
    }

    /// Sends the preflight command and waits the required delay.
    private func sendPreflight() async throws {
        try await bleController.write(
            data: DeskCommand.preflight,
            to: DeskUUID.command,
            type: .withoutResponse
        )
        try await clock.sleep(for: presetPreflightDelay)
    }

    /// Starts the background task that drives the desk toward `targetMM`.
    private func startPresetControlLoop(targetMM: Int) {
        let rawTarget = UInt16(targetMM * 10)
        let targetData = DeskCommand.moveTo(tenthsOfMm: rawTarget)
        let controller = bleController
        let clockRef = clock
        let deadline = clock.now().advanced(by: presetTimeout)

        presetMoveTask = Task { [weak self] in
            await self?.runPresetLoop(
                targetMM: targetMM,
                targetData: targetData,
                controller: controller,
                clock: clockRef,
                deadline: deadline
            )
        }
    }

    /// Executes the control loop: writes target every 100ms until arrival,
    /// stall, or the 30s timeout. The stall watchdog stops early (2s of no
    /// height change) and raises `needsReference`, so a blocked module — e.g.
    /// E16/E26 during a recall — is no longer hammered for the full timeout.
    private func runPresetLoop(
        targetMM: Int,
        targetData: Data,
        controller: any BLEControllerProtocol,
        clock: any ClockProtocol,
        deadline: ContinuousClock.Instant
    ) async {
        var tracker = StallTracker(height: state.heightMM, now: clock.now())
        var stalled = false

        while !Task.isCancelled {
            if hasArrived(at: targetMM) { break }
            if clock.now() >= deadline { break }
            try? await controller.write(
                data: targetData,
                to: DeskUUID.targetHeartbeat,
                type: .withoutResponse
            )
            try? await clock.sleep(for: presetLoopInterval)

            if tracker.isStalled(height: state.heightMM, now: clock.now()) {
                stalled = true
                break
            }
        }

        if stalled {
            FileLog.debug(
                "preset stall: height unchanged for \(stallTimeout) — stopping recall; desk may need a reset",
                category: "movement"
            )
            // Set the full stopped state immediately so the UI is consistent at
            // the moment of the stall — a stalled desk sends no more height
            // notifications, so we must not rely on clearPresetMoveState's
            // delayed settle to clear isMoving.
            updateState {
                $0.isMoving = false
                $0.moveDirection = nil
                $0.speedMMS = 0
                $0.targetPreset = nil
                $0.needsReference = true
            }
        }
        await clearPresetMoveState()
    }

    /// Returns true when desk height is within the arrival tolerance of the target.
    private func hasArrived(at targetMM: Int) -> Bool {
        guard let current = state.heightMM else { return false }
        return abs(current - targetMM) <= presetArrivalToleranceMM
    }

    /// Clears movement and target state after the control loop completes.
    /// Sends stop commands to ensure the desk halts, then resets the movement flags.
    private func clearPresetMoveState() async {
        FileLog.debug("clearPresetMoveState: height=\(state.heightMM.map(String.init) ?? "nil")", category: "core")
        // Send stop to ensure desk stops and speed drops to zero.
        try? await bleController.write(data: DeskCommand.stop, to: DeskUUID.command, type: .withoutResponse)
        try? await bleController.write(data: DeskCommand.stop, to: DeskUUID.command, type: .withoutResponse)
        // Wait for deceleration — the desk sends height notifications during
        // deceleration with speed > threshold, keeping isMoving=true. Once fully
        // stopped it sends no more notifications, so isMoving would stay true
        // forever. This delay lets the desk settle before we force the final state.
        try? await clock.sleep(for: .milliseconds(500))
        updateState {
            $0.isMoving = false
            $0.moveDirection = nil
            $0.speedMMS = 0
            $0.targetPreset = nil
            // Recalculate activePreset now that movement is done.
            if let height = $0.heightMM {
                $0.activePreset = activePreset(
                    height: height,
                    presets: $0.presets,
                    isMoving: false
                )
            }
        }
    }
}
