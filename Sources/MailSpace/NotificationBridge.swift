import AppKit
import UserNotifications
import WebKit

/// The account-aware parts of a web notification, kept pure so they can be
/// tested without a notification centre.
enum NotificationContent {
    /// A notification with neither title nor body still has to identify itself,
    /// so the account name is the floor.
    static func title(payloadTitle: String, accountName: String) -> String {
        payloadTitle.isEmpty ? accountName : payloadTitle
    }

    /// Web `tag` semantics are replace-not-stack. Scoping the tag by account
    /// keeps two accounts' identically tagged notifications apart, while an
    /// untagged notification gets a fresh identity and replaces nothing.
    static func identifier(tag: String, accountId: UUID) -> String {
        tag.isEmpty ? UUID().uuidString : "\(accountId.uuidString)|\(tag)"
    }
}

/// Where a clicked notification should take the user.
protocol NotificationRouting: AnyObject {
    func focusAccount(_ accountId: UUID, view: AccountView)
}

/// Carries web notifications from the injected shim to
/// `UNUserNotificationCenter`, and clicks back to the originating account.
final class NotificationBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    private enum InfoKey {
        static let accountId = "accountId"
        static let view = "view"
    }

    weak var locator: SessionLocating?
    weak var router: NotificationRouting?

    /// Called after a mail notification lands, so the unread badge can catch up
    /// without waiting for the next poll.
    var onMailNotification: ((UUID) -> Void)?

    private var center: UNUserNotificationCenter? {
        // `UNUserNotificationCenter.current()` traps in a process without a
        // bundle identifier — only reachable when running the bare binary.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// Registers as the notification delegate and asks for permission once.
    func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == NotificationShim.handlerName,
            let payload = message.body as? [String: Any],
            let webView = message.webView,
            let session = locator?.session(hosting: webView),
            let view = session.view(for: webView),
            let account = locator?.account(for: session.accountId)
        else { return }

        post(
            title: (payload["title"] as? String) ?? "",
            body: (payload["body"] as? String) ?? "",
            tag: (payload["tag"] as? String) ?? "",
            account: account,
            view: view
        )
    }

    private func post(title: String, body: String, tag: String, account: Account, view: AccountView) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = NotificationContent.title(payloadTitle: title, accountName: account.name)
        // userInfo only routes the click; the subtitle is what actually tells
        // the user which account the notification came from.
        content.subtitle = account.name
        content.body = body
        content.sound = .default
        content.userInfo = [
            InfoKey.accountId: account.id.uuidString,
            InfoKey.view: view.rawValue
        ]

        let identifier = NotificationContent.identifier(tag: tag, accountId: account.id)

        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                Log.error("could not post notification: \(error.localizedDescription)")
            }
        }

        if view == .mail {
            let accountId = account.id
            DispatchQueue.main.async { [weak self] in
                self?.onMailNotification?(accountId)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Banners matter most when MailSpace is frontmost on another account.
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if
            let rawId = info[InfoKey.accountId] as? String,
            let accountId = UUID(uuidString: rawId),
            let rawView = info[InfoKey.view] as? String,
            let view = AccountView(rawValue: rawView)
        {
            DispatchQueue.main.async { [weak self] in
                self?.router?.focusAccount(accountId, view: view)
            }
        }
        completionHandler()
    }
}
