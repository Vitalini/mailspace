import AppKit
import WebKit

/// What the window controller needs from the app to drive accounts.
protocol AccountHosting: AnyObject {
    var accountStore: AccountStore { get }
    func session(for accountId: UUID) -> AccountSession?
    func requestAddAccount()
    func requestEditAccount(id: UUID)
    /// Confirms on `presentedOn` — the window the user clicked in — and falls
    /// back to an app-modal dialog when there is none. Swift forbids a default
    /// value in a protocol requirement, so every caller passes its own window.
    func requestRemoveAccount(id: UUID, presentedOn: NSWindow?)
    /// This tab is now the visible one.
    func tabBecameVisible(accountId: UUID, view: AccountView)
    /// Something that feeds the Dock badge changed. `repoll` is for a change to
    /// what the number *means* (the badge scope); without it the existing
    /// counts are simply re-totalled.
    func badgeInputsChanged(repoll: Bool)
}

/// The one MailSpace window: a Mailplane-style account tab bar across the top,
/// the active account's Mail or Calendar webview below it.
///
/// Switching never reloads — every account's webviews are retained by its
/// `AccountSession`, so a switch is a view swap and Gmail keeps its compose
/// drafts and scroll position.
final class MainWindowController: NSObject, NSWindowDelegate {
    struct Selection: Equatable {
        let accountId: UUID
        let view: AccountView
    }

    private static let lastAccountDefaultsKey = "lastAccountId"
    private static let frameAutosaveName: NSWindow.FrameAutosaveName = "MailSpaceMainWindow"

    private unowned let host: AccountHosting
    private var store: AccountStore { host.accountStore }

    let window: NSWindow
    private let tabBar = AccountTabBar()
    private let contentContainer = NSView()
    private let emptyState = EmptyStateView()

    private(set) var selection: Selection?

    init(host: AccountHosting) {
        self.host = host
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        // The controller holds the only strong reference to the window, so
        // AppKit must not release it on close — otherwise Cmd+W followed by a
        // Dock click (applicationShouldHandleReopen) touches a freed window.
        window.isReleasedWhenClosed = false
        window.title = "MailSpace"
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 560)
        // R9: MailSpace's chrome stays light next to light Gmail/Calendar,
        // whatever the system appearance is.
        window.appearance = NSAppearance(named: .aqua)

        buildLayout()
        emptyState.onAddAccount = { [weak self] in self?.host.requestAddAccount() }
        tabBar.onSelectTab = { [weak self] tab in self?.select(accountId: tab.accountId, view: tab.view) }
        tabBar.onReorderTab = { [weak self] tab, index in
            self?.store.moveTab(tab, to: index)
            self?.refresh()
        }
        tabBar.onAddAccount = { [weak self] in self?.host.requestAddAccount() }
        tabBar.onEditAccount = { [weak self] id in self?.host.requestEditAccount(id: id) }
        tabBar.onRemoveAccount = { [weak self] id in
            self?.host.requestRemoveAccount(id: id, presentedOn: self?.window)
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        let root = NSView()
        window.contentView = root

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.white.cgColor

        root.addSubview(tabBar)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: AccountTabBar.height),

            contentContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Nothing else in the hierarchy demands a size, and a window whose
            // content view uses Auto Layout shrinks to fit its constraints.
            contentContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 800),
            contentContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 480)
        ])
    }

    // MARK: - Lifecycle

    func showWindow() {
        // `setFrameUsingName` restores a saved frame and reports whether there
        // was one, so a genuinely first run is the only run that centres. The
        // autosave name is attached afterwards, so registering it can never
        // overwrite the frame we are about to restore.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.makeKeyAndOrderFront(nil)
    }

    /// B6. The only way back from a frame stranded on a display that is no
    /// longer attached. A rescue belongs in a menu, not in Settings.
    func resetWindowPosition() {
        NSWindow.removeFrame(usingName: Self.frameAutosaveName)
        window.setContentSize(NSSize(width: 1280, height: 840))
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Restores the last account and view from the previous run (R14).
    func restoreSelection() {
        let remembered = UserDefaults.standard.string(forKey: Self.lastAccountDefaultsKey)
            .flatMap(UUID.init(uuidString:))
        let account = remembered.flatMap { store.account(id: $0) } ?? store.accounts.first
        if let account, let view = account.effectiveView {
            select(accountId: account.id, view: view)
        } else {
            selection = nil
            refresh()
        }
    }

    // MARK: - Selection

    func select(accountId: UUID, view: AccountView) {
        guard let account = store.account(id: accountId) else { return }
        // A disabled service is not selectable — fall back to what the account
        // does offer.
        guard let resolved = account.isEnabled(view) ? view : account.effectiveView else { return }

        selection = Selection(accountId: accountId, view: resolved)
        store.setLastView(resolved, for: accountId)
        UserDefaults.standard.set(accountId.uuidString, forKey: Self.lastAccountDefaultsKey)
        refresh()
    }

    /// Selects an account, landing on whichever view it was last showing.
    func select(accountId: UUID) {
        guard let account = store.account(id: accountId), let view = account.effectiveView else { return }
        select(accountId: accountId, view: view)
    }

    /// The flattened tab list, in dragged order — the same list Cmd+1..9
    /// addresses.
    var tabs: [TabRef] { TabOrder.tabs(for: store.accounts) }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        select(accountId: tab.accountId, view: tab.view)
    }

    func selectView(_ view: AccountView) {
        guard let accountId = selection?.accountId else { return }
        select(accountId: accountId, view: view)
    }

    /// Brings the app forward on a specific account and view — used by
    /// notification clicks and by the mailto handler.
    func focus(accountId: UUID, view: AccountView) {
        select(accountId: accountId, view: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Rendering

    /// Brings the in-memory selection back in step with the store.
    ///
    /// Two things can strand it: the account disappearing, and the selected
    /// service being switched off in the account dialog. The second used to
    /// drop the window into the zero-accounts state even though the account
    /// still had its other service. The fallback is the account's own
    /// `effectiveView` — the same rule `AccountStore.update` heals `lastView`
    /// with — and then the first account.
    ///
    /// Pure and static so it can be tested without an AppKit window.
    static func reconciledSelection(_ current: Selection?, accounts: [Account]) -> Selection? {
        var resolved = current
        if let selection = resolved {
            if let account = accounts.first(where: { $0.id == selection.accountId }) {
                if !account.isEnabled(selection.view) {
                    resolved = account.effectiveView.map { Selection(accountId: account.id, view: $0) }
                }
            } else {
                resolved = nil
            }
        }
        if resolved == nil, let first = accounts.first, let view = first.effectiveView {
            resolved = Selection(accountId: first.id, view: view)
        }
        return resolved
    }

    /// Rebuilds the tab bar, Accounts menu and content area from current state.
    func refresh() {
        selection = Self.reconciledSelection(selection, accounts: store.accounts)

        tabBar.rebuild(accounts: store.accounts, selection: selection)
        rebuildAccountsMenu()
        showActiveContent()
    }

    private func showActiveContent() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        guard
            let selection,
            let account = store.account(id: selection.accountId),
            let session = host.session(for: selection.accountId),
            let webView = session.webView(for: selection.view)
        else {
            window.title = "MailSpace"
            pin(emptyState, in: contentContainer)
            return
        }

        pin(webView, in: contentContainer)
        window.title = "\(account.name) — \(selection.view.displayName)"
        // Hand focus straight to the page so Gmail's own shortcuts work
        // without an extra click (R15).
        window.makeFirstResponder(webView)
        // Bringing a tab up is also the cue to revive one whose content process
        // kept crashing; the user asking to see it is the bound on how often
        // that is retried.
        host.tabBecameVisible(accountId: selection.accountId, view: selection.view)
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }

    // MARK: - Menus

    private func rebuildAccountsMenu() {
        guard let menu = NSApp.mainMenu?.item(withTitle: MainMenu.accountsMenuTitle)?.submenu else { return }
        let tabs = self.tabs
        menu.removeAllItems()

        menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "")

        guard !tabs.isEmpty else { return }
        menu.addItem(.separator())

        for (index, tab) in tabs.enumerated() {
            guard let account = store.account(id: tab.accountId) else { continue }
            let shortcut = index < 9 ? String(index + 1) : ""
            let item = menu.addItem(
                withTitle: "\(account.name) · \(tab.view.displayName)",
                action: #selector(selectTabMenuItem(_:)),
                keyEquivalent: shortcut
            )
            item.target = self
            item.representedObject = index
            item.state = (selection?.accountId == tab.accountId && selection?.view == tab.view) ? .on : .off
        }

        menu.addItem(.separator())
        // No key equivalent: ⌘, belongs to the app's own Settings window.
        let settings = menu.addItem(withTitle: "Account Settings…", action: #selector(editCurrentAccount(_:)), keyEquivalent: "")
        settings.target = self
        let remove = menu.addItem(withTitle: "Remove Current Account…", action: #selector(removeCurrentAccount(_:)), keyEquivalent: "")
        remove.target = self
    }

    @objc private func selectTabMenuItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        selectTab(at: index)
    }

    @objc private func editCurrentAccount(_ sender: Any?) {
        guard let id = selection?.accountId else { return }
        host.requestEditAccount(id: id)
    }

    @objc private func removeCurrentAccount(_ sender: Any?) {
        guard let id = selection?.accountId else { return }
        host.requestRemoveAccount(id: id, presentedOn: window)
    }

    // MARK: - Diagnostics

    /// One-line state summary used by the headless self-check.
    var stateDescription: String {
        let selectionText = selection.map { "\($0.accountId.uuidString.prefix(8))/\($0.view.rawValue)" } ?? "none"
        return "accounts=\(store.accounts.count) selection=\(selectionText) "
            + "zeroState=\(contentContainer.subviews.contains(emptyState) ? 1 : 0) "
            + "tabs=\(tabBar.tabCount)"
    }
}

