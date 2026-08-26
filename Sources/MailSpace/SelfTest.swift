import AppKit
import UserNotifications
import WebKit

/// Headless checks driven by `scripts/smoke.sh` and by hand during QA.
///
/// `MAILSPACE_SELFTEST=1` boots the app exactly as normal, prints a single
/// `SELFTEST …` state line to stdout and exits — the only non-interactive
/// proof that the assembled bundle starts and reaches its first-launch state.
///
/// `MAILSPACE_SELFTEST=login` instead loads the real Google sign-in page with
/// the app's user agent and reports whether Google served the form or the
/// "this browser or app may not be secure" block.
///
/// `MAILSPACE_SELFTEST=shim` exercises the whole notification path against a
/// local page: `new Notification(…)` and
/// `ServiceWorkerRegistration.showNotification(…)` go through the injected
/// shim, the real `NotificationBridge` and on into `UNUserNotificationCenter`,
/// and the probe reports the native authorization status plus how many
/// notifications actually landed in Notification Center. Counting script
/// messages alone would pass even if the native half were dead.
///
/// `MAILSPACE_SELFTEST=autofill` loads the real Google sign-in page with the
/// autofill script attached and a stub credential, then reads the identifier
/// field back — proof that the fill lands on the page Google actually serves.
/// All modes are inert on a normal launch.
enum SelfTest {
    enum Mode: String {
        case state
        case login
        case shim
        case autofill
    }

    static var mode: Mode? {
        guard let raw = ProcessInfo.processInfo.environment["MAILSPACE_SELFTEST"] else { return nil }
        if raw == "1" || raw.isEmpty { return .state }
        return Mode(rawValue: raw)
    }

    static var isEnabled: Bool { mode != nil }

    /// Waits for the first-launch UI to settle, prints the report, then exits.
    static func schedule(report: @escaping () -> String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            finish(report())
        }
    }

    static func finish(_ line: String) -> Never {
        print("SELFTEST \(line)")
        fflush(stdout)
        exit(0)
    }

    /// A probe webview must be in a window for WebKit to run the page normally;
    /// keep it off-screen so nothing flashes on the display.
    static func presentOffscreen(_ webView: WKWebView) {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(webView)
        webView.frame = window.contentView?.bounds ?? .zero
        webView.translatesAutoresizingMaskIntoConstraints = true
        window.orderBack(nil)
    }

    /// A throwaway session for a probe: the app's real configuration, but with
    /// nothing written to disk.
    static func makeProbeConfiguration() -> WKWebViewConfiguration {
        let configuration = WebViewFactory.makeConfiguration(dataStoreIdentifier: UUID())
        configuration.websiteDataStore = .nonPersistent()
        return configuration
    }
}

/// Loads `accounts.google.com` in a throwaway session using the app's real
/// webview configuration, then reports whether Google served the sign-in form
/// or the embedded-browser block (`disallowed_useragent`).
final class LoginProbe: NSObject, WKNavigationDelegate {
    private static let blockMarkers = [
        "browser or app may not be secure",
        "disallowed_useragent",
        "couldn’t sign you in",
        "couldn't sign you in"
    ]

    private let webView: WKWebView
    private var finished = false

