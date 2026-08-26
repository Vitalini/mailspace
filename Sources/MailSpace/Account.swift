import AppKit

/// The two web surfaces MailSpace can host for an account. An account enables
/// either or both.
enum AccountView: String, Codable, CaseIterable {
    case mail
    case calendar

    var displayName: String {
        switch self {
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        }
    }

    /// Each account has its own isolated data store, so there is only ever one
    /// signed-in identity per store — `/u/0/` is always the right entry point
    /// and Gmail's own multi-account switcher never comes into play.
    var url: URL {
        switch self {
        case .mail: return URL(string: "https://mail.google.com/mail/u/0/")!
        case .calendar: return URL(string: "https://calendar.google.com/calendar/u/0/r")!
        }
    }
}

/// One entry in the flattened tab list: an account plus one of its services.
struct TabRef: Equatable, Hashable {
    let accountId: UUID
    let view: AccountView

    /// Round-trips through a drag pasteboard.
    var identifier: String { "\(accountId.uuidString)|\(view.rawValue)" }

    init(accountId: UUID, view: AccountView) {
        self.accountId = accountId
        self.view = view
    }

    init?(identifier: String) {
        let parts = identifier.split(separator: "|", maxSplits: 1)
        guard
            parts.count == 2,
            let id = UUID(uuidString: String(parts[0])),
            let view = AccountView(rawValue: String(parts[1]))
        else { return nil }
        self.init(accountId: id, view: view)
    }
}

/// The flattened tab list, in the order the user has dragged it into.
///
/// Order is free-form: a service tab moves independently of its account
/// sibling, so `[Work · Mail] [Personal · Mail] [Work · Calendar]` is a valid
/// arrangement. Each account stores one index per service; the store keeps
/// those indices complete, so this is a plain sort.
enum TabOrder {
    static func tabs(for accounts: [Account]) -> [TabRef] {
        accounts
            .flatMap { account in
                account.enabledViews.map { view in
                    (tab: TabRef(accountId: account.id, view: view),
                     order: account.order(for: view) ?? Int.max)
                }
            }
            .enumerated()
            // Sorting on (order, original position) keeps the sort stable, so
            // tabs with no index yet fall in after the ordered ones rather
            // than shuffling.
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.tab)
    }
}

/// The palette an account's tabs are tinted with, so several accounts stay
/// distinguishable at a glance. A fixed set rather than a free colour picker:
/// every choice stays legible against the light chrome.
enum AccountColor: String, Codable, CaseIterable {
    case blue, purple, pink, red, orange, green, teal, graphite

    var displayName: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .blue: return NSColor.systemBlue
        case .purple: return NSColor.systemPurple
        case .pink: return NSColor.systemPink
        case .red: return NSColor.systemRed
        case .orange: return NSColor.systemOrange
        case .green: return NSColor.systemGreen
        case .teal: return NSColor.systemTeal
        case .graphite: return NSColor.systemGray
        }
    }

    /// Default colour for the n-th account, so a new account is never the same
    /// colour as the one before it.
    static func forPosition(_ index: Int) -> AccountColor {
        let all = AccountColor.allCases
        return all[((index % all.count) + all.count) % all.count]
    }
}

/// A Google account as MailSpace knows it. `id` doubles as the identifier of
/// the account's `WKWebsiteDataStore`, which is what keeps sessions isolated.
///
/// `email` is the Google address used for sign-in autofill and as the Keychain
/// item's account name. The password itself is never stored here — only in the
/// Keychain (see `KeychainStore`).
struct Account: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var email: String
    var mailEnabled: Bool
    var calendarEnabled: Bool
    var lastView: AccountView

    /// `nil` for an account written before colours existed. The store
    /// backfills those on load so no two accounts start out identical.
    private var explicitColor: AccountColor?

    /// Position of this account's Mail and Calendar tabs in the flattened tab
    /// bar. The store keeps them filled in; `nil` only ever appears for a file
    /// written before tabs were reorderable.
    private var mailOrder: Int?
    private var calendarOrder: Int?

    var color: AccountColor {
        get { explicitColor ?? .blue }
        set { explicitColor = newValue }
    }

    var hasExplicitColor: Bool { explicitColor != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, email, mailEnabled, calendarEnabled, lastView
        case explicitColor = "color"
        case mailOrder, calendarOrder
    }

    func order(for view: AccountView) -> Int? {
        switch view {
        case .mail: return mailOrder
        case .calendar: return calendarOrder
        }
    }

    mutating func setOrder(_ value: Int?, for view: AccountView) {
        switch view {
        case .mail: mailOrder = value
        case .calendar: calendarOrder = value
        }
    }

    /// True when every enabled service already has a tab position.
    var hasCompleteTabOrder: Bool {
        enabledViews.allSatisfy { order(for: $0) != nil }
    }

    init(
        id: UUID = UUID(),
        name: String,
        email: String = "",
        mailEnabled: Bool = true,
        calendarEnabled: Bool = true,
        color: AccountColor? = nil,
        lastView: AccountView = .mail
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.explicitColor = color
        // An account with nothing enabled would have no views at all; Mail is
        // the sensible floor.
        self.mailEnabled = (mailEnabled || calendarEnabled) ? mailEnabled : true
        self.calendarEnabled = calendarEnabled
        self.lastView = lastView
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        let mail = try container.decodeIfPresent(Bool.self, forKey: .mailEnabled) ?? true
        let calendar = try container.decodeIfPresent(Bool.self, forKey: .calendarEnabled) ?? true
        let lastView = try container.decodeIfPresent(AccountView.self, forKey: .lastView) ?? .mail
        self.init(
            id: id,
            name: name,
            email: email,
            mailEnabled: mail,
            calendarEnabled: calendar,
            lastView: lastView
        )
        self.explicitColor = try container.decodeIfPresent(AccountColor.self, forKey: .explicitColor)
        self.mailOrder = try container.decodeIfPresent(Int.self, forKey: .mailOrder)
        self.calendarOrder = try container.decodeIfPresent(Int.self, forKey: .calendarOrder)
    }

    func isEnabled(_ view: AccountView) -> Bool {
        switch view {
        case .mail: return mailEnabled
        case .calendar: return calendarEnabled
        }
    }

    var enabledViews: [AccountView] {
        AccountView.allCases.filter(isEnabled)
    }

    /// The view to actually show: the remembered one while it is still
    /// enabled, otherwise the first enabled service.
    var effectiveView: AccountView? {
        isEnabled(lastView) ? lastView : enabledViews.first
    }
}
