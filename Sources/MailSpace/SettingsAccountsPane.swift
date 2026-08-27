import AppKit

/// Settings ▸ Accounts — A1…A5.
///
/// The pane owns three checkboxes per account and one app-level pop-up. It owns
/// no account *logic*: ＋, − and **Edit Account…** call the same three
/// `AccountHosting` functions the tab context menu, the Accounts menu and the
/// tab bar's ＋ already call. It never constructs an `AccountEditor`, never
/// removes an account itself, and reproduces no part of the removal teardown —
/// that ordering is a bug someone already paid for, and an earlier build's
/// version of it reported success while the Google session was still on disk.
final class SettingsAccountsPane: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    /// Which of the three buttons under the table are live. Pure so the rule is
    /// a test rather than a click.
    enum Buttons {
        /// ＋ is always live; − and Edit need a selected row.
        static func addEnabled() -> Bool { true }

        static func removeEnabled(selectedRow: Int, rowCount: Int) -> Bool {
            (0..<rowCount).contains(selectedRow)
        }

        static func editEnabled(selectedRow: Int, rowCount: Int) -> Bool {
            removeEnabled(selectedRow: selectedRow, rowCount: rowCount)
        }

        /// Where the pane's own selection lands after a removal: the row that
        /// took the removed one's place, or the last row when it was the last
        /// one. Local UI state, and the only thing this pane decides about
        /// selection — the main window's is `reconciledSelection`'s job.
        static func selectionAfterRemoval(removedRow: Int, newRowCount: Int) -> Int? {
            guard newRowCount > 0 else { return nil }
            return min(max(removedRow, 0), newRowCount - 1)
        }
    }

    private enum Column {
        static let account = NSUserInterfaceItemIdentifier("account")
        static let mail = NSUserInterfaceItemIdentifier("mailAlerts")
        static let calendar = NSUserInterfaceItemIdentifier("calendarAlerts")
        static let badge = NSUserInterfaceItemIdentifier("countInBadge")
    }

    private unowned let host: AccountHosting
    private let settings: AppSettings

    private let tableView = NSTableView()
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let editButton = NSButton(title: "Edit Account…", target: nil, action: nil)
    private let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scopeCaption = NSTextField(labelWithString: "")

    /// The rows as they are drawn right now. Read by the checkbox actions, so
    /// it has to be the same snapshot the table was reloaded from.
    private var accounts: [Account] = []

    /// The row a removal was started from, so the pane's own selection can land
    /// on whatever takes its place. Local UI state and nothing more.
    private var pendingSelectionRow: Int?

    init(accounts host: AccountHosting, settings: AppSettings = .shared) {
        self.host = host
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MailSpace builds its UI in code")
    }

    override func loadView() {
        buildTable()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true

        let buttons = buttonRow()

        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        for scope in BadgeScope.allCases {
            scopePopup.addItem(withTitle: scope.displayName)
            scopePopup.lastItem?.representedObject = scope.rawValue
        }
        let scopeLabel = NSTextField(labelWithString: "Dock badge counts:")
        let scopeRow = NSStackView(views: [scopeLabel, scopePopup]).horizontal()

        scopeCaption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        scopeCaption.textColor = .secondaryLabelColor
        scopeCaption.lineBreakMode = .byWordWrapping
        scopeCaption.maximumNumberOfLines = 2
        scopeCaption.preferredMaxLayoutWidth = 480

        let stack = NSStackView(views: [scroll, buttons, scopeRow, scopeCaption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: scroll)
        stack.setCustomSpacing(16, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = content
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// Re-reads the account list. Called on every account change (KTD-S10) and
    /// whenever the window opens, so a change made while Settings was closed is
    /// never missed.
    func reload() {
        guard isViewLoaded else { return }
        let selectedId = selectedAccountId()
        let removedRow = pendingSelectionRow
        pendingSelectionRow = nil
        accounts = host.accountStore.accounts
        tableView.reloadData()
        if let selectedId, let row = accounts.firstIndex(where: { $0.id == selectedId }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else if
            let removedRow,
            let row = Buttons.selectionAfterRemoval(removedRow: removedRow, newRowCount: accounts.count)
        {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        }
        scopePopup.selectItem(at: BadgeScope.allCases.firstIndex(of: settings.badgeScope) ?? 0)
        scopeCaption.stringValue = settings.badgeScope == .primary
            ? "Matches the number Gmail shows on its own Primary tab."
            : "Includes Promotions and Social, so this number runs higher than Gmail's own."
        updateButtons()
    }

    // MARK: - Table

    private func buildTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 38
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editSelected(_:))
        tableView.menu = rowMenu()

        // A header wide enough for its own title: "Count in Dock badge" does not
        // fit a column this narrow, so the column says "Dock badge" and the
        // tooltip — and the pop-up underneath — carry the rest.
        for (identifier, title, tooltip, width) in [
            (Column.account, "Account", "", CGFloat(190)),
            (Column.mail, "Mail alerts", "Show a banner for this account's mail", CGFloat(78)),
            (Column.calendar, "Calendar alerts", "Show a banner for this account's calendar", CGFloat(100)),
            (Column.badge, "Dock badge", "Count this account in the Dock badge", CGFloat(105))
        ] {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.headerToolTip = tooltip.isEmpty ? nil : tooltip
            column.width = width
            tableView.addTableColumn(column)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { accounts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, accounts.indices.contains(row) else { return nil }
        let account = accounts[row]

        if tableColumn.identifier == Column.account {
            return Self.accountCell(for: account)
        }

        let flag: AccountStore.Flag
        let value: Bool
        let enabled: Bool
        switch tableColumn.identifier {
        case Column.mail:
            flag = .notifyMail
            value = account.notifyMail
            enabled = account.mailEnabled
        case Column.calendar:
            flag = .notifyCalendar
            value = account.notifyCalendar
            enabled = account.calendarEnabled
        default:
            flag = .countInBadge
            value = account.countInBadge
            enabled = account.mailEnabled
        }

        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleFlag(_:)))
        // A service the account does not offer has nothing to alert about, so
        // the box reads as off and cannot be clicked. The truth is already in
        // `Account.isEnabled`; this does not store a second copy of it.
        box.state = (value && enabled) ? .on : .off
        box.isEnabled = enabled
        box.tag = Self.tag(row: row, flag: flag)
        box.setAccessibilityLabel("\(tableColumn.title) — \(account.name)")
        return Self.centered(box)
    }

    /// A bare checkbox in a table column sits against its leading edge, under a
    /// centred header. Centring it is what makes the column read as a column.
    private static func centered(_ control: NSView) -> NSView {
        let container = NSView()
        control.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            control.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private static func accountCell(for account: Account) -> NSView {
        let swatch = NSImageView(image: account.color.dotImage(diameter: 12))
        swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true

        let name = NSTextField(labelWithString: account.name)
        name.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingTail

        let email = NSTextField(labelWithString: account.email)
        email.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        email.textColor = .secondaryLabelColor
        email.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: account.email.isEmpty ? [name] : [name, email])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let row = NSStackView(views: [swatch, text]).horizontal(spacing: 8)
        return row
    }

    // MARK: - Per-account flags (A2, A3, A4)

    /// Row and flag in one `tag`, because an `NSButton` has one.
    private static func tag(row: Int, flag: AccountStore.Flag) -> Int {
        let flagIndex: Int
        switch flag {
        case .notifyMail: flagIndex = 0
        case .notifyCalendar: flagIndex = 1
        case .countInBadge: flagIndex = 2
        }
        return row * 10 + flagIndex
    }

    @objc private func toggleFlag(_ sender: NSButton) {
        let row = sender.tag / 10
        guard accounts.indices.contains(row) else { return }
        let flag: AccountStore.Flag
        switch sender.tag % 10 {
        case 0: flag = .notifyMail
        case 1: flag = .notifyCalendar
        default: flag = .countInBadge
        }

        let id = accounts[row].id
        host.accountStore.setFlag(flag, to: sender.state == .on, for: id)
        accounts = host.accountStore.accounts
        if flag == .countInBadge {
            // Re-totals now rather than at the next poll: the number is already
            // in hand, only the set of accounts being added up changed.
            host.badgeInputsChanged(repoll: false)
        }
    }

    // MARK: - Add / edit / remove (A1) — every one of them through the host

    private func buttonRow() -> NSView {
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Account")
        addButton.bezelStyle = .smallSquare
        addButton.target = self
        addButton.action = #selector(addAccount(_:))
        addButton.setAccessibilityLabel("Add Account")
        addButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove Account")
        removeButton.bezelStyle = .smallSquare
        removeButton.target = self
        removeButton.action = #selector(removeSelected(_:))
        removeButton.setAccessibilityLabel("Remove Account")
        removeButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelected(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [addButton, removeButton, spacer, editButton]).horizontal(spacing: 6)
        row.widthAnchor.constraint(equalToConstant: 512).isActive = true
        return row
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Account Settings…", action: #selector(editClickedRow(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Remove Account…", action: #selector(removeClickedRow(_:)), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func addAccount(_ sender: Any?) {
        host.requestAddAccount()
    }

    @objc private func editSelected(_ sender: Any?) {
        guard let id = selectedAccountId() else { return }
        host.requestEditAccount(id: id)
    }

    @objc private func removeSelected(_ sender: Any?) {
        guard let id = selectedAccountId() else { return }
        remove(id: id, row: tableView.selectedRow)
    }

    @objc private func editClickedRow(_ sender: Any?) {
        guard accounts.indices.contains(tableView.clickedRow) else { return }
        host.requestEditAccount(id: accounts[tableView.clickedRow].id)
    }

    @objc private func removeClickedRow(_ sender: Any?) {
        let row = tableView.clickedRow
        guard accounts.indices.contains(row) else { return }
        remove(id: accounts[row].id, row: row)
    }

    private func remove(id: UUID, row: Int) {
        // The confirmation belongs to the window that asked — a sheet here, not
        // a dialog floating over the main window about an account the user is
        // not looking at. Everything after the confirmation is the host's.
        host.requestRemoveAccount(id: id, presentedOn: view.window)
        // `reload()` arrives from the host once the removal has actually run;
        // this only decides where the pane's own selection lands afterwards.
        pendingSelectionRow = row
    }

    private func selectedAccountId() -> UUID? {
        let row = tableView.selectedRow
        guard accounts.indices.contains(row) else { return nil }
        return accounts[row].id
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    private func updateButtons() {
        addButton.isEnabled = Buttons.addEnabled()
        removeButton.isEnabled = Buttons.removeEnabled(selectedRow: tableView.selectedRow, rowCount: accounts.count)
        editButton.isEnabled = Buttons.editEnabled(selectedRow: tableView.selectedRow, rowCount: accounts.count)
    }

    // MARK: - Badge scope (A5)

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        guard
            let raw = sender.selectedItem?.representedObject as? String,
            let scope = BadgeScope(rawValue: raw)
        else { return }
        settings.badgeScope = scope
        // The number means something different now, so it is fetched again
        // rather than relabelled.
        host.badgeInputsChanged(repoll: true)
        reload()
    }
}
