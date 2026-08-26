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
/// and the probe reports the native authorization status, how many frames
/// passed the real origin check, and how many notifications actually landed in
/// Notification Center. Counting script messages alone would pass even if the
/// native half were dead. If the throwaway identity holds no authorization the
/// probe cannot prove native delivery, and reports `result=SKIPPED` with the
/// reason rather than passing on the plumbing alone.
///
/// `MAILSPACE_SELFTEST=autofill` loads the real Google sign-in page with the
/// autofill script attached and a stub credential, then reads the identifier
/// field back — proof that the fill lands on the page Google actually serves,
/// that only the top frame of `accounts.google.com` is answered, and that page
/// scripts cannot see the handler at all.
///
/// `MAILSPACE_SELFTEST=store` builds a real `AccountSession`, uses its data
/// store, then tears it down exactly the way account removal does and deletes
/// the store — proof that "signed out and deleted from this Mac" is true.
/// All modes are inert on a normal launch.
///
/// ## Every self-test runs under a throwaway bundle identity
///
/// The probes talk to the real `UNUserNotificationCenter`, and an automated run
/// has nobody to answer a permission prompt — macOS records that silence as a
/// denial, which is how an earlier smoke run cost the user the notification
/// permission of the app he actually uses. So a self-test refuses to run as
/// `com.vitalii.MailSpace` at all: `make smoke` assembles the same binary into
/// `build/MailSpace-SelfTest.app` under `com.vitalii.MailSpace.SelfTest`, and
/// every prompt, authorization record, account list, Keychain item and website
/// data store a probe can touch belongs to that disposable identity.
enum SelfTest {
    enum Mode: String {
        case state
        case login
        case shim
        case autofill
        case store
    }

    /// The throwaway identity self-tests run under. Assembled by
    /// `make selftest-app`; never the identity of the app the user launches.
    static let bundleIdentifier = "com.vitalii.MailSpace.SelfTest"

    static var mode: Mode? {
        guard let raw = ProcessInfo.processInfo.environment["MAILSPACE_SELFTEST"] else { return nil }
        if raw == "1" || raw.isEmpty { return .state }
        return Mode(rawValue: raw)
    }

    static var isEnabled: Bool { mode != nil }

    static func isSelfTestBundle(_ identifier: String?) -> Bool {
        identifier == bundleIdentifier
    }

    /// Whether *this* process is the throwaway one. Read from the bundle rather
    /// than from an environment variable on purpose: an env var can be dropped
    /// or forged, the identity the system authorizes notifications against
    /// cannot.
    static var isSelfTestBundle: Bool { isSelfTestBundle(Bundle.main.bundleIdentifier) }

