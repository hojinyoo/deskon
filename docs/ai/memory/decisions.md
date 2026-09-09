# Decisions -- linak-control
<!-- Architecture choices and rationale. Updated: 2026-04-02 -->

## 2026-04-01 -- Xcode project via xcodegen for .app bundle

**Decision**: Use `project.yml` + `xcodegen` to generate `Deskon.xcodeproj` alongside the Swift Package.

**Rationale**: SPM `executableTarget` produces raw binaries. A proper `.app` bundle is required for:
- `LSUIElement` / `NSBluetoothAlwaysUsageDescription` via embedded Info.plist
- CoreBluetooth entitlements
- `SMAppService` login item (requires bundle identifier)

**Approach**:
- `project.yml` at repo root, scheme `DeskonApp`, ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`)
- `LinakControl/Package.swift` exposes `LinakControlKit` as an explicit library product so Xcode can link against it
- xcodegen 2.x bug: omits `package` back-reference in `XCSwiftPackageProductDependency`; fixed via `postGenCommand` sed patch in `project.yml`
- `make xcode-build` / `make xcode-build-debug` for app bundle; `make build` remains for CLI (`deskctl`) via SPM
- deskctl stays as a raw SPM binary -- no bundle needed

## 2026-04-02 -- DeskManager as Swift actor (single source of truth)

**Decision**: `DeskManager` is a Swift actor owning all desk state. State changes are broadcast via `AsyncStream<DeskState>`.

**Rationale**: BLE callbacks arrive on a serial dispatch queue, movement/preset loops run as async Tasks, and the UI observes from MainActor. An actor serialises all mutations and prevents data races without manual locking.

## 2026-04-02 -- Raw heights in state, offset at display layer only

**Decision**: `DeskState.heightMM` and preset heights store raw BLE values (relative to desk zero). The desk offset is applied only in `DeskViewModel.apply()` for display.

**Rationale**: The BLE protocol uses raw values for move-to commands. Mixing absolute and raw values in state caused bugs (preset commands sent wrong targets). Keeping state raw and converting at the UI boundary is safer.

## 2026-04-02 -- DeskLimits as single source of truth for ranges

**Decision**: All height/command ranges defined in `DeskLimits` enum in `DeskProtocol.swift`. No duplicate constants anywhere.

**Rationale**: Duplicate range constants in DeskManager+Presets, DeskManager+Movement, and DeskProtocol had divergent values, causing silent failures. Centralised enum prevents drift.

## 2026-04-02 -- TimedStreamBuffer actor for DPG notification consumption

**Decision**: Replace `@unchecked Sendable` class with actor-isolated `TimedStreamBuffer`. Shared between HandshakeService and PresetSave.

**Rationale**: The `AsyncStream.AsyncIterator` is not Sendable. The old class used `@unchecked Sendable` to suppress compiler warnings but had a latent data race. An actor makes iterator access safe by construction.

## 2026-04-02 -- Atomic continuation extraction (take* helpers)

**Decision**: All `CheckedContinuation` access in `BLEController` goes through `take*()` helpers that atomically nil-and-return.

**Rationale**: Disconnect and characteristic-discovery callbacks race on `bleQueue`. Direct access + nil-set was not atomic, risking double-resume crashes. The take pattern makes double-resume structurally impossible.
