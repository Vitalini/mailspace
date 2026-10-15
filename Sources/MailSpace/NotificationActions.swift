import AppKit
import UserNotifications

/// Every notification category MailSpace registers, and the buttons each one
/// carries.
///
/// One owner on purpose: `setNotificationCategories` replaces the whole set,
/// so a second registration site would silently delete this one's categories.
/// A new action is a new case here plus a branch in `handle`; registration and
/// dispatch stay as they are.
enum NotificationCategory: CaseIterable {
    /// A Mail notification carrying one confident sign-in code (`OneTimeCode`).
    case oneTimeCode
    /// A Calendar reminder carrying one allow-listed meeting link
    /// (`MeetingLink`).
    case meetingJoin

    /// `userInfo` keys a category's notification carries.
    enum InfoKey {
        /// The code, decided once at post time and never re-extracted: the
        /// button's promise is fixed when the banner is drawn. Notification
        /// Center already holds the body that contains it.
        static let code = "oneTimeCode"
        /// The meeting URL, decided at post time from the reminder's own data
        /// or the Calendar page. Re-checked against the allow-list on press.
        static let meetingURL = "meetingURL"
    }

    enum ActionId {
        static let copyCode = "com.vitalii.MailSpace.action.copyCode"
        static let join = "com.vitalii.MailSpace.action.join"
    }

    var identifier: String {
        switch self {
        case .oneTimeCode: return "com.vitalii.MailSpace.category.oneTimeCode"
        case .meetingJoin: return "com.vitalii.MailSpace.category.meetingJoin"
        }
    }

    /// No `.foreground`: the press is delivered without activating MailSpace
    /// or switching tabs.
    var actions: [UNNotificationAction] {
        switch self {
        case .oneTimeCode:
            return [UNNotificationAction(identifier: ActionId.copyCode, title: "Copy Code", options: [])]
        case .meetingJoin:
            return [UNNotificationAction(identifier: ActionId.join, title: "Join", options: [])]
        }
    }

    var category: UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: actions, intentIdentifiers: [], options: [])
    }

    /// What `NotificationBridge.start()` registers, in its one call.
    static var registered: Set<UNNotificationCategory> {
        Set(allCases.map(\.category))
    }

    /// Runs a category's own action. Returns `false` for anything else — a
    /// body click, a dismissal — so the caller keeps its usual routing.
    ///
    /// The pasteboard is a parameter so tests never touch the user's clipboard.
    /// Nothing from the notification is ever logged.
    static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], pasteboard: NSPasteboard) -> Bool {
        switch actionIdentifier {
        case ActionId.copyCode:
            guard let code = userInfo[InfoKey.code] as? String, !code.isEmpty else {
                Log.error("Copy Code pressed on a notification that carries no code")
                return true
            }
            pasteboard.clearContents()
            pasteboard.setString(code, forType: .string)
            return true
        default:
            return false
        }
    }

    /// What a Join press did.
    enum JoinResult: Equatable {
        /// Not a Join press; the caller keeps its usual routing.
        case notHandled
        /// The meeting was handed to the default browser.
        case opened
        /// The stored link is missing or fails the allow-list: nothing was
        /// opened, and the caller shows the account's Calendar tab instead.
        case focusCalendar
    }

    /// Runs the Join action. The stored URL is checked against the allow-list
    /// again before anything is opened (R30); `open` is a parameter so tests
    /// never launch a browser. The URL is never logged (R31).
    static func handleJoin(actionIdentifier: String, userInfo: [AnyHashable: Any], open: (URL) -> Void) -> JoinResult {
        guard actionIdentifier == ActionId.join else { return .notHandled }
        guard let raw = userInfo[InfoKey.meetingURL] as? String,
              MeetingLink.isAllowed(raw),
              let url = URL(string: raw)
        else {
            Log.error("Join pressed on a notification without an allowed meeting link")
            return .focusCalendar
        }
        open(url)
        return .opened
    }
}
