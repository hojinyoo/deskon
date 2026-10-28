# Tools -- linak-control
<!-- CI, build pipeline, API clients, local dev setup. Updated: 2026-10-28 -->

## Build Commands

| Command | What |
|---------|------|
| `make xcode-build-debug` | Build .app bundle (debug) via xcodegen + xcodebuild |
| `make xcode-build` | Build .app bundle (release) |
| `make build` | Build CLI binary via SPM |
| `make test` | Run 385 tests via SPM |
| `./run.sh` | Kill running instance, build debug, launch app |
| `./run.sh --clean` | Same but wipes config (first-run pairing mode) |

## Release

- `.github/workflows/release.yml` runs `scripts/release.sh` on `v*` tags: Developer ID sign (hardened runtime), notarize, staple `build/Deskon.app`.
- `xcodebuild build` injects `com.apple.security.get-task-allow` even in Release. Notarization rejects it, so the script re-signs without `--preserve-metadata=entitlements`.
- `gh` resolves this checkout to the `upstream` remote (MMoMM-org/linak-control). Pass `-R hojinyoo/deskon` for PRs, releases and secrets.

## Debug Logging

- Debug builds write to `~/Library/Logs/LinakControl/debug.log`
- `FileLog.debug("msg", category: "ble")` -- categories: ble, core, handshake, ui, app
- Log reset on each app launch, capped at 1 MB
- `tail -f ~/Library/Logs/LinakControl/debug.log` for real-time monitoring

## Config Location

- `~/Library/Application Support/LinakControl/config.json`
- Permissions: directory 0700, file 0600
- `./run.sh --clean` deletes this directory

## Xcode Project

- Generated from `project.yml` via xcodegen (`brew install xcodegen`)
- Required for .app bundle (BLE entitlements, Info.plist, login item)
- SPM Package.swift at `LinakControl/Package.swift` for library + tests
- Sole external dependency: `swift-argument-parser` (Apple, for CLI)

## Sandbox (Claude Code)

- `excludedCommands: ["swift", "xcodebuild", "xcrun", "xcodegen", "codesign"]`
- Needs write access to: DerivedData, org.swift.swiftpm caches
- SPM lock files in `.build/` can block tests if background agents leave orphan processes
