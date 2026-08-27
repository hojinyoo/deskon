// BLEControllerTests.swift
// LinakControlTests — Verifies MockBLEController behavior and BLEControllerProtocol contract.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

// MARK: - Helpers

private func makeMockDesk(
    name: String = "LINAK Desk",
    rssi: Int = -60
) -> DiscoveredDesk {
    DiscoveredDesk(peripheralId: UUID(), name: name, rssi: rssi)
}

// MARK: - BLEState cases

final class BLEStateTests: XCTestCase {

    func testAllCasesExist() {
        // Each case must be expressible — verifies the enum hasn't silently dropped a case.
        let cases: [BLEState] = [.unknown, .resetting, .unsupported, .unauthorized, .poweredOff, .poweredOn]
        XCTAssertEqual(cases.count, 6)
    }

    func testStateStreamReceivesEmittedValues() async {
        let mock = MockBLEController()
        var received: [BLEState] = []

        let task = Task {
            for await state in mock.stateStream {
                received.append(state)
                if received.count == 2 { break }
            }
        }

        mock.emitState(.poweredOn)
        mock.emitState(.poweredOff)
        await task.value

        XCTAssertEqual(received, [.poweredOn, .poweredOff])
    }
}

// MARK: - Scan behavior

final class MockBLEControllerScanTests: XCTestCase {

    func testScanYieldsAllMockDesks() async {
        let mock = MockBLEController()
        mock.mockDesks = [
            makeMockDesk(name: "Desk A"),
            makeMockDesk(name: "Desk B"),
        ]

        var discovered: [DiscoveredDesk] = []
        for await desk in mock.scanForPeripherals() {
            discovered.append(desk)
        }

        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(discovered[0].name, "Desk A")
        XCTAssertEqual(discovered[1].name, "Desk B")
    }

    func testScanTerminatesAfterYieldingAllDesks() async {
        let mock = MockBLEController()
        mock.mockDesks = [makeMockDesk()]

        var count = 0
        for await _ in mock.scanForPeripherals() {
            count += 1
        }
        // Stream must finish — test will hang (and timeout) if it doesn't.
        XCTAssertEqual(count, 1)
    }

    func testScanWithNoMockDesksTerminatesImmediately() async {
        let mock = MockBLEController()
        mock.mockDesks = []

        var count = 0
        for await _ in mock.scanForPeripherals() {
            count += 1
        }
        XCTAssertEqual(count, 0)
    }

    func testDiscoveredDeskPreservesRSSI() async {
        let mock = MockBLEController()
        mock.mockDesks = [makeMockDesk(rssi: -45)]

        var desks: [DiscoveredDesk] = []
        for await desk in mock.scanForPeripherals() {
            desks.append(desk)
        }

        XCTAssertEqual(desks.first?.rssi, -45)
    }
}

// MARK: - Connect behavior

final class MockBLEControllerConnectTests: XCTestCase {

    func testConnectSucceedsWhenNotConfiguredToFail() async throws {
        let mock = MockBLEController()
        // Must not throw
        try await mock.connect(peripheralId: UUID())
    }

    func testConnectThrowsWhenShouldFailConnectIsTrue() async {
        let mock = MockBLEController()
        mock.shouldFailConnect = true

        do {
            try await mock.connect(peripheralId: UUID())
            XCTFail("Expected connect to throw BLEError.connectionFailed")
        } catch BLEError.connectionFailed {
            // Expected path
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testConnectRespectsConnectDelay() async throws {
        let mock = MockBLEController()
        mock.connectDelay = .milliseconds(50)

        let start = ContinuousClock().now
        try await mock.connect(peripheralId: UUID())
        let elapsed = ContinuousClock().now - start

        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(50))
    }
}

// MARK: - Write capture

final class MockBLEControllerWriteTests: XCTestCase {

    func testWriteCapturesDataAndCharacteristic() async throws {
        let mock = MockBLEController()
        let data = DeskCommand.wakeUp
        let uuid = DeskUUID.command

        try await mock.write(data: data, to: uuid, type: .withoutResponse)

        XCTAssertEqual(mock.writtenData.count, 1)
        XCTAssertEqual(mock.writtenData[0].data, data)
        XCTAssertEqual(mock.writtenData[0].characteristic, uuid)
    }

