# Usage

Operate LinakControl after install and pairing: menu bar interactions, common sit/stand workflows, the full `deskctl` CLI surface, and the JSON output and exit codes you need for scripting.

## Basic use

LinakControl has two front ends. They share the same paired desk and the same configuration file, so you can mix them freely.

**Menu bar app — two zones**

After launching `Deskon.app`, the menu bar shows two separate items (Zone 2 is created first so macOS places Zone 1 to its left):

- **Zone 1 — desk icon.** Click to toggle the popover. The popover shows the current height, manual up/down controls, and a 2×2 preset grid. While the desk is not connected the icon switches to a dimmed outline desk; a desk fault replaces it with an orange warning triangle.
- **Zone 2 — height/preset text.** Click to open a dropdown listing the four presets and their stored heights; pick one to move there. It only exists while the desk is connected, so no stale height is left in the menu bar after a disconnect.

**CLI — `deskctl`**

The CLI talks to the running menu bar app over a Unix socket, so the app must be running for desk commands to work. The simplest sanity-check after pairing:

```bash
deskctl status
```

A successful run prints the connection state, the desk name, the current height, and the four preset slots (`*` marks the active one):

```
LinakControl Daemon
  Connection: connected
  Desk:       LINAK-DPG1C-1A2B
  Height:     72.4 cm
  Presets:    1=63 cm  2=78.5 cm*  3=110 cm  4=120 cm
```

If `deskctl` reports `Daemon: not running`, launch the app first.

## Common workflows

The patterns below cover what most users want LinakControl for. Each one shows both the GUI path and the CLI path.

**Set up a sit/stand routine**

The point of presets is one-click switching between sitting and standing height. Once paired:

1. Move the desk to your preferred sitting height (manual up/down in the popover, or `deskctl up --manual` then `deskctl stop`).
2. Save it to preset 1 — open the popover **Settings**, find preset 1, and tap **Save current height**. From the CLI: `deskctl preset 1 --save`.
3. Repeat at your standing height and save to preset 2.
4. Switch between the two from the menu bar Zone 2 dropdown, the popover preset grid, or:

   ```bash
   deskctl preset 1   # sit
   deskctl preset 2   # stand
   deskctl toggle     # whichever of the two you are not at
   ```

**Label your presets**

Labels appear in `deskctl status` and (when supported by the UI) in the menu — useful when you can't remember which slot is which.

```bash
deskctl config label 1 Sitting
deskctl config label 2 Standing
deskctl config label 3 --clear   # remove a label
deskctl config label 2           # show current label without changing it
```

**Manual movement when no preset fits**

The popover has hold-to-move up/down buttons. Releasing the button stops the desk. If you have `auto_run_up` / `auto_run_down` set to `auto` (see [Configuration](configuration.md)), the buttons toggle continuous movement instead of requiring a hold.

The CLI mirrors both modes:

```bash
deskctl up --manual    # repeats the raw move command; runs until stop
deskctl up --auto      # starts continuous up movement
deskctl stop           # stops any movement immediately
deskctl down --auto    # same in the other direction
```

`--auto` and `--manual` are mutually exclusive; passing neither is the same as `--manual`. Neither mode is a nudge: both run until `deskctl stop`, until the height stops changing for 2 seconds, or until the desk reaches an end stop.

To go straight to a height instead of nudging:

```bash
deskctl goto 110.5   # in the unit from `deskctl config show`
```

The height is the one `deskctl status` prints, so the desk offset is already accounted for. A target outside `desk_offset_mm` to `desk_offset_mm + max_stroke_mm` is refused before anything reaches the desk, and the error names the range. The desk reports its lowest position but not its travel, so `max_stroke_mm` is a setting; see [Configuration](configuration.md).

**Script height changes**

`deskctl toggle` is the sit/stand switch, so a hotkey or cron job is one line:

```bash
deskctl toggle
```

Use it from a cron job, a hotkey via macOS Shortcuts/Raycast, or a Home Assistant automation. Both presets 1 and 2 have to be set; toggle moves to whichever one the desk is further from.

## deskctl CLI reference

All commands are subcommands of `deskctl`. Every command except `config show`, `config reset`, `config label`, and `service install` requires the menu bar app to be running (it owns the BLE connection; the CLI is an IPC client).

| Command | Description | Flags |
|---|---|---|
| `deskctl status` | Connection state, paired desk name, current height, presets. | `--json` |
| `deskctl height` | Just the current height (no surrounding fields). | `--json` |
| `deskctl up` | Move the desk up. | `--auto`, `--manual` (mutually exclusive) |
| `deskctl down` | Move the desk down. | `--auto`, `--manual` (mutually exclusive) |
| `deskctl stop` | Stop any active movement immediately. | — |
| `deskctl preset <1-4>` | Move to the named preset. | `--save` (overwrite that slot with the current height) |
| `deskctl goto <height>` | Move to an absolute height, in the configured unit. | - |
| `deskctl toggle` | Move to whichever of presets 1 and 2 the desk is further from. | - |
| `deskctl config show` | Print the full config JSON. | — |
| `deskctl config reset` | Wipe config back to defaults (clears pairing). Prompts unless forced. | `--force` |
| `deskctl config label <1-4> [text]` | Show, set, or clear a preset label. | `--clear` |
| `deskctl config name [text]` | Show, set, or clear the desk name. Overrides the name learned over BLE. | `--clear` |
| `deskctl service status` | Check whether the daemon (the menu bar app) is reachable. | — |
| `deskctl service stop` | Send SIGTERM to the running daemon. | — |
| `deskctl service install` | Print instructions for enabling Start-at-Login. | — |

