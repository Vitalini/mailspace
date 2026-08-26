import Foundation

/// The two web surfaces MailSpace hosts for every account.
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
struct Account: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var lastView: AccountView

    init(id: UUID = UUID(), name: String, lastView: AccountView = .mail) {
        self.id = id
        self.name = name
        self.lastView = lastView
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lastView = try container.decodeIfPresent(AccountView.self, forKey: .lastView) ?? .mail
    }
}
