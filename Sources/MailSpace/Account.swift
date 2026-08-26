import Foundation

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

    init(
        id: UUID = UUID(),
        name: String,
        email: String = "",
        mailEnabled: Bool = true,
        calendarEnabled: Bool = true,
        lastView: AccountView = .mail
    ) {
        self.id = id
        self.name = name
        self.email = email
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
        self.init(id: id, name: name, email: email, mailEnabled: mail, calendarEnabled: calendar, lastView: lastView)
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
