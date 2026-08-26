import AppKit
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
/// `MAILSPACE_SELFTEST=shim` exercises the notification shim against a local
/// page: it proves permission is granted and that both `new Notification(…)`
/// and `ServiceWorkerRegistration.showNotification(…)` reach the native
/// handler. All modes are inert on a normal launch.
enum SelfTest {
    enum Mode: String {
        case state
        case login
        case shim
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
        let configuration = WebViewFactory.makeConfiguration(dataStoreIdentifier: UUID())
        configuration.websiteDataStore = .nonPersistent()
        webView = WebViewFactory.makeWebView(configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 30) {
        // The probe webview must be in a window for WebKit to run the page
        // normally; keep it off-screen so nothing flashes on the display.
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(webView)
        webView.frame = window.contentView?.bounds ?? .zero
        webView.translatesAutoresizingMaskIntoConstraints = true
        window.orderBack(nil)

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


/// Drives the notification shim against a local page, so the JS-to-native
/// plumbing can be checked without a Google sign-in.
final class ShimProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private let webView: WKWebView
    private var delivered: [String] = []
    private var finished = false

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
        let configuration = WebViewFactory.makeConfiguration(dataStoreIdentifier: UUID())
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(NotificationShim.userScript)
        webView = WebViewFactory.makeWebView(configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: NotificationShim.handlerName)
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 20) {
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://mail.google.com/"))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            SelfTest.finish("shim result=timeout delivered=\(self.delivered.count)")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        delivered.append((payload["title"] as? String) ?? "")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.report()
        }
    }

    private func report() {
        guard !finished else { return }
        finished = true
        webView.evaluateJavaScript("JSON.stringify(window.__probe || {})") { [weak self] value, _ in
            let probe = (value as? String) ?? "{}"
            let titles = (self?.delivered ?? []).joined(separator: "|")
            let count = self?.delivered.count ?? 0
            SelfTest.finish("shim result=\(count == 3 ? "ok" : "PARTIAL") delivered=\(count) titles=\(titles) probe=\(probe)")
        }
    }
}
