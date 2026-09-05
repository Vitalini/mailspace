import AppKit

/// The Settings window, ⌘, .
///
/// Programmatic `NSWindow` plus an `NSToolbar` whose items select panes:
/// General carries the app-wide behaviour, Accounts the per-account switches
/// and the add/edit/remove buttons.
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    private struct Pane {
        let identifier: NSToolbarItem.Identifier
        let title: String
        let symbol: String
        let controller: NSViewController
    }

    private let panes: [Pane]
    private let accountsPane: SettingsAccountsPane
    private let generalPane: SettingsGeneralPane
    private var window: NSWindow?
    private var selected: NSToolbarItem.Identifier

    init(
        updates: UpdateController,
        settings: AppSettings = .shared,
        accounts host: AccountHosting,
        calendar: CalendarCountdownControls = CalendarCountdownControls(),
        unread: UnreadCheckControls = UnreadCheckControls()
    ) {
        generalPane = SettingsGeneralPane(
            updates: updates,
            settings: settings,
            accounts: host,
            calendar: calendar
        )
        accountsPane = SettingsAccountsPane(accounts: host, unread: unread)
        panes = [
            Pane(
                identifier: NSToolbarItem.Identifier("general"),
                title: "General",
                symbol: "gearshape",
                controller: generalPane
            ),
            Pane(
                identifier: NSToolbarItem.Identifier("accounts"),
                title: "Accounts",
                symbol: "person.2",
                controller: accountsPane
            )
        ]
        selected = panes[0].identifier
        super.init()
    }

    func show() {
        buildIfNeeded()
        // Covers anything that changed while the window was closed.
        reloadAccounts()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The account list changed underneath the window (KTD-S10). Returns
    /// immediately when the window has never been built — touching the `lazy`
    /// property in `AppDelegate` constructs view controllers, not a window, and
    /// a pane whose view has not loaded has nothing to reload.
    func reloadAccounts() {
        guard window != nil else { return }
        accountsPane.reload()
        generalPane.reload()
    }

    /// Builds the window without showing it, for the headless render check.
    /// Nothing here activates the app or orders a window on screen.
    func windowForOffscreenRender(paneIndex: Int) -> NSWindow? {
        buildIfNeeded()
        guard panes.indices.contains(paneIndex) else { return nil }
        select(panes[paneIndex].identifier)
        reloadAccounts()
        window?.layoutIfNeeded()
        return window
    }

    private func buildIfNeeded() {
        guard window == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
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
        window.title = pane.title
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
