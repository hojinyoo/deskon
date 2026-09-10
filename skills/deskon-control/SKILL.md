---
name: deskon-control
description: Raise, lower, stop, or query a LINAK standing desk through the deskctl CLI installed by Deskon - presets, sit/stand toggle, absolute height, and status. Use for requests to move the desk or read its height, not for developing the Deskon app itself.
---

# Deskon Control

`deskctl` at `/usr/local/bin/deskctl` drives a LINAK DPG1C desk. It is an IPC client: the Deskon menu bar app owns the Bluetooth link, so every desk command needs that app running and connected to the desk.

This moves real furniture. Someone's monitor, laptop and coffee ride on it.

## Authorization

A direct request authorizes exactly the movement it names. "Lower the desk to preset one" is `deskctl preset 1`, run once, no confirmation step and no follow-up questions. Do not turn a clear request into a questionnaire.

Never run any of these unless the user asked for that specific effect:

| Never as a helpful extra | What it does |
|---|---|
| `deskctl preset N --save` | overwrites a stored preset with the current height |
| `deskctl config reset` | clears pairing and every setting |
| `deskctl config label`, `deskctl config name` | edits stored config |
| `deskctl service stop` | SIGTERMs the app that owns the BLE link |
| editing `~/Library/Application Support/LinakControl/config.json` | same, by hand |
| re-pairing or forgetting the desk | drops the paired identity |

**Never retry a movement that failed or timed out.** Report the failure and the current status. Sending the desk moving again is a new physical action and needs a new request.

**Never invent a target.** "A bit higher" or "standing height" with no number is a question for the user, not a height to guess. When the user names a preset, use the preset rather than converting it to a height.

## Commands

| Request | Command |
|---|---|
| Go to a preset | `deskctl preset 2` |
| Sit/stand switch | `deskctl toggle` |
| A specific height | `deskctl goto 110.5` |
| Start moving | `deskctl up`, `deskctl down` |
| Stop | `deskctl stop` |
| Current height | `deskctl height` (`--json`) |
| Full state | `deskctl status` (`--json`) |

**`preset`** takes 1-4. Anything else exits 64 without reaching the desk.

**`toggle`** moves to whichever of presets 1 and 2 the desk is further from, so repeated toggles alternate sitting and standing. Both slots must be set; otherwise it exits 1 and names the unset one.

**`goto`** reads the height in the unit from `deskctl config show`, and it is the height `deskctl status` prints, with the desk offset already included. A target outside `desk_offset_mm` to `desk_offset_mm + max_stroke_mm` is refused before anything reaches the desk (exit 1, and the message names the range).

**`up` / `down` keep going.** They are not a nudge: the desk moves until `deskctl stop`, until its height stops changing for 2 seconds, or until it hits an end stop. Pair every `up` or `down` with a plan to stop it. `--auto` drives at the travel limit and ends on arrival; `--manual`, which is also what you get with no flag, repeats the raw move command. The two flags are mutually exclusive. For a known destination prefer `preset` or `goto`, which stop themselves.

## Readiness

Check before moving only when a check changes what you do: the last thing you saw was a disconnect or a fault, or the user asked whether the desk is ready. Otherwise just run the command - it fails loudly with a specific exit code and sends nothing to the desk.

`deskctl service status` prints one of `Daemon: running (connected)`, `Daemon: running (disconnected)`, or `Daemon: not running`.

`needs_reference: true` in `deskctl status --json` means the desk stalled or reported a fault, and the app stood down so someone can use the control box. Movement will not take effect until the desk is re-referenced by hand, which only a person standing at the desk can do. Plain `deskctl status` prints a `Warning:` line that already decodes `fault_code` into what the desk needs, so relay that line rather than the raw number, and do not send movement.

## Exit codes and output

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | connection failed, bad response, target out of range, or preset unset - the stderr message is specific, pass it on |
| 2 | Deskon.app is not running; ask the user to start it |
| 3 | app running, desk not connected (powered off, out of range) |
| 5 | the desk did not answer in time |
| 64 | bad arguments, e.g. `deskctl preset 5`; nothing was sent |

Errors go to stderr, so stdout stays clean for piping. Under `--json` an error is a single `{"error": <code>, "message": "..."}` whose code matches the exit status.

`deskctl status --json` omits optional fields rather than nulling them - an unset preset is `{"index": 4}`, and `fault_code` appears only when the desk pushed one. `height_mm` is always millimetres with `desk_offset_mm` already added; `height_display` carries its unit as text, so use `height_mm` for arithmetic.
