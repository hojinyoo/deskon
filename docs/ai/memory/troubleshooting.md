# Troubleshooting -- linak-control
<!-- Known issues and proven fixes. Updated: 2026-07-18 -->

<!-- 2026-08-27 -->
## Desk's own control panel dead while the app is connected -> heartbeat removed -- Status: resolved
The physical rocker did nothing and the panel LED blinked green whenever the app held a connection; kill the app and the rocker worked with the LED solid green. Cause: `startHeartbeat()` wrote `DeskCommand.heartbeat` (01 80) to `DeskUUID.targetHeartbeat` (99FA0031) once a second for the whole connection. 0x0031 is reference input, where a remote controller writes its target height, so a write every second told the desk it was being driven remotely and it locked out its local panel. Isolated on hardware with one variable: app off -> rocker works, LED solid; connected with heartbeat -> rocker dead, LED blinking; connected with `startHeartbeat()` commented out and nothing else changed -> rocker works, LED solid, and the log showed the desk moving 19mm -> 5mm over 7s across 94 height samples with zero BLE writes from the app.
Fix: the heartbeat is gone, along with the `lastUserAction` / `ensureAwake` idle tracking that existed only to pause and resume it. Keeping the desk awake was the heartbeat's stated job, but every move and preset recall already writes `DeskCommand.wakeUp` (fe 00) first, and a probe held a connected session for over two minutes with no writes and no disconnect. `DeskManagerIdleSilenceTests` guards the invariant: connected and idle must write nothing. If periodic traffic ever turns out to be needed, it must not go to reference input -- the characteristic is the problem, not the interval.

<!-- 2026-07-18 -->
## Cannot initialise the desk while the app runs -> stand-down on fault -- Status: resolved
The user couldn't do the manual re-reference on the control box while linak-control was connected: the app kept reconnecting + re-running the handshake (wake-up + USER_ID write + DPG queries), interfering with the initialisation. Note: production auto-reconnect is actually NOT wired (`handleDisconnection` only called by tests; `BLEController.didDisconnectPeripheral` -> `cleanUpOnDisconnect` never notifies DeskManager) -- the interference came from launch auto-connect + re-handshakes. Fix: on the `needsReference` rising edge, `ConnectionStateObserver` calls `DeskManager.standDown()` -- like `disconnect()` (releases BLE, `isUserInitiatedDisconnect=true`) but PRESERVES `needsReference`/`faultCode` (does NOT use `resetToDisconnected`, which wipes them). So on ANY fault (decoded E16/E26/Initialise OR timing stall) the app disconnects and stands down; the desk is free to initialise. Recovery: `ensureConnectedForAction()` replaces `requireConnected()` in `startMovement`/`executeGoToPreset` -> a move auto-reconnects to `pairedDeskUUID` first; plus a manual Disconnect button (popover footer) + Reconnect (retryConnection). `connect()` success (applyHandshakeResult) clears the preserved fault. Popover DisconnectedContent shows the fault message when needsReference survives. Menu-bar warning icon works in the disconnected state too.

<!-- 2026-07-18 -->
## Desk status characteristic 99fa0003 decode + E16/E26 (fast fault detection) -- Status: resolved
The status characteristic 99fa0003 pushes a short pulse `[0x01, 0x00, code]` with a non-zero code when the control box raises a fault, then clears to empty `[]`. Empirically mapped from captured logs: `0x1e` -> display **E16** (control box read the BLE move commands as an illegal key combination; needs manual re-reference; NOT hardware), `0x17` -> display **E26** (channel 4 missing; possible leg motor/cable fault), `0x1d` -> control box shows **Initialise** (desk lost its position reference; hold DOWN to the bottom to re-initialise). Surfaced three ways: menu-bar icon turns to an orange `exclamationmark.triangle.fill` with a tooltip (MenuBarController.updateZone1Icon), popover banner, and a one-shot macOS notification. Community references (LinakDeskApp, linak-controller, anson-vandoren/linak-desk-spec) do NOT document 99fa0003 — the code->display mapping is ours from real captures. The char is "Readable, Notifiable, Indicatable" per the spec.
Implementation: `DeskProtocol.parseDeskStatus` -> `.ok`/`.fault(code)`, `describeFault`/`faultSummary` for messages. `DeskManager.handleStatusNotification` reacts to a fault pulse instantly (~135ms observed): stops movement+preset, sets `DeskState.needsReference` + `faultCode`. `.ok`/empty is NOT acted on (the clear pulse follows the fault ~60ms later; clearing on it would flash the banner). `needsReference`/`faultCode` cleared optimistically on next move/preset start. UI/IPC surface the code-specific message. E16 is move-triggered so a pre-move read would miss it — react-to-pulse is the reliable path. Also extended the 2s stall watchdog (StallTracker, shared) to `runPresetLoop` — E26 originally hit during a preset recall which the manual/auto-only watchdog didn't cover (hammered 30s). Ref [[project_swift_build_needs_no_sandbox]].

