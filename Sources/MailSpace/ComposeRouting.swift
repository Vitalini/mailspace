import Foundation

/// Which account a `mailto:` link composes from (G1).
///
/// Pure on purpose: the whole point of the setting is that the answer stops
/// depending on which tab happened to be frontmost, and that rule is worth
/// asserting in a test rather than reading out of an `AppDelegate`.
enum ComposeRouting {
    enum Resolution: Equatable {
        /// Compose here, no question asked.
        case account(UUID)
        /// Ask, offering these accounts in this order.
        case ask([UUID])
        /// Nowhere to compose — no account has Mail switched on.
        case none
    }

    /// - Parameters:
    ///   - accounts: the Mail-capable accounts in the order the tab bar shows
    ///     them; anything with Mail switched off is ignored here.
    ///   - selected: the account whose tab is on screen, if any.
    static func resolve(setting: ComposeFrom, selected: UUID?, accounts: [Account]) -> Resolution {
        let mailAccounts = accounts.filter(\.mailEnabled).map(\.id)
        guard let first = mailAccounts.first else { return .none }

        // Today's rule, kept exactly: the account on screen while it has Mail
        // switched on, otherwise the first account that does.
        func followingCurrentTab() -> Resolution {
            if let selected, mailAccounts.contains(selected) { return .account(selected) }
            return .account(first)
        }

        switch setting {
        case .current:
            return followingCurrentTab()
        case .fixed(let id):
            // An account that has since been removed, or has had Mail switched
            // off, degrades to the current-tab rule rather than dropping the
            // compose on the floor.
            return mailAccounts.contains(id) ? .account(id) : followingCurrentTab()
        case .ask:
            // Asking is pointless when there is only one possible answer.
            return mailAccounts.count == 1 ? .account(first) : .ask(mailAccounts)
        }
    }
}
