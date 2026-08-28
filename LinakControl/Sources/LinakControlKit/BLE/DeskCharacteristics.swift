// DeskCharacteristics.swift
// LinakControlKit — BLE UUID constants and command byte sequences for the LINAK DPG1C protocol.

import CoreBluetooth

// MARK: - UUIDs

/// All BLE service and characteristic UUIDs for the LINAK DPG1C desk.
///
/// UUIDs share the base pattern: 99fa****-338a-1024-8a49-009c0215f78a
public enum DeskUUID {

    // MARK: Control Service (0x0001)

    /// Control service — contains the command and status characteristics.
    public static let controlService = CBUUID(string: "99fa0001-338a-1024-8a49-009c0215f78a")

    /// Command characteristic (Write) — accepts movement and control commands.
    public static let command = CBUUID(string: "99fa0002-338a-1024-8a49-009c0215f78a")

    /// Status characteristic (Read/Notify) — reports desk state.
    public static let status = CBUUID(string: "99fa0003-338a-1024-8a49-009c0215f78a")

    // MARK: DPG Service (0x0010)

    /// DPG service — exposes device configuration and preset data.
    public static let dpgService = CBUUID(string: "99fa0010-338a-1024-8a49-009c0215f78a")

    /// DPG characteristic (Read/Write/Notify) — query and configure desk parameters.
    public static let dpg = CBUUID(string: "99fa0011-338a-1024-8a49-009c0215f78a")

    // MARK: Reference Output Service (0x0020)

    /// Reference Output service — exposes current height readings.
    public static let referenceOutputService = CBUUID(string: "99fa0020-338a-1024-8a49-009c0215f78a")

    /// Height characteristic (Read/Notify) — current desk height in 0.1 mm units (LE uint16).
    public static let height = CBUUID(string: "99fa0021-338a-1024-8a49-009c0215f78a")

    /// Output Mask characteristic (Read) — bitmask of active outputs.
    public static let outputMask = CBUUID(string: "99fa0029-338a-1024-8a49-009c0215f78a")

    // MARK: Reference Input Service (0x0030)

    /// Reference Input service: accepts target position writes.
    public static let referenceInputService = CBUUID(string: "99fa0030-338a-1024-8a49-009c0215f78a")

    /// Target characteristic (Write) for the reference input move-to target.
    public static let targetHeartbeat = CBUUID(string: "99fa0031-338a-1024-8a49-009c0215f78a")
}

// MARK: - Commands

/// BLE command byte payloads for the LINAK DPG1C protocol.
///
/// Movement commands (``moveUp``, ``moveDown``) must be repeated approximately every 100 ms.
/// ``stop`` should be sent twice.  ``wakeUp`` revives a sleeping desk before issuing other commands.
public enum DeskCommand {

    // MARK: Control characteristic commands (written to DeskUUID.command / 0x0002)

    /// Move desk upward — repeat every ~100 ms while movement is desired.
    public static let moveUp = Data([0x47, 0x00])

    /// Move desk downward — repeat every ~100 ms while movement is desired.
    public static let moveDown = Data([0x46, 0x00])

    /// Stop all movement — send twice for reliable halt.
    public static let stop = Data([0xFF, 0x00])

    /// Wake a sleeping desk before sending other commands.
    public static let wakeUp = Data([0xFE, 0x00])

    /// Preflight — enable the Reference Input service before sending move-to commands.
    public static let preflight = Data([0x00, 0x00])

    // MARK: Target characteristic commands (written to DeskUUID.targetHeartbeat / 0x0031)

    /// Move to an absolute height expressed in 0.1 mm units (little-endian uint16).
    ///
    /// - Parameter tenthsOfMm: Target height in 0.1 mm units (e.g., 6500 = 650.0 mm).
    public static func moveTo(tenthsOfMm: UInt16) -> Data {
        Data([UInt8(tenthsOfMm & 0xFF), UInt8(tenthsOfMm >> 8)])
    }

    // MARK: DPG characteristic commands (written to DeskUUID.dpg / 0x0011)
    //
    // DPG read format:  [0x7F, cmd, 0x00]       — third byte 0x00 signals "read"
    // DPG write format: [0x7F, cmd, 0x80, ...]   — third byte 0x80 signals "write"

    /// Query general desk capabilities.
    public static let getCapabilities = Data([0x7F, 0x80, 0x00])

    /// Query the active user ID stored in the desk (DPG cmd 134 / 0x86).
    /// The USER_ID must be read and written back with byte 0 = 0x01 to
    /// activate the motor controller for movement commands.
    public static let getUserID = Data([0x7F, 0x86, 0x00])

    /// Query the desk's base height offset (DPG cmd 129 / 0x81).
    public static let getBaseOffset = Data([0x7F, 0x81, 0x00])

    /// Query the desk's programmed height offset (DPG cmd 136 / 0x88).
    public static let getDeskOffset = Data([0x7F, 0x88, 0x00])

    /// Write the user ID to activate the DPG session (DPG cmd 134 / 0x86).
    ///
    /// The desk requires a USER_ID write before responding to movement commands.
    /// The first byte of the user ID payload must be `0x01` for DPG1C desks.
    /// - Parameter userData: The user ID bytes read from GET_USER_ID (modified if needed).
    public static func setUserID(userData: Data) -> Data {
        var payload = Data([0x7F, 0x86, 0x80])
        payload.append(userData)
        return payload
    }

    // MARK: Preset commands

    /// Read the height stored at a preset slot (1–4).
    ///
    /// - Parameter index: Preset number in the range 1…4.
    /// - Returns: Command bytes to write to ``DeskUUID/dpg``, or `nil` for an out-of-range index.
    public static func readPreset(index: Int) -> Data? {
        guard let slot = presetSlotByte(for: index) else { return nil }
        return Data([0x7F, slot, 0x00])
    }

    /// Save a height to a preset slot (1–4).
    ///
    /// - Parameters:
    ///   - index: Preset number in the range 1…4.
    ///   - tenthsOfMm: Height to store in 0.1 mm units (little-endian uint16).
    /// - Returns: Command bytes to write to ``DeskUUID/dpg``, or `nil` for an out-of-range index.
    public static func savePreset(index: Int, tenthsOfMm: UInt16) -> Data? {
        guard let slot = presetSlotByte(for: index) else { return nil }
        let lo = UInt8(tenthsOfMm & 0xFF)
        let hi = UInt8(tenthsOfMm >> 8)
        return Data([0x7F, slot, 0x80, 0x01, lo, hi])
    }
}

// MARK: - Private helpers

private func presetSlotByte(for index: Int) -> UInt8? {
    switch index {
    case 1: return 0x89
    case 2: return 0x8A
    case 3: return 0x8B
    case 4: return 0x8C
    default: return nil
    }
}
