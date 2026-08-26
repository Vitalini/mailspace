import AppKit
import WebKit

/// What the window controller needs from the app to drive accounts.
protocol AccountHosting: AnyObject {
    var accountStore: AccountStore { get }
    func session(for accountId: UUID) -> AccountSession?
    func requestAddAccount()
    func requestRemoveAccount(id: UUID)
}

/// The one MailSpace window: a light account sidebar on the left, the active
/// account's Mail or Calendar webview on the right.
///
/// Switching never reloads — every account's webviews are retained by its
/// `AccountSession`, so a switch is a view swap and Gmail keeps its compose
/// drafts and scroll position.
final class MainWindowController: NSObject, NSWindowDelegate {
    struct Selection: Equatable {
        let accountId: UUID
        let view: AccountView
    }

    private enum Layout {
        static let sidebarWidth: CGFloat = 200
    }

    private static let lastAccountDefaultsKey = "lastAccountId"

    private unowned let host: AccountHosting
    private var store: AccountStore { host.accountStore }

    let window: NSWindow
    private let sidebarEffect = NSVisualEffectView()
    private let sidebar = SidebarView()
    private let sidebarScroll = NSScrollView()
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
        window.minSize = NSSize(width: 800, height: 520)
        // R9: MailSpace's chrome stays light next to light Gmail/Calendar,
        // whatever the system appearance is.
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameAutosaveName("MailSpaceMainWindow")

        buildLayout()
        emptyState.onAddAccount = { [weak self] in self?.host.requestAddAccount() }
        sidebar.onSelect = { [weak self] kind in self?.handleSidebarClick(kind) }
        sidebar.onRemoveAccount = { [weak self] id in self?.host.requestRemoveAccount(id: id) }
    }

    // MARK: - Layout

    private func buildLayout() {
        let root = NSView()
        window.contentView = root

        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.state = .followsWindowActiveState
        sidebarEffect.translatesAutoresizingMaskIntoConstraints = false

        sidebarScroll.drawsBackground = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.autohidesScrollers = true
        sidebarScroll.documentView = sidebar
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        // A plain 1pt view, not NSBox(.separator): a separator box carries an
        // intrinsic content size that collapses the window's height to 1pt when
        // it is pinned top-to-bottom.
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.white.cgColor

        root.addSubview(sidebarEffect)
        sidebarEffect.addSubview(sidebarScroll)
        root.addSubview(divider)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebarEffect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarEffect.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarEffect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarEffect.widthAnchor.constraint(equalToConstant: Layout.sidebarWidth),

            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarEffect.topAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor),

            divider.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentContainer.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Nothing else in the hierarchy demands height, and a window whose
            // content view uses Auto Layout will shrink to fit its constraints.
            contentContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
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
        let accountId = remembered.flatMap { store.account(id: $0) }?.id ?? store.accounts.first?.id
        if let accountId, let account = store.account(id: accountId) {
            select(accountId: accountId, view: account.lastView)
        } else {
            selection = nil
            refresh()
        }
    }

    // MARK: - Selection

    func select(accountId: UUID, view: AccountView) {
        guard store.account(id: accountId) != nil else { return }
        selection = Selection(accountId: accountId, view: view)
        store.setLastView(view, for: accountId)
        UserDefaults.standard.set(accountId.uuidString, forKey: Self.lastAccountDefaultsKey)
        refresh()
    }

    /// Selects an account, landing on whichever view it was last showing.
    func select(accountId: UUID) {
        guard let account = store.account(id: accountId) else { return }
        select(accountId: accountId, view: account.lastView)
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

    private func handleSidebarClick(_ kind: SidebarView.RowKind) {
        switch kind {
        case .addAccount:
            host.requestAddAccount()
        case .accountHeader(let id):
            select(accountId: id)
        case .accountView(let id, let view):
            select(accountId: id, view: view)
        }
    }

    // MARK: - Rendering

    /// Rebuilds the sidebar, Accounts menu and content area from current state.
    func refresh() {
        if let selection, store.account(id: selection.accountId) == nil {
            self.selection = nil
        }
        if selection == nil, let first = store.accounts.first {
            selection = Selection(accountId: first.id, view: first.lastView)
        }

        sidebar.rebuild(accounts: store.accounts, selection: selection)
        rebuildAccountsMenu()
        showActiveContent()
    }

    private func showActiveContent() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }

        guard
            let selection,
            let account = store.account(id: selection.accountId),
            let session = host.session(for: selection.accountId)
        else {
            window.title = "MailSpace"
            pin(emptyState, in: contentContainer)
            return
        }

        let webView = session.webView(for: selection.view)
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

        let add = menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "")
        add.target = nil

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
        let remove = menu.addItem(withTitle: "Remove Current Account…", action: #selector(removeCurrentAccount(_:)), keyEquivalent: "")
        remove.target = self
    }

    @objc private func selectAccountMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        select(accountId: id)
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
            + "sidebarRows=\(sidebar.rowCount)"
    }
}

