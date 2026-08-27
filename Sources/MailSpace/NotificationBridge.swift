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
        /// A finished download rather than a web notification: clicking it
        /// reveals the file instead of switching tabs (G4).
        static let downloadPath = "downloadPath"
    }

    weak var locator: SessionLocating?
    weak var router: NotificationRouting?

    /// Called after a mail notification lands, so the unread badge can catch up
    /// without waiting for the next poll.
    var onMailNotification: ((UUID) -> Void)?

    /// The tab on screen right now, or `nil` when MailSpace has none. B1 reads
    /// it to decide whether a banner would be announcing the page the user is
    /// already looking at.
    var currentSelection: () -> TabRef? = { nil }

    private var center: UNUserNotificationCenter? {
        // `UNUserNotificationCenter.current()` traps in a process without a
        // bundle identifier — only reachable when running the bare binary.
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    /// What `start()` is allowed to ask the system for, decided by the identity
    /// the process is running under. This is the single place a permission
    /// prompt can come from, and it is why an automated run cannot raise one:
    ///
    /// * the throwaway self-test bundle asks **provisionally** — macOS grants
    ///   that silently, delivers the notifications quietly to Notification
    ///   Center (so a probe can still read them back) and never draws a prompt;
    /// * a self-test running under any other identity asks for **nothing**, so
    ///   even a hand-run `MAILSPACE_SELFTEST=… build/MailSpace.app/…` cannot put
    ///   an unanswerable prompt on screen for the real app;
    /// * the real app, launched by the user, asks the normal interactive way.
    ///
    /// - Returns: the options to request, or `nil` to not ask at all.
    static func authorizationOptions(
        bundleIdentifier: String?,
        selfTestActive: Bool
    ) -> UNAuthorizationOptions? {
        if SelfTest.isSelfTestBundle(bundleIdentifier) { return [.provisional, .alert, .sound, .badge] }
        if selfTestActive { return nil }
        return [.alert, .sound, .badge]
    }

    /// Registers as the notification delegate and asks for permission once.
    /// The completion reports whether the process ended up authorized, so a
    /// caller that is about to post a notification can wait for the answer
    /// instead of racing it.
    func start(completion: ((Bool) -> Void)? = nil) {
        guard let center else {
            completion?(false)
            return
        }
        center.delegate = self
        guard let options = Self.authorizationOptions(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            selfTestActive: SelfTest.isEnabled
        ) else {
            Log.error("notification authorization not requested: self-test running outside \(SelfTest.bundleIdentifier)")
            completion?(false)
            return
        }
        center.requestAuthorization(options: options) { granted, error in
            if let error {
                Log.error("notification authorization failed: \(error.localizedDescription)")
            }
            completion?(granted)
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

        // A preference, downstream of the origin check and never merged into
        // it: the origin check decides whether the page *may* raise a
        // notification, this decides whether the user wants to see it (A2/A3).
        guard NotificationPolicy.shouldPost(account: account, view: view) else { return }

        post(
            title: (payload["title"] as? String) ?? "",
            body: (payload["body"] as? String) ?? "",
            tag: (payload["tag"] as? String) ?? "",
            silent: (payload["silent"] as? Bool) ?? false,
            account: account,
            view: view
        )
    }

    /// A download that has just landed (G4). Not a web notification: it carries
    /// the file's path so a click reveals it in Finder.
    func postDownloadFinished(at url: URL) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = url.lastPathComponent
        content.body = "Downloaded to \(url.deletingLastPathComponent().lastPathComponent)"
        content.sound = nil
        content.userInfo = [InfoKey.downloadPath: url.path]

        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error {
                Log.error("could not post download notification: \(error.localizedDescription)")
            }
        }
    }

    /// Internal rather than private: the session-health indicator posts through
    /// the same path, so its click routes back to the right account and view
    /// with nothing new to build. It never asks for a sound of its own, so
    /// `silent` defaults to the web-notification default.
    func post(title: String, body: String, tag: String, silent: Bool = false, account: Account, view: AccountView) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = NotificationContent.title(payloadTitle: title, accountName: account.name)
        // userInfo only routes the click; the subtitle is what actually tells
        // the user which account the notification came from.
        content.subtitle = account.name
        content.body = body
        content.sound = NotificationPolicy.sound(silent: silent)
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
        // The one case where a banner says nothing is the tab already on
        // screen: it still goes to Notification Center, without the interruption.
        let suppressed = NotificationPolicy.suppressBanner(
            appIsActive: NSApp.isActive,
            notification: Self.tab(from: notification.request.content.userInfo),
            selection: currentSelection()
        )
        completionHandler(suppressed ? [.list] : [.banner, .list, .sound])
    }

    /// The tab a notification came from, as recorded in its own `userInfo`.
    private static func tab(from info: [AnyHashable: Any]) -> TabRef? {
        guard
            let rawId = info[InfoKey.accountId] as? String,
            let accountId = UUID(uuidString: rawId),
            let rawView = info[InfoKey.view] as? String,
            let view = AccountView(rawValue: rawView)
        else { return nil }
        return TabRef(accountId: accountId, view: view)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let path = info[InfoKey.downloadPath] as? String {
            // A finished download takes the user to the file, not to a tab.
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        } else if let tab = Self.tab(from: info) {
            DispatchQueue.main.async { [weak self] in
                self?.router?.focusAccount(tab.accountId, view: tab.view)
            }
        }
        completionHandler()
    }
}
