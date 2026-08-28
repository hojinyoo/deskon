<p align="center">
  <img src="assets/linak-control-gh-logo.png" alt="linak-control" width="600">
</p>

# linak-control

macOS menu bar app and CLI for controlling LINAK DPG1C standing desks via Bluetooth Low Energy.

## Features

- **Menu bar app** with two zones: desk icon (popover) and height/preset text (dropdown)
- **Preset recall**: 4 saved height positions, switchable from the popover, menu bar dropdown, or `deskctl preset N`
- **Manual movement**: hold-to-move up/down buttons, or auto-run mode (tap to start/stop)
- **Live height display**: real-time height with configurable desk offset
- **Settings**: display unit (cm/inch), movement mode, preset management, desk offset
- **Auto-reconnect**: reconnects on disconnect with exponential backoff, plus system wake detection
- **CLI tool** (`deskctl`): status, height, preset, and move commands via IPC

## Requirements

macOS 14+ with full Xcode 15+ (Swift 5.9) and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), plus a LINAK DPG1C-compatible desk. See [docs/installation.md#prerequisites](docs/installation.md#prerequisites) for the full breakdown.

## Quick Start

```bash
# Build and launch the debug app
./run.sh

# Build and launch with clean config (first-run pairing)
./run.sh --clean
```

On first launch, the app scans for nearby LINAK desks. Select your desk to pair. The desk's Bluetooth controller LED should be in pairing mode (blue).

## Screenshots

Both menu bar zones in context:

<p align="center">
  <img src="docs/screenshots/menubar.png" alt="Menu bar zones">
</p>

Popover (zone 1) and preset menu (zone 2):

<p align="center">
  <img src="docs/screenshots/menubar-popover.png" alt="Menu bar popover" width="320">
  <img src="docs/screenshots/menubar-preset-menu.png" alt="Preset menu" width="180" valign="top">
</p>

Settings (top and scrolled):

<p align="center">
  <img src="docs/screenshots/settings.png" alt="Settings view" width="300">
  <img src="docs/screenshots/settings-scrolled.png" alt="Settings view scrolled" width="300">
</p>

Regenerate from a clean state with `/Applications/LinakControl.app` installed (`./install.sh`), the desk powered on and paired, and the app running:

```bash
./scripts/take-screenshots.sh
```

This runs the `LinakControlUITests` XCUITest target which drives the installed app, captures full-screen shots, crops them to each UI region, and writes the PNGs into `docs/screenshots/`. Captured shots: `menubar`, `menubar-popover`, `menubar-preset-menu`, `settings`, `settings-scrolled`.

The first run will prompt for **Accessibility permission** for the XCUITest runner (System Settings → Privacy & Security → Accessibility). Grant it once; subsequent runs are silent.

## Install

```bash
./install.sh                  # release app → /Applications, deskctl → /usr/local/bin, then launch
./install.sh ~/Applications   # custom app location
```

`install.sh` stops any running instance, rebuilds Release, installs both binaries (may prompt for `sudo`), and opens the app. See [docs/installation.md](docs/installation.md) for the full prerequisites/install/verify/updating flow.

## Build

```bash
make help               # Show all targets
make xcode-build-debug  # Build .app bundle (debug)
make xcode-build        # Build .app bundle (release)
make build              # Build CLI binary via SPM
make test               # Run test suite (385 tests)
make install            # Install deskctl to /usr/local/bin
make clean              # Remove build artifacts
```

The `.app` bundle is built via Xcode (xcodegen generates the project from `project.yml`). A proper bundle is required for CoreBluetooth entitlements, `Info.plist` embedding, and `SMAppService` login item support.

## Architecture

```
LinakControl/
  Sources/
    App/                    # AppDelegate, SwiftUI entry point
    LinakControlKit/
      BLE/                  # CoreBluetooth, DPG1C protocol, handshake
      Config/               # AppConfig (JSON), ConfigStore
      Core/                 # DeskManager (actor), movement, presets, reconnection
      IPC/                  # Unix socket server/client for CLI communication
      UI/                   # SwiftUI views, DeskViewModel, MenuBarController
      Util/                 # HeightConverter, FileLog, TimedStreamBuffer, Clock
    deskctl/                # CLI tool (swift-argument-parser)
  Tests/
    LinakControlTests/      # 385 tests across BLE, Core, UI, IPC, Integration
```

**Key design decisions:**
- `DeskManager` is a Swift actor (single source of truth for desk state)
- BLE layer uses protocol abstraction (`BLEControllerProtocol`) for testability
- Height values from BLE are raw (relative to desk zero); display adds user-configured offset
- DPG1C session requires USER_ID read before queries respond
- Nothing is written to the desk while connected and idle: periodic writes to reference input (0x0031) lock out the desk's own control panel

## Configuration

Settings live at `~/Library/Application Support/LinakControl/config.json`. The full key reference, override mechanism (UI / `deskctl config` / hand edit), and annotated samples are in [docs/configuration.md](docs/configuration.md).

## Debug Logging

Debug builds write to `~/Library/Logs/LinakControl/debug.log` (truncated per launch, 1 MB cap). Release builds write no log file — see [docs/troubleshooting.md#where-to-look-for-logs](docs/troubleshooting.md#where-to-look-for-logs).

## Protocol Notes

The LINAK DPG1C desk communicates via four BLE services:

| Service | UUID (short) | Purpose |
|---------|-------------|---------|
| Control | 0x0001 | Movement commands (up/down/stop/wake) |
| DPG | 0x0010 | Configuration queries (capabilities, presets, user ID) |
| Reference Output | 0x0020 | Height notifications, output mask |
| Reference Input | 0x0030 | Move-to targets |

DPG queries use 3-byte read format `[0x7F, cmd, 0x00]` and require USER_ID session activation before responding. Height values are uint16 in 0.1mm units (little-endian). See `DeskCharacteristics.swift` and `DeskProtocol.swift` for full protocol details.

## Acknowledgements

The BLE protocol implementation is based on reverse-engineering work from these open-source projects:

- [linak-controller](https://github.com/rhyst/linak-controller) -- Python desk controller by rhyst. Key reference for DPG1C handshake, USER_ID activation, and base offset parsing.
- [LinakDeskApp](https://github.com/anetczuk/LinakDeskApp) -- Linux desktop app by anetczuk. Reference for BLE service UUIDs, characteristics, and command bytes.
- [linak-desk-spec](https://github.com/anson-vandoren/linak-desk-spec) -- Protocol specification by anson-vandoren. Detailed reverse-engineered documentation of the DPG1C wire format.
- [hass-linak-dpg](https://github.com/Laeborg/hass-linak-dpg) -- Home Assistant integration by Laeborg.
- [linak_desk](https://github.com/mdrwiega/linak_desk) -- Home Assistant component by mdrwiega.

See [docs/spec.md](docs/spec.md) for the full project specification.

<!-- doc-product:documentation:start -->
## Documentation

- [Installation](docs/installation.md)
- [Configuration](docs/configuration.md)
- [Usage](docs/usage.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Linak DPG1C macOS Desk Control -- Specification](docs/spec.md)
<!-- doc-product:documentation:end -->

## License

Released under the [MIT License](LICENSE) © 2026 Marcus Breiden.

Third-party dependencies and protocol attributions are listed in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
