// MenuBarControllerTests.swift
// LinakControlTests — Menu bar zone state per connection state.
//
// setup() is never called: it would create real NSStatusItems in the test process.

import AppKit
import XCTest
@testable import LinakControlKit

@MainActor
private func makeController() -> (DeskViewModel, MenuBarController) {
    let store = makeTempConfigStore(tag: "MenuBarController")
    let manager = DeskManager(bleController: MockBLEController(), configStore: store)
    let viewModel = DeskViewModel(deskManager: manager, configStore: store)
    return (viewModel, MenuBarController(viewModel: viewModel))
}

@MainActor
final class MenuBarControllerZoneStateTests: XCTestCase {

    func testZone2HiddenWhileNotConnected() {
        let (viewModel, controller) = makeController()
        for state: ConnectionState in [.disconnected, .scanning, .connecting] {
            viewModel.connectionState = state
            XCTAssertFalse(controller.zone2Visible, "zone 2 must be hidden while \(state)")
        }
    }

    func testZone2VisibleWhenConnected() {
        let (viewModel, controller) = makeController()
        viewModel.connectionState = .connected
        XCTAssertTrue(controller.zone2Visible)
    }

    func testZone2StaysHiddenWhenConnectedButDisabledInConfig() {
        let (viewModel, controller) = makeController()
        viewModel.connectionState = .connected
        viewModel.showZone2 = false
        XCTAssertFalse(controller.zone2Visible)
    }

    func testIconSymbolDiffersWhenNotConnected() {
        let (_, controller) = makeController()
        let connected = controller.zone1SymbolName(for: .connected)
        for state: ConnectionState in [.disconnected, .scanning, .connecting] {
            XCTAssertNotEqual(controller.zone1SymbolName(for: state), connected,
                              "icon must differ from connected while \(state)")
        }
    }

    /// An unresolvable symbol name would leave the status item blank, not fail loudly.
    func testIconSymbolsResolveOnThisDeploymentTarget() {
        let (_, controller) = makeController()
        for state: ConnectionState in [.connected, .disconnected, .scanning, .connecting] {
            let name = controller.zone1SymbolName(for: state)
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil),
                            "\(name) does not resolve")
        }
    }
}
