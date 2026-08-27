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
    /// This tab is now the visible one. `isSelectionChange` separates a real
    /// tab change from a `refresh()` that happened to re-render the same tab —
    /// the second must not re-navigate anything.
    func tabBecameVisible(accountId: UUID, view: AccountView, isSelectionChange: Bool)
    /// This tab has just stopped being the visible one.
    func tabWasDeselected(accountId: UUID, view: AccountView)
    /// Accounts the health monitor currently reports as signed out.
    func signedOutAccounts() -> Set<UUID>
    /// Accounts whose Mail tab failed to reload and has not come back.
    func stalledAccounts() -> Set<UUID>
    /// The same fact per tab, so a dead Calendar tab is marked on the Calendar
    /// tab rather than on its working Mail sibling.
    func stalledTabs() -> Set<TabRef>
    /// This account's own unread count, or `nil` when nothing is known. One
    /// number per account, read once and rendered twice — this and the Dock
    /// badge are the same value (KTD-S7).
    func unreadCount(for accountId: UUID) -> Int?
    /// Seconds until this account's next event later today, or `nil` whenever
    /// there is nothing honest to say — including when the setting is off.
    func calendarCountdownSeconds(for accountId: UUID) -> Int?
    /// The spoken form of the same number, for the tooltip. Generated from the
    /// integer; it names no event.
    func calendarCountdownDescription(for accountId: UUID) -> String?
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
    /// What the content area is actually showing. A `refresh()` that resolves to
    /// this same selection is a redundant re-pin.
    private var pinned: Selection?

    /// Whether the window is genuinely on screen — the recycler's opportunity
    /// gate for the selected tab.
    var isOnScreen: Bool {
        window.isVisible && !window.isMiniaturized
    }

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

        let next = Selection(accountId: accountId, view: resolved)
        // G11: Gmail issues actions optimistically, so a tab that has just
        // become "background" may still have a request in flight. The recycler
        // holds off on it for five minutes.
        if let previous = selection, previous != next {
            host.tabWasDeselected(accountId: previous.accountId, view: previous.view)
        }
        selection = next
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

        tabBar.rebuild(
            accounts: store.accounts,
            selection: selection,
            signedOut: host.signedOutAccounts(),
            stalledTabs: host.stalledTabs(),
            indicators: indicatorLookup()
        )
        rebuildAccountsMenu()
        showActiveContent()
    }

    /// Redraws the tab indicators and nothing else (KTD-S8).
    ///
    /// This is the whole update path for a count that ticked over or a countdown
    /// that lost a minute, and it deliberately does not go near `refresh()`:
    /// that tears the active webview out of its container, re-pins it, moves
    /// first responder and fires `tabBecameVisible`. Doing that from a
    /// 30-second timer would take the caret out of a half-written reply twice a
    /// minute and re-run crashed-content recovery on tabs that never crashed.
    func refreshIndicators() {
        tabBar.updateIndicators(indicatorLookup())
    }

    /// One place that assembles what every tab shows, so `rebuild` and
    /// `refreshIndicators` can never disagree about it.
    private func indicatorLookup() -> (TabRef) -> TabIndicator.State {
        let signedOut = host.signedOutAccounts()
        let stalledTabs = host.stalledTabs()
        return { [host] tab in
            let unread = host.unreadCount(for: tab.accountId)
            let indicator = TabIndicator.resolve(
                view: tab.view,
                warning: AccountTabBar.warning(
                    tab: tab, signedOut: signedOut, stalledTabs: stalledTabs
                ),
                unread: unread,
                countdownSeconds: host.calendarCountdownSeconds(for: tab.accountId)
            )
            return TabIndicator.State(
                indicator: indicator,
                detail: TabIndicator.tooltipSuffix(
                    indicator,
                    unread: unread,
                    countdownDescription: host.calendarCountdownDescription(for: tab.accountId)
                )
            )
        }
    }

    /// Whether the content area already shows exactly this view and nothing
    /// else. Pure so the "do not re-pin what is already pinned" rule is a test.
    static func needsRepin(currentSubviews: [NSView], desired: NSView) -> Bool {
        currentSubviews.count != 1 || currentSubviews[0] !== desired
    }

    private func showActiveContent() {
        guard
            let selection,
            let account = store.account(id: selection.accountId),
            let session = host.session(for: selection.accountId),
            let webView = session.webView(for: selection.view)
        else {
            window.title = "MailSpace"
            if Self.needsRepin(currentSubviews: contentContainer.subviews, desired: emptyState) {
                contentContainer.subviews.forEach { $0.removeFromSuperview() }
                pin(emptyState, in: contentContainer)
            }
            pinned = nil
            return
        }

        // Every `refresh()` used to remove all subviews and re-pin, including a
        // re-click of the tab already showing and every drag drop. Each round
        // trip makes WebKit drop and rebuild the compositing backing store for
        // that page, which is real repaint work on a webview that has not
        // changed.
        if Self.needsRepin(currentSubviews: contentContainer.subviews, desired: webView) {
            contentContainer.subviews.forEach { $0.removeFromSuperview() }
            pin(webView, in: contentContainer)
        }
        window.title = "\(account.name) — \(selection.view.displayName)"

        // A real tab change still hands focus straight to the page, so Gmail's
        // own shortcuts work without an extra click (R15). A redundant refresh
        // does not, because yanking first responder back mid-typing is exactly
        // the cost the skip above exists to avoid.
        let isSelectionChange = pinned != selection
        if isSelectionChange {
            window.makeFirstResponder(webView)
        }
        pinned = selection
        // Bringing a tab up is also the cue to revive one whose content process
        // kept crashing, and to put the sign-in page in front of the user when
        // the account is signed out; the user asking to see it is the bound on
        // how often either is retried.
        host.tabBecameVisible(
            accountId: selection.accountId,
            view: selection.view,
            isSelectionChange: isSelectionChange
        )
    }

    /// The selected tab's webview object has been replaced underneath us — an
    /// automatic recycle. Force the re-pin the skip above would otherwise
    /// suppress, and hand focus to the new page.
    func replacedSelectedWebView() {
        pinned = nil
        refresh()
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
///
/// All tabs share one width — see `TabMetrics` for the rule and `layout()` for
/// where it is applied.
final class AccountTabBar: NSView {
    static let height: CGFloat = 42

    private static let addButtonWidth: CGFloat = 34
    private static let addButtonTrailingInset: CGFloat = 10
    private static let addButtonSpacing: CGFloat = 4
    private static let stackInset: CGFloat = 10

    /// The room the tabs themselves have in a bar this wide: everything left
    /// once the `+` button and the stack's own insets are taken out. Excludes
    /// the gaps *between* tabs, which `TabMetrics.uniformWidth` accounts for.
    static func availableTabWidth(inBarWidth barWidth: CGFloat) -> CGFloat {
        max(0, barWidth
            - addButtonWidth
            - addButtonTrailingInset
            - addButtonSpacing
            - stackInset * 2)
    }

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
    /// Set while a whole pass of indicators is being written, so the row is
    /// re-measured once at the end rather than once per changed tab.
    private var isBatchingIndicators = false

    init() {
        super.init(frame: .zero)

        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false

        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.spacing = TabMetrics.spacing
        tabStack.edgeInsets = NSEdgeInsets(
            top: 0, left: Self.stackInset, bottom: 0, right: Self.stackInset
        )
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
            tabScroll.trailingAnchor.constraint(
                equalTo: addButton.leadingAnchor, constant: -Self.addButtonSpacing
            ),

            tabStack.topAnchor.constraint(equalTo: tabScroll.contentView.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabScroll.contentView.bottomAnchor),
            tabStack.leadingAnchor.constraint(equalTo: tabScroll.contentView.leadingAnchor),

            addButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.addButtonTrailingInset
            ),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: Self.addButtonWidth),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — the UI is built programmatically") }

    /// Which warning this tab carries, if any.
    ///
    /// The evidence for *signed out* is the account's mail webview — the feed
    /// probe and the classified URL both live there — so it is shown on the
    /// Mail tab, which is also the tab whose selection is the recovery for it.
    /// *Not loading* is known per webview, so it goes on whichever tab is
    /// actually dead.
    ///
    /// Signed-out wins when both are true. They are nearly disjoint in practice
    /// (a signed-out tab is not recycled at all, by G1), and if the session is
    /// gone *and* the tab will not load, the sign-in is the thing to fix.
    ///
    /// Whichever it is, it outranks the count or countdown that would otherwise
    /// have the slot — see `TabIndicator.resolve`.
    /// - Parameter stalled: dead tabs known only per account. Lands on the Mail
    ///   tab, as it always has.
    /// - Parameter stalledTabs: the same fact at tab resolution, which is what
    ///   the live path supplies. A Calendar tab that will not load says so on
    ///   *itself*; marking its Mail sibling would point the user at a tab that
    ///   is working. Signed-out stays Mail-only either way, because its evidence
    ///   really is the mail feed probe.
    static func warning(
        tab: TabRef,
        signedOut: Set<UUID>,
        stalled: Set<UUID> = [],
        stalledTabs: Set<TabRef> = []
    ) -> TabWarning? {
        if tab.view == .mail {
            if signedOut.contains(tab.accountId) { return .signedOut }
            if stalled.contains(tab.accountId) { return .notLoading }
        }
        return stalledTabs.contains(tab) ? .notLoading : nil
    }

    func rebuild(
        accounts: [Account],
        selection: MainWindowController.Selection?,
        signedOut: Set<UUID> = [],
        stalled: Set<UUID> = [],
        stalledTabs: Set<TabRef> = [],
        indicators: (TabRef) -> TabIndicator.State = { _ in .none }
    ) {
        for view in tabStack.arrangedSubviews {
            tabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let tabs = TabOrder.tabs(for: accounts)
        tabCount = tabs.count

        for tab in tabs {
            guard let account = accounts.first(where: { $0.id == tab.accountId }) else { continue }
            let isSelected = selection.map { $0.accountId == tab.accountId && $0.view == tab.view } ?? false
            // A genuine rebuild — an account added, renamed, removed, a tab
            // dragged, a service toggled — starts with the number it should
            // already be showing, rather than flashing blank until the next
            // tick of a poller.
            var state = indicators(tab)
            if state == .none {
                state.indicator = Self.warning(
                    tab: tab, signedOut: signedOut, stalled: stalled, stalledTabs: stalledTabs
                ).map(TabIndicator.warning) ?? .none
            }
            let tabView = AccountTabView(
                account: account,
                view: tab.view,
                isSelected: isSelected,
                state: state
            )
            tabView.onNaturalWidthChanged = { [weak self] in self?.applyUniformTabWidth() }
            tabView.onClick = { [weak self] tab in self?.onSelectTab?(tab) }
            tabView.onEdit = { [weak self] id in self?.onEditAccount?(id) }
            tabView.onRemove = { [weak self] id in self?.onRemoveAccount?(id) }
            tabView.onDragBegan = { [weak self] in self?.isDragging = true }
            tabStack.addArrangedSubview(tabView)
        }
        // A rebuild is every change that can alter the widest label: an account
        // added, renamed or removed, a service toggled, a tab dragged. Sizing
        // here rather than only on the next resize means the new set of tabs is
        // already even by the time it is drawn.
        applyUniformTabWidth()
        tabStack.layoutSubtreeIfNeeded()
    }

    /// Updates every tab's indicator in place — no teardown, no new views, no
    /// webview touched, first responder where it was (KTD-S8).
    ///
    /// The row is re-laid-out only when an indicator appeared or disappeared.
    /// A countdown ticking or a count climbing keeps the same fixed-width slot,
    /// so under the equal-width rule the whole bar stays exactly as wide as it
    /// was — which is the difference between a tab bar and a tab bar that
    /// breathes once a minute.
    func updateIndicators(_ indicators: (TabRef) -> TabIndicator.State) {
        // Each tab that gains or loses its indicator would otherwise ask for a
        // re-measure of the whole row on the spot, so a pass that changed three
        // tabs would size the bar three times over. Held until the pass is done
        // and then sized once.
        isBatchingIndicators = true
        var geometryChanged = false
        for tabView in tabStack.arrangedSubviews.compactMap({ $0 as? AccountTabView }) {
            let new = indicators(tabView.tab)
            if TabIndicator.needsRelayout(from: tabView.state.indicator, to: new.indicator) {
                geometryChanged = true
            }
            tabView.state = new
        }
        isBatchingIndicators = false

        guard geometryChanged else { return }
        applyUniformTabWidth()
        tabStack.layoutSubtreeIfNeeded()
    }

    /// The tabs currently in the bar, so a test can assert on the row's
    /// geometry without reaching through `arrangedSubviews` itself.
    var tabViewsForTesting: [AccountTabView] {
        tabStack.arrangedSubviews.compactMap { $0 as? AccountTabView }
    }

    /// The bar's own width decides whether the tabs get what they asked for, so
    /// the rule is re-applied on every resize as well as on every rebuild.
    override func layout() {
        super.layout()
        applyUniformTabWidth()
    }

    /// Gives every tab the one width `TabMetrics` computes for the set.
    ///
    /// Only changed widths are written back, so the layout pass this triggers
    /// settles on the second pass instead of looping.
    private func applyUniformTabWidth() {
        guard !isBatchingIndicators else { return }
        let tabViews = tabStack.arrangedSubviews.compactMap { $0 as? AccountTabView }
        guard !tabViews.isEmpty else { return }

        let width = TabMetrics.uniformWidth(
            naturalWidths: tabViews.map(\.naturalWidth),
            available: Self.availableTabWidth(inBarWidth: bounds.width)
        )
        for tabView in tabViews where tabView.assignedWidth != width {
            tabView.assignedWidth = width
        }
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

    let tab: AccountTabBar.Tab
    private let tint: NSColor
    private let selected: Bool

    var onClick: ((AccountTabBar.Tab) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onDragBegan: (() -> Void)?
    /// The tab has gained or lost its accessory, so the bar has to re-decide
    /// the one width every tab shares.
    var onNaturalWidthChanged: (() -> Void)?

    /// Set on mouse-down and cleared once a drag starts, so a press that never
    /// moves is a click and a press that moves is a reorder.
    private var pressOrigin: NSPoint?

    /// The label's measured width, taken once at init in the selected weight.
    private let labelWidth: CGFloat
    private let baseDescription: String
    private let label = NSTextField(labelWithString: "")
    private let pill = TabAccessoryPill()
    /// The two ways the content group can end: at the pill, or at the label
    /// when there is no pill. Exactly one is active, which is what makes a
    /// hidden accessory cost no width at all.
    private var contentEndsAtPill: NSLayoutConstraint!
    private var contentEndsAtLabel: NSLayoutConstraint!

    /// What this tab's trailing slot is showing. Assigning it redraws the pill
    /// and rewrites the words; it does not rebuild anything.
    var state: TabIndicator.State {
        didSet {
            guard state != oldValue else { return }
            let changedGeometry = TabIndicator.needsRelayout(
                from: oldValue.indicator, to: state.indicator
            )
            applyState()
            guard changedGeometry else { return }
            invalidateIntrinsicContentSize()
            onNaturalWidthChanged?()
        }
    }

    /// What this tab would like to be, measured from its own content. The bar
    /// collects these, takes the widest, and hands every tab the same
    /// `assignedWidth`.
    ///
    /// Computed rather than stored, because an indicator that appears has to
    /// widen this tab — and, under the equal-width rule, every tab beside it.
    var naturalWidth: CGFloat {
        TabMetrics.naturalWidth(
            labelWidth: labelWidth,
            accessoryWidth: state.indicator.accessoryWidth
        )
    }

    /// The width the bar has decided every tab gets. Same for every tab in the
    /// bar, always.
    var assignedWidth: CGFloat = TabMetrics.minimumWidth {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// The tab is sized by the bar, not by its own content: hugging and
    /// compression resistance are both required horizontally, so `assignedWidth`
    /// is what the stack view gives it — and the label inside truncates instead.
    override var intrinsicContentSize: NSSize {
        NSSize(width: assignedWidth, height: TabMetrics.height)
    }

    /// - Parameter state: what the trailing accessory slot shows — the health
    ///   warning, the account's unread count, or the Calendar countdown. One
    ///   slot, one width, and `TabIndicator` decides which of the three gets it.
    init(
        account: Account,
        view: AccountView,
        isSelected: Bool,
        state: TabIndicator.State = .none
    ) {
        self.tab = AccountTabBar.Tab(accountId: account.id, view: view)
        self.tint = account.color.nsColor
        self.selected = isSelected
        self.state = state

        let labelText = "\(account.name) · \(view.displayName)"
        // Measured in the selected weight whatever this tab's state is, so
        // selecting a tab never resizes the row.
        self.labelWidth = TabMetrics.textWidth(labelText, font: TabMetrics.measurementFont)
        self.baseDescription = account.email.isEmpty ? labelText : "\(labelText) — \(account.email)"
        super.init(frame: .zero)

        wantsLayer = true

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: view == .mail ? "envelope.fill" : "calendar",
            accessibilityDescription: view.displayName
        )
        icon.contentTintColor = isSelected ? tint : tint.withAlphaComponent(0.75)
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = labelText
        label.font = TabMetrics.labelFont(selected: isSelected)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        // The tab's width is the bar's decision. When it is not enough for the
        // full name, the label is the part that gives way — with a tail
        // ellipsis, and the whole name still in the tooltip. The pill opposite
        // it resists to `.required`, so a narrow tab truncates the account name
        // and never the number.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)

        // The trailing accessory slot, built once and kept. Three things want
        // it — the health warning, the unread count, the Calendar countdown —
        // and `TabIndicator` decides which one gets it, with the warning always
        // winning. Rendering it in place rather than rebuilding the tab is what
        // lets a count tick over without touching the webview under it.
        //
        // The warning is filled orange rather than the account tint on purpose:
        // every other element in this bar is tinted with the account colour, so
        // the single non-tint thing in the tab bar is the one thing that cannot
        // be read as "this is the purple account".
        pill.configure(tint: tint, selected: isSelected)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        // Icon, label and any accessory travel as one group, centred in
        // whatever width the bar hands out. Left-aligning them would leave a
        // visible pocket of dead space at the trailing edge of every tab
        // shorter than the widest. `horizontalPadding` is the floor on each
        // side, not the actual inset.
        let content = NSLayoutGuide()
        addLayoutGuide(content)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        contentEndsAtPill = content.trailingAnchor.constraint(equalTo: pill.trailingAnchor)
        contentEndsAtLabel = content.trailingAnchor.constraint(equalTo: label.trailingAnchor)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: TabMetrics.horizontalPadding
            ),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -TabMetrics.horizontalPadding
            ),

            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: TabMetrics.iconSize),
            icon.heightAnchor.constraint(equalToConstant: TabMetrics.iconSize),

            label.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: TabMetrics.iconLabelSpacing
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            heightAnchor.constraint(equalToConstant: TabMetrics.height)
        ])

        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: TabMetrics.accessorySpacing
            ),
            pill.centerYAnchor.constraint(equalTo: centerYAnchor),
            // One width for every indicator, fixed for the life of the tab.
            // This is the constraint that stops a ticking countdown from
            // resizing the whole row.
            pill.widthAnchor.constraint(equalToConstant: TabIndicator.slotWidth),
            pill.heightAnchor.constraint(equalToConstant: SignedOutPill.size.height)
        ])
        applyState()

        let contextMenu = NSMenu()
        let settings = contextMenu.addItem(withTitle: "Account Settings…", action: #selector(edit(_:)), keyEquivalent: "")
        settings.target = self
        let removeItem = contextMenu.addItem(withTitle: "Remove Account…", action: #selector(removeAccount(_:)), keyEquivalent: "")
        removeItem.target = self
        menu = contextMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used — the UI is built programmatically") }

    /// Draws the slot and writes the words for it. Everything here is a
    /// property assignment — nothing is added, removed or re-created, which is
    /// the whole point of doing this outside `refresh()` (KTD-S8).
    private func applyState() {
        let indicator = state.indicator
        pill.indicator = indicator
        pill.isHidden = !indicator.isPresent
        // A hidden accessory has to cost no width, not just no ink: the content
        // group ends at the label instead, so the tab is exactly as wide as it
        // was before the indicator existed.
        contentEndsAtPill.isActive = indicator.isPresent
        contentEndsAtLabel.isActive = !indicator.isPresent

        if case .warning(let warning) = indicator {
            // A warning replaces the description rather than extending it:
            // what the tab is showing is no longer about this account's mail.
            toolTip = warning.tooltip
            setAccessibilityLabel("\(baseDescription). \(warning.accessibilitySuffix)")
            return
        }
        guard let detail = state.detail else {
            toolTip = baseDescription
            setAccessibilityLabel(baseDescription)
            return
        }
        toolTip = "\(baseDescription) — \(detail)"
        setAccessibilityLabel("\(baseDescription). \(detail)")
    }

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

/// The warning capsule in a tab's trailing accessory slot: this account's
/// Google session is gone and MailSpace has stopped receiving its mail.
/// What a tab's orange pill is warning about.
///
/// Two states, one slot, one shape: both mean "this tab is not showing you your
/// mail, and clicking it is the fix". Splitting them into two visual languages
/// would teach the user two things where one will do; only the words differ.
enum TabWarning: Equatable {
    /// The Google session has expired. Clicking goes to the sign-in page.
    case signedOut
    /// A rebuild of this tab failed and the retries ran out. Clicking loads it
    /// again — and so does the network coming back, without any click at all.
    case notLoading

    var tooltip: String {
        switch self {
        case .signedOut: return "Signed out of Google — click this tab to sign in again."
        case .notLoading: return "This tab could not reload — click it to try again."
        }
    }

    var accessibilitySuffix: String {
        switch self {
        case .signedOut: return "Signed out of Google."
        case .notLoading: return "Not loading."
        }
    }
}

final class SignedOutPill: NSView {
    static let size = NSSize(width: 24, height: 16)

    override var intrinsicContentSize: NSSize { Self.size }

    override func draw(_ dirtyRect: NSRect) {
        Self.drawWarning(in: bounds)
    }

    /// The orange capsule and its glyph, so the shared accessory slot and this
    /// view draw the identical thing rather than two lookalikes.
    static func drawWarning(in bounds: NSRect) {
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.systemOrange.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2).fill()

        guard
            let symbol = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Signed out"
            )
        else { return }
        let configured = symbol.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        ) ?? symbol
        let side: CGFloat = 11
        let rect = NSRect(
            x: body.midX - side / 2,
            y: body.midY - side / 2,
            width: side,
            height: side
        )
        // The white has to be composited in a context of its own. Done directly
        // into this view's context, `sourceAtop` sees the orange capsule
        // underneath as opaque and paints a white block over the whole glyph
        // box instead of only the glyph.
        let glyph = NSImage(size: rect.size, flipped: false) { bounds in
            configured.isTemplate = true
            configured.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        glyph.draw(in: rect)
    }
}

