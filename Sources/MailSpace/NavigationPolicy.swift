import AppKit
import WebKit

/// Decides which URLs belong inside MailSpace and which belong to the user's
/// browser. Pure logic, kept separate from the delegate so it can be tested.
enum LinkRouter {
    /// Hosts (and their subdomains) that are part of the Gmail/Calendar
    /// experience and must keep the account's session. Deliberately excludes
    /// youtube.com — a video link is browser work.
    private static let inAppHosts = [
        "googlemail.com",
        "googleusercontent.com",
        "gstatic.com",
        "googleapis.com"
    ]

    /// Gmail routes outbound clicks through `https://www.google.com/url?q=…`.
    /// Unwrap it so the real destination decides in-app versus external —
    /// otherwise every external link would look like a Google link.
    static func unwrapRedirect(_ url: URL) -> URL {
        guard
            let host = url.host?.lowercased(),
            host.hasSuffix("google.com") || host.hasSuffix("googlemail.com"),
            url.path == "/url",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let target = items.first(where: { $0.name == "q" || $0.name == "url" })?.value,
            let resolved = URL(string: target),
            resolved.scheme != nil
        else { return url }
        return resolved
    }

    /// What should happen to a URL the webview wants to go to.
    enum Destination: Equatable {
        /// Stays in the webview: Google pages, and every non-web URL the page
        /// drives itself (`about:blank`, `blob:`, `data:`, `javascript:`).
        case allowInApp
        /// A real web page somewhere else — the user's browser owns it.
        case openExternally(URL)
        /// A `mailto:` link, which MailSpace composes itself.
        case compose(URL)
    }

    /// The single routing decision, shared by the navigation and popup paths.
    ///
    /// Only a genuine http(s) URL with a host is ever handed to the system.
    /// Google's sign-in SPA opens `about:blank` popups and iframes, and passing
    /// those to `NSWorkspace` is what makes macOS put up "There is no
    /// application set to open the URL about:blank".
    static func destination(for requested: URL) -> Destination {
        let url = unwrapRedirect(requested)

        guard let scheme = url.scheme?.lowercased() else { return .allowInApp }
        if scheme == "mailto" { return .compose(url) }
        guard scheme == "http" || scheme == "https" else { return .allowInApp }
        guard let host = url.host, !host.isEmpty else { return .allowInApp }

        return isInApp(url) ? .allowInApp : .openExternally(url)
    }

    static func isInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }

        if inAppHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return true }
        return isGoogleDomain(host)
    }

    /// True for `google.com` and its country variants (`google.co.uk`,
    /// `google.de`) plus any subdomain of them.
    static func isGoogleDomain(_ host: String) -> Bool {
        guard let range = host.range(of: "google.", options: .backwards) else { return false }

        let before = host[..<range.lowerBound]
        guard before.isEmpty || before.hasSuffix(".") else { return false }

        let tld = host[range.upperBound...]
        guard !tld.isEmpty, tld.count <= 6 else { return false }
        return tld.allSatisfy { $0.isLetter || $0 == "." }
    }

    /// Picks a non-colliding destination in `directory`, appending " (2)",
    /// " (3)" … the way Safari does.
    static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let name = filename.isEmpty ? "download" : filename
        var candidate = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let suffixed = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Tells a Google sign-in step apart from a signed-in Gmail/Calendar surface.
///
/// Two decisions hang off this, both in `NavigationPolicy`:
/// - a "Sign in" link may take over the tab it was clicked in instead of
///   opening a popup the tab never hears from again;
/// - a webview that went through the sign-in chain and then landed on an app
///   surface has finished authenticating, so its popup can close and the
///   account's stale tabs can be brought onto their real surfaces.
///
/// The app side is a positive allowlist on purpose. Google's auth chain has no
/// enumerable set of steps (identifier, password, TOTP, passkey, consent,
/// speed bumps, chooser), so a missing entry there would close a popup
/// mid-2FA; an unrecognised surface here just means "not done yet".
/// Pure logic, kept next to `LinkRouter` so it can be tested.
enum AuthSurface {
    enum Kind: Equatable {
        /// Part of the sign-in chain — the user is still authenticating.
        case signIn
        /// A signed-in Gmail/Calendar surface, i.e. one of MailSpace's own tabs.
        case app(AccountView)
        /// Everything else, marketing and help pages included.
        case other
    }

