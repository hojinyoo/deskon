# Installation

Install LinakControl on macOS: prerequisites, the `install.sh` script, how to verify the menu bar app and the `deskctl` CLI are working, and how to update later.

## Prerequisites

Before installing, make sure you have the following.

**Hardware**

- A LINAK DPG1C-compatible standing desk with a Bluetooth controller. The controller must be powered on and in pairing mode (blue LED) the first time you connect.
- A Mac with Bluetooth LE support.

**Operating system**

- macOS 14 (Sonoma) or later.

**Build tools** (`install.sh` checks for these and refuses to run if either is missing)

- **Xcode 15+** with the Swift 5.9 toolchain. A full Xcode install is required — Command Line Tools alone are not sufficient because the `.app` bundle is produced via `xcodebuild` with CoreBluetooth entitlements and an embedded `Info.plist`.
- **xcodegen** — install with `brew install xcodegen`. The Xcode project is generated from `project.yml` on every build.

**Privileges**

- Installing the `deskctl` CLI to `/usr/local/bin` may prompt for `sudo`. If you would rather not grant admin, use a custom install path (see [Install](#install)).

## Install

The repository ships an `install.sh` script that builds both binaries, installs them, and launches the menu bar app. Run it from the repo root.

**Default install** (app to `/Applications`, CLI to `/usr/local/bin`):

```bash
./install.sh
```

**Custom app location** — pass an alternative directory; the CLI still goes to `/usr/local/bin`:

```bash
./install.sh ~/Applications
```

The script performs these steps in order:

1. Preflights `xcodebuild` and `xcodegen`. Aborts with an install hint if either is missing.
2. Stops any running `LinakControl` instance so the reinstall is clean.
3. Regenerates `LinakControl.xcodeproj` from `project.yml` and builds a Release `.app` bundle.
4. Removes the previous install at the target directory (if any) and copies in the new `.app`.
5. Builds `deskctl` in Release mode via SPM and installs it to `/usr/local/bin/deskctl` (prompting for `sudo` if needed).
6. Opens `LinakControl.app` so you can confirm the menu bar icon appears.

To install only the CLI without an `.app` bundle, you can also use the Makefile target — it builds `deskctl` with SPM and installs to `INSTALL_BIN` (defaults to `/usr/local/bin`):

```bash
make install                            # CLI only, default location
make install INSTALL_BIN=~/.local/bin   # custom CLI location
```

## Verify the installation

After `install.sh` exits cleanly, walk through these three checks. Each one targets a different layer (app bundle, CLI binary, BLE link).

**1. Menu bar app launched**

The script ends with `open` on the installed `.app`. Confirm the menu bar shows the LinakControl desk icon. If macOS prompts for **Bluetooth permission** (it will on first launch — the app declares `NSBluetoothAlwaysUsageDescription`), grant it. Without Bluetooth, the app cannot find your desk.

**2. CLI responds**

```bash
deskctl --help
```

You should see the command list (`status`, `height`, `preset`, `move`, `config`, …). If the shell reports `command not found`, your `$PATH` does not include the install location — either add it, or re-run `./install.sh` without a custom `INSTALL_BIN`.

**3. Pairing succeeds**

Power on your desk and put its Bluetooth controller into pairing mode (the LED turns blue). Click the menu bar icon to open the popover, then pick your desk from the scan list. Once paired, the popover and the second menu bar zone show a live height reading. From the CLI:

```bash
deskctl status
```

A successful status print confirms IPC, BLE, and the persisted desk identity are all working.

If any check fails, see [Troubleshooting](troubleshooting.md).

## Updating

There is no separate updater — `install.sh` is idempotent and reuses itself for upgrades.

**Update to the latest commit:**

```bash
git pull
./install.sh
```

The script stops the running app, rebuilds Release, removes the existing `LinakControl.app` from the target directory, and copies the new bundle into place. The CLI at `/usr/local/bin/deskctl` is overwritten in the same run.

**What is preserved across updates**

- `~/Library/Application Support/LinakControl/config.json` — your settings, paired desk, preset labels, and offsets stay intact.
- Login Item registration (if you enabled `start_at_login`) survives the reinstall.

**What is reset**

- `~/Library/Logs/LinakControl/debug.log` persists across app restarts (release builds included). At 1 MB it is rotated to `debug.log.1` and a fresh `debug.log` is started, so the previous megabyte stays available — but a second rotation discards it. Save a copy first if you need a specific event for an issue report.

**Starting fresh** — if you want to re-pair from scratch (forgetting the saved desk and all settings), wipe the config directory before relaunching:

```bash
rm -rf ~/Library/Application\ Support/LinakControl
open /Applications/LinakControl.app
```

For local development builds, `./run.sh --clean` does the same wipe and then builds and launches a debug build.