    func testMultipleWritesAreAppendedInOrder() async throws {
        let mock = MockBLEController()

        try await mock.write(data: DeskCommand.wakeUp, to: DeskUUID.command, type: .withoutResponse)
        try await mock.write(data: DeskCommand.moveUp, to: DeskUUID.command, type: .withoutResponse)
        try await mock.write(data: DeskCommand.stop, to: DeskUUID.command, type: .withoutResponse)

        XCTAssertEqual(mock.writtenData.count, 3)
        XCTAssertEqual(mock.writtenData[0].data, DeskCommand.wakeUp)
        XCTAssertEqual(mock.writtenData[1].data, DeskCommand.moveUp)
        XCTAssertEqual(mock.writtenData[2].data, DeskCommand.stop)
    }

    func testWriteToTargetCharacteristicCapturesCorrectUUID() async throws {
        let mock = MockBLEController()
        let data = DeskCommand.moveTo(tenthsOfMm: 6500)

        try await mock.write(data: data, to: DeskUUID.targetHeartbeat, type: .withoutResponse)

        XCTAssertEqual(mock.writtenData.first?.characteristic, DeskUUID.targetHeartbeat)
    }
}

// MARK: - Read behavior

final class MockBLEControllerReadTests: XCTestCase {

    func testReadReturnsMockResponse() async throws {
        let mock = MockBLEController()
        let expected = Data([0x7F, 0x80, 0x1C])
        mock.mockReadResponses[DeskUUID.dpg] = expected

        let result = try await mock.read(DeskUUID.dpg)

        XCTAssertEqual(result, expected)
    }

    func testReadThrowsWhenNoMockResponseConfigured() async {
        let mock = MockBLEController()

        do {
            _ = try await mock.read(DeskUUID.status)
            XCTFail("Expected read to throw BLEError.characteristicNotFound")
        } catch BLEError.characteristicNotFound(let uuid) {
            XCTAssertEqual(uuid, DeskUUID.status)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testReadReturnsDifferentResponsesForDifferentCharacteristics() async throws {
        let mock = MockBLEController()
        let statusData = Data([0x01])
        let dpgData = Data([0x7F, 0x80, 0x04])
        mock.mockReadResponses[DeskUUID.status] = statusData
        mock.mockReadResponses[DeskUUID.dpg] = dpgData

        let statusResult = try await mock.read(DeskUUID.status)
        let dpgResult = try await mock.read(DeskUUID.dpg)

        XCTAssertEqual(statusResult, statusData)
        XCTAssertEqual(dpgResult, dpgData)
    }
}

// MARK: - Notification stream behavior

final class MockBLEControllerNotificationTests: XCTestCase {

    func testNotificationsReturnsConfiguredStream() async {
        let mock = MockBLEController()
        let values: [Data] = [Data([0x01]), Data([0x02]), Data([0x03])]

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        mock.mockNotificationStreams[DeskUUID.height] = stream

        for value in values {
            continuation.yield(value)
        }
        continuation.finish()

        var received: [Data] = []
        for await data in mock.notifications(for: DeskUUID.height) {
            received.append(data)
        }

        XCTAssertEqual(received, values)
    }

    func testNotificationsForUnknownCharacteristicTerminatesImmediately() async {
        let mock = MockBLEController()

        var count = 0
        for await _ in mock.notifications(for: DeskUUID.status) {
            count += 1
        }
        XCTAssertEqual(count, 0)
    }
}

// MARK: - DiscoveredDesk value type

final class DiscoveredDeskTests: XCTestCase {

    func testDiscoveredDeskStoresAllProperties() {
        let id = UUID()
        let desk = DiscoveredDesk(peripheralId: id, name: "Standing Desk", rssi: -72)

        XCTAssertEqual(desk.peripheralId, id)
        XCTAssertEqual(desk.name, "Standing Desk")
        XCTAssertEqual(desk.rssi, -72)
    }
}
