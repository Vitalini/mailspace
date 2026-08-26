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

/// Which frames may raise a native notification.
///
/// Unlike the autofill handler, the shim cannot hide in its own content world:
/// it replaces `window.Notification` and
/// `ServiceWorkerRegistration.prototype.showNotification`, which only works in
/// the page's own world, and a page-world script can only reach a page-world
/// handler. So `window.webkit.messageHandlers.mailspaceNotify` is reachable
/// from any script in any frame of any page an account webview loads, and the
/// origin check *is* the boundary: without it a third-party frame — an ad, an
/// embed, anything reached through a link — could put native macOS banners on
/// screen carrying the user's account name.
enum NotificationOrigin {
    /// The hosts each view's real notifications come from.
    static func hosts(for view: AccountView) -> Set<String> {
        switch view {
        case .mail: return ["mail.google.com", "mail.googlemail.com"]
        case .calendar: return ["calendar.google.com"]
        }
    }

    /// Top frame, https, one of the view's own hosts. Gmail's and Calendar's
    /// notifications are raised by the page itself and by the service-worker
    /// registration the page holds, both in the main frame.
    static func isTrusted(scheme: String, host: String, port: Int, isMainFrame: Bool, view: AccountView) -> Bool {
        guard isMainFrame else { return false }
        guard scheme.lowercased() == "https" else { return false }
        // WebKit reports 0 for a scheme's own default port.
        guard port == 0 || port == 443 else { return false }
        return hosts(for: view).contains(host.lowercased())
    }

    static func isTrusted(_ frame: WKFrameInfo, view: AccountView) -> Bool {
        let origin = frame.securityOrigin
        return isTrusted(
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port,
            isMainFrame: frame.isMainFrame,
            view: view
        )
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
            NotificationOrigin.isTrusted(message.frameInfo, view: view),
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