<!-- 2026-07-18 -->
## Desk stalls / E16 while app keeps sending move commands -- Status: resolved (issue #1)
The manual/auto move loops (DeskManager+Movement.swift) wrote the move command every 100ms with `try?` and inspected no feedback, so a blocked desk module (which shows E16 and needs a manual re-reference) was hammered 10x/sec. Fix: the loops are now actor-isolated and watch `state.heightMM`; if height does not change for `stallTimeout` (2s) while moving, the loop stops, writes stop twice, and sets `DeskState.needsReference` (surfaced via popover banner, macOS notification, IPC status). Pattern mirrors `runPresetLoop`. Known limit: a physical end-stop also triggers this (harmless) -- precise E16 vs end-stop needs the status-byte decode (see below).
Deferred layer: the status characteristic 99fa0003 was subscribed in handshake but never consumed. Now `startStatusNotificationListener` logs raw status packets (category "status"). `FileLog.debug` writes in RELEASE too and is no longer reset at launch, so the log at ~/Library/Logs/LinakControl/debug.log persists across app restarts (1MB rolling). Capture a real E16 there, then decode the status byte to set `needsReference` precisely. High-frequency per-tick logs use `FileLog.trace` (DEBUG-only) to avoid flooding the release log.

<!-- 2026-04-08 -->
## Movement button icon no feedback during auto-move -- Status: resolved
UP/DOWN button showed static icon while desk auto-moved to preset, leaving user without visual cue to stop. Fix: swap icon to STOP during active movement (commit 9e44e03).

## Hold mode kept moving after button release -- Status: resolved
In hold mode, pressing UP/DOWN started movement but release did not stop it -- user had to hit stop button. Root cause: hold-button logic was shared with auto-preset flow where continued movement is correct. Fix: manual hold release stops movement; auto mode remains latched (commit 86b752e).

## Auto mode UP key triggered DOWN movement -- Status: resolved
Auto-up target calculation overflowed, causing the UP key to move the desk down. Fix: clamp auto-up target to valid range (commit 86b752e).


## USER_ID corruption -- Status: resolved
Writing incorrect USER_ID data back to the desk corrupted its user profile, resetting calibration/offset to 0. Fix: skip write-back when byte 0 is already 0x01. If corrupted, use the LINAK Desk Control iOS app to repair the desk's user profile.

## DPG queries return 0x0B 0x00 -- Status: resolved
All DPG queries failed because: (a) commands were 2 bytes instead of required 3 bytes, and (b) USER_ID session activation was missing. Fix: 3-byte read format [0x7F, cmd, 0x00] + USER_ID read+write before queries.

## Heartbeat disrupts movement -- Status: superseded by the heartbeat removal below
Heartbeat [0x01 0x80] writes to same characteristic (0x0031) as moveTo targets. Desk interpreted heartbeat as target position ~33m, causing erratic movement. Fix at the time: suppress heartbeat when state.isMoving is true.

## Height validation rejects real values -- Status: resolved
validHeightRange was 500-1500mm (absolute), but height characteristic reports raw values (0-650mm). All real desk heights were rejected. Fix: widen to 0-7000mm for raw values.

## Preset move fails silently -- Status: resolved
validHeightRangeMM in DeskManager+Presets.swift had stale absolute range (600-1350). Raw preset values (49, 420, 486mm) were rejected. Fix: use DeskLimits.safeCommandRange (0-6500) as single source of truth.

## Config lost on restart -- Status: resolved
Adding new fields (deskOffsetMM) to AppConfig broke the auto-synthesized Codable decoder -- missing keys caused entire decode to fail, falling back to defaults. Fix: custom init(from:) with decodeIfPresent for all fields.

## SPM lock files block tests -- Status: known
Background agent processes can leave orphan swift-package processes holding `.build/*.lock`. Fix: `killall swift-package; make test` or `rm -f LinakControl/.build/*.lock`.

## Desk offset resets to handshake value -- Status: resolved
persistPairingInfo and apply() both overwrote the user's manual offset with the handshake-parsed value (1413mm, incorrectly interpreted). Fix: offset exclusively from config, never from handshake state.