/// The one accessory in a tab's trailing slot, whichever of the three it is
/// currently showing (U10, U11).
///
/// A single view rather than one per kind, because the slot has to change what
/// it says without the tab being rebuilt around it: assigning `indicator` is a
/// redraw, and a redraw does not move first responder or disturb the webview.
/// Its width is fixed by the tab, so what it draws never changes its size.
final class TabAccessoryPill: NSView {
    var indicator: TabIndicator = .none {
        didSet {
            guard indicator != oldValue else { return }
            needsDisplay = true
        }
    }

    private var tint: NSColor = .secondaryLabelColor
    private var selected = false

    func configure(tint: NSColor, selected: Bool) {
        self.tint = tint
        self.selected = selected
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: TabIndicator.slotWidth, height: SignedOutPill.size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text: String
        switch indicator {
        case .none:
            return
        case .warning:
            SignedOutPill.drawWarning(in: bounds)
            return
        case .count(let value), .countdown(let value):
            text = value
        }

        // The same "the account tint is always present, selection deepens it"
        // rule the tab body and the icon already follow, at the same two
        // strengths. A low-alpha tint fill against the light chrome stays
        // legible for all eight palette entries — the number is never
        // white-on-saturated.
        let body = bounds.insetBy(dx: 0.5, dy: 0.5)
        tint.withAlphaComponent(selected ? 0.28 : 0.14).setFill()
        NSBezierPath(roundedRect: body, xRadius: body.height / 2, yRadius: body.height / 2).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: TabIndicator.font,
            .foregroundColor: selected ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // Centred in the fixed slot, so `(5m)` and `(45m)` sit in the same
        // place rather than growing out of one edge.
        (text as NSString).draw(
            at: NSPoint(x: body.midX - size.width / 2, y: body.midY - size.height / 2),
            withAttributes: attributes
        )
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