    /// Auth hosts that are not `accounts.google.<tld>`: the YouTube sign-in
    /// bridge, the device/passkey challenge helper, and the short sign-in host.
    private static let signInHosts: Set<String> = [
        "accounts.youtube.com",
        "gds.google.com",
        "signin.google.com"
    ]

    /// First path segment under `/mail` or `/calendar` that means a marketing
    /// or documentation page rather than the product itself.
    private static let nonAppSegments: Set<String> = ["about", "help", "intl", "policies", "support"]

    /// Classifies on host and path only — query and fragment (`?pli=1`,
    /// `?authuser=`, `#inbox`, `?view=cm`) never change what a page is.
    static func classify(_ url: URL?) -> Kind {
        guard
            let url,
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return .other }

        if isSignInHost(host) { return .signIn }

        let segments = url.path.split(separator: "/").map(String.init)
        switch host {
        case "mail.google.com", "mail.googlemail.com":
            return isAppPath(segments, root: "mail") ? .app(.mail) : .other
        case "calendar.google.com":
            return isAppPath(segments, root: "calendar") ? .app(.calendar) : .other
        default:
            return .other
        }
    }

    static func isSignInHost(_ host: String) -> Bool {
        let host = host.lowercased()
        if signInHosts.contains(host) { return true }
        return host.hasPrefix("accounts.") && LinkRouter.isGoogleDomain(host)
    }

    /// True when this URL is the view's own signed-in surface — which is both
    /// "authentication finished" and "this tab needs nothing done to it".
    static func isSignedIn(_ url: URL?, for view: AccountView) -> Bool {
        classify(url) == .app(view)
    }

    /// Whether a new-window request should take over the opener rather than
    /// become a popup.
    ///
    /// Only a clicked link qualifies. A scripted `window.open` gets a real
    /// window: its return value and the `window.opener` channel are part of the
    /// flow Google runs, and Gmail's own print, compose-in-a-new-window and
    /// "open in new window" all come through that way. And a window opened from
    /// a signed-in surface is left alone whatever it is — that page can hold an
    /// unsent draft.
    static func shouldLoadInOpener(requested: URL, openerURL: URL?, isLinkActivated: Bool) -> Bool {
        guard isLinkActivated, classify(requested) == .signIn else { return false }
        if case .app = classify(openerURL) { return false }
        return true
    }

    /// `/mail`, `/mail/`, `/mail/u/0/…` yes; `/mail/about/…`, `/calendar/help/…` no.
    private static func isAppPath(_ segments: [String], root: String) -> Bool {
        guard segments.first == root else { return false }
        guard segments.count > 1 else { return true }
        return !nonAppSegments.contains(segments[1])
    }
}

/// A set of objects held weakly and compared by identity.
///
/// `ObjectIdentifier` alone is not enough to remember "this webview went
/// through sign-in": the value is the object's address, and a later allocation
/// can reuse it, which would hand a fresh popup someone else's history. Holding
/// the object weakly makes a reused address fail the identity check instead.
struct WeakObjectSet<Element: AnyObject> {
    private struct Ref {
        weak var object: AnyObject?
    }

    private var refs: [ObjectIdentifier: Ref] = [:]

    var count: Int { refs.values.filter { $0.object != nil }.count }

    mutating func insert(_ object: Element) {
        refs = refs.filter { $0.value.object != nil }
        refs[ObjectIdentifier(object)] = Ref(object: object)
    }

    func contains(_ object: Element) -> Bool {
        refs[ObjectIdentifier(object)]?.object === object
    }

    /// Removes the object and says whether it really was in the set — the
    /// one-shot check that keeps sign-in completion from firing twice.
    @discardableResult
    mutating func remove(_ object: Element) -> Bool {
        let held = contains(object)
        refs[ObjectIdentifier(object)] = nil
        return held
    }
}

