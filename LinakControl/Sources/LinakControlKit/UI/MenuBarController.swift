// MenuBarController.swift
// LinakControlKit — Two-zone NSStatusItem controller per ADR-6.

import AppKit
import Combine
import SwiftUI

// MARK: - MenuBarController

/// Owns the two NSStatusItems in the macOS menu bar.
///
/// Zone 1: desk icon that toggles an NSPopover containing `PopoverView`.
/// Zone 2: preset + height text that shows an `NSMenu` with four preset items;
/// hidden while the desk is not connected.
///
/// Observes `DeskViewModel` to update both zones reactively.
@MainActor
public final class MenuBarController: NSObject {

    // MARK: - Private state

    private var zone1StatusItem: NSStatusItem?
    private var zone2StatusItem: NSStatusItem?
    private var popover: NSPopover?
    private let viewModel: DeskViewModel
    private var lastZone2Title: String = ""
    private var cancellable: AnyCancellable?

    // MARK: - Init

    public init(viewModel: DeskViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    // MARK: - Public API

    /// Creates both NSStatusItems and connects them to the view model.
    ///
    /// When `autoOpen` is true the popover opens immediately after setup,
    /// which is useful for first-run pairing so the user sees the scanning UI
    /// without having to find and click the (dimmed) menu-bar icon first.
    public func setup(autoOpen: Bool = false) {
        FileLog.debug("setup(autoOpen: \(autoOpen)) isFirstRun=\(viewModel.isFirstRun)", category: "ui")
        // Zone 2 first — macOS places the first-created status item rightmost.
        setupZone2()
        setupZone1()
        startObservingViewModel()
        refreshZones()

        if autoOpen {
            // Slight delay so the status item is laid out in the menu bar first.
            DispatchQueue.main.async { [weak self] in
                self?.togglePopover()
            }
        }
    }

    // MARK: - Zone 1: desk icon → popover

    private func setupZone1() {
        FileLog.debug("setupZone1: creating square-length status item", category: "ui")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.action = #selector(togglePopover)
        item.button?.target = self
        item.button?.setAccessibilityIdentifier("linak.menubar.zone1.icon")
        zone1StatusItem = item

        let hosting = NSPopover()
        hosting.contentViewController = NSHostingController(
            rootView: PopoverView(viewModel: viewModel)
        )
        hosting.contentSize = NSSize(width: 280, height: 400)
        // During first-run the popover must stay open so the user can complete
        // the pairing flow without it dismissing on focus loss.
        hosting.behavior = viewModel.isFirstRun ? .applicationDefined : .transient
        popover = hosting
    }

    @objc private func togglePopover() {
        guard let button = zone1StatusItem?.button else { return }
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Make the popover's window key so clicks register immediately
            // without needing an extra activation click first.
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Zone 2: preset text → dropdown menu

    private func setupZone2() {
        FileLog.debug("setupZone2: creating variable-length status item", category: "ui")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.action = #selector(showPresetMenu)
        item.button?.target = self
        item.button?.setAccessibilityIdentifier("linak.menubar.zone2.text")
        zone2StatusItem = item
    }

    @objc private func showPresetMenu() {
        let menu = buildPresetMenu()
        zone2StatusItem?.menu = menu
        zone2StatusItem?.button?.performClick(nil)
        zone2StatusItem?.menu = nil
    }

    // MARK: - View model observation

    private func startObservingViewModel() {
        // objectWillChange fires before the mutation, so we schedule the
        // refresh on the next main-queue cycle to read updated values.
        cancellable = viewModel.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshZones()
            }
        }
    }

    private func refreshZones() {
        updateZone1Icon()
        updateZone2Visibility()
        updateZone2Title()
        updatePopoverBehavior()
    }

    private func updateZone1Icon() {
        guard let button = zone1StatusItem?.button else { return }
        button.alphaValue = 1.0

        if viewModel.needsReference {
            // Persistent fault indicator — visible without opening the popover or
            // catching the one-shot notification. Hover shows the specific cause.
            // Use a self-coloured (non-template) orange symbol so it renders
            // regardless of the status-bar tint.
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            let warning = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Desk fault"
            )?.withSymbolConfiguration(config)
            warning?.isTemplate = false
            button.image = warning
            button.contentTintColor = nil
            button.toolTip = viewModel.faultMessage
        } else {
            button.image = zone1Image(for: viewModel.connectionState)
            button.contentTintColor = nil
            button.alphaValue = viewModel.connectionState == .connected ? 1.0 : 0.7
            button.toolTip = nil
        }
    }

    private func updateZone2Visibility() {
        guard let item = zone2StatusItem else { return }
        if zone2Visible {
            item.length = NSStatusItem.variableLength
            item.button?.action = #selector(showPresetMenu)
            // Title is set by updateZone2Title() — no duplicate here.
        } else {
            item.length = 0
            item.button?.title = ""
            item.button?.action = nil
            lastZone2Title = ""
        }
    }

    private func updateZone2Title() {
        guard zone2Visible else { return }
        let title = zone2Title()
        guard title != lastZone2Title else { return }
        lastZone2Title = title
        zone2StatusItem?.button?.title = title
    }

    private func updatePopoverBehavior() {
        // Switch from applicationDefined → transient once first-run completes
        // so the popover dismisses normally on focus loss.
        if !viewModel.isFirstRun, popover?.behavior == .applicationDefined {
            popover?.behavior = .transient
        }
    }

    // MARK: - Helpers

    /// Zone 2 carries the live height, so it stays hidden unless the desk is connected.
    var zone2Visible: Bool {
        viewModel.showZone2 && viewModel.connectionState == .connected
    }

    /// "table.furniture" is available on macOS 13+ and resembles a desk. SF Symbols
    /// has no .slash variant of it, so disconnected is the outline glyph, which the
    /// dimmed alphaValue in `updateZone1Icon()` reinforces.
    func zone1SymbolName(for state: ConnectionState) -> String {
        state == .connected ? "table.furniture.fill" : "table.furniture"
    }

    private func zone1Image(for state: ConnectionState) -> NSImage? {
        let image = NSImage(
            systemSymbolName: zone1SymbolName(for: state),
            accessibilityDescription: state == .connected ? "Desk connected" : "Desk disconnected"
        )
        image?.isTemplate = true
        return image
    }

    private func zone2Title() -> String {
        guard let active = viewModel.activePreset else { return viewModel.heightDisplay }
        return "\(active)  \(viewModel.heightDisplay)"
    }

    private func buildPresetMenu() -> NSMenu {
        let menu = NSMenu()
        for preset in viewModel.presets {
            menu.addItem(presetMenuItem(for: preset))
        }
        return menu
    }

    private func presetMenuItem(for preset: PresetPosition) -> NSMenuItem {
        let heightText = preset.heightMM.map { HeightConverter.display(mm: $0, unit: viewModel.unit) } ?? "—"
        let prefix = (preset.index == viewModel.targetPreset) ? "→ " : ""
        let title = "\(prefix)\(preset.index)  \(heightText)"

        let item = NSMenuItem(title: title, action: #selector(presetMenuItemSelected(_:)), keyEquivalent: "")
        item.tag = preset.index
        item.target = self
        item.state = (preset.index == viewModel.activePreset) ? .on : .off
        return item
    }

    @objc private func presetMenuItemSelected(_ sender: NSMenuItem) {
        viewModel.goToPreset(index: sender.tag)
    }
}