// MARK: - Sidebar

/// The account list. Rebuilt wholesale on any change — the list is a handful
/// of rows, so manual layout beats the ceremony of a table view here.
final class SidebarView: NSView {
    override var isFlipped: Bool { true }

    enum RowKind: Equatable {
        case accountHeader(UUID)
        case accountView(UUID, AccountView)
        case addAccount
    }

    var onSelect: ((RowKind) -> Void)?
    var onRemoveAccount: ((UUID) -> Void)?

    private var rows: [SidebarRowView] = []
    var rowCount: Int { rows.count }

    func rebuild(accounts: [Account], selection: MainWindowController.Selection?) {
        rows.forEach { $0.removeFromSuperview() }
        rows = []

        for account in accounts {
            rows.append(makeRow(
                kind: .accountHeader(account.id),
                title: account.name.uppercased(),
                indent: 14,
                height: 26,
                font: .systemFont(ofSize: 10, weight: .semibold),
                color: .secondaryLabelColor,
                selectable: false,
                accountId: account.id
            ))

            for view in AccountView.allCases {
                let isSelected = selection == .init(accountId: account.id, view: view)
                let row = makeRow(
                    kind: .accountView(account.id, view),
                    title: view.displayName,
                    indent: 22,
                    height: 28,
                    font: .systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular),
                    color: .labelColor,
                    selectable: true,
                    accountId: account.id
                )
                row.isSelected = isSelected
                rows.append(row)
            }
        }

        rows.append(makeRow(
            kind: .addAccount,
            title: accounts.isEmpty ? "＋  Add Account…" : "＋  Add Account",
            indent: 14,
            height: 30,
            font: .systemFont(ofSize: 13),
            color: .controlAccentColor,
            selectable: true,
            accountId: nil
        ))

        rows.forEach(addSubview)
        var height: CGFloat = 12
        for row in rows { height += row.rowHeight + 2 }
        setFrameSize(NSSize(width: 200, height: height + 12))
        needsLayout = true
    }

    private func makeRow(
        kind: RowKind,
        title: String,
        indent: CGFloat,
        height: CGFloat,
        font: NSFont,
        color: NSColor,
        selectable: Bool,
        accountId: UUID?
    ) -> SidebarRowView {
        let row = SidebarRowView(kind: kind, title: title, indent: indent, height: height, font: font, color: color)
        if selectable {
            row.onClick = { [weak self] kind in self?.onSelect?(kind) }
        }
        if let accountId {
            let menu = NSMenu()
            let item = menu.addItem(withTitle: "Remove Account…", action: #selector(SidebarRowView.removeAccount(_:)), keyEquivalent: "")
            item.target = row
            row.menu = menu
            row.onRemove = { [weak self] in self?.onRemoveAccount?(accountId) }
        }
        return row
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 12
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: row.rowHeight)
            y += row.rowHeight + 2
        }
    }
}

final class SidebarRowView: NSView {
    let kind: SidebarView.RowKind
    let rowHeight: CGFloat
    var onClick: ((SidebarView.RowKind) -> Void)?
    var onRemove: (() -> Void)?

    var isSelected = false { didSet { needsDisplay = true } }

    private let label: NSTextField

    init(kind: SidebarView.RowKind, title: String, indent: CGFloat, height: CGFloat, font: NSFont, color: NSColor) {
        self.kind = kind
        self.rowHeight = height
        self.label = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — the UI is built programmatically") }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(kind)
    }

    @objc func removeAccount(_ sender: Any?) {
        onRemove?()
    }
}

// MARK: - Zero-accounts state

/// Shown on first launch, or after the last account is removed (U3 §2a).
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

        let subtitle = NSTextField(labelWithString: "Each account gets its own isolated Google session for Mail and Calendar.")
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
