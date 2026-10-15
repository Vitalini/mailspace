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

    /// `userInfo` keys a category's notification carries.
    enum InfoKey {
        /// The code, decided once at post time and never re-extracted: the
        /// button's promise is fixed when the banner is drawn. Notification
        /// Center already holds the body that contains it.
        static let code = "oneTimeCode"
    }

    enum ActionId {
        static let copyCode = "com.vitalii.MailSpace.action.copyCode"
    }

    var identifier: String {
        switch self {
        case .oneTimeCode: return "com.vitalii.MailSpace.category.oneTimeCode"
        }
    }

    /// No `.foreground`: the press is delivered without activating MailSpace
    /// or switching tabs.
    var actions: [UNNotificationAction] {
        switch self {
        case .oneTimeCode:
            return [UNNotificationAction(identifier: ActionId.copyCode, title: "Copy Code", options: [])]
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
}
