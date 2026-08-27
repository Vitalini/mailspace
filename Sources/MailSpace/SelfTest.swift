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
/// `MAILSPACE_SELFTEST=update` drives the updater's verify-and-swap against the
/// real signed `MailSpace.app` (path in `MAILSPACE_UPDATE_FIXTURE`), inside a
/// temporary directory: it packages the bundle the way `scripts/release.sh`
/// does, unpacks it the way the installer does, checks it against the pinned
/// designated requirement, and performs the atomic replacement. It also proves
/// the requirement discriminates — this bundle, which differs only in its
/// identifier, must be rejected — and that a version that disagrees with the
/// release is refused. Nothing outside the temporary directory is touched.
///
/// `MAILSPACE_SELFTEST=settings` checks that `AppSettings.registerDefaults`
/// populates the documented values, that a written value round-trips, and — the
/// point of running it under a bundle rather than in `swift test` — that all of
/// it happens in the throwaway defaults domain rather than the real app's.
/// With `MAILSPACE_SETTINGS_SHOT=<directory>` it also renders both Settings
/// panes into PNGs. The window is built at negative coordinates and ordered
/// back, never front: nothing appears on any display.
///
/// `MAILSPACE_SELFTEST=agenda` runs the *production* agenda parser — the one
/// that lives inside the page, because the response holds event titles — over
/// every hand-written fixture in `AgendaFixtures`, and asserts it agrees with
/// `AgendaParser`, the Swift reference, on all of them. It is the only way to
/// test the parser that actually ships. **It touches no network**: an offscreen
/// webview on a non-persistent store, `loadHTMLString`, no `htmlembed` fetch, no
/// signed-in session, no real calendar.
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
        case update
        case settings
        /// Measures what a recycle actually reclaims, against a synthetic page
        /// that touches no Google account and loads no mail.
        case bench
        /// Settles the two platform behaviours the recycling guards rest on.
        case assume
        /// Drives a real webview through a failed recycle and out the other
        /// side, against a network the harness owns and switches off itself.
        case recovery
        /// Renders the tab bar offscreen to a PNG, so the signed-out signal can
        /// be looked at without opening a window on anyone's screen.
        case tabshot
        case agenda
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

    /// A window WebKit will run a page in that never reaches the display.
    ///
    /// Stronger than `presentOffscreen`: the process takes no activation policy
    /// at all, the window is created deferred so no backing store is realised
    /// before it is ordered out, and it is ordered out before the run loop turns.
    /// The benchmark runs for half an hour on a Mac somebody is using.
    @discardableResult
    static func headlessWindow(hosting view: NSView) -> NSWindow {
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: -8000, width: 1200, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.contentView?.addSubview(view)
        view.frame = window.contentView?.bounds ?? .zero
        view.translatesAutoresizingMaskIntoConstraints = true
        window.orderOut(nil)
        return window
    }

    /// The pids of every `com.apple.WebKit.WebContent` process this user owns
    /// right now.
    ///
    /// Attribution without SPI and without privileges: snapshot this set before
    /// the harness creates its webview and again afterwards, and the difference
    /// is the harness's own process. It cannot misattribute to an already
    /// running MailSpace, whose processes are in the first snapshot.
    static func webContentPids() -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-xo", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var pids: Set<Int32> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("com.apple.WebKit.WebContent") else { continue }
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if let first = fields.first, let pid = Int32(first) { pids.insert(pid) }
        }
        return pids
    }

    /// One process's physical footprint in MB, from `footprint(1)` — the same
    /// number the memory report was measured with. Falls back to RSS.
    static func footprintMB(pid: Int32) -> Double? {
        if let value = shell("/usr/bin/footprint", ["-p", "\(pid)"]) {
            for line in value.split(separator: "\n") where line.contains("phys_footprint:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let text = parts[1].trimmingCharacters(in: .whitespaces)
                let pieces = text.split(separator: " ")
                guard let number = Double(pieces.first ?? "") else { continue }
                switch pieces.last.map(String.init) {
                case "KB": return number / 1024
                case "MB": return number
                case "GB": return number * 1024
                case "B": return number / (1024 * 1024)
                default: return number / 1024
                }
            }
        }
        guard
            let rss = shell("/bin/ps", ["-o", "rss=", "-p", "\(pid)"]),
            let kb = Double(rss.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return kb / 1024
    }

    private static func shell(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func environmentDouble(_ name: String, default fallback: Double) -> Double {
        ProcessInfo.processInfo.environment[name].flatMap(Double.init) ?? fallback
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

    /// `var` because the second round mutes it — exactly the flag the Accounts
    /// pane writes.
    private var account: Account
    private let bridge = NotificationBridge()
    private let session: AccountSession
    private let webView: WKWebView
    private var delivered: [String] = []
    /// What the first round delivered, kept for the report once `delivered` is
    /// reused by the muted round.
    private var deliveredWhileAudible: [String] = []
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

    /// The second round, with `notifyMail` off (A2). Its whole point is that
    /// the script messages still arrive and pass the origin check while nothing
    /// reaches Notification Center — which is only true if the guard sits on
    /// the native side rather than in the injected page script.
    private var mutedRound = false
    private var mutedMessages = -1
    private var mutedNative = -1

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
            guard let self else { return }
            if self.mutedRound {
                self.readMutedRound()
            } else {
                self.readNotificationCenter()
            }
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
                DispatchQueue.main.async { self.startMutedRound() }
            }
        }
    }

    /// Round two: the same page, the same origin, the same bridge — with the
    /// account's mail alerts switched off.
    private func startMutedRound() {
        mutedRound = true
        // The first round's read-back armed this against a second `didFinish`;
        // the second round is exactly that, and it is wanted.
        finished = false
        account.notifyMail = false
        deliveredWhileAudible = delivered
        delivered = []
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://mail.google.com/"))
    }

    private func readMutedRound() {
        guard !finished else { return }
        finished = true
        mutedMessages = delivered.count

        guard Bundle.main.bundleIdentifier != nil else {
            report()
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { [weak self, account] notifications in
            guard let self else { return }
            let mine = notifications.filter { $0.request.content.subtitle == account.name }
            self.mutedNative = mine.count
            center.removeDeliveredNotifications(withIdentifiers: mine.map(\.request.identifier))
            DispatchQueue.main.async { self.report() }
        }
    }

    private func report() {
        webView.evaluateJavaScript("JSON.stringify(window.__probe || {})") { [weak self] value, _ in
            guard let self else { return }
            let probe = (value as? String) ?? "{}"
            let titles = self.deliveredWhileAudible.joined(separator: "|")
            let count = self.deliveredWhileAudible.count
            let plumbing = count == 3 && self.gated == 6
            // A2, proven where it counts: the page still posted, the messages
            // still reached the native side and still passed the origin check,
            // and none of them became a notification.
            let muteHolds = self.mutedMessages == 3 && self.mutedNative == 0
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
            } else if self.nativeDelivered == 3 && !muteHolds {
                result = "FAILED"
                reason = " reason=muted-account-still-reached-notification-center"
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
                + "native=\(self.nativeDelivered) mutedMessages=\(self.mutedMessages) "
                + "mutedNative=\(self.mutedNative) auth=\(self.authorization) alert=\(self.alertSetting) "
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


/// Drives the update installer's verify-and-swap end to end, against the real
/// signed app, entirely inside a temporary directory.
///
/// A probe rather than a unit test because every interesting failure lives
/// outside Swift: `ditto` round-tripping a bundle, `SecStaticCodeCheckValidity`
/// against a pinned certificate, and `replaceItemAt` on an app bundle. This is
/// the one piece of the updater that could corrupt an install, so it is proven
/// on a real bundle rather than reasoned about.
final class UpdateProbe {
    private let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mailspace-update-probe-\(UUID().uuidString)")

    private func done(_ line: String) -> Never {
        try? FileManager.default.removeItem(at: scratch)
        SelfTest.finish(line)
    }

    func run() {
        SelfTest.armWatchdog(60) { "update result=TIMEOUT" }

        guard let fixturePath = ProcessInfo.processInfo.environment["MAILSPACE_UPDATE_FIXTURE"] else {
            done("update result=SKIPPED reason=no-MAILSPACE_UPDATE_FIXTURE")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            done("update result=FAILED step=fixture reason=no-app-at-\(fixture.path)")
        }
        guard
            let plist = try? Data(contentsOf: fixture.appendingPathComponent("Contents/Info.plist")),
            let info = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
            let version = SemanticVersion((info["CFBundleShortVersionString"] as? String) ?? "")
        else {
            done("update result=FAILED step=fixture reason=unreadable-version")
        }

        // 1. The genuine app satisfies the requirement the installer demands.
        do {
            try UpdateSecurity.verifyCodeSignature(of: fixture)
        } catch {
            done("update result=FAILED step=genuine-signature error=\(UpdateInstaller.describe(error))")
        }

        // 2. …and the requirement actually discriminates. This bundle is the
        //    same binary under a different identifier, which is the cheapest
        //    possible impostor, and it has to be refused.
        do {
            try UpdateSecurity.verifyCodeSignature(of: Bundle.main.bundleURL)
            done("update result=FAILED step=impostor-accepted bundle=\(Bundle.main.bundleIdentifier ?? "none")")
        } catch {
            // Expected.
        }

        // 3. Package it the way scripts/release.sh does.
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        } catch {
            done("update result=FAILED step=scratch error=\(error.localizedDescription)")
        }
        let archive = scratch.appendingPathComponent("MailSpace.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", fixture.path, archive.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
        } catch {
            done("update result=FAILED step=package error=\(error.localizedDescription)")
        }
        guard ditto.terminationStatus == 0, let payload = try? Data(contentsOf: archive) else {
            done("update result=FAILED step=package reason=ditto-exit-\(ditto.terminationStatus)")
        }

        // 4. An "installed" copy to replace, beside it in the same directory.
        let installed = scratch.appendingPathComponent("MailSpace.app")
        let copy = Process()
        copy.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        copy.arguments = [fixture.path, installed.path]
        try? copy.run()
        copy.waitUntilExit()
        guard copy.terminationStatus == 0 else {
            done("update result=FAILED step=stage-installed reason=ditto-exit-\(copy.terminationStatus)")
        }
        let originalInode = (try? FileManager.default.attributesOfItem(atPath: installed.path)[.systemFileNumber] as? Int) ?? nil

        // 5. A release whose version disagrees with the app inside it must be
        //    refused before anything is replaced.
        let wrong = Self.release(version: SemanticVersion(version.major, version.minor, version.patch + 1))
        do {
            _ = try UpdateInstaller.stageAndSwap(payload: payload, release: wrong, installedBundle: installed)
            done("update result=FAILED step=version-mismatch-accepted")
        } catch {
            // Expected.
        }

        // 6. The real thing.
        let replaced: URL
        do {
            replaced = try UpdateInstaller.stageAndSwap(
                payload: payload,
                release: Self.release(version: version),
                installedBundle: installed
            )
        } catch {
            done("update result=FAILED step=swap error=\(UpdateInstaller.describe(error))")
        }

        // 7. What is there afterwards has to be a working, verifying app — and
        //    nothing else may be left lying around next to it.
        do {
            try UpdateSecurity.verifyCodeSignature(of: replaced)
            try UpdateSecurity.verifyIdentity(of: replaced, expecting: version)
        } catch {
            done("update result=FAILED step=after-swap error=\(UpdateInstaller.describe(error))")
        }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
            .filter { $0.hasPrefix(".MailSpace-update-") || $0.hasSuffix(".app.old") }
        guard leftovers.isEmpty else {
            done("update result=FAILED step=cleanup leftovers=\(leftovers.joined(separator: ","))")
        }
        let newInode = (try? FileManager.default.attributesOfItem(atPath: replaced.path)[.systemFileNumber] as? Int) ?? nil

        done(
            "update result=ok version=\(version) genuineAccepted=1 impostorRejected=1 "
            + "versionMismatchRejected=1 swapped=1 replacedInPlace=\(replaced.path == installed.path ? 1 : 0) "
            + "inodeChanged=\(originalInode != newInode ? 1 : 0) bytes=\(payload.count)"
        )
    }

    private static func release(version: SemanticVersion) -> UpdateRelease {
        UpdateRelease(
            version: version,
            tag: "v\(version)",
            title: "MailSpace \(version)",
            notes: "",
            assetURL: URL(string: "https://example.invalid/MailSpace-\(version).zip")!,
            signatureURL: URL(string: "https://example.invalid/MailSpace-\(version).zip.sig")!,
            assetSize: 0
        )
    }
}

/// Checks the settings domain, and optionally renders the Settings window.
///
/// Two things are only provable inside a bundle: that `registerDefaults` lands
/// in the *throwaway* defaults domain (a `swift test` process has no bundle
/// identity of its own to be wrong about), and that the window builds and lays
/// out with real accounts in it.
///
/// The render is offscreen by construction — the window is moved to negative
/// coordinates and ordered *back*, the same way every webview probe here does
/// it. Nothing is ordered front and the app is never activated.
final class SettingsProbe: NSObject, AccountHosting {
    private let store: AccountStore
    private var controller: SettingsWindowController?
    /// What the pane asked the host to do, so "the checkbox re-totals the
    /// badge" is an assertion rather than a hope.
    private var badgeCalls: [Bool] = []
    /// And which account command each button reached. The pane must call these
    /// and never a parallel implementation, so "the button is wired to
    /// `AccountHosting`" is worth asserting rather than reading.
    private var hostCalls: [String] = []
    /// And what G6 told the countdown poller to do.
    private var calendarCalls: [Bool] = []

    /// Its own directory under the temporary folder: a probe never writes the
    /// account list of the app the user runs.
    override init() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mailspace-settings-probe-\(UUID().uuidString)", isDirectory: true)
        store = AccountStore(directory: directory)
        super.init()
    }

    // MARK: - AccountHosting

    var accountStore: AccountStore { store }
    func session(for accountId: UUID) -> AccountSession? { nil }
    func requestAddAccount() { hostCalls.append("add") }
    func requestEditAccount(id: UUID) { hostCalls.append("edit:\(id.uuidString)") }
    /// Records the ask and stops there: no dialog, no teardown. What is under
    /// test here is that the pane's − reaches this function at all.
    func requestRemoveAccount(id: UUID, presentedOn: NSWindow?) {
        hostCalls.append("remove:\(id.uuidString)")
    }
    func tabBecameVisible(accountId: UUID, view: AccountView, isSelectionChange: Bool) {}
    func tabWasDeselected(accountId: UUID, view: AccountView) {}
    func signedOutAccounts() -> Set<UUID> { [] }
    func stalledAccounts() -> Set<UUID> { [] }
    func badgeInputsChanged(repoll: Bool) { badgeCalls.append(repoll) }

    func run() {
        SelfTest.armWatchdog(30) { "settings result=TIMEOUT" }

        guard SelfTest.isSelfTestBundle else {
            SelfTest.finish("settings result=FAILED reason=not-the-self-test-bundle")
        }

        let defaults = UserDefaults.standard
        AppSettings.registerDefaults(in: defaults)
        let settings = AppSettings(defaults: defaults)

        var failures: [String] = []
        func expect(_ condition: Bool, _ label: String) {
            if !condition { failures.append(label) }
        }
        expect(settings.composeFrom == .ask, "composeFrom")
        expect(settings.openLinksInBackground, "openLinksInBackground")
        expect(settings.downloadFinishedAction == .notify, "downloadFinishedAction")
        expect(settings.badgeScope == .primary, "badgeScope")
        expect(settings.showsCalendarCountdown, "showCalendarCountdown")
        expect(settings.usesSystemDownloadDirectory, "downloadDirectory")
        expect(settings.unreadPollSeconds == 60, "unreadPollSeconds")
        expect(!settings.unreadUsePlainFeed, "unreadUsePlainFeed")
        expect(!settings.disableSignInAutofill, "disableSignInAutofill")

        // A written value round-trips, and it lands in this bundle's own domain.
        settings.badgeScope = .everything
        expect(settings.badgeScope == .everything, "badgeScope-roundtrip")
        expect(
            defaults.persistentDomain(forName: SelfTest.bundleIdentifier)?[AppSettings.Key.badgeScope] != nil,
            "domain-is-the-self-test-one"
        )
        settings.badgeScope = .primary

        guard failures.isEmpty else {
            SelfTest.finish("settings result=FAILED failed=\(failures.joined(separator: ","))")
        }

        seedAccounts()
        let controller = SettingsWindowController(
            updates: UpdateController(settings: settings),
            settings: settings,
            accounts: self,
            // Records the ask and stops there: no poller, no webview, no fetch.
            // What is under test is that G6 reaches this seam at all.
            calendar: CalendarCountdownControls(
                status: { CalendarCountdownStatus(kind: .notCheckedYet, checked: 0, showing: 0) },
                setEnabled: { [weak self] enabled in self?.calendarCalls.append(enabled) },
                recheck: { done in done() }
            )
        )
        self.controller = controller

        let applied = live(controller, settings: settings)
        guard applied.failures.isEmpty else {
            SelfTest.finish("settings result=FAILED live=\(applied.failures.joined(separator: ","))")
        }

        guard let directory = ProcessInfo.processInfo.environment["MAILSPACE_SETTINGS_SHOT"] else {
            SelfTest.finish(
                "settings result=ok defaults=9 applied=\(applied.checked) "
                + "domain=\(SelfTest.bundleIdentifier) render=skipped"
            )
        }
        render(into: URL(fileURLWithPath: directory, isDirectory: true), applied: applied.checked)
    }

    /// Fires the panes' own controls the way a click does — `NSApp.sendAction`
    /// on the control's real target and action — and asserts the value moved.
    ///
    /// This is the check a screenshot cannot make: that a control is wired to a
    /// preference and to the code that applies it, rather than being a
    /// checkbox that only remembers its own state.
    private func live(_ controller: SettingsWindowController, settings: AppSettings) -> (checked: Int, failures: [String]) {
        var failures: [String] = []
        var checked = 0
        func expect(_ condition: Bool, _ label: String) {
            checked += 1
            if !condition { failures.append(label) }
        }

        guard
            let generalWindow = controller.windowForOffscreenRender(paneIndex: 0),
            let generalView = generalWindow.contentViewController?.view
        else { return (checked, ["no-general-pane"]) }
        generalWindow.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        generalWindow.displayIfNeeded()

        // G2
        if let box: NSButton = Self.control(in: generalView, where: { $0.title.hasPrefix("Open links") }) {
            box.state = .off
            Self.click(box)
            expect(!settings.openLinksInBackground, "G2-off")
            box.state = .on
            Self.click(box)
            expect(settings.openLinksInBackground, "G2-on")
        } else {
            failures.append("G2-missing")
        }

        // G4
        if let popup: NSPopUpButton = Self.control(in: generalView, where: { $0.itemTitles.contains("Notify me") }) {
            popup.selectItem(withTitle: DownloadFinishedAction.reveal.displayName)
            Self.click(popup)
            expect(settings.downloadFinishedAction == .reveal, "G4-reveal")
            popup.selectItem(withTitle: DownloadFinishedAction.notify.displayName)
            Self.click(popup)
            expect(settings.downloadFinishedAction == .notify, "G4-notify")
        } else {
            failures.append("G4-missing")
        }

        // G6 — the countdown switch, and the seam it drives. The pane must move
        // the preference *and* tell the poller, or switching it off would leave
        // both clocks running behind a hidden pill.
        if let box: NSButton = Self.control(in: generalView, where: { $0.title.hasPrefix("Show time until") }) {
            box.state = .off
            Self.click(box)
            expect(!settings.showsCalendarCountdown, "G6-off")
            expect(calendarCalls.last == false, "G6-off-reaches-the-poller")
            box.state = .on
            Self.click(box)
            expect(settings.showsCalendarCountdown, "G6-on")
            expect(calendarCalls.last == true, "G6-on-reaches-the-poller")
        } else {
            failures.append("G6-missing")
        }

        // G1 — the pop-up is rebuilt from the account list, so the third item is
        // the first account.
        if
            let popup: NSPopUpButton = Self.control(in: generalView, where: { $0.itemTitles.contains("Ask me each time") }),
            let first = store.accounts.first
        {
            popup.selectItem(withTitle: first.name)
            Self.click(popup)
            expect(settings.composeFrom == .fixed(first.id), "G1-fixed")
            popup.selectItem(withTitle: "Ask me each time")
            Self.click(popup)
            expect(settings.composeFrom == .ask, "G1-ask")
        } else {
            failures.append("G1-missing")
        }

        guard
            let accountsWindow = controller.windowForOffscreenRender(paneIndex: 1),
            let accountsView = accountsWindow.contentViewController?.view
        else { return (checked, failures + ["no-accounts-pane"]) }
        accountsWindow.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        accountsWindow.displayIfNeeded()

        guard let account = store.accounts.first else { return (checked, failures + ["no-account"]) }

        // A2 and A4, through the table's own checkboxes.
        for (label, flag) in [("Mail alerts", AccountStore.Flag.notifyMail), ("Dock badge", .countInBadge)] {
            guard let box: NSButton = Self.control(
                in: accountsView,
                where: { $0.accessibilityLabel() == "\(label) — \(account.name)" }
            ) else {
                failures.append("A-\(flag)-missing")
                continue
            }
            badgeCalls = []
            box.state = .off
            Self.click(box)
            let stored = store.account(id: account.id)
            expect(
                flag == .notifyMail ? stored?.notifyMail == false : stored?.countInBadge == false,
                "\(label)-off"
            )
            if flag == .countInBadge {
                // A4 re-totals immediately; it must not wait for a poll.
                expect(badgeCalls == [false], "\(label)-resums-the-badge")
            }
            box.state = .on
            Self.click(box)
        }

        // A1 — the three commands, every one of them through `AccountHosting`.
        // A parallel implementation in the pane would leave these empty.
        if let table: NSTableView = Self.control(in: accountsView, where: { _ in true }) {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        for (label, expected) in [
            ("Add Account", "add"),
            ("Edit Account…", "edit:\(account.id.uuidString)"),
            ("Remove Account", "remove:\(account.id.uuidString)")
        ] {
            guard let button: NSButton = Self.control(
                in: accountsView,
                where: { $0.accessibilityLabel() == label || $0.title == label }
            ) else {
                failures.append("button-\(expected)-missing")
                continue
            }
            hostCalls = []
            Self.click(button)
            expect(hostCalls == [expected], "button-\(expected)")
        }

        // A5
        if let popup: NSPopUpButton = Self.control(
            in: accountsView,
            where: { $0.itemTitles.contains(BadgeScope.primary.displayName) }
        ) {
            badgeCalls = []
            popup.selectItem(withTitle: BadgeScope.everything.displayName)
            Self.click(popup)
            expect(settings.badgeScope == .everything, "A5-everything")
            // The number means something else now, so it is fetched again.
            expect(badgeCalls == [true], "A5-repolls")
            popup.selectItem(withTitle: BadgeScope.primary.displayName)
            Self.click(popup)
            expect(settings.badgeScope == .primary, "A5-primary")
        } else {
            failures.append("A5-missing")
        }

        return (checked, failures)
    }

    private static func click(_ control: NSControl) {
        guard let action = control.action else { return }
        NSApp.sendAction(action, to: control.target, from: control)
    }

    /// The first control of this kind anywhere in the pane that matches.
    private static func control<T: NSControl>(in view: NSView, where matches: (T) -> Bool) -> T? {
        if let control = view as? T, matches(control) { return control }
        for subview in view.subviews {
            if let found: T = control(in: subview, where: matches) { return found }
        }
        return nil
    }

    private func render(into directory: URL, applied: Int) {
        guard let controller else {
            SelfTest.finish("settings result=FAILED reason=no-controller")
        }

        var written: [String] = []
        for (index, name) in [(0, "settings-general"), (1, "settings-accounts")] {
            guard let window = controller.windowForOffscreenRender(paneIndex: index) else {
                SelfTest.finish("settings result=FAILED reason=no-window pane=\(name)")
            }
            // Off every display, and ordered *back*: the probe must never put a
            // window in front of whatever the user is doing.
            window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            window.orderBack(nil)
            window.displayIfNeeded()

            let target = directory.appendingPathComponent("\(name).png")
            guard Self.capture(window, to: target) else {
                SelfTest.finish("settings result=FAILED reason=capture-failed pane=\(name)")
            }
            written.append(target.lastPathComponent)
        }
        SelfTest.finish(
            "settings result=ok accounts=\(store.accounts.count) applied=\(applied) "
            + "rendered=\(written.joined(separator: ","))"
        )
    }

    /// The account rows the render shows. Read from a source file when one is
    /// named, so the picture carries the real names and tab colours rather than
    /// invented ones; nothing is ever written back to it.
    private func seedAccounts() {
        guard store.accounts.isEmpty else { return }
        let source = ProcessInfo.processInfo.environment["MAILSPACE_SETTINGS_SHOT_ACCOUNTS"]
            .map { URL(fileURLWithPath: $0) }
        if
            let source,
            let data = try? Data(contentsOf: source),
            let records = try? JSONDecoder().decode([Account].self, from: data),
            !records.isEmpty
        {
            for account in records {
                store.add(
                    name: account.name,
                    email: account.email,
                    mailEnabled: account.mailEnabled,
                    calendarEnabled: account.calendarEnabled,
                    color: account.color
                )
            }
            return
        }
        store.add(name: "Personal", email: "personal@example.com", color: .blue)
        store.add(name: "Work", email: "work@example.com", color: .orange)
    }

    /// Captures the window with its titlebar and toolbar: the theme frame is
    /// the view that draws them, and it caches offscreen just as the content
    /// view does.
    private static func capture(_ window: NSWindow, to url: URL) -> Bool {
        guard let target = window.contentView?.superview ?? window.contentView else { return false }
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return false }
        target.cacheDisplay(in: target.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}


/// Proves the parser that ships and the parser that is tested are the same
/// parser.
///
/// Privacy forces the agenda parse into the page (KTD-S14): the response holds
/// meeting titles, so it is read where it lands and only numbers cross the
/// bridge. That leaves the shipped parser out of reach of `swift test`. This
/// probe closes the gap from the other side — it loads each hand-written
/// fixture into an offscreen webview, runs the **production** `msParseAgenda`
/// over it, and asserts the answer equals `AgendaParser`'s on the same bytes at
/// the same instant. A disagreement means one of them is wrong and neither is
/// trusted.
///
/// Nothing here goes near the network, a real calendar or a signed-in session:
/// a non-persistent data store, `loadHTMLString`, and fixtures written by hand
/// with placeholder titles.
final class AgendaProbe: NSObject, WKNavigationDelegate {
    /// Two moments on the fixtures' day: one in the morning, when most of them
    /// have something ahead, and one late at night, when none of them do.
    private static let hours = [9, 23]

    private let webView: WKWebView
    private var pending: [(name: String, html: String, now: Date)] = []
    private var mismatches: [String] = []
    private var compared = 0
    private var started = false

    override init() {
        webView = WebViewFactory.makeWebView(configuration: SelfTest.makeProbeConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 60) {
        SelfTest.armWatchdog(timeout) { [weak self] in
            "agenda result=TIMEOUT compared=\(self?.compared ?? 0)"
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for hour in Self.hours {
            guard let now = calendar.date(from: DateComponents(
                year: AgendaFixtures.day.year,
                month: AgendaFixtures.day.month,
                day: AgendaFixtures.day.day,
                hour: hour,
                minute: 0
            )) else { continue }
            for fixture in AgendaFixtures.all {
                pending.append((fixture.name, fixture.html, now))
            }
        }

        SelfTest.presentOffscreen(webView)
        // Any page will do — the fixture is an argument, not the document. This
        // one just gives the production script a JavaScript context to run in.
        webView.loadHTMLString(
            "<html><head><title>agenda self-test</title></head><body></body></html>",
            baseURL: URL(string: "about:blank")
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !started else { return }
        started = true
        compareNext()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        SelfTest.finish("agenda result=FAILED reason=page-load error=\(error.localizedDescription)")
    }

    private func compareNext() {
        guard let next = pending.first else { return report() }
        pending.removeFirst()

        let expected = AgendaParser.parse(html: next.html, now: next.now, timeZone: .current)
        webView.callAsyncJavaScript(
            AgendaScript.parseFunction + "\n\nreturn msParseAgenda(html, nowMs);",
            arguments: [
                "html": next.html,
                "nowMs": next.now.timeIntervalSince1970 * 1000
            ],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self else { return }
            self.compared += 1
            switch result {
            case .failure(let error):
                // The fixture name is ours, not the calendar's; the error is
                // WebKit's. Neither can carry event content.
                self.mismatches.append(
                    "\(next.name)@\(Self.hour(of: next.now)):script-\(error.localizedDescription)"
                )
            case .success(let value):
                if let complaint = Self.disagreement(swift: expected, javaScript: value) {
                    self.mismatches.append("\(next.name)@\(Self.hour(of: next.now)):\(complaint)")
                }
            }
            self.compareNext()
        }
    }

    /// Compares the two answers. `nil` when they agree, and a short
    /// machine-shaped complaint when they do not — numbers and the fixture's own
    /// name only.
    private static func disagreement(swift expected: AgendaParser.Result?, javaScript value: Any) -> String? {
        guard let payload = value as? [String: Any],
              let status = payload["status"] as? Int
        else { return "no-payload" }

        guard let expected else {
            // Swift did not understand it, so the script must not have either.
            return status == AgendaOutcome.notUnderstood.rawValue ? nil : "swift=nil js-status=\(status)"
        }
        guard status == AgendaOutcome.ok.rawValue else { return "swift=ok js-status=\(status)" }

        let seconds = payload["startsInSeconds"] as? Int
        if seconds != expected.startsInSeconds {
            return "starts swift=\(expected.startsInSeconds.map(String.init) ?? "nil") "
                + "js=\(seconds.map(String.init) ?? "nil")"
        }
        let remaining = (payload["remainingCount"] as? Int) ?? -1
        if remaining != expected.remainingCount {
            return "remaining swift=\(expected.remainingCount) js=\(remaining)"
        }
        return nil
    }

    private static func hour(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.component(.hour, from: date)
    }

    private func report() {
        guard mismatches.isEmpty else {
            SelfTest.finish(
                "agenda result=FAILED fixtures=\(AgendaFixtures.all.count) compared=\(compared) "
                + "mismatches=\(mismatches.count) at=\(mismatches.joined(separator: ","))"
            )
        }
        SelfTest.finish(
            "agenda result=ok fixtures=\(AgendaFixtures.all.count) compared=\(compared) "
            + "mismatches=0 network=none"
        )
    }
}
