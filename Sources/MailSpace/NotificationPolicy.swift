import UserNotifications

/// Whether a web notification is allowed to become a native one, and how it is
/// allowed to arrive.
///
/// Its own file, and pure, for one reason: this is a *preference*, and it must
/// never be folded into `NotificationOrigin.isTrusted`, which is a security
/// boundary. The origin check decides whether the page may raise a notification
/// at all; this one decides whether the user wants to see it.
enum NotificationPolicy {
    /// A2/A3. A tab can stop interrupting without being deleted.
    static func shouldPost(account: Account, view: AccountView) -> Bool {
        guard account.isEnabled(view) else { return false }
        switch view {
        case .mail: return account.notifyMail
        case .calendar: return account.notifyCalendar
        }
    }

    /// B2. Gmail's own `silent` flag, which the shim used to read off the
    /// options object and throw away.
    ///
    /// This is why there is no sound picker: the page already knows when it
    /// does not want to make noise, and macOS's per-app notification settings
    /// can override the rest.
    static func sound(silent: Bool) -> UNNotificationSound? {
        silent ? nil : .default
    }

    /// B1. No banner for the tab already on screen.
    ///
    /// The notification still lands in Notification Center — it is a record of
    /// something that happened — but a banner announcing the page the user is
    /// looking at is noise with no answer to it.
    static func suppressBanner(appIsActive: Bool, notification: TabRef?, selection: TabRef?) -> Bool {
        guard appIsActive, let notification, let selection else { return false }
        return notification == selection
    }
}
