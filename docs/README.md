# Documentation

LinakControl is a macOS menu bar app and `deskctl` companion CLI for controlling LINAK DPG1C standing desks over Bluetooth Low Energy. These pages take you from a clean Mac to a running setup, and back up after something breaks.

## Overview

LinakControl runs on macOS 13+ and is distributed as source — there is no App Store build. The menu bar app handles pairing, live height display, manual movement, and presets. `deskctl` exposes the same surface to scripts and hotkey tools via a Unix-socket IPC, so anything you can click in the popover you can also automate from the shell.

## Documentation map

**New to LinakControl**

- [Installation](installation.md) — prerequisites, `install.sh`, verifying the menu bar app and `deskctl` both work, updating later.

**Already running**

- [Usage](usage.md) — menu bar interactions, sit/stand workflows, the full `deskctl` command surface, and JSON output / exit codes for scripting.
- [Configuration](configuration.md) — every key in `~/Library/Application Support/LinakControl/config.json`, how to override settings safely, defaults, and an annotated sample.

**Something broke**

- [Troubleshooting](troubleshooting.md) — symptom-first list of common issues, where logs live (and why release builds don't have any), a 6-step diagnostic checklist, and how to file a useful bug report.

## Quick links

Common reasons people land here, with a jump straight to the right section:

- [Pair a new desk](installation.md#verify-the-installation) — get the menu bar icon recognising your desk for the first time.
- [Set up a sit/stand routine](usage.md#common-workflows) — save preset 1 + preset 2 and switch with one click or command.
- [Where is `config.json`?](configuration.md#where-settings-live) — file location, permissions, and what wipes it.
- [`deskctl` reference](usage.md#deskctl-cli-reference) — every subcommand and flag in one table.
- [`deskctl` says "Daemon: not running"](troubleshooting.md#common-issues) — the most common CLI error and the fix.
- [File a bug report](troubleshooting.md#getting-help) — what to include so the round-trip is short.
