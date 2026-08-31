# Troubleshooting

Recover from common LinakControl failures without filing a ticket: a symptom-first list of the issues you're most likely to hit, where the logs live (release builds write them too), an ordered diagnostic checklist, and what to include if you do need to escalate.

## Common issues

Each entry below leads with the symptom you'll see, then explains what is happening, then gives the fix.

**Menu bar icon never appears after launch**

The app launched but `LSUIElement` failed to register, or macOS suppressed the icon while waiting for Bluetooth permission.

- Open **System Settings → Privacy & Security → Bluetooth** and confirm `LinakControl` is listed and enabled. Without it, `CBCentralManager` never starts and the icon may be hidden until the user grants permission.
- If it's not in the list, re-launch the app — macOS should now prompt for Bluetooth permission.

**Popover is dimmed and says "Not Connected"**

The app is paired but cannot reach the desk over BLE. Most common causes: the desk lost power, you carried the Mac out of range, or macOS dropped the connection on sleep.

- Power-cycle the desk's Bluetooth controller (cable on, wait, cable off → on).
- Click **Retry** in the popover (or wait — the app auto-reconnects with exponential backoff).
- If reconnect keeps failing, run `deskctl config reset` and re-pair from a clean state.

**First-run scanning finds no desks**

- Put the desk's Bluetooth controller in pairing mode — the LED must be **blue**.
- Confirm macOS Bluetooth is on (Control Centre → Bluetooth).
- Confirm Bluetooth permission for `LinakControl` (see first item).
- The desk must be within Bluetooth LE range (a few metres in the same room).

**`deskctl` says `Daemon: not running` (exit code 2)**

The menu bar app must be running for any movement, status, or preset command to work. The CLI is a thin IPC client over a Unix socket at `~/Library/Application Support/LinakControl/linakcontrol.sock`.

- Launch `LinakControl.app` (Spotlight → "LinakControl").
- Verify with `deskctl service status` — it should print `Daemon: running`.

**`deskctl` exits with code 3 (`notConnected`)**

The daemon is up, but the desk isn't currently connected. Different from code 2.

- Power the desk on; the app auto-reconnects.
- Open the popover to confirm the desk shows up and the LED state on the controller.

**`deskctl` exits with code 5 (`timeout`)**

The desk took longer than the IPC timeout to respond. This is usually transient.

- Retry the command once. If it keeps timing out, restart the desk's Bluetooth controller and the menu bar app.

**Heights look wrong — everything is off by a constant**

The desk reports raw heights relative to its own zero, not the floor. The displayed height is raw + `desk_offset_mm`.

