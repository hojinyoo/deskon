// ConfigModels.swift
// LinakControlKit

import Foundation

// MARK: - Config Models

/// Persisted application settings. Stored as config.json in
/// ~/Library/Application Support/LinakControl/.
public struct AppConfig: Codable, Equatable {

    // MARK: Pairing

    /// CoreBluetooth peripheral identifier for the paired desk.
    public var pairedDeskUUID: String?

    /// Desk name learned from the peripheral after connecting.
    public var pairedDeskName: String?

    /// Desk name chosen by the user. Wins over `pairedDeskName` wherever the desk is named.
    public var userDeskName: String?

    /// Name to show for the paired desk, user-set first.
    public var resolvedDeskName: String? {
        userDeskName ?? pairedDeskName
    }

    /// Applies a user-set desk name. Empty or whitespace-only input clears it so the
    /// learned name comes back instead of a blank label.
    public mutating func setUserDeskName(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        userDeskName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Travel above the desk's lowest position, in raw mm, used to reject a `goto` target
    /// the desk cannot reach. The desk does not report its stroke: GET_CAPABILITIES answers
    /// a flags byte and GET_BASE_OFFSET answers the base height, so this is a setting.
    /// The default is the raw height auto-up already drives to, so `goto` cannot reach past
    /// what the up button reaches. Lower it to your desk's real stroke to tighten the check.
    public var maxStrokeMM: Int = 650

    // MARK: Display

    /// Height display unit. Defaults to .cm.
    public var unit: HeightUnit

    /// Desk base offset in mm. Raw heights from the desk are relative to its internal
    /// zero point; adding this offset gives the absolute height from floor.
    public var deskOffsetMM: Int

    // MARK: Movement

    /// Up button behaviour. Defaults to .manual (hold to move).
    public var autoRunUp: RunMode

    /// Down button behaviour. Defaults to .manual (hold to move).
    public var autoRunDown: RunMode

    // MARK: System

    /// Register the app as a login item. Defaults to false.
    public var startAtLogin: Bool

    /// Enable global keyboard shortcuts. Defaults to false.
    public var hotkeysEnabled: Bool

    /// Show the Zone 2 status item (preset dropdown in menu bar). Defaults to true.
    public var showZone2: Bool

    // MARK: Preset Labels

    /// Optional labels for preset slots 1–4, e.g. ["Sitting", "Standing", nil, nil].
    public var presetLabels: [String?]

    // MARK: Init

    public init(
        pairedDeskUUID: String? = nil,
        pairedDeskName: String? = nil,
        userDeskName: String? = nil,
        maxStrokeMM: Int = 650,
        unit: HeightUnit = .cm,
        deskOffsetMM: Int = 0,
        autoRunUp: RunMode = .manual,
        autoRunDown: RunMode = .manual,
        startAtLogin: Bool = false,
        hotkeysEnabled: Bool = false,
        showZone2: Bool = true,
        presetLabels: [String?] = [nil, nil, nil, nil]
    ) {
        self.pairedDeskUUID = pairedDeskUUID
        self.pairedDeskName = pairedDeskName
        self.userDeskName = userDeskName
        self.maxStrokeMM = maxStrokeMM
        self.unit = unit
        self.deskOffsetMM = deskOffsetMM
        self.autoRunUp = autoRunUp
        self.autoRunDown = autoRunDown
        self.startAtLogin = startAtLogin
        self.hotkeysEnabled = hotkeysEnabled
        self.showZone2 = showZone2
        self.presetLabels = presetLabels
    }

    // MARK: CodingKeys — snake_case JSON per SDD schema

    enum CodingKeys: String, CodingKey {
        case pairedDeskUUID   = "paired_desk_uuid"
        case pairedDeskName   = "paired_desk_name"
        case userDeskName     = "user_desk_name"
        case maxStrokeMM      = "max_stroke_mm"
        case unit
        case deskOffsetMM     = "desk_offset_mm"
        case autoRunUp        = "auto_run_up"
        case autoRunDown      = "auto_run_down"
        case startAtLogin     = "start_at_login"
        case hotkeysEnabled   = "hotkeys_enabled"
        case showZone2        = "show_zone_2"
        case presetLabels     = "preset_labels"

        // Legacy keys for backward-compatible reading of old config files.
        case preset1Label     = "preset_1_label"
        case preset2Label     = "preset_2_label"
        case preset3Label     = "preset_3_label"
        case preset4Label     = "preset_4_label"
    }

    // MARK: Decodable — tolerant of missing keys

    /// Custom decoder that provides defaults for any missing keys.
    /// Reads the new `preset_labels` array when present, otherwise falls back
    /// to the legacy `preset_1_label`…`preset_4_label` individual keys for
    /// backward compatibility with old config files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairedDeskUUID = try c.decodeIfPresent(String.self, forKey: .pairedDeskUUID)
        pairedDeskName = try c.decodeIfPresent(String.self, forKey: .pairedDeskName)
        userDeskName   = try c.decodeIfPresent(String.self, forKey: .userDeskName)
        // Clamped: this key is hand-edited, and `executeMoveToHeight` builds `0...stroke`
        // from it, which traps outright on a negative bound. Above the encoding bound the
        // range would also refuse targets the error message says it accepts.
        maxStrokeMM    = min(
            DeskLimits.safeCommandRange.upperBound,
            max(0, try c.decodeIfPresent(Int.self, forKey: .maxStrokeMM) ?? 650)
        )
        unit           = try c.decodeIfPresent(HeightUnit.self, forKey: .unit) ?? .cm
        deskOffsetMM   = try c.decodeIfPresent(Int.self, forKey: .deskOffsetMM) ?? 0
        autoRunUp      = try c.decodeIfPresent(RunMode.self, forKey: .autoRunUp) ?? .manual
        autoRunDown    = try c.decodeIfPresent(RunMode.self, forKey: .autoRunDown) ?? .manual
        startAtLogin   = try c.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        hotkeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeysEnabled) ?? false
        showZone2      = try c.decodeIfPresent(Bool.self, forKey: .showZone2) ?? true