/// Decides whether a crashed webview may be reloaded again.
///
/// A page that keeps killing its WebContent process would otherwise reload
/// forever; after `limit` terminations inside `window` seconds the webview is
/// left alone until the burst ages out. Pure logic with an injected clock so it
/// can be tested without crashing a real process.
struct CrashThrottle {
    let limit: Int
    let window: TimeInterval

    private var bursts: [ObjectIdentifier: (count: Int, startedAt: Date)] = [:]

    init(limit: Int = 3, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Records one termination and answers whether a reload should follow.
    mutating func shouldReload(_ key: ObjectIdentifier, now: Date = Date()) -> Bool {
        var burst = bursts[key] ?? (count: 0, startedAt: now)
        if now.timeIntervalSince(burst.startedAt) > window {
            burst = (count: 0, startedAt: now)
        }
        burst.count += 1
        bursts[key] = burst
        return burst.count <= limit
    }

    mutating func forget(_ key: ObjectIdentifier) {
        bursts[key] = nil
    }
}

/// The single navigation/UI delegate shared by every account webview.
///
/// - non-Google links leave for the default browser (R12)
/// - Google popups (sign-in, print) open as in-app child windows on the same
///   session, using the exact configuration WebKit hands over (KTD7)
/// - downloads land in `~/Downloads` (R13)
final class NavigationPolicy: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate {
    /// Handles a `mailto:` link clicked inside a webview.
    var mailtoHandler: ((URL) -> Void)?

    /// Fires once when a webview on an account's data store finishes the Google
    /// sign-in chain, so that account's other tabs can leave their signed-out
    /// pages behind.
    var onSignInCompleted: ((UUID) -> Void)?

    /// One in-app popup: the window, and the account whose data store it runs
    /// on so removing that account can take its popups with it.
    private struct Popup {
        let window: NSWindow
        let accountId: UUID?
    }

    private var popupWindows: [ObjectIdentifier: Popup] = [:]
    private var crashThrottle = CrashThrottle()
    /// Webviews that have been through a sign-in step. Landing on an app
    /// surface only means "signed in" for these — Gmail's own print and
    /// compose popups land on the very same URLs.
    private var sawSignIn = WeakObjectSet<WKWebView>()

    private static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }

        guard let requested = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        switch LinkRouter.destination(for: requested) {
        case .allowInApp:
            decisionHandler(.allow)

        case .compose(let mailto):
            // Our own compose, never the system's default mail app — that
            // could be MailSpace itself and loop.
            mailtoHandler?(mailto)
            decisionHandler(.cancel)

        case .openExternally(let url):
            // Only user-initiated navigation leaves the app: a redirect or a
            // subframe load inside Gmail must not be hijacked.
            guard navigationAction.navigationType == .linkActivated else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Remembers that this webview is inside the sign-in chain. Provenance is
    /// what separates a real sign-in from Gmail's print and compose popups,
    /// which finish on the same `mail.google.com/mail/u/0/…` URLs.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard AuthSurface.classify(webView.url) == .signIn else { return }
        sawSignIn.insert(webView)
    }

    /// Sign-in is finished the moment a webview that was authenticating settles
    /// on an app surface. `didFinish` rather than `decidePolicyFor` is what
    /// makes that safe: signed out, `mail.google.com/mail/u/0/` only ever
    /// appears as a redirect hop back to `accounts.google.com`, so a *finished*
    /// navigation there is itself the proof the session took.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard case .app = AuthSurface.classify(webView.url) else { return }
        // One shot: the account is reconciled once per sign-in, not once per
        // page load afterwards.
        guard sawSignIn.remove(webView) else { return }
        let accountId = webView.configuration.websiteDataStore.identifier

