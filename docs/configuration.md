# Configuration

Reference for every user-configurable option in `~/Library/Application Support/LinakControl/config.json`: where the file lives, the full key/type/default table, how to override settings safely, and an annotated sample.

## Where settings live

LinakControl persists all user-facing settings in a single JSON file:

```
~/Library/Application Support/LinakControl/config.json
```

The app creates the directory with mode `0700` and the file with mode `0600` on first save, so it is readable and writeable only by your user. The file format is pretty-printed JSON with sorted keys (so manual diffs stay clean across reinstalls).

When the file does not exist, the app and the CLI both fall back to `AppConfig.default` — the same defaults documented in [Settings reference](#settings-reference). Nothing is written until you change a setting.

`config.json` is the **only** persistent state for the app. There is no system-level `defaults` plist, no environment variable overrides, and no separate keychain entry — wiping the directory above resets the app completely (see [Updating → Starting fresh](installation.md#updating)).

## Settings reference

The table below covers every key the app reads from or writes to `config.json`. All keys are optional — missing keys fall back to the default value shown.

| JSON key | Type | Default | Description |
|---|---|---|---|
| `paired_desk_uuid` | `string \| null` | `null` | CoreBluetooth peripheral UUID of the paired desk. Set when you pick a desk during first-run scanning; cleared by `deskctl config reset` or by wiping the config directory. Don't edit by hand. |
| `paired_desk_name` | `string \| null` | `null` | Human-readable name of the paired desk shown in the UI and `deskctl status`. Same lifecycle as `paired_desk_uuid`. |
| `unit` | `"cm" \| "inch"` | `"cm"` | Display unit for height in the popover, the menu bar, and `deskctl` output. Internal storage and BLE values are always millimetres; this is presentation only. |
| `desk_offset_mm` | `integer` (mm) | `0` | Base height of the desk's lowest position above the floor, in millimetres. Heights from the desk are relative to its internal zero; this offset is added to produce the absolute floor-height shown in the UI. |
| `max_stroke_mm` | `integer` (mm) | `650` | How far the desk travels above its lowest position. `deskctl goto` refuses a target outside `desk_offset_mm` to `desk_offset_mm + max_stroke_mm` instead of driving into an end stop. The desk reports its base height but not its travel, so this is a setting; the default is the raw height the up button already drives to. Set it to your desk's own travel to tighten the check. |
| `auto_run_up` | `"manual" \| "auto"` | `"manual"` | Up button behaviour in the popover. `manual` = hold to move, release to stop. `auto` = tap once to start continuous motion. The CLI flags `--manual` / `--auto` on `deskctl up` mirror this. |
| `auto_run_down` | `"manual" \| "auto"` | `"manual"` | Same as `auto_run_up`, but for the Down button. |
| `start_at_login` | `boolean` | `false` | Register the app as a Login Item via `SMAppService`. Toggle this from **Settings → Start at Login** rather than editing the file by hand — the underlying API requires the toggle to make the system call. |
| `hotkeys_enabled` | `boolean` | `false` | Enable global keyboard shortcuts. |
| `show_zone_2` | `boolean` | `true` | Show the Zone 2 menu bar item (the height + preset dropdown). Setting it to `false` hides the second status item; Zone 1 (the icon + popover) stays visible. |
| `preset_labels` | `array(4)` of `string \| null` | `[null, null, null, null]` | Labels for presets 1–4. Use `deskctl config label N <text>` or the popover Settings; the label appears in `deskctl status` and the Zone 2 menu. |

**Legacy keys (read-only).** Older config files (pre-`preset_labels`) stored one key per preset: `preset_1_label`, `preset_2_label`, `preset_3_label`, `preset_4_label`. The app still **reads** these for backward compatibility, but only **writes** the new `preset_labels` array — so on the next save the legacy keys disappear from the file.

## Overriding settings

Three ways to change a setting, in order of safety:

**1. Popover Settings (preferred for most settings)**

Click the menu bar icon, then the Settings gear in the popover. The view lets you change the unit, desk offset, movement modes, login-at-startup, hotkeys, Zone 2 visibility, and preset labels. Changes are written through `ConfigStore.save()` immediately.

**2. `deskctl` CLI**

The CLI exposes a focused subset:

```bash
deskctl config show              # print the current config (reads config.json directly)
deskctl config label 1 Sitting   # set/clear preset labels (see Usage)
deskctl config reset             # wipe back to defaults; prompts unless --force
```

`config show` and `config reset` operate on `config.json` directly — they work even when the menu bar app is not running. The other CLI commands (`up`, `down`, `preset`, `status`, `height`) read settings indirectly through the daemon.

**3. Editing `config.json` by hand** (last resort)

You can open `config.json` in any editor — the file is plain JSON. Keep two things in mind:

- **There is no file watcher.** The running app holds `AppConfig` in memory and won't notice a hand edit until you quit and relaunch the app. If you make a change and the running app then saves the config (because you toggled something in Settings), your hand edit is overwritten.
- **The encoder sorts keys and pretty-prints.** Any reformatting you do is harmless — the app will normalise the file on the next save.

Recommended flow for hand edits: quit the app first → edit the file → relaunch.

**Precedence**

There is no merge logic. The last writer wins. The UI, `deskctl config`, and a hand edit all write the full file via `ConfigStore.save()` (or by being the editor). Concurrent edits between the UI and a separate hand edit can clobber each other — quit the app before editing if it matters.

## Defaults and example

**A fresh `config.json`** — what gets written the first time the app saves with no settings yet customised (sorted keys, pretty-printed):

```json
{
  "auto_run_down" : "manual",
  "auto_run_up" : "manual",
  "desk_offset_mm" : 0,
  "hotkeys_enabled" : false,
  "preset_labels" : [null, null, null, null],
  "show_zone_2" : true,
  "start_at_login" : false,
  "unit" : "cm"
}
```

Note that `paired_desk_uuid` and `paired_desk_name` are absent — `null` values for those two keys are not written at all (the encoder skips them). They appear automatically the first time you pair a desk.

**A customised `config.json`** — typical sit/stand setup, US units, two preset labels, hidden Zone 2:

```json
{
  "auto_run_down" : "auto",
  "auto_run_up" : "auto",
  "desk_offset_mm" : 620,
  "hotkeys_enabled" : false,
  "paired_desk_name" : "LINAK-DPG1C-1A2B",
  "paired_desk_uuid" : "4D2F1C9B-7E1F-4C8D-9B6A-2E5F8D4A1B3C",
  "preset_labels" : ["Sitting", "Standing", null, null],
  "show_zone_2" : false,
  "start_at_login" : true,
  "unit" : "inch"
}
```

**Which defaults are safe to leave alone**

- `auto_run_up` / `auto_run_down` (`"manual"`) — safe. Auto mode is a personal preference; manual is conservative.
- `desk_offset_mm` (`0`) — safe **only if** you don't care that the displayed height is relative to the desk's lowest position rather than the floor. Measure the lowest position above the floor and set this once for accurate absolute heights.
- `hotkeys_enabled` (`false`) — safe. Global hotkeys are off by default; turn on only if you've configured them.
- `show_zone_2` (`true`) — safe. Hide only if the second menu bar item is too cluttered for your menu bar.
- `start_at_login` (`false`) — safe. Toggle from Settings if you want the app to auto-launch.

**Which defaults you'll probably want to change**

- `unit` — set to `"inch"` if you measure in inches.
- `preset_labels` — labels make the menu and `deskctl status` readable.
- `desk_offset_mm` — see above.

**Which keys to never touch by hand**

- `paired_desk_uuid` and `paired_desk_name` — the app manages these during the pairing flow. Hand-editing them will either dangle the connection or break it. If you want to re-pair, run `deskctl config reset` (or wipe the directory) and let the app rescan.