    override init() {
        webView = WebViewFactory.makeWebView(configuration: SelfTest.makeProbeConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 30) {
        SelfTest.presentOffscreen(webView)
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=mail")!))

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            SelfTest.finish("login result=timeout ua=\(WebViewFactory.userAgent)")
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        finished = true
        // Give Google's client-side rendering a moment to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
            self?.report()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !finished else { return }
        finished = true
        SelfTest.finish("login result=navigation-failed error=\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !finished else { return }
        finished = true
        SelfTest.finish("login result=navigation-failed error=\(error.localizedDescription)")
    }

    private func report() {
        let js = """
        return {
          text: (document.body ? document.body.innerText : '').slice(0, 4000),
          title: document.title,
          hasEmailField: !!document.querySelector('input[type=email], input[name=identifier]'),
          url: location.href
        };
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
            switch result {
            case .failure(let error):
                SelfTest.finish("login result=script-failed error=\(error.localizedDescription)")
            case .success(let value):
                let dict = value as? [String: Any] ?? [:]
                let text = ((dict["text"] as? String) ?? "").lowercased()
                let blocked = Self.blockMarkers.contains { text.contains($0) }
                let hasEmailField = (dict["hasEmailField"] as? Bool) ?? false
                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                SelfTest.finish(
                    "login result=\(blocked ? "BLOCKED" : "ok") emailField=\(hasEmailField ? 1 : 0) "
                    + "title=\"\(title)\" url=\(url)"
                )
            }
        }
    }
}


/// Drives the notification path end to end against a local page: injected shim
/// → `NotificationBridge` → `UNUserNotificationCenter`, so both the JS-to-native
/// plumbing and native delivery can be checked without a Google sign-in.
///
/// The probe counts script messages *and* reads back what Notification Center
/// actually holds. The two are independent failures — the shim can deliver
/// every message while the system drops every notification — and only the
/// second one is what the user sees.
final class ShimProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// A fixed identifier so repeated probe runs reuse one throwaway data store
    /// instead of leaving a new one behind each time.
    private static let probeAccountId = UUID(uuidString: "5D9F2C71-0A4B-4E1E-9C3A-6B8F0D2E7A15")!

    private let account: Account
    private let bridge = NotificationBridge()
    private let session: AccountSession
    private let webView: WKWebView
    private var delivered: [String] = []
    private var finished = false

    private var authorization = "unknown"
    private var alertSetting = "unknown"
    private var nativeDelivered = -1

    private static let page = """
    <!DOCTYPE html><html><body><script>
      window.__probe = { permission: Notification.permission };
      Notification.requestPermission(function (granted) { window.__probe.callback = granted; });
      new Notification('Page title', { body: 'Page body', tag: 'page-tag' });
      if (window.ServiceWorkerRegistration && window.ServiceWorkerRegistration.prototype.showNotification) {
        window.ServiceWorkerRegistration.prototype.showNotification.call({}, 'Worker title', { body: 'Worker body' });
        window.__probe.serviceWorkerOverridden = true;
      }
      Notification('No-new title');
    </script></body></html>
    """

    override init() {
        account = Account(id: Self.probeAccountId, name: "Probe", mailEnabled: true, calendarEnabled: false)
        // The real session type, so the bridge's own webview→account lookup is
        // the thing under test rather than a stand-in for it.
        session = AccountSession(
            account: account,
            userScripts: [NotificationShim.userScript],
            messageHandlers: [:]
        )
        webView = session.webView(for: .mail)!
        super.init()
        bridge.locator = self
        webView.configuration.userContentController.add(self, name: NotificationShim.handlerName)
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 25) {
        // Exactly what a normal launch does: register the delegate and ask for
        // permission once.
        bridge.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            SelfTest.finish("shim result=timeout delivered=\(self.delivered.count)")
        }

        // Notification Center holds delivered notifications between runs, so a
        // leftover from an earlier probe would inflate this run's count. Clear
        // the probe's own — and only those, never the user's real mail
        // notifications — before posting anything.
        purgeProbeNotifications { [weak self] in
            guard let self else { return }
            SelfTest.presentOffscreen(self.webView)
            self.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://mail.google.com/"))
        }
    }

    /// The bridge stamps every notification with the account name as subtitle,
    /// which is what tells the probe's own notifications apart from real ones.
    private func purgeProbeNotifications(then next: @escaping () -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            next()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { [account] delivered in
            let mine = delivered
                .filter { $0.request.content.subtitle == account.name }
                .map(\.request.identifier)
            if !mine.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: mine)
            }
            DispatchQueue.main.async(execute: next)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        delivered.append((payload["title"] as? String) ?? "")
        // Hand the message straight on to the real bridge, which is what turns
        // it into a `UNNotificationRequest`.
        bridge.userContentController(userContentController, didReceive: message)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.readNotificationCenter()
        }
    }

    /// Reads the native side back: what the system thinks we are allowed to do,
    /// and what actually reached Notification Center.
    private func readNotificationCenter() {
        guard !finished else { return }
        finished = true

        guard Bundle.main.bundleIdentifier != nil else {
            report()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self, account] settings in
            self?.authorization = Self.describe(settings.authorizationStatus)
            self?.alertSetting = Self.describe(settings.alertSetting)
            center.getDeliveredNotifications { notifications in
                // Count only what this probe posted, so a real mail
                // notification sitting in Notification Center cannot pass the
                // check on the probe's behalf.
                let mine = notifications.filter { $0.request.content.subtitle == account.name }
                self?.nativeDelivered = mine.count
                center.removeDeliveredNotifications(withIdentifiers: mine.map(\.request.identifier))
                DispatchQueue.main.async { self?.report() }
            }
        }
    }

    private func report() {
        webView.evaluateJavaScript("JSON.stringify(window.__probe || {})") { [weak self] value, _ in
            guard let self else { return }
            let probe = (value as? String) ?? "{}"
            let titles = self.delivered.joined(separator: "|")
            let count = self.delivered.count
            // Both halves have to hold: every shim message arrived, and
            // Notification Center really is holding the notifications they
            // produced. `auth` is reported but not gated on — whether the user
            // has answered the permission prompt is their decision, not a
            // defect in the build.
            let ok = count == 3 && self.nativeDelivered == 3
            SelfTest.finish(
                "shim result=\(ok ? "ok" : "PARTIAL") delivered=\(count) native=\(self.nativeDelivered) "
                + "auth=\(self.authorization) alert=\(self.alertSetting) "
                + "titles=\(titles) probe=\(probe)"
            )
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: return "notSupported"
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        @unknown default: return "unknown(\(setting.rawValue))"
        }
    }
}

extension ShimProbe: SessionLocating {
    func session(hosting webView: WKWebView) -> AccountSession? {
        session.hosts(webView) ? session : nil
    }

    func account(for accountId: UUID) -> Account? {
        accountId == account.id ? account : nil
    }
}


/// Loads the real Google sign-in page with `LoginAutofill` attached and a stub
/// credential, then reports whether the identifier field actually got filled.
final class AutofillProbe: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let probeEmail = "mailspace.probe@gmail.com"

    private let webView: WKWebView
    private var finished = false

    override init() {
        let configuration = SelfTest.makeProbeConfiguration()
        configuration.userContentController.addUserScript(LoginAutofill.userScript)
        webView = WebViewFactory.makeWebView(configuration: configuration)
        super.init()
        configuration.userContentController.addScriptMessageHandler(
            self, contentWorld: .page, name: LoginAutofill.handlerName
        )
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 40) {
        SelfTest.presentOffscreen(webView)
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=mail")!))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            SelfTest.finish("autofill result=timeout")
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        replyHandler(["email": Self.probeEmail], nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        finished = true
        // The script polls, so give the observer a few cycles to see the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.report()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !finished else { return }
        finished = true
        SelfTest.finish("autofill result=navigation-failed error=\(error.localizedDescription)")
    }

    private func report() {
        let js = """
        var field = document.querySelector('#identifierId, input[type=email], input[name="identifier"]');
        return {
          fieldFound: !!field,
          value: field ? field.value : '',
          filled: window.__mailspaceFilled || null
        };
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { result in
            let dict = (try? result.get()) as? [String: Any] ?? [:]
            let value = (dict["value"] as? String) ?? ""
            let found = (dict["fieldFound"] as? Bool) ?? false
            let ok = value == Self.probeEmail
            SelfTest.finish("autofill result=\(ok ? "ok" : "FAILED") fieldFound=\(found ? 1 : 0) value=\(value)")
        }
    }
}
