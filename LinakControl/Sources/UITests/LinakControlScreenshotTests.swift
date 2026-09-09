// LinakControlScreenshotTests.swift
// LinakControlUITests — captures documentation screenshots via XCUITest.
//
// Assumes ~/Library/Application Support/LinakControl/config.json has a valid
// paired_desk_uuid and that the desk is powered on and reachable. No demo BLE
// mocking — see commit history for the rationale.

import AppKit
import XCTest

final class LinakControlScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Target the installed app at LINAK_APP_PATH (default /Applications/LinakControl.app)
        // rather than the freshly built Debug binary. The installed app has stable
        // TCC permissions for Bluetooth; a fresh ad-hoc-signed Debug build does not.
        let envPath = ProcessInfo.processInfo.environment["LINAK_APP_PATH"]
        let appPath = envPath?.isEmpty == false ? envPath! : "/Applications/LinakControl.app"
        let appURL = URL(fileURLWithPath: appPath)
        app = XCUIApplication(url: appURL)

        // activate() reuses an already-running instance if present (preserving its
        // BLE connection state) and only cold-launches as a fallback.
        app.activate()

        // Settle: give the menu bar time to draw and any cold-connect time to run.
        Thread.sleep(forTimeInterval: 5)

        dumpStatusItems()
    }

    override func tearDownWithError() throws {
        // Intentionally do not terminate — preserve the user's running app
        // instance (and its BLE connection) between tests and across runs.
    }

    func test_screenshot_menubar() throws {
        let zone1 = resolveZone1()
        let zone2 = resolveZone2()
        XCTAssertTrue(zone1.waitForExistence(timeout: 10), "zone1 not findable")
        XCTAssertTrue(zone2.waitForExistence(timeout: 10), "zone2 not findable")

        // Make sure nothing from a prior test is still on screen.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        let zone1Frame = zone1.frame
        let zone2Frame = zone2.frame

        let crop = CGRect(
            x: max(0, zone1Frame.minX - 10),
            y: 0,
            width: (zone2Frame.maxX - zone1Frame.minX) + 20,
            height: max(zone1Frame.maxY, 30)
        )
        attach(name: "menubar",
               image: cropFullScreen(to: crop) ?? XCUIScreen.main.screenshot().image)
    }

    func test_screenshot_menubar_popover() throws {
        let zone1 = resolveZone1()
        XCTAssertTrue(zone1.waitForExistence(timeout: 10), "zone1 status item not findable")
        let zone1Frame = zone1.frame

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        zone1.click()
        Thread.sleep(forTimeInterval: 0.6)

        let crop = CGRect(
            x: zone1Frame.midX - 150,
            y: zone1Frame.minY,
            width: 340,
            height: 380
        )
        attach(name: "menubar-popover",
               image: cropFullScreen(to: crop) ?? XCUIScreen.main.screenshot().image)

        app.typeKey(.escape, modifierFlags: [])
    }

    func test_screenshot_preset_menu() throws {
        let zone2 = resolveZone2()
        XCTAssertTrue(
            zone2.waitForExistence(timeout: 10),
            "zone2 status item not findable — is zone 2 visible in the menu bar?"
        )
        let zone2Frame = zone2.frame

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        zone2.click()
        Thread.sleep(forTimeInterval: 0.4)

        // app.menuItems unions NSApp menu-bar items (huge bounds), so we crop
        // from zone2 directly. The dropdown hangs straight below the icon.
        let crop = CGRect(
            x: max(0, zone2Frame.midX - 80),
            y: zone2Frame.maxY,
            width: 160,
            height: 110
        )
        attach(name: "menubar-preset-menu",
               image: cropFullScreen(to: crop) ?? XCUIScreen.main.screenshot().image)

        app.typeKey(.escape, modifierFlags: [])
    }

    func test_screenshot_settings() throws {
        let zone1 = resolveZone1()
        XCTAssertTrue(zone1.waitForExistence(timeout: 10), "zone1 status item not findable")
        let zone1Frame = zone1.frame

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        zone1.click()
        Thread.sleep(forTimeInterval: 0.6)

        let gear = app.buttons["linak.popover.settings.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "gear button not findable")
        gear.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Slightly narrower than the popover test to keep adjacent menu-bar
        // icons (Dropbox, language flag) and the desktop wallpaper sliver out
        // of the upper-right corner.
        let crop = CGRect(
            x: zone1Frame.midX - 150,
            y: zone1Frame.minY,
            width: 300,
            height: 380
        )
        attach(name: "settings",
               image: cropFullScreen(to: crop) ?? XCUIScreen.main.screenshot().image)

        dismissPopoverFromSettings()
    }

    func test_screenshot_settings_scrolled() throws {
        let zone1 = resolveZone1()
        XCTAssertTrue(zone1.waitForExistence(timeout: 10), "zone1 status item not findable")
        let zone1Frame = zone1.frame

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)

        zone1.click()
        Thread.sleep(forTimeInterval: 0.6)

        let gear = app.buttons["linak.popover.settings.gear"]
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "gear button not findable")
        gear.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Scroll the settings content to expose the Presets / login / hotkeys
        // section. Try the scroll view first, then fall back to swiping an
        // element inside the popover.
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.scroll(byDeltaX: 0, deltaY: -300)
        } else {
            app.windows.firstMatch.swipeUp()
        }
        Thread.sleep(forTimeInterval: 0.4)

        let crop = CGRect(
            x: zone1Frame.midX - 150,
            y: zone1Frame.minY,
            width: 300,
            height: 380
        )
        attach(name: "settings-scrolled",
               image: cropFullScreen(to: crop) ?? XCUIScreen.main.screenshot().image)

        dismissPopoverFromSettings()
    }

    /// Settings view persists `viewModel.showSettings = true` even after the
    /// popover is dismissed, which would make the next zone1 click open the
    /// popover directly on the settings screen. Press Back first, then escape.
    private func dismissPopoverFromSettings() {
        let back = app.buttons["linak.settings.back"]
        if back.exists {
            back.click()
            Thread.sleep(forTimeInterval: 0.2)
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Screenshot cropping

    /// Capture the whole screen and crop to `rect` (in points/screen-coordinates,
    /// top-left origin). Returns nil if anything along the pipeline fails so the
    /// caller can fall back to an uncropped attachment.
    private func cropFullScreen(to rect: CGRect) -> NSImage? {
        let full = XCUIScreen.main.screenshot().image
        guard let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        // The CGImage may be at native pixel scale while rect is in points.
        let scaleX = CGFloat(cg.width) / full.size.width
        let scaleY = CGFloat(cg.height) / full.size.height
        let bounded = rect.intersection(CGRect(origin: .zero, size: full.size))
        guard !bounded.isEmpty else { return nil }
        let pixelRect = CGRect(
            x: bounded.minX * scaleX,
            y: bounded.minY * scaleY,
            width: bounded.width * scaleX,
            height: bounded.height * scaleY
        )
        guard let cropped = cg.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: bounded.size)
    }

    // MARK: - Element lookup

    /// Prefer the a11y identifier; if absent (e.g. older installed build), fall
    /// back to scanning all visible status items for one whose label/value looks
    /// like our icon (no text, image-only).
    private func resolveZone1() -> XCUIElement {
        let byIdentifier = app.statusItems["linak.menubar.zone1.icon"]
        if byIdentifier.exists { return byIdentifier }
        // Fallback: zone1 is square-length with no text — pick the first
        // status item with empty title that we can click.
        for i in 0..<app.statusItems.count {
            let item = app.statusItems.element(boundBy: i)
            if item.label.isEmpty && (item.value as? String ?? "").isEmpty {
                return item
            }
        }
        return byIdentifier
    }

    /// Prefer the a11y identifier; if absent, fall back to scanning for a
    /// status item whose title looks like our zone 2 text. Zone 2 only exists
    /// while the desk is connected, so that title always carries a height.
    private func resolveZone2() -> XCUIElement {
        let byIdentifier = app.statusItems["linak.menubar.zone2.text"]
        if byIdentifier.exists { return byIdentifier }
        for i in 0..<app.statusItems.count {
            let item = app.statusItems.element(boundBy: i)
            let title = (item.value as? String) ?? item.label
            if title.isEmpty { continue }
            if title.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) {
                return item
            }
        }
        return byIdentifier
    }

    // MARK: - Diagnostics

    /// Print the a11y identifier, label, and value of every visible status
    /// item. Run output shows up in the xcresult log — invaluable when the
    /// expected identifier mysteriously doesn't resolve.
    private func dumpStatusItems() {
        let count = app.statusItems.count
        print("=== status items visible to XCUITest (\(count)) ===")
        for i in 0..<count {
            let item = app.statusItems.element(boundBy: i)
            let id = item.identifier
            let label = item.label
            let value = (item.value as? String) ?? "<nil>"
            print("  [\(i)] id='\(id)' label='\(label)' value='\(value)'")
        }
        print("===============================================")
    }

    private func attach(name: String, image: NSImage) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
