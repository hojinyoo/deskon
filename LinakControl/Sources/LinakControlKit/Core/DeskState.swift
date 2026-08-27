// DeskState.swift
// LinakControl

// MARK: - ConnectionState

public enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
}

// MARK: - MoveDirection

public enum MoveDirection {
    case up
    case down
}

// MARK: - PresetPosition

public struct PresetPosition {
    public let index: Int
    public var heightMM: Int?
    public var label: String?

    public init(index: Int, heightMM: Int? = nil, label: String? = nil) {
        self.index = index
        self.heightMM = heightMM
        self.label = label
    }
}

// MARK: - DeskState

public struct DeskState {
    public var connectionState: ConnectionState
    public var deskName: String?
    public var heightMM: Int?
    public var speedMMS: Int?
    public var isMoving: Bool
    public var moveDirection: MoveDirection?
    public var targetPreset: Int?
    public var presets: [PresetPosition]
    public var activePreset: Int?

    /// Set when a movement was commanded but the desk stopped responding —
    /// either the timing watchdog saw no height change, or the desk pushed a
    /// fault on its status characteristic (E16/E26). Cleared optimistically on
    /// each new move attempt.
    public var needsReference: Bool

    /// Raw fault code from the desk status characteristic (99fa0003) when
    /// `needsReference` was raised by a decoded fault, else nil (e.g. a
    /// timing-only stall carries no code). Observed: 0x1e→E16, 0x17→E26.
    public var faultCode: UInt8?

    /// Desk base offset in mm. Added to raw heights for display.
    public var deskOffsetMM: Int

    public init() {
        connectionState = .disconnected
        deskName = nil
        heightMM = nil
        speedMMS = nil
        isMoving = false
        moveDirection = nil
        targetPreset = nil
        presets = (1...4).map { PresetPosition(index: $0) }
        activePreset = nil
        needsReference = false
        faultCode = nil
        deskOffsetMM = 0
    }
}

// MARK: - Active Preset Detection

private let presetMatchToleranceMM = 5

/// Returns the index (1–4) of the preset whose height is within 5mm of `heightMM`,
/// or nil if moving or no preset matches.
/// When multiple presets match, the one with the lowest index is returned.
public func activePreset(height heightMM: Int, presets: [PresetPosition], isMoving: Bool) -> Int? {
    guard !isMoving else { return nil }
    return presets
        .filter { preset in
            guard let presetHeight = preset.heightMM else { return false }
            return abs(presetHeight - heightMM) <= presetMatchToleranceMM
        }
        .min(by: { $0.index < $1.index })
        .map(\.index)
}

/// Picks between the sit and stand presets (1 and 2) for a toggle: the desk moves to
/// whichever it is further from, so repeated toggles alternate. A tie goes to standing,
/// which is the harmless direction when the two are close together.
public func toggleTarget(height heightMM: Int, sitMM: Int, standMM: Int) -> Int {
    abs(heightMM - sitMM) <= abs(heightMM - standMM) ? 2 : 1
}
