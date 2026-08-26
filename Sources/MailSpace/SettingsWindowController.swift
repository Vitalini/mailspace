import AppKit

/// The Settings window, ⌘, .
///
/// This is the shell `docs/plans/2026-08-26-1224-feat-settings-window-plan.md`
/// specifies in U1 — programmatic `NSWindow` plus an `NSToolbar` whose items
/// select panes — carrying only the General pane, and in it only the update
/// preferences. The rest of that plan's General controls and the whole Accounts
/// pane drop in by adding to `panes` below; nothing here has to move.
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    private struct Pane {
        let identifier: NSToolbarItem.Identifier
        let title: String
        let symbol: String
        let controller: NSViewController
    }

    private let panes: [Pane]
    private var window: NSWindow?
    private var selected: NSToolbarItem.Identifier

    init(updates: UpdateController, settings: AppSettings = .shared) {
        panes = [
            Pane(
                identifier: NSToolbarItem.Identifier("general"),
                title: "General",
                symbol: "gearshape",
                controller: SettingsGeneralPane(updates: updates, settings: settings)
            )
        ]
        selected = panes[0].identifier
        super.init()
    }

    func show() {
        buildIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildIfNeeded() {
        guard window == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        // Matches the main window, which is pinned to Aqua so Gmail's own light
        // chrome does not sit inside a dark frame.
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MailSpaceSettingsWindow")
        window.center()

        let toolbar = NSToolbar(identifier: "MailSpaceSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = selected
        window.toolbar = toolbar
        window.toolbarStyle = .preference

        self.window = window
        select(selected)
    }

    private func select(_ identifier: NSToolbarItem.Identifier) {
        guard let pane = panes.first(where: { $0.identifier == identifier }), let window else { return }
        selected = identifier
        window.title = panes.count == 1 ? "Settings" : pane.title
        window.contentViewController = pane.controller
        window.toolbar?.selectedItemIdentifier = identifier
    }

    @objc private func toolbarItemClicked(_ sender: NSToolbarItem) {
        select(sender.itemIdentifier)
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        panes.map(\.identifier)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let pane = panes.first(where: { $0.identifier == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemClicked(_:))
        return item
    }
}