- Measure the lowest desk position from the floor in millimetres.
- Set `desk_offset_mm` from the Settings panel (or by editing `config.json`, with the app quit). See [Configuration → Settings reference](configuration.md#settings-reference).

**`deskctl: command not found`**

The CLI installed somewhere your shell does not search.

- Default location: `/usr/local/bin/deskctl`. Confirm it is in your `$PATH`.
- If you used a custom `INSTALL_BIN` with `make install`, add that directory to `$PATH` in your shell profile.

**Desk stops mid-move and the popover shows a warning (control box shows E16 or E26)**

When a move (manual, auto, or preset recall) does not make the desk move, the app **stands down**: it stops sending commands and **disconnects from the desk** so you can operate the control box without the app interfering (it kept reconnecting and re-handshaking otherwise). It warns you three ways: the **menu bar icon turns into an orange warning triangle** (hover it for the cause), a banner appears in the popover, and a macOS notification is posted. It reacts instantly if the desk reports a fault on its status channel, and otherwise after ~2 seconds of no movement (a timing backstop).

**To resume:** initialise / reset the desk on the control box, then either click **Reconnect** in the popover, or simply trigger any movement from the app — a move **auto-reconnects** first, then runs. (You can also disconnect manually any time via the bolt-slash button in the popover footer.)

The message is specific to what the control box reports:

- **Initialise / re-initialisation required.** The desk lost its position reference and asks to be re-initialised. Hold the **down** button until the desk reaches its lowest position and resets (follow your LINAK control box's initialisation procedure). Movement from the app then works normally — the warning clears on your next move.
- **E16 — "needs a reset on the control box".** The control box read the Bluetooth move commands as an illegal key combination and stopped. This is not a hardware fault. Re-reference the desk manually as above. 
- **E26 — "possible hardware fault in a desk leg (check the cables)".** The control box reports channel 4 (a leg motor) as missing. If this recurs, check the motor cable connections to the legs; a persistent E26 points at a cable or motor, not the app.
- Reaching the desk's **physical end-stop** does *not* raise this warning. The app only claims a fault when the desk never moved at all under a move command; a desk that moved and then stopped is treated as having arrived. (An **auto** move targets the end-stop by design, so this is the normal way one finishes.)

The exact bytes the desk reports are recorded in the log under `[status]` (see [Where to look for logs](#where-to-look-for-logs)); include them if you report a movement fault.

**A hand edit to `config.json` was silently undone**

There is no file watcher. The running app holds the config in memory; the next `ConfigStore.save()` (any UI change) overwrites your edit.

- Quit the app first → edit the file → relaunch. See [Configuration → Overriding settings](configuration.md#overriding-settings).

## Where to look for logs

Both debug **and release** builds write an event log to:

```
~/Library/Logs/LinakControl/debug.log
```

```bash
tail -f ~/Library/Logs/LinakControl/debug.log
```

Each line is timestamped with millisecond precision and tagged with a category (e.g. `[ui]`, `[ble]`, `[status]`, `[movement]`). The log **persists across app restarts** (it is no longer truncated at launch). At **1 MB** it is rotated: the full file becomes `debug.log.1` and logging continues in a fresh `debug.log` — so an intermittent fault can be captured after it happens, and if it is not in `debug.log`, look in `debug.log.1`. Only one rotated file is kept; the next rotation replaces it. Each launch appends a `=== LinakControl launch ===` banner so you can find the session boundary.

This is what makes it possible to diagnose intermittent hardware faults (e.g. the desk showing **E16** and needing a manual re-reference): reproduce the fault, then send the relevant slice of `debug.log`. The `[status]` lines are the raw bytes the desk reports on its status characteristic — the raw material for pinning down exactly what the desk signalled.

High-frequency per-tick output (the ~10 Hz BLE write hexdump) is **debug-only** so it never floods the bounded release log; release logs stay event-level.

**Console.app fallback**

`Console.app` also captures `os_log` entries and unhandled errors:

1. Open `Console.app`.
2. Filter on `LinakControl` in the search bar.
3. Reproduce the issue.

It does not show the structured `[category]` lines from `debug.log`.

**`deskctl` does not log**

The CLI is stateless and short-lived. It prints to stdout/stderr only — there is no `deskctl` log file. If a command misbehaves, re-run it with `--json` so the error payload is machine-readable, and capture stderr.

## Diagnostic steps

Run these checks in order before reaching out for help. Each step takes under a minute and rules out the most common root causes.

**1. Is the menu bar app running?**

```bash
deskctl service status
```

- `Daemon: running (connected)` — app and desk both good. Symptom is elsewhere.
- `Daemon: running (disconnected)` — app up, BLE link down. Continue to step 3.
- `Daemon: not running` — launch `LinakControl.app` and retry.

**2. Is the desk reachable?**

```bash
deskctl status
```

- Prints a height → desk is reachable; the problem is in your command or expectations.
- Exits non-zero → note the exit code (`echo $?`) and match it against the table in [Usage → Output formats and exit codes](usage.md#output-formats-and-exit-codes).

**3. Is the desk powered and in range?**

- Confirm the desk's Bluetooth controller LED is lit.
- Move the Mac closer; BLE range is roughly the same room.
- Power-cycle the desk's controller if the LED is unresponsive.

**4. Does macOS still trust the Bluetooth permission?**

- **System Settings → Privacy & Security → Bluetooth** — `LinakControl` toggle should be **on**.
- If the toggle is missing, re-launch the app and accept the prompt.

**5. Is the config sane?**

```bash
deskctl config show
```

- Confirm `paired_desk_uuid` and `paired_desk_name` are set. If absent, the app has not paired yet.
- Confirm `desk_offset_mm` looks reasonable for your installation.
- If anything looks wrong, `deskctl config reset` wipes back to defaults — you'll re-pair from scratch.

**6. Capture the log around the failure**

If steps 1–5 look fine but the symptom persists, watch the log while you reproduce it (this works on the installed release build too):

```bash
tail -f ~/Library/Logs/LinakControl/debug.log
```

Reproduce the issue and copy the last 50–100 lines for the bug report. Grab it soon after the fault — heavy activity afterwards rotates the event into `debug.log.1`, and a second rotation discards it altogether. If the fault is not in `debug.log`, check `debug.log.1` before giving up.

## Getting help

If the [Common issues](#common-issues) entries and the [Diagnostic steps](#diagnostic-steps) didn't resolve your problem, file an issue at:

**[github.com/MMoMM-org/linak-control/issues](https://github.com/MMoMM-org/linak-control/issues)**

To save a round-trip, include this in the report:

**Environment**

- macOS version (e.g. 14.4, 15.0).
- Mac model (e.g. MacBook Pro M2).
- LINAK desk model and Bluetooth controller revision if known.

**Build**

- Did you install via `./install.sh` (release) or `./run.sh` (debug)?
- Output of `deskctl --version`.

**Symptom**

- Exactly what you did and what happened.
- Expected vs actual behaviour.
- Whether it reproduces every time or intermittently.

**Diagnostic output**

- Output of `deskctl service status`.
- Output of `deskctl status --json`.
- Output of `deskctl config show` (redact `paired_desk_uuid` if you care; the name and offset are harmless).
- The last ~100 lines of `~/Library/Logs/LinakControl/debug.log` around the time of the failure (works on release builds too — see [Where to look for logs](#where-to-look-for-logs)).

**One thing to leave out**

The full `debug.log` can contain your home directory path. Skim the snippet you paste and redact anything personal before posting.
