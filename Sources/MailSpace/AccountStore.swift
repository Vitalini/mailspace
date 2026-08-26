import Foundation

/// Persists the account list to `accounts.json` under Application Support.
///
/// The store owns nothing but the metadata: the actual browser session for an
/// account lives in a `WKWebsiteDataStore` keyed by the account's `id`
/// (see `AccountSession`). Sidebar order is creation order; v1 has no
/// reordering.
final class AccountStore {
    private static let fileName = "accounts.json"

    /// The throwaway self-test identity keeps its own account list, so a probe
    /// can boot the whole app without reading — or rewriting — the accounts,
    /// colours and tab order of the app the user actually runs.
    static func folderName(isSelfTest: Bool) -> String {
        isSelfTest ? "MailSpace-SelfTest" : "MailSpace"
    }

    private let directory: URL
    private let fileURL: URL

    private(set) var accounts: [Account] = []

    /// False when `accounts.json` was there but could not be read in full —
    /// unparseable outright, or with a record skipped.
    ///
    /// `accounts` is then not the whole list, and anything that treats it as
    /// the whole list does damage: the launch sweep would read "no account
    /// claims this session" and delete a session that is very much claimed.
    /// A first run, with no file at all, is clean.
    private(set) var didLoadCleanly = true

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(
            folderName(isSelfTest: SelfTest.isSelfTestBundle),
            isDirectory: true
        )
    }

    init(directory: URL = AccountStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        load()
    }

    // MARK: - Queries

    func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func add(
        name: String,
        email: String = "",
        mailEnabled: Bool = true,
        calendarEnabled: Bool = true,
        color: AccountColor? = nil
    ) -> Account {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmedEmail.isEmpty ? "Account \(accounts.count + 1)" : trimmedEmail
        let account = Account(
            name: trimmedName.isEmpty ? fallback : trimmedName,
            email: trimmedEmail,
            mailEnabled: mailEnabled,
            calendarEnabled: calendarEnabled,
            color: color ?? .forPosition(accounts.count),
            lastView: mailEnabled ? .mail : .calendar
        )
        accounts.append(account)
        appendTabOrders(for: account.id)
        save()
        return account
    }

    /// Applies an edit from the account dialog. Returns the updated account.
    @discardableResult
    func update(
        id: UUID,
        name: String,
        email: String,
        mailEnabled: Bool,
        calendarEnabled: Bool,
        color: AccountColor
    ) -> Account? {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return nil }
        let existing = accounts[index]
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        var updated = Account(
            id: existing.id,
            name: trimmedName.isEmpty ? (trimmedEmail.isEmpty ? existing.name : trimmedEmail) : trimmedName,
            email: trimmedEmail,
            mailEnabled: mailEnabled,
            calendarEnabled: calendarEnabled,
            color: color,
            lastView: existing.lastView,
            // The account dialog knows nothing about the alert and badge
            // flags, so an edit carries them across rather than resetting
            // them to `true` through the memberwise init.
            notifyMail: existing.notifyMail,
            notifyCalendar: existing.notifyCalendar,
            countInBadge: existing.countInBadge
        )
        // The memberwise init starts from scratch, so carry the account's tab
        // positions across an edit — otherwise saving settings would shuffle
        // the tab bar.
        //
        // A service being switched off gives its slot up instead. `applyTabOrder`
        // only renumbers *enabled* tabs, so a slot kept by a disabled one goes
        // stale and starts colliding with whatever gets renumbered onto it —
        // and switching the service back on then wedged it mid-bar rather than
        // appending it, because `appendTabOrders` only fills slots that are nil.
        for view in AccountView.allCases {
            updated.setOrder(updated.isEnabled(view) ? existing.order(for: view) : nil, for: view)
        }
        // Never leave the account pointing at a service it no longer offers.
        if !updated.isEnabled(updated.lastView), let fallback = updated.enabledViews.first {
            updated.lastView = fallback
        }
        accounts[index] = updated
        appendTabOrders(for: updated.id)
        save()
        return accounts[index]
    }

    func remove(id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.remove(at: index)
        save()
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = trimmed
        save()
    }

    /// The three per-account switches the Accounts pane owns (A2, A3, A4).
    enum Flag {
        case notifyMail
        case notifyCalendar
        case countInBadge
    }

    /// Mirrors `setLastView`: one write, one save, no other state touched. The
    /// Settings pane never reaches past this into the account record.
    func setFlag(_ flag: Flag, to value: Bool, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        switch flag {
        case .notifyMail:
            guard accounts[index].notifyMail != value else { return }
            accounts[index].notifyMail = value
        case .notifyCalendar:
            guard accounts[index].notifyCalendar != value else { return }
            accounts[index].notifyCalendar = value
        case .countInBadge:
            guard accounts[index].countInBadge != value else { return }
            accounts[index].countInBadge = value
        }
        save()
    }

    func setLastView(_ view: AccountView, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].lastView != view,
              accounts[index].isEnabled(view)
        else { return }
        accounts[index].lastView = view
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            accounts = []
            return
        }
        do {
            // Decoding per record rather than as `[Account]`: one hand-edited
            // entry with an unknown enum value (`"lastView":"notes"`) would
            // otherwise fail the whole array, and the next save would make the
            // loss of every account permanent.
            let records = try JSONDecoder().decode([LenientRecord].self, from: data)
            let failures = records.compactMap(\.failure)
            for failure in failures {
                Log.error("skipping unreadable account in \(fileURL.path): \(failure)")
            }
            didLoadCleanly = failures.isEmpty
            accounts = records.compactMap(\.account)
            backfillColors()
            backfillTabOrder()
        } catch {
            // A corrupt or hand-edited file must never block launch: start
            // empty and let the next save rewrite it.
            Log.error("could not read \(fileURL.path): \(error)")
            didLoadCleanly = false
            accounts = []
        }
    }

    /// One element of `accounts.json`: either a decoded account, or the reason
    /// that record could not be read. Decoding never throws, so a single bad
    /// entry costs only itself.
    private struct LenientRecord: Decodable {
        let account: Account?
        let failure: String?

        init(from decoder: Decoder) throws {
            do {
                account = try Account(from: decoder)
                failure = nil
            } catch {
                account = nil
                failure = "\(error)"
            }
        }
    }

    /// Accounts written before tab colours existed have none; give each one a
    /// distinct colour rather than letting every tab come up blue.
    private func backfillColors() {
        var changed = false
        for index in accounts.indices where !accounts[index].hasExplicitColor {
            accounts[index].color = .forPosition(index)
            changed = true
        }
        if changed { save() }
    }

    /// Gives every enabled service a tab position, so ordering is a plain sort
    /// and a file written before tabs were reorderable still opens sensibly.
    private func backfillTabOrder() {
        guard accounts.contains(where: { !$0.hasCompleteTabOrder }) else { return }
        applyTabOrder(TabOrder.tabs(for: accounts))
    }

    /// Moves one tab to a new position in the flattened list. `index` is the
    /// slot in the *current* list the tab should land in.
    func moveTab(_ tab: TabRef, to index: Int) {
        var ordered = TabOrder.tabs(for: accounts)
        guard let from = ordered.firstIndex(of: tab) else { return }

        let moved = ordered.remove(at: from)
        // Removing the tab shifts everything after it left by one.
        let destination = min(max(index > from ? index - 1 : index, 0), ordered.count)
        guard destination != from else { return }
        ordered.insert(moved, at: destination)

        applyTabOrder(ordered)
    }

    private func applyTabOrder(_ ordered: [TabRef]) {
        for (position, tab) in ordered.enumerated() {
            guard let index = accounts.firstIndex(where: { $0.id == tab.accountId }) else { continue }
            accounts[index].setOrder(position, for: tab.view)
        }
        save()
    }

    /// A newly enabled service goes to the end of the tab bar rather than
    /// colliding with an existing position.
    private func appendTabOrders(for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        var next = (accounts.flatMap { account in
            AccountView.allCases.compactMap { account.order(for: $0) }
        }.max() ?? -1) + 1

        for view in accounts[index].enabledViews where accounts[index].order(for: view) == nil {
            accounts[index].setOrder(next, for: view)
            next += 1
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(accounts).write(to: fileURL, options: .atomic)
        } catch {
            Log.error("could not write \(fileURL.path): \(error)")
        }
    }
}