// MARK: - Account tab bar

/// One tab per enabled service per account, in account order:
/// `[Work · Mail] [Work · Calendar] [Personal · Calendar]`. A single click
/// goes from one account's mail straight to another's calendar, and Cmd+1..9
/// addresses this flattened list.
///
/// Every tab of an account carries that account's colour, so the accounts stay
/// apart at a glance; Mail and Calendar differ by icon and label.
final class AccountTabBar: NSView {
    static let height: CGFloat = 42

    typealias Tab = TabRef

    var onSelectTab: ((Tab) -> Void)?
    /// Called when a tab is dropped: the dragged tab and the slot it landed in.
    var onReorderTab: ((Tab, Int) -> Void)?
    var onAddAccount: (() -> Void)?
    var onEditAccount: ((UUID) -> Void)?
    var onRemoveAccount: ((UUID) -> Void)?

    private let background = NSVisualEffectView()
    private let tabScroll = NSScrollView()
    private let tabStack = NSStackView()
    private let addButton = NSButton()

    private(set) var tabCount = 0
    private var isDragging = false

    init() {
        super.init(frame: .zero)

        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 6
        tabStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        tabScroll.drawsBackground = false
        tabScroll.hasHorizontalScroller = false
        tabScroll.hasVerticalScroller = false
        tabScroll.horizontalScrollElasticity = .allowed
        tabScroll.documentView = tabStack
        tabScroll.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "＋"
        addButton.bezelStyle = .texturedRounded
        addButton.toolTip = "Add Account"
        addButton.target = self
        addButton.action = #selector(addAccount(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(tabScroll)
        addSubview(addButton)
        addSubview(separator)

        registerForDraggedTypes([AccountTabView.pasteboardType])

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            tabScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabScroll.topAnchor.constraint(equalTo: topAnchor),
            tabScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            tabScroll.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -4),

            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),

            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 34),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — the UI is built programmatically") }

    func rebuild(accounts: [Account], selection: MainWindowController.Selection?) {
        for view in tabStack.arrangedSubviews {
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let tabs = TabOrder.tabs(for: accounts)
        tabCount = tabs.count

        for tab in tabs {
            guard let account = accounts.first(where: { $0.id == tab.accountId }) else { continue }
            let isSelected = selection.map { $0.accountId == tab.accountId && $0.view == tab.view } ?? false
            let tabView = AccountTabView(account: account, view: tab.view, isSelected: isSelected)
            tabView.onClick = { [weak self] tab in self?.onSelectTab?(tab) }
            tabView.onEdit = { [weak self] id in self?.onEditAccount?(id) }
            tabView.onRemove = { [weak self] id in self?.onRemoveAccount?(id) }
            tabView.onDragBegan = { [weak self] in self?.isDragging = true }
            tabStack.addArrangedSubview(tabView)
        }
        tabStack.layoutSubtreeIfNeeded()
    }

    @objc private func addAccount(_ sender: Any?) {
        onAddAccount?()
    }

    // MARK: - Reordering

    /// Tabs are dragged into any order the user likes; a service tab can move
    /// independently of its account sibling.
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .move : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .move : []
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        isDragging = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDragging = false
        guard
            let raw = sender.draggingPasteboard.string(forType: AccountTabView.pasteboardType),
            let tab = TabRef(identifier: raw)
        else { return false }

        onReorderTab?(tab, insertionIndex(at: convert(sender.draggingLocation, from: nil)))
        return true
    }

    private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: AccountTabView.pasteboardType) != nil
    }

    /// The slot a drop at `point` should land in: the first tab whose midpoint
    /// is to the right of the cursor, or the end of the bar.
    private func insertionIndex(at point: NSPoint) -> Int {
        for (index, tabView) in tabStack.arrangedSubviews.enumerated() {
            let frame = convert(tabView.bounds, from: tabView)
            if point.x < frame.midX { return index }
        }
        return tabStack.arrangedSubviews.count
    }
}

