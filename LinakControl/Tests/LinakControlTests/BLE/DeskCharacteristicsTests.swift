// DeskCharacteristicsTests.swift
// LinakControlTests — Verifies all BLE UUID strings and command byte sequences match the SDD.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

final class DeskCharacteristicsTests: XCTestCase {

    // MARK: - UUID correctness

    func testControlServiceUUID() {
        XCTAssertEqual(DeskUUID.controlService.uuidString.lowercased(),
                       "99fa0001-338a-1024-8a49-009c0215f78a")
    }

    func testCommandUUID() {
        XCTAssertEqual(DeskUUID.command.uuidString.lowercased(),
                       "99fa0002-338a-1024-8a49-009c0215f78a")
    }

    func testStatusUUID() {
        XCTAssertEqual(DeskUUID.status.uuidString.lowercased(),
                       "99fa0003-338a-1024-8a49-009c0215f78a")
    }

    func testDpgServiceUUID() {
        XCTAssertEqual(DeskUUID.dpgService.uuidString.lowercased(),
                       "99fa0010-338a-1024-8a49-009c0215f78a")
    }

    func testDpgUUID() {
        XCTAssertEqual(DeskUUID.dpg.uuidString.lowercased(),
                       "99fa0011-338a-1024-8a49-009c0215f78a")
    }

    func testReferenceOutputServiceUUID() {
        XCTAssertEqual(DeskUUID.referenceOutputService.uuidString.lowercased(),
                       "99fa0020-338a-1024-8a49-009c0215f78a")
    }

    func testHeightUUID() {
        XCTAssertEqual(DeskUUID.height.uuidString.lowercased(),
                       "99fa0021-338a-1024-8a49-009c0215f78a")
    }

    func testOutputMaskUUID() {
        XCTAssertEqual(DeskUUID.outputMask.uuidString.lowercased(),
                       "99fa0029-338a-1024-8a49-009c0215f78a")
    }

    func testReferenceInputServiceUUID() {
        XCTAssertEqual(DeskUUID.referenceInputService.uuidString.lowercased(),
                       "99fa0030-338a-1024-8a49-009c0215f78a")
    }

    func testTargetHeartbeatUUID() {
        XCTAssertEqual(DeskUUID.targetHeartbeat.uuidString.lowercased(),
                       "99fa0031-338a-1024-8a49-009c0215f78a")
    }

    // MARK: - Static command byte sequences

    func testMoveUpBytes() {
        XCTAssertEqual(DeskCommand.moveUp, Data([0x47, 0x00]))
    }

    func testMoveDownBytes() {
        XCTAssertEqual(DeskCommand.moveDown, Data([0x46, 0x00]))
    }

    func testStopBytes() {
        XCTAssertEqual(DeskCommand.stop, Data([0xFF, 0x00]))
    }

    func testWakeUpBytes() {
        XCTAssertEqual(DeskCommand.wakeUp, Data([0xFE, 0x00]))
    }

    func testPreflightBytes() {
        XCTAssertEqual(DeskCommand.preflight, Data([0x00, 0x00]))
    }

    func testGetCapabilitiesBytes() {
        XCTAssertEqual(DeskCommand.getCapabilities, Data([0x7F, 0x80, 0x00]))
    }

    func testGetCapabilitiesExtendedBytes() {
        // getUserID is now 0x86 (was incorrectly labelled getCapabilitiesExtended)
        XCTAssertEqual(DeskCommand.getUserID, Data([0x7F, 0x86, 0x00]))
        XCTAssertEqual(DeskCommand.getBaseOffset, Data([0x7F, 0x81, 0x00]))
    }

    func testGetUserIDBytes() {
        XCTAssertEqual(DeskCommand.getUserID, Data([0x7F, 0x86, 0x00]))
    }

    func testGetDeskOffsetBytes() {
        XCTAssertEqual(DeskCommand.getDeskOffset, Data([0x7F, 0x88, 0x00]))
    }

    // MARK: - setUserID encoding

    func testSetUserIDBytes() {
        let userData = Data([0x01, 0x00])
        let result = DeskCommand.setUserID(userData: userData)
        XCTAssertEqual(result, Data([0x7F, 0x86, 0x80, 0x01, 0x00]))
    }

    // MARK: - moveTo encoding

    func testMoveToEncodesLowByteThenHighByte() {
        // 0x19C4 = 6596; lo = 0xC4, hi = 0x19
        let data = DeskCommand.moveTo(tenthsOfMm: 0x19C4)
        XCTAssertEqual(data, Data([0xC4, 0x19]))
    }

    func testMoveToZero() {
        XCTAssertEqual(DeskCommand.moveTo(tenthsOfMm: 0), Data([0x00, 0x00]))
    }

    func testMoveToMaxUInt16() {
        XCTAssertEqual(DeskCommand.moveTo(tenthsOfMm: 0xFFFF), Data([0xFF, 0xFF]))
    }

    // MARK: - readPreset indices 1–4

    func testReadPreset1() {
        XCTAssertEqual(DeskCommand.readPreset(index: 1), Data([0x7F, 0x89, 0x00]))
    }

    func testReadPreset2() {
        XCTAssertEqual(DeskCommand.readPreset(index: 2), Data([0x7F, 0x8A, 0x00]))
    }

    func testReadPreset3() {
        XCTAssertEqual(DeskCommand.readPreset(index: 3), Data([0x7F, 0x8B, 0x00]))
    }

    func testReadPreset4() {
        XCTAssertEqual(DeskCommand.readPreset(index: 4), Data([0x7F, 0x8C, 0x00]))
    }

    func testReadPresetOutOfRangeReturnsNil() {
        XCTAssertNil(DeskCommand.readPreset(index: 0))
        XCTAssertNil(DeskCommand.readPreset(index: 5))
    }

    // MARK: - savePreset encoding

    func testSavePreset1EncodesHeightLittleEndian() {
        // Height 6500 (0x1964): lo = 0x64, hi = 0x19
        let data = DeskCommand.savePreset(index: 1, tenthsOfMm: 6500)
        XCTAssertEqual(data, Data([0x7F, 0x89, 0x80, 0x01, 0x64, 0x19]))
    }

    func testSavePreset2UsesCorrectSlot() {
        let data = DeskCommand.savePreset(index: 2, tenthsOfMm: 0)
        XCTAssertEqual(data, Data([0x7F, 0x8A, 0x80, 0x01, 0x00, 0x00]))
    }

    func testSavePreset3UsesCorrectSlot() {
        let data = DeskCommand.savePreset(index: 3, tenthsOfMm: 0)
        XCTAssertEqual(data, Data([0x7F, 0x8B, 0x80, 0x01, 0x00, 0x00]))
    }

    func testSavePreset4UsesCorrectSlot() {
        let data = DeskCommand.savePreset(index: 4, tenthsOfMm: 0)
        XCTAssertEqual(data, Data([0x7F, 0x8C, 0x80, 0x01, 0x00, 0x00]))
    }

    func testSavePresetOutOfRangeReturnsNil() {
        XCTAssertNil(DeskCommand.savePreset(index: 0, tenthsOfMm: 6500))
        XCTAssertNil(DeskCommand.savePreset(index: 5, tenthsOfMm: 6500))
    }
}
