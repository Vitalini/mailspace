import AppKit
import WebKit

/// What the window controller needs from the app to drive accounts.
protocol AccountHosting: AnyObject {
    var accountStore: AccountStore { get }
    func session(for accountId: UUID) -> AccountSession?
    func requestAddAccount()
    func requestEditAccount(id: UUID)
    func requestRemoveAccount(id: UUID)
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

        window.title = "MailSpace"
        window.delegate = self
        window.minSize = NSSize(width: 860, height: 560)
        // R9: MailSpace's chrome stays light next to light Gmail/Calendar,
        // whatever the system appearance is.
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameAutosaveName("MailSpaceMainWindow")

        buildLayout()
        emptyState.onAddAccount = { [weak self] in self?.host.requestAddAccount() }
        tabBar.onSelectAccount = { [weak self] id in self?.select(accountId: id) }
        tabBar.onSelectView = { [weak self] view in self?.selectView(view) }
        tabBar.onAddAccount = { [weak self] in self?.host.requestAddAccount() }
        tabBar.onEditAccount = { [weak self] id in self?.host.requestEditAccount(id: id) }
        tabBar.onRemoveAccount = { [weak self] id in self?.host.requestRemoveAccount(id: id) }
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
        // `setFrameAutosaveName` restores a saved frame if there is one; centre
        // the window only on a genuinely first run.
        let hasSavedFrame = UserDefaults.standard.string(forKey: "NSWindow Frame \(window.frameAutosaveName)") != nil
        if !hasSavedFrame {
            window.center()
        }
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

    func selectAccount(at index: Int) {
        guard store.accounts.indices.contains(index) else { return }
        select(accountId: store.accounts[index].id)
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

    /// Rebuilds the tab bar, Accounts menu and content area from current state.
    func refresh() {
        if let selection, store.account(id: selection.accountId) == nil {
            self.selection = nil
        }
        if selection == nil, let first = store.accounts.first, let view = first.effectiveView {
            selection = Selection(accountId: first.id, view: view)
        }

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
        menu.removeAllItems()

        menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "")

        guard !store.accounts.isEmpty else { return }
        menu.addItem(.separator())

        for (index, account) in store.accounts.enumerated() {
            let shortcut = index < 9 ? String(index + 1) : ""
            let item = menu.addItem(withTitle: account.name, action: #selector(selectAccountMenuItem(_:)), keyEquivalent: shortcut)
            item.target = self
            item.representedObject = account.id
            item.state = account.id == selection?.accountId ? .on : .off
        }

        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Account Settings…", action: #selector(editCurrentAccount(_:)), keyEquivalent: ",")
        settings.target = self
        let remove = menu.addItem(withTitle: "Remove Current Account…", action: #selector(removeCurrentAccount(_:)), keyEquivalent: "")
        remove.target = self
    }

    @objc private func selectAccountMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        select(accountId: id)
    }

    @objc private func editCurrentAccount(_ sender: Any?) {
        guard let id = selection?.accountId else { return }
        host.requestEditAccount(id: id)
    }

    @objc private func removeCurrentAccount(_ sender: Any?) {
        guard let id = selection?.accountId else { return }
        host.requestRemoveAccount(id: id)
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

/// Mailplane-style top bar: one tab per account on the left, a Mail/Calendar
/// toggle for the active account on the right. The toggle only ever offers the
/// services that account has enabled.
final class AccountTabBar: NSView {
    static let height: CGFloat = 40

    var onSelectAccount: ((UUID) -> Void)?
    var onSelectView: ((AccountView) -> Void)?
    var onAddAccount: (() -> Void)?
    var onEditAccount: ((UUID) -> Void)?
    var onRemoveAccount: ((UUID) -> Void)?

    private let background = NSVisualEffectView()
    private let tabStack = NSStackView()
    private let addButton = NSButton()
    private let viewToggle = NSSegmentedControl()
    private var toggleViews: [AccountView] = []

    private(set) var tabCount = 0

    init() {
        super.init(frame: .zero)

        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = 4
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        addButton.title = "＋"
        addButton.bezelStyle = .texturedRounded
        addButton.toolTip = "Add Account"
        addButton.target = self
        addButton.action = #selector(addAccount(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        viewToggle.segmentStyle = .texturedRounded
        viewToggle.trackingMode = .selectOne
        viewToggle.target = self
        viewToggle.action = #selector(toggleChanged(_:))
        viewToggle.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(tabStack)
        addSubview(addButton)
        addSubview(viewToggle)
        addSubview(separator)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            tabStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            tabStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            addButton.leadingAnchor.constraint(equalTo: tabStack.trailingAnchor, constant: 6),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 34),

            viewToggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            viewToggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            viewToggle.leadingAnchor.constraint(greaterThanOrEqualTo: addButton.trailingAnchor, constant: 12),

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

        for account in accounts {
            let tab = AccountTabView(account: account, isSelected: account.id == selection?.accountId)
            tab.onClick = { [weak self] id in self?.onSelectAccount?(id) }
            tab.onEdit = { [weak self] id in self?.onEditAccount?(id) }
            tab.onRemove = { [weak self] id in self?.onRemoveAccount?(id) }
            tabStack.addArrangedSubview(tab)
        }
        tabCount = accounts.count

        let active = selection.flatMap { current in accounts.first { $0.id == current.accountId } }
        rebuildToggle(for: active, selection: selection)
    }

    private func rebuildToggle(for account: Account?, selection: MainWindowController.Selection?) {
        guard let account, account.enabledViews.count > 1 else {
            // A single-service account has nothing to toggle between.
            viewToggle.isHidden = true
            toggleViews = []
            return
        }

        toggleViews = account.enabledViews
        viewToggle.isHidden = false
        viewToggle.segmentCount = toggleViews.count
        for (index, view) in toggleViews.enumerated() {
            viewToggle.setLabel(view.displayName, forSegment: index)
            viewToggle.setWidth(88, forSegment: index)
        }
        if let current = selection?.view, let index = toggleViews.firstIndex(of: current) {
            viewToggle.selectedSegment = index
        }
    }

    @objc private func addAccount(_ sender: Any?) {
        onAddAccount?()
    }

    @objc private func toggleChanged(_ sender: NSSegmentedControl) {
        guard toggleViews.indices.contains(sender.selectedSegment) else { return }
        onSelectView?(toggleViews[sender.selectedSegment])
    }
}

/// A single account tab.
final class AccountTabView: NSView {
    private let accountId: UUID
    private let selected: Bool

    var onClick: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?

    init(account: Account, isSelected: Bool) {
        self.accountId = account.id
        self.selected = isSelected
        super.init(frame: .zero)

        wantsLayer = true
        let label = NSTextField(labelWithString: account.name)
        label.font = .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        toolTip = account.email.isEmpty ? account.name : "\(account.name) · \(account.email)"

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220)
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
        guard selected else { return }
        NSColor.controlBackgroundColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(accountId)
    }

    @objc private func edit(_ sender: Any?) {
        onEdit?(accountId)
    }

    @objc private func removeAccount(_ sender: Any?) {
        onRemove?(accountId)
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