    /// Waits for the first-launch UI to settle, prints the report, then exits.
    static func schedule(report: @escaping () -> String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            finish(report())
        }
    }

    /// Guarantees a probe prints *something*: after `seconds`, whatever the
    /// probe has reached is reported and the process exits.
    ///
    /// Deliberately unconditional. A probe that only fired its watchdog while
    /// some `finished` flag was still false disarmed itself the moment a
    /// navigation completed, so a callback that never came back left the run
    /// hanging with no output at all until the smoke script's own kill — which
    /// reads as an empty failure line and says nothing about what broke.
    /// `finish` exits the process, so a report that already happened cancels
    /// this by definition.
    static func armWatchdog(_ seconds: TimeInterval, line: @escaping () -> String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            finish(line())
        }
    }

    static func finish(_ line: String) -> Never {
        print("SELFTEST \(line)")
        fflush(stdout)
        exit(0)
    }

    /// A self-test that must not run — the wrong bundle identity — says so on
    /// both streams and exits non-zero, so a script cannot mistake it for a
    /// pass and a human cannot miss it in the log.
    static func refuse(_ line: String) -> Never {
        let text = "SELFTEST \(line)"
        print(text)
        fflush(stdout)
        FileHandle.standardError.write(Data((text + "\n").utf8))
        exit(2)
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
        SelfTest.armWatchdog(timeout) { "login result=timeout ua=\(WebViewFactory.userAgent)" }
        SelfTest.presentOffscreen(webView)
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=mail")!))
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
/// The probe counts script messages, checks each message's frame against the
/// real origin gate, *and* reads back what Notification Center actually holds.
/// These are independent failures — the shim can deliver every message while
/// the system drops every notification — and only the last one is what the
/// user sees.
///
/// Everything here happens as `com.vitalii.MailSpace.SelfTest`: the
/// authorization it holds, the notifications it posts and the ones it clears
/// afterwards all belong to the throwaway identity, so the probe cannot reach
/// the real app's permission or its notifications even by accident.
final class ShimProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// A fixed identifier so repeated probe runs reuse one throwaway data store
    /// instead of leaving a new one behind each time.
    private static let probeAccountId = UUID(uuidString: "5D9F2C71-0A4B-4E1E-9C3A-6B8F0D2E7A15")!

    private let account: Account
    private let bridge = NotificationBridge()
    private let session: AccountSession
    private let webView: WKWebView
    private var delivered: [String] = []
    /// Of those, the ones whose frame passed the real origin check. The shim's
    /// handler has to live in the page world, so that check is the only thing
    /// keeping a third-party frame from raising native banners — it is worth
    /// proving against a real load rather than only in a unit test.
    private var gated = 0
    private var lastOrigin = ""
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

    func run(timeout: TimeInterval = 35) {
        SelfTest.armWatchdog(timeout) { [weak self] in
            "shim result=TIMEOUT delivered=\(self?.delivered.count ?? -1) trusted=\(self?.gated ?? -1) "
            + "native=\(self?.nativeDelivered ?? -1) auth=\(self?.authorization ?? "unknown")"
        }

        // Exactly what a normal launch does: register the delegate and ask for
        // permission once — provisionally, because this is the throwaway
        // identity (see `NotificationBridge.authorizationOptions`). Waiting for
        // the answer before posting is what keeps the first run on a fresh
        // identity from racing its own authorization.
        bridge.start { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Notification Center holds delivered notifications between
                // runs, so a leftover from an earlier probe would inflate this
                // run's count. Clear the probe's own before posting anything.
                self.purgeProbeNotifications {
                    SelfTest.presentOffscreen(self.webView)
                    self.webView.loadHTMLString(Self.page, baseURL: URL(string: "https://mail.google.com/"))
                }
            }
        }
    }

    /// Only ever sees the throwaway identity's own notifications, and the
    /// bridge stamps each with the account name as subtitle, so the filter is a
    /// second fence rather than the only one.
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

        let origin = message.frameInfo.securityOrigin
        lastOrigin = "\(origin.protocol)://\(origin.host):\(origin.port)"
        if NotificationOrigin.isTrusted(message.frameInfo, view: .mail) { gated += 1 }

        // Hand the message straight on to the real bridge, which is what turns
        // it into a `UNNotificationRequest` — and which applies the same origin
        // check itself, so an untrusted frame reaches the counter above but
        // never Notification Center.
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
        pollDelivered(expected: delivered.count, deadline: Date().addingTimeInterval(12))
    }

    /// `add(…)` returning without error does not mean the notification has
    /// reached Notification Center yet, and under load it can take seconds. So
    /// the read-back polls until the expected count arrives instead of looking
    /// once and calling a slow delivery a dropped one.
    private func pollDelivered(expected: Int, deadline: Date) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self, account] settings in
            guard let self else { return }
            self.authorization = Self.describe(settings.authorizationStatus)
            self.alertSetting = Self.describe(settings.alertSetting)
            center.getDeliveredNotifications { notifications in
                // Count only what this probe posted. Another identity's
                // notifications are not visible here at all, and the subtitle
                // keeps the probe's apart from anything else this one posted.
                let mine = notifications.filter { $0.request.content.subtitle == account.name }
                guard mine.count >= expected || Date() >= deadline else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        self?.pollDelivered(expected: expected, deadline: deadline)
                    }
                    return
                }
                self.nativeDelivered = mine.count
                center.removeDeliveredNotifications(withIdentifiers: mine.map(\.request.identifier))
                DispatchQueue.main.async { self.report() }
            }
        }
    }

    private func report() {
        webView.evaluateJavaScript("JSON.stringify(window.__probe || {})") { [weak self] value, _ in
            guard let self else { return }
            let probe = (value as? String) ?? "{}"
            let titles = self.delivered.joined(separator: "|")
            let count = self.delivered.count
            let plumbing = count == 3 && self.gated == 3
            let authorized = self.authorization == "authorized" || self.authorization == "provisional"

            // Three independent things have to hold: every shim message
            // arrived, every one came from a frame the real origin check
            // trusts, and Notification Center really is holding what they
            // produced. Only the last one is native delivery — and if this
            // throwaway identity has no authorization at all, nothing can prove
            // it, so the probe says so instead of quietly passing.
            let result: String
            var reason = ""
            if !plumbing {
                result = "FAILED"
                reason = " reason=shim-to-bridge-plumbing-broken"
            } else if self.nativeDelivered == 3 {
                result = "ok"
            } else if !authorized {
                result = "SKIPPED"
                reason = " reason=NATIVE-DELIVERY-NOT-PROVEN-no-authorization-for-\(SelfTest.bundleIdentifier)"
            } else {
                result = "FAILED"
                reason = " reason=authorized-but-notification-center-dropped-them"
            }

            SelfTest.finish(
                "shim result=\(result)\(reason) delivered=\(count) trusted=\(self.gated) "
                + "native=\(self.nativeDelivered) auth=\(self.authorization) alert=\(self.alertSetting) "
                + "bundle=\(Bundle.main.bundleIdentifier ?? "none") "
                + "origin=\(self.lastOrigin) titles=\(titles) probe=\(probe)"
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
    /// Whether the asking frame passed the real origin check. Reported so the
    /// smoke run proves the gate against the page Google actually serves, not
    /// just against a fixture.
    private var trustedOrigin = false

    override init() {
        let configuration = SelfTest.makeProbeConfiguration()
        configuration.userContentController.addUserScript(LoginAutofill.userScript)
        webView = WebViewFactory.makeWebView(configuration: configuration)
        super.init()
        configuration.userContentController.addScriptMessageHandler(
            self, contentWorld: LoginAutofill.contentWorld, name: LoginAutofill.handlerName
        )
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 40) {
        SelfTest.armWatchdog(timeout) { [weak self] in
            "autofill result=TIMEOUT gated=\((self?.trustedOrigin ?? false) ? 1 : 0)"
        }
        SelfTest.presentOffscreen(webView)
        webView.load(URLRequest(url: URL(string: "https://accounts.google.com/ServiceLogin?service=mail")!))
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // The same gate the real handler applies before it reads the Keychain.
        guard LoginAutofill.isTrustedOrigin(message.frameInfo) else {
            replyHandler([String: String](), nil)
            return
        }
        trustedOrigin = true
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
        // Read the field back from the page's own world, and separately ask
        // that world whether it can see the handler at all: it must not, or the
        // isolation the fix relies on is not there.
        let js = """
        var field = document.querySelector('#identifierId, input[type=email], input[name="identifier"]');
        return {
          fieldFound: !!field,
          value: field ? field.value : '',
          handlerVisibleToPage: !!(window.webkit
            && window.webkit.messageHandlers
            && window.webkit.messageHandlers.mailspaceAutofill)
        };
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [trustedOrigin] result in
            let dict = (try? result.get()) as? [String: Any] ?? [:]
            let value = (dict["value"] as? String) ?? ""
            let found = (dict["fieldFound"] as? Bool) ?? false
            let leaked = (dict["handlerVisibleToPage"] as? Bool) ?? true
            let ok = value == Self.probeEmail && trustedOrigin && !leaked
            SelfTest.finish(
                "autofill result=\(ok ? "ok" : "FAILED") fieldFound=\(found ? 1 : 0) "
                + "gated=\(trustedOrigin ? 1 : 0) pageCanReachHandler=\(leaked ? 1 : 0) value=\(value)"
            )
        }
    }
}


/// Proves an account's browser session really can be deleted from disk.
///
/// A probe rather than a unit test because the whole failure lives in WebKit's
/// process model, and it was invisible: `WKWebsiteDataStore.remove` refuses
/// while anything still references the store, and the refusal only reached a
/// stderr line — so the removal dialog's promise that the Google session is
/// "deleted from this Mac" was false while the cookies stayed put.
///
/// Runs the real `AccountSession` through the real teardown and then the real
/// `destroyDataStore`. Needs no network: a local page on a Gmail origin puts
/// the store in use just as effectively as Gmail itself does.
final class StoreRemovalProbe: NSObject, WKNavigationDelegate {
    private static let page = """
    <!DOCTYPE html><html><body>probe<script>
      try { localStorage.setItem('mailspace', 'probe'); } catch (e) {}
      document.cookie = 'mailspace=probe';
    </script></body></html>
    """

    private let account = Account(name: "MailSpace store probe")
    private var session: AccountSession?
    private var settled = false

    func run(timeout: TimeInterval = 40) {
        SelfTest.armWatchdog(timeout) { "store result=TIMEOUT" }

        let session = AccountSession(account: account)
        self.session = session

        guard let webView = session.webView(for: .mail) else {
            SelfTest.finish("store result=FAILED reason=no-webview")
        }
        SelfTest.presentOffscreen(webView)
        webView.navigationDelegate = self
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://mail.google.com/")!)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { settle() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        settle()
    }

    private func settle() {
        guard !settled else { return }
        settled = true
        // Let the page's storage writes land before anything is torn down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.removeStore()
        }
    }

    private func removeStore() {
        let identifier = account.id
        // The same shape as `AppDelegate.requestRemoveAccount`: detach, then let
        // the session itself go. Its configuration holds the data store for its
        // whole lifetime, so detaching alone leaves the store in use and every
        // removal attempt fails however long it waits.
        session?.detach()
        session = nil

        WebViewFactory.destroyDataStore(for: identifier) { error in
            guard let error else {
                SelfTest.finish("store result=ok removed=1")
            }
            SelfTest.finish("store result=FAILED error=\(error.localizedDescription)")
        }
    }
}