        if let labels = try c.decodeIfPresent([String?].self, forKey: .presetLabels) {
            presetLabels = labels
        } else {
            presetLabels = [
                try c.decodeIfPresent(String.self, forKey: .preset1Label),
                try c.decodeIfPresent(String.self, forKey: .preset2Label),
                try c.decodeIfPresent(String.self, forKey: .preset3Label),
                try c.decodeIfPresent(String.self, forKey: .preset4Label),
            ]
        }
    }

    // MARK: Encodable — write only the new format

    /// Encodes using the new `preset_labels` array key only. Legacy individual
    /// keys are not written — they are read-only for migration.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(pairedDeskUUID, forKey: .pairedDeskUUID)
        try c.encodeIfPresent(pairedDeskName, forKey: .pairedDeskName)
        try c.encodeIfPresent(userDeskName, forKey: .userDeskName)
        try c.encode(maxStrokeMM, forKey: .maxStrokeMM)
        try c.encode(unit, forKey: .unit)
        try c.encode(deskOffsetMM, forKey: .deskOffsetMM)
        try c.encode(autoRunUp, forKey: .autoRunUp)
        try c.encode(autoRunDown, forKey: .autoRunDown)
        try c.encode(startAtLogin, forKey: .startAtLogin)
        try c.encode(hotkeysEnabled, forKey: .hotkeysEnabled)
        try c.encode(showZone2, forKey: .showZone2)
        try c.encode(presetLabels, forKey: .presetLabels)
    }

    // MARK: Defaults

    /// Factory default — matches SDD initial values.
    public static let `default` = AppConfig()
}

// MARK: - HeightUnit

/// Height display unit.
public enum HeightUnit: String, Codable {
    case cm
    case inch
}

// MARK: - RunMode

/// Movement button behaviour.
public enum RunMode: String, Codable {
    /// Hold the button to keep moving (release to stop).
    case manual

    /// Tap once to start; the desk runs automatically to the target.
    case auto
}
