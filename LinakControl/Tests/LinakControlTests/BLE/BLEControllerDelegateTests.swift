// BLEControllerDelegateTests.swift
// LinakControlTests - The real controller against CoreBluetooth. MockBLEController
// always delivers, so nothing in the suite could see the delegate stop firing.

import XCTest
import CoreBluetooth
@testable import LinakControlKit

/// Returns the first element of `stream`, or nil if none arrives in time.
private func firstState(from stream: AsyncStream<BLEState>, within seconds: Double) async -> BLEState? {
    await withTaskGroup(of: BLEState?.self) { group in
        group.addTask { for await state in stream { return state }; return nil }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

final class BLEControllerDelegateTests: XCTestCase {

    /// CoreBluetooth answers a freshly built central manager with one state
    /// callback whatever Bluetooth is doing, so this holds on any machine. If it
    /// does not arrive, nothing downstream can ever connect.
    func testRealControllerReportsAStateAfterInit() async throws {
        let controller = BLEController()
        let state = await firstState(from: controller.stateStream, within: 5)
        XCTAssertNotNil(state, "CBCentralManagerDelegate never fired: nothing downstream can connect")
    }
}

// MARK: - The app's wiring

extension BLEControllerDelegateTests {

    /// The app path: real controller, handed to DeskManager, waited on. Whatever
    /// CoreBluetooth reports has to reach the actor, or the wait never ends.
    func testTheWaitSeesWhatTheRealControllerReports() async throws {
        let controller = BLEController()
        let manager = DeskManager(bleController: controller, configStore: makeTempConfigStore())

        let wait = Task { try? await manager.waitUntilPoweredOn() }
        defer { wait.cancel() }

        await waitFor(timeout: 5) { await manager.bleState != nil }
        let seen = await manager.bleState
        XCTAssertNotNil(seen, "the observer never received a state from the real controller")
    }
}