        // Never tear a webview down from inside its own navigation callback.
        DispatchQueue.main.async { [weak self, weak webView] in
            guard let self else { return }
            // A no-op unless this webview is a popup — an in-place sign-in has
            // no window to close.
            if let webView { self.closePopup(hosting: webView) }
            if let accountId { self.onSignInCompleted?(accountId) }
        }
    }

    /// KTD8: macOS may reclaim a background account's WebContent process under
    /// memory pressure. Reload so notifications and unread polling resume
    /// instead of dying silently — but a page that keeps crashing gets a few
    /// attempts, not an endless reload loop.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard crashThrottle.shouldReload(ObjectIdentifier(webView)) else {
            Log.error(
                "web content process kept terminating for \(webView.url?.absoluteString ?? "an unloaded page")"
                + "; not reloading again"
            )
            return
        }
        webView.reload()
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A blank or scriptable target (window.open() then location=…,
        // about:blank, blob:) has no external destination and must open in-app;
        // Google's sign-in relies on exactly that.
        if let requested = navigationAction.request.url, !requested.absoluteString.isEmpty {
            switch LinkRouter.destination(for: requested) {
            case .openExternally(let url):
                NSWorkspace.shared.open(url)
                return nil
            case .compose(let mailto):
                mailtoHandler?(mailto)
                return nil
            case .allowInApp:
                // A clicked "Sign in" on a signed-out Google page belongs to
                // the tab, not to a window of its own: run the whole flow
                // in-place so the user ends up signed in where they were
                // looking. Returning nil without loading would swallow the
                // click and look like a dead button.
                if AuthSurface.shouldLoadInOpener(
                    requested: requested,
                    openerURL: webView.url,
                    isLinkActivated: navigationAction.navigationType == .linkActivated
                ) {
                    webView.load(URLRequest(url: requested))
                    return nil
                }
            }
        }
        return presentPopup(configuration: configuration, windowFeatures: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        closePopup(hosting: webView)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    // MARK: - Popups

    /// The popup webview *must* be built from the configuration WebKit passed
    /// in — any other instance raises `NSInternalInconsistencyException`. That
    /// configuration already carries the account's data store, so a sign-in or
    /// print popup keeps the session.
    private func presentPopup(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures) -> WKWebView {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.customUserAgent = WebViewFactory.userAgent
        popup.navigationDelegate = self
        popup.uiDelegate = self

        let width = windowFeatures.width?.doubleValue ?? 720
        let height = windowFeatures.height?.doubleValue ?? 640
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: max(width, 480), height: max(height, 480)),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        // `popupWindows` is the only owner; letting AppKit release the window
        // on a titlebar close would over-release it.
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = popup
        // Closing from the titlebar never reaches `webViewDidClose` — only a
        // page calling window.close() does — so the window itself has to say
        // when it goes, or its entry (and the webview under it) is retained
        // for the rest of the session.
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        popupWindows[ObjectIdentifier(popup)] = Popup(
            window: window,
            accountId: configuration.websiteDataStore.identifier
        )
        return popup
    }

    /// Closes every popup running on this account's data store. WebKit refuses
    /// to delete a store that is still in use, so account removal has to take
    /// the account's popups down before `destroyDataStore`.
    func closePopups(for accountId: UUID) {
        for (key, popup) in popupWindows where popup.accountId == accountId {
            popupWindows[key] = nil
            crashThrottle.forget(key)
            dismiss(popup.window)
        }
    }

    private func closePopup(hosting webView: WKWebView) {
        let key = ObjectIdentifier(webView)
        guard let popup = popupWindows.removeValue(forKey: key) else { return }
        crashThrottle.forget(key)
        dismiss(popup.window)
    }

    /// Drops the popup's webview before the window goes, so nothing keeps the
    /// account's data store alive.
    private func dismiss(_ window: NSWindow) {
        detachContent(of: window)
        window.close()
    }

    private func detachContent(of window: NSWindow) {
        if let popup = window.contentView as? WKWebView {
            popup.stopLoading()
            popup.navigationDelegate = nil
            popup.uiDelegate = nil
            sawSignIn.remove(popup)
        }
        window.contentView = nil
    }

    /// A titlebar close never goes through `dismiss`, so the webview has to be
    /// released here too — otherwise a hand-closed popup keeps loading on the
    /// account's data store, which is exactly what blocks `destroyDataStore`.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        for (key, popup) in popupWindows where popup.window === window {
            popupWindows[key] = nil
            crashThrottle.forget(key)
        }
        detachContent(of: window)
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let directory = Self.downloadsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        completionHandler(LinkRouter.uniqueDestination(in: directory, filename: suggestedFilename))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Log.error("download failed: \(error.localizedDescription)")
    }
}