/// A single account × service tab, tinted with the account's colour.
final class AccountTabView: NSView, NSDraggingSource {
    static let pasteboardType = NSPasteboard.PasteboardType("com.vitalii.MailSpace.tab")

    private let tab: AccountTabBar.Tab
    private let tint: NSColor
    private let selected: Bool

    var onClick: ((AccountTabBar.Tab) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onDragBegan: (() -> Void)?

    /// Set on mouse-down and cleared once a drag starts, so a press that never
    /// moves is a click and a press that moves is a reorder.
    private var pressOrigin: NSPoint?

    init(account: Account, view: AccountView, isSelected: Bool) {
        self.tab = AccountTabBar.Tab(accountId: account.id, view: view)
        self.tint = account.color.nsColor
        self.selected = isSelected
        super.init(frame: .zero)

        wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: view == .mail ? "envelope.fill" : "calendar",
            accessibilityDescription: view.displayName
        )
        icon.contentTintColor = isSelected ? tint : tint.withAlphaComponent(0.75)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "\(account.name) · \(view.displayName)")
        label.font = .systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .regular)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        toolTip = account.email.isEmpty
            ? "\(account.name) · \(view.displayName)"
            : "\(account.name) · \(view.displayName) — \(account.email)"

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 260)
        ])

        let contextMenu = NSMenu()
        let settings = contextMenu.addItem(withTitle: "Account Settings…", action: #selector(edit(_:)), keyEquivalent: "")
        settings.target = self
        let removeItem = contextMenu.addItem(withTitle: "Remove Account…", action: #selector(removeAccount(_:)), keyEquivalent: "")
        removeItem.target = self
        menu = contextMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — the UI is built programmatically") }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: body, xRadius: 7, yRadius: 7)

        // The account colour is always present as a tint; selection deepens it
        // and adds a colour bar so the active tab reads at a glance.
        tint.withAlphaComponent(selected ? 0.20 : 0.07).setFill()
        path.fill()
        tint.withAlphaComponent(selected ? 0.85 : 0.25).setStroke()
        path.lineWidth = selected ? 1.5 : 1
        path.stroke()

        guard selected else { return }
        let bar = NSRect(x: body.minX + 4, y: body.minY + 1.5, width: body.width - 8, height: 2.5)
        tint.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
    }

    /// Clicking a tab while MailSpace is in the background should switch tabs,
    /// not just bring the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }
        let travelled = hypot(
            event.locationInWindow.x - origin.x,
            event.locationInWindow.y - origin.y
        )
        guard travelled > 4 else { return }

        pressOrigin = nil
        beginReorderDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressOrigin != nil else { return }
        pressOrigin = nil
        onClick?(tab)
    }

    private func beginReorderDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(tab.identifier, forType: Self.pasteboardType)

        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        draggingItem.setDraggingFrame(bounds, contents: snapshot())

        onDragBegan?()
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return image }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Reordering is in-window only; dragging a tab to the Finder or another
        // app should do nothing.
        context == .withinApplication ? .move : []
    }

    @objc private func edit(_ sender: Any?) {
        onEdit?(tab.accountId)
    }

    @objc private func removeAccount(_ sender: Any?) {
        onRemove?(tab.accountId)
    }
}

// MARK: - Zero-accounts state

/// Shown on first launch, or after the last account is removed.
final class EmptyStateView: NSView {
    var onAddAccount: (() -> Void)?

    private let button = NSButton(title: "Add Account…", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor

        let title = NSTextField(labelWithString: "Add your first account")
        title.font = .systemFont(ofSize: 20, weight: .medium)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "Each account gets its own isolated Google session, and you choose whether it shows Mail, Calendar, or both.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.usesSingleLineMode = false
        subtitle.maximumNumberOfLines = 0
        subtitle.preferredMaxLayoutWidth = 380

        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(addAccount(_:))

        let stack = NSStackView(views: [title, subtitle, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — the UI is built programmatically") }

    @objc private func addAccount(_ sender: Any?) {
        onAddAccount?()
    }
}