A few details that are not obvious from `--help`:

- **`config name` overrides the BLE name** - the desk reports whatever LINAK stamped on it (`DESK 3424`). Setting a name wins everywhere the desk is named; clearing it falls back to the reported one. The menu bar app picks up a rename on its next connection.
- **Preset indices are validated** — `deskctl preset 5` returns a `ValidationError`. The same goes for labels.
- **`config show` reads the config file directly**, so it works even if the daemon is stopped. Same for `config reset` and `config label`.
- **`config reset` clears pairing too** — the next app launch goes back to first-run scanning. Use `--force` only in scripts where you're certain.
- **`service install`** does not register anything itself; it just prints the steps for the Settings panel.
- **Version** — `deskctl --version` prints `1.0.0` (defined in `DeskctlCommand.swift`).

## Output formats and exit codes

**Plain text (default).** Status, height, and preset commands print human-readable lines. Error messages are also plain text and go to **stderr**, never stdout — so piping stdout into another program stays clean.

**`--json` (where available).** `deskctl status` and `deskctl height` accept `--json`. Field names are snake_case. The schema is **additive**: fields get added as the app grows (`needs_reference` and `fault_code` both arrived after the first release), so parse by key and ignore what you do not recognise rather than assuming a fixed set.

`deskctl status --json` shape:

```json
{
  "connected": true,
  "desk_name": "DESK 0726",
  "height_mm": 1097,
  "height_display": "109.7 cm",
  "unit": "cm",
  "presets": [
    {"index": 1, "height_mm": 709},
    {"index": 2, "height_mm": 1097, "label": "Standing"},
    {"index": 3, "height_mm": 1146},
    {"index": 4}
  ],
  "active_preset": 2,
  "needs_reference": false
}
```

Two things to know before you parse it:

- **Optional fields are omitted, not null.** An unset preset is `{"index": 4}` — no `height_mm`, no `label`. Same for `fault_code` below. Use `jq`'s `//` default or check for presence; do not expect `null`.
- **`height_display` includes the unit** (`"109.7 cm"`, `"43.2 in"`). Use `height_mm` for arithmetic — it is always millimetres regardless of the `unit` setting, and already includes `desk_offset_mm`.

**Fault fields.** Two fields report whether the desk is asking to be re-referenced:

| Field | Type | Always present | Meaning |
|---|---|---|---|
| `needs_reference` | bool | yes | A move stalled or the desk reported a fault. The app has disconnected so you can operate the control box. |
| `fault_code` | int | **no** — only when the desk pushed one | Raw code behind `needs_reference`, e.g. `30` (`0x1e`) for **E16**, `23` (`0x17`) for **E26**. |

When `needs_reference` is `true`, the desk needs a manual re-reference on the control box — see [Troubleshooting](troubleshooting.md). A script that drives the desk unattended should check it before issuing a move, since movement commands will not take effect until the desk is re-referenced:

```bash
if [ "$(deskctl status --json | jq '.needs_reference')" = "true" ]; then
  echo "Desk needs a manual reset — code: $(deskctl status --json | jq '.fault_code // "none reported"')" >&2
  exit 1
fi
```

`deskctl height --json` shape:

```json
{"height_mm": 724, "height_display": "72.4 cm", "unit": "cm"}
```

Errors in `--json` mode print a single JSON object: `{"error": <code>, "message": "<text>"}`. The code matches the process exit code.

**Exit codes.** Scripts can branch on these:

| Code | Name | Cause |
|---|---|---|
| `0` | `success` | Command completed. |
| `1` | `general` | Connection failed, invalid response, or any uncategorised failure. |
| `2` | `daemonNotRunning` | The menu bar app is not running. Start `Deskon.app` and retry. |
| `3` | `notConnected` | The daemon is up but the desk is not currently paired/connected (e.g. desk powered off). |
| `5` | `timeout` | The desk did not respond within the timeout. Often resolved by trying again. |

A robust polling script:

```bash
if ! deskctl status >/dev/null 2>&1; then
    case $? in
        2) echo "Start Deskon.app first."; exit 1 ;;
        3) echo "Desk disconnected — power on and re-pair."; exit 1 ;;
        5) echo "Desk timed out; retrying."; exec "$0" ;;
        *) echo "Unknown failure."; exit 1 ;;
    esac
fi
```
