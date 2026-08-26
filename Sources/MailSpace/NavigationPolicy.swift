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
    ///
    /// The host test is `isGoogleDomain`, not a bare `hasSuffix`: without the
    /// dot boundary `notgoogle.com/url?q=…` unwrapped too, and since the
    /// webview then navigates to the *original* URL rather than the unwrapped
    /// one, a look-alike domain got to load inside the account's session.
    static func unwrapRedirect(_ url: URL) -> URL {
        guard
            let host = url.host?.lowercased(),
            isGoogleDomain(host) || matches(host: host, domain: "googlemail.com"),
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

    /// The same decision, told which frame the navigation would take over and
    /// whether an `SSOEscort` covers it.
    ///
    /// Navigation *type* is deliberately not part of this. Gating the external
    /// hand-off on `.linkActivated` meant a `302`, a `window.location =` or a
    /// form POST put an arbitrary site inside the account's cookie jar, with
    /// MailSpace's injected scripts attached — `google.com/url?q=…` followed as
    /// `.other`, redirected, and the redirect was `.other` again.
    ///
    /// - `isMainFrameTarget`: false only for a subframe load. Gmail and
    ///   Calendar embed foreign content — ads, maps, tracked images — and
    ///   sending those to the browser would open a window per embed. A
    ///   subframe cannot navigate the page the user is looking at, so it stays.
    /// - `isSSOEscorted`: a live `SSOEscort` pass authorises this one hop off
    ///   Google. A Workspace account is redirected to its own identity provider
    ///   on a host MailSpace has never heard of; handing that to the browser
    ///   would leave the sign-in unfinishable, because the browser has no
    ///   access to this account's data store. Everything that keeps the pass
    ///   narrow lives in `SSOEscort` — this function only obeys it.
    static func destination(for requested: URL, isMainFrameTarget: Bool, isSSOEscorted: Bool) -> Destination {
        let decision = destination(for: requested)
        guard case .openExternally = decision else { return decision }
        return isMainFrameTarget && !isSSOEscorted ? decision : .allowInApp
    }

    /// Whether an `SSOEscort` has any say over this navigation at all: only a
    /// whole page, on a host that would otherwise leave for the browser.
    ///
    /// The escort is consulted through this so a pass is never *spent* on a
    /// navigation that was going to stay in-app regardless — every Gmail hop
    /// would otherwise burn the budget a real sign-in needs.
    static func needsEscort(for requested: URL, isMainFrameTarget: Bool) -> Bool {
        guard isMainFrameTarget else { return false }
        if case .openExternally = destination(for: requested) { return true }
        return false
    }

    static func isInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }

        if inAppHosts.contains(where: { matches(host: host, domain: $0) }) { return true }
        return isGoogleDomain(host)
    }

    /// `host` is `domain` itself or a subdomain of it. The dot matters:
    /// `notgoogle.com` is not `google.com`.
    static func matches(host: String, domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    /// True for `google.com` and its country variants (`google.co.uk`,
    /// `google.de`) plus any subdomain of them.
    ///
    /// The suffix after `google.` used to be "up to six letters and dots",
    /// which admits far more than country variants: `google.ev.io` and
    /// `google.hax.io` both fit, and both are a subdomain anyone who owns
    /// `ev.io` or `hax.io` can create — a look-alike that MailSpace would have
    /// loaded inside the account's session. Google's public suffixes have three
    /// shapes and no more, so they are matched as shapes.
    static func isGoogleDomain(_ host: String) -> Bool {
        // A fully-qualified name may carry the root dot; it names the same host.
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }

        guard let range = host.range(of: "google.", options: .backwards) else { return false }

        let before = host[..<range.lowerBound]
        guard before.isEmpty || before.hasSuffix(".") else { return false }

        return isGoogleSuffix(String(host[range.upperBound...]))
    }

    /// `com`, a bare country code (`de`, `co`, `jp`), or a country code under
    /// `co`/`com` (`co.uk`, `com.au`, `com.br`). Anything else is somebody
    /// else's domain with `google` for a label.
    private static func isGoogleSuffix(_ suffix: String) -> Bool {
        let labels = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isLetter) }) else { return false }

        switch labels.count {
        case 1:
            return labels[0] == "com" || labels[0].count == 2
        case 2:
            return (labels[0] == "co" || labels[0] == "com") && labels[1].count == 2
        default:
            return false
        }
    }

    /// Reduces a server-supplied download name to something that can only land
    /// inside the download directory.
    ///
    /// `suggestedFilename` comes from the `Content-Disposition` header, so it
    /// is whatever the server said. `../../Library/LaunchAgents/x.plist`
    /// resolved straight out of `~/Downloads` — and the collision loop never
    /// fired to catch it, because the escaped path was a new one.
    static func safeFilename(_ suggested: String) -> String {
        let last = (suggested as NSString).lastPathComponent
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !trimmed.contains("/"),           // `lastPathComponent` of "/" is "/"
            !trimmed.allSatisfy({ $0 == "." }) // ".", "..", "…"
        else { return "download" }
        return trimmed
    }

    /// Picks a non-colliding destination in `directory`, appending " (2)",
    /// " (3)" … the way Safari does.
    static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let name = safeFilename(filename)
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
    /// bridge, the device/passkey challenge helper, the short sign-in host, and
    /// the "Before you continue" consent screen, which renders in the middle of
    /// the chain for EU users. That last one matters for `provenance` — a page
    /// that actually renders mid-chain and is not listed here would be read as
    /// the chain ending.
    private static let signInHosts: Set<String> = [
        "accounts.youtube.com",
        "consent.google.com",
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

        let segments = url.path.split(separator: "/").map { $0.lowercased() }

        if isSignInHost(host) {
            // Creating a *brand new* Google account is not this tab's sign-in
            // finishing: there is no session the tab is waiting on, and the
            // identity that comes out of it is not the one the account record,
            // its name and its Keychain item describe. So it is an ordinary
            // page — it gets its own window rather than taking over the tab of
            // an account that already exists.
            return segments.contains("signup") ? .other : .signIn
        }

        switch host {
        case "mail.google.com", "mail.googlemail.com":
            return isAppPath(segments, root: "mail") ? .app(.mail) : .other
        case "calendar.google.com":
            return isAppPath(segments, root: "calendar") ? .app(.calendar) : .other
        default:
            return .other
        }
    }

    /// What a webview should remember about its sign-in after committing a page.
    enum Provenance: Equatable {
        /// A sign-in step: this webview is authenticating.
        case record
        /// The chain ended somewhere that is neither a sign-in step nor an app
        /// surface. Forget it — otherwise a much later, unrelated arrival on an
        /// app surface reads as a sign-in that has just finished and yanks the
        /// account's other tabs onto their home surfaces.
        case clear
        /// Says nothing either way; whatever is recorded stands.
        case keep
    }

    /// Only a *Google* page that is neither a sign-in step nor an app surface
    /// ends the chain — the marketing page a signed-out tab bounces to, a Drive
    /// preview, `myaccount.google.com`.
    ///
    /// A foreign host is left alone on purpose: a Workspace account signs in
    /// through its own identity provider on a host MailSpace cannot recognise,
    /// and clearing there would strand the very tabs the sign-in exists to
    /// bring back. Nothing else reaches a foreign host in an account webview's
    /// main frame — `NavigationPolicy` hands those to the browser unless this
    /// same flag is already set.
    ///
    /// The trade this makes: if Google ever routes the chain through a Google
    /// host that is not an auth host, completion is missed and the user is back
    /// to closing the popup by hand. That is recoverable; a flag that never
    /// clears silently reloads tabs out from under them.
    static func provenance(for url: URL?) -> Provenance {
        switch classify(url) {
        case .signIn:
            return .record
        case .app:
            // `didFinish` is what consumes the flag here; clearing on commit
            // would take it one callback too early.
            return .keep
        case .other:
            guard let url else { return .keep }
            return LinkRouter.isInApp(url) ? .clear : .keep
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

/// The narrow, expiring pass that lets one Google sign-in finish through a
/// customer's identity provider — and nothing else — inside the account's
/// webview.
///
/// What this replaces was a sticky per-webview flag. Any commit on an
/// `accounts.google.<tld>` page set it; only a *Google* page that was neither
/// sign-in nor app surface cleared it, and on a foreign host the rule was
/// "keep". So the first foreign page to load under the flag kept the flag on
/// for the next one, for the rest of the webview's life.
///
/// That was exploitable with no bug in Google at all. Mail a link to the
/// genuine authorization endpoint with an attacker's `redirect_uri`
/// (`accounts.google.com/o/oauth2/v2/auth?client_id=…&redirect_uri=https://evil.example/cb`):
/// the real Google consent page commits and arms the flag, the user presses
/// Continue, Google's `302` delivers the attacker's page into the account's
/// data store — and the tab then stays in "follow anything" mode indefinitely.
/// MailSpace has no address bar, so the page is indistinguishable from Google's
/// own.
///
/// The pass is therefore narrow, spent, and short-lived:
///
/// - **Armed** only by committing a Google sign-in step that is not a
///   *delegated* authorization endpoint. Those endpoints exist precisely to
///   hand the browser to an arbitrary third-party `redirect_uri`; MailSpace is
///   never that third party.
/// - **Re-armed** with a fresh budget every time the chain comes back and
///   commits another Google sign-in page — which is what a real SSO bounce
///   does.
/// - **Expires** after `timeToLive`, or after `hopBudget` escorted
///   destinations, whichever comes first.
/// - **Pinned** to one foreign host the moment a foreign page commits under
///   it: after that only that host (and Google, which never needs a pass) may
///   keep the tab. The IdP's own login POST still works; the attacker's landing
///   page cannot move the tab anywhere else.
/// - **Dropped** when the webview commits a Google page that is neither a
///   sign-in step nor an app surface, when the sign-in completes, and when the
///   webview is discarded.
///
/// The trade: an SSO chain that renders on one foreign host and then hands off
/// to a *second* one — a separate MFA provider, say — loses the pass and gets
/// the browser. That fails safe and the user can start the sign-in again;
/// a pass that never ends does not.
///
/// Pure logic with an injected clock, so all of it is testable.
enum SSOEscort {
    /// One sign-in step's pass. Long enough for a password manager, a TOTP app
    /// and a slow identity provider; short enough that a tab parked on a
    /// sign-in page is not a standing invitation.
    static let timeToLive: TimeInterval = 120

    /// How many escorted *destinations* one pass may authorise. Server
    /// redirects inside a navigation the pass already paid for are refunded
    /// (`didReceiveServerRedirectForProvisionalNavigation`), so a long redirect
    /// chain costs one.
    static let hopBudget = 6

    struct Pass: Equatable {
        var armedAt: Date
        var spent: Int = 0
        /// The foreign host that has actually rendered under this pass, once
        /// one has. From then on it is the only foreign host the pass covers.
        var landedHost: String?
    }

    enum Outcome: Equatable {
        /// Stays in the account's webview; keep this pass.
        case allow(Pass)
        /// The user's browser owns it.
        case deny
    }

    /// Whether committing this URL may arm a pass.
    static func arms(_ url: URL?) -> Bool {
        guard let url, AuthSurface.classify(url) == .signIn else { return false }
        return !isDelegatedAuthorization(url)
    }

    /// Google's OAuth authorization and consent endpoints — `/o/oauth2/v2/auth`,
    /// `/signin/oauth/consent`, `/o/oauth2/postmessageRelay`. They are Google
    /// pages on a Google host, and their entire purpose is to redirect to a
    /// `redirect_uri` chosen by whoever registered the client. Anyone can
    /// register one, so a pass armed here is a pass handed to a stranger.
    static func isDelegatedAuthorization(_ url: URL) -> Bool {
        url.path.split(separator: "/").contains { $0.lowercased().hasPrefix("oauth") }
    }

    /// The decision for one navigation that would otherwise leave for the
    /// browser (see `LinkRouter.needsEscort`).
    static func authorize(_ pass: Pass?, to url: URL, now: Date) -> Outcome {
        guard var pass else { return .deny }
        let age = now.timeIntervalSince(pass.armedAt)
        guard age >= 0, age <= timeToLive else { return .deny }
        guard pass.spent < hopBudget else { return .deny }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .deny }
        if let landed = pass.landedHost, landed != host { return .deny }

        pass.spent += 1
        return .allow(pass)
    }

    /// What committing `url` does to the pass.
    static func afterCommit(_ pass: Pass?, of url: URL?, now: Date) -> Pass? {
        if arms(url) { return Pass(armedAt: now) }

        guard
            let url,
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else {
            // `about:blank`, `blob:`, `data:`, nothing at all: says neither way.
            return pass
        }

        guard !LinkRouter.isInApp(url) else {
            // An app surface is left alone — `didFinish` there is what completes
            // the sign-in, and completing it drops the pass. Any other Google
            // page ends the chain, delegated authorization endpoints included.
            if case .app = AuthSurface.classify(url) { return pass }
            return nil
        }

        // A foreign page rendered. The pass now covers that host and no other.
        guard var pass else { return nil }
        pass.landedHost = host
        return pass
    }

    /// A server redirect inside a navigation the pass already authorised is
    /// part of that navigation, not a new destination.
    static func refunding(_ pass: Pass?) -> Pass? {
        guard var pass else { return nil }
        pass.spent = max(0, pass.spent - 1)
        return pass
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

/// A dictionary keyed by object identity, holding its keys weakly.
///
/// Same reason as `WeakObjectSet`: `ObjectIdentifier` is the object's address
/// and the allocator reuses addresses, so a value left behind by a dead webview
/// must not be handed to whatever is allocated there next — here that would be
/// a fresh webview inheriting somebody else's live sign-in pass.
struct WeakObjectMap<Key: AnyObject, Value> {
    private struct Entry {
        weak var key: AnyObject?
        var value: Value
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    var count: Int { entries.values.filter { $0.key != nil }.count }

    subscript(key: Key) -> Value? {
        get {
            guard let entry = entries[ObjectIdentifier(key)], entry.key === key else { return nil }
            return entry.value
        }
        set {
            let id = ObjectIdentifier(key)
            guard let newValue else {
                entries[id] = nil
                return
            }
            entries = entries.filter { $0.value.key != nil }
            entries[id] = Entry(key: key, value: newValue)
        }
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        let existing = self[key]
        entries[ObjectIdentifier(key)] = nil
        return existing
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
final class NavigationPolicy: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, NSWindowDelegate, WebViewDiscarding {
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

    /// One in-flight download, and the account whose data store it is running
    /// on. WebKit refuses to delete a store anything still holds, and a
    /// download holds one just as firmly as a webview does.
    private struct ActiveDownload {
        let download: WKDownload
        let accountId: UUID?
    }

    private var popupWindows: [ObjectIdentifier: Popup] = [:]
    private var downloads: [ObjectIdentifier: ActiveDownload] = [:]
    private var crashThrottle = CrashThrottle()
    /// Webviews that have been through a sign-in step. Landing on an app
    /// surface only means "signed in" for these — Gmail's own print and
    /// compose popups land on the very same URLs.
    ///
    /// Deliberately *not* the same state as `escorts`: this one may live as
    /// long as the user takes to get through 2FA, because all it decides is
    /// whether arriving on the inbox counts as a sign-in finishing. Letting a
    /// page off Google is the other question entirely, and it expires.
    private var sawSignIn = WeakObjectSet<WKWebView>()
    /// Live `SSOEscort` passes: the only thing that lets a foreign page take
    /// over an account webview's main frame.
    private var escorts = WeakObjectMap<WKWebView, SSOEscort.Pass>()
    /// Webviews the crash throttle has stopped reloading. Held so the tab has a
    /// way back: without one, three terminations left it blank until the app
    /// was restarted.
    private var stalled = WeakObjectSet<WKWebView>()

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

        // A `nil` target frame is a new window, which is as much "a whole page
        // the user will look at" as the main frame is.
        let isMainFrameTarget = navigationAction.targetFrame?.isMainFrame ?? true
        let isSSOEscorted = spendEscort(on: webView, requested: requested, isMainFrameTarget: isMainFrameTarget)
        let decision = LinkRouter.destination(
            for: requested,
            isMainFrameTarget: isMainFrameTarget,
            isSSOEscorted: isSSOEscorted
        )

        switch decision {
        case .allowInApp:
            decisionHandler(.allow)

        case .compose(let mailto):
            // Our own compose, never the system's default mail app — that
            // could be MailSpace itself and loop.
            mailtoHandler?(mailto)
            decisionHandler(.cancel)

        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    /// Asks this webview's `SSOEscort` pass to cover one navigation, and spends
    /// a step of it when it does. Only ever consulted for a navigation that
    /// would otherwise leave for the browser, so ordinary Gmail traffic cannot
    /// burn the budget a real sign-in needs.
    private func spendEscort(on webView: WKWebView, requested: URL, isMainFrameTarget: Bool) -> Bool {
        guard LinkRouter.needsEscort(for: requested, isMainFrameTarget: isMainFrameTarget) else { return false }

        switch SSOEscort.authorize(escorts[webView], to: LinkRouter.unwrapRedirect(requested), now: Date()) {
        case .allow(let pass):
            escorts[webView] = pass
            return true
        case .deny:
            return false
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
        adopt(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        adopt(download, from: webView)
    }

    /// Takes the download over *and* remembers whose data store it is running
    /// on, so removing that account can stop it.
    private func adopt(_ download: WKDownload, from webView: WKWebView) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = ActiveDownload(
            download: download,
            accountId: webView.configuration.websiteDataStore.identifier
        )
    }

    /// Keeps the webview's sign-in provenance in step with what it just landed
    /// on. Provenance is what separates a real sign-in from Gmail's print and
    /// compose popups, which finish on the same `mail.google.com/mail/u/0/…`
    /// URLs — and clearing it is what stops a tab that merely passed through
    /// `accounts.google.com` from claiming a sign-in hours later.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        switch AuthSurface.provenance(for: webView.url) {
        case .record: sawSignIn.insert(webView)
        case .clear: sawSignIn.remove(webView)
        case .keep: break
        }
        // The off-Google pass is kept separately and on much stricter terms;
        // see `SSOEscort`.
        escorts[webView] = SSOEscort.afterCommit(escorts[webView], of: webView.url, now: Date())
    }

    /// A `302` inside a navigation the pass already authorised is that same
    /// navigation, so it must not cost another destination out of the budget.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        escorts[webView] = SSOEscort.refunding(escorts[webView])
    }

    /// Sign-in is finished the moment a webview that was authenticating settles
    /// on an app surface. `didFinish` rather than `decidePolicyFor` is what
    /// makes that safe: signed out, `mail.google.com/mail/u/0/` only ever
    /// appears as a redirect hop back to `accounts.google.com`, so a *finished*
    /// navigation there is itself the proof the session took.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard case .app = AuthSurface.classify(webView.url) else { return }
        completeSignIn(for: webView)
    }

    /// Ends the sign-in this webview was running — once, whichever way it ends.
    ///
    /// Two endings reach here. The webview settles on an app surface
    /// (`didFinish`), or Google closes its own popup once auth is done, the
    /// `window.opener` pattern OAuth flows use (`webViewDidClose`). Only the
    /// first was handled, so a popup Google closed itself vanished tidily while
    /// the owning tab sat on the signed-out page — the original bug, minus the
    /// stray window. `sawSignIn.remove` reports membership exactly once, so
    /// whichever ending arrives first wins and the other is a no-op.
    private func completeSignIn(for webView: WKWebView) {
        // Whatever else happens, the sign-in is over: nothing has any further
        // business leaving Google in this webview.
        escorts.removeValue(forKey: webView)
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
                + "; not reloading again until the tab is selected or reloaded by hand"
            )
            // Remembered rather than abandoned: the throttle exists to stop a
            // reload loop, not to retire the tab for the rest of the session.
            stalled.insert(webView)
            return
        }
        webView.reload()
    }

    /// How a webview is actually brought back — which is not always `reload()`.
    enum Recovery: Equatable {
        /// The webview has a page. Reloading it is the retry.
        case reload
        /// It never got one. `reload()` on a webview whose `url` is `nil` does
        /// nothing at all, so the tab that crashed on its very first load — the
        /// only tab that reaches the throttle before committing anything —
        /// stayed blank while the one recovery it gets was consumed. Re-navigate
        /// to the view's own entry point instead, the same way the initial load
        /// does.
        case load(URL)
        /// No page and nowhere to go. Nothing may be consumed for this.
        case impossible
    }

    /// Pure, so the "reload() on a blank webview" rule is covered by a test
    /// rather than by a webview that has to crash first.
    static func recovery(currentURL: URL?, baseURL: URL?) -> Recovery {
        if currentURL != nil { return .reload }
        guard let baseURL else { return .impossible }
        return .load(baseURL)
    }

    /// Which web view ⌘R acts on: the key window's own, whatever that window
    /// is. A popup brings its own web view and has no entry point to fall back
    /// to; the main window's is the selected tab's, which does.
    ///
    /// Generic over the web view so the routing rule is testable without
    /// standing up WebKit.
    static func reloadTarget<View: AnyObject>(
        keyWindowWebView: View?,
        selectedTab: (webView: View, baseURL: URL)?
    ) -> (webView: View, baseURL: URL?)? {
        if let keyWindowWebView { return (keyWindowWebView, nil) }
        guard let selectedTab else { return nil }
        return (selectedTab.webView, selectedTab.baseURL)
    }

    /// Gives a webview the throttle gave up on another chance, and says whether
    /// there was anything to recover. Driven by the user bringing the tab up,
    /// so the retry rate is bounded by them rather than by the crashing page.
    ///
    /// `baseURL` is the view's own entry point, needed because a webview that
    /// crashed before committing anything has no URL to reload.
    @discardableResult
    func recoverIfStalled(_ webView: WKWebView, baseURL: URL?) -> Bool {
        guard stalled.contains(webView) else { return false }

        let action = Self.recovery(currentURL: webView.url, baseURL: baseURL)
        // The stall token is the tab's one way back. Spending it on a recovery
        // that cannot happen leaves the tab blank for the rest of the session.
        guard action != .impossible else { return false }

        stalled.remove(webView)
        crashThrottle.forget(ObjectIdentifier(webView))
        perform(action, on: webView)
        return true
    }

    /// Reloads a webview the user asked for by hand, re-navigating rather than
    /// calling `reload()` on one that never loaded a page.
    func reload(_ webView: WKWebView, baseURL: URL?) {
        clearCrashThrottle(for: webView)
        perform(Self.recovery(currentURL: webView.url, baseURL: baseURL), on: webView)
    }

    private func perform(_ action: Recovery, on webView: WKWebView) {
        switch action {
        case .reload: webView.reload()
        case .load(let url): webView.load(URLRequest(url: url))
        case .impossible: break
        }
    }

    /// Wipes the crash record for a webview the user has explicitly reloaded,
    /// so a deliberate retry always starts from a full burst.
    func clearCrashThrottle(for webView: WKWebView) {
        crashThrottle.forget(ObjectIdentifier(webView))
        stalled.remove(webView)
    }

    // MARK: - WebViewDiscarding

    /// The throttle and the provenance set are keyed by object identity, and
    /// the allocator reuses addresses: a webview dropped by
    /// `AccountSession.syncEnabledViews` (Mail switched off, then on again)
    /// would otherwise hand its exhausted crash budget to the fresh webview
    /// that lands at the same address.
    func webViewWasDiscarded(_ webView: WKWebView) {
        crashThrottle.forget(ObjectIdentifier(webView))
        stalled.remove(webView)
        sawSignIn.remove(webView)
        escorts.removeValue(forKey: webView)
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
        // Google closing its own sign-in popup is the auth finishing just as
        // much as landing on the inbox is; the owning tab has to be told either
        // way. One-shot, so this cannot double up with the `didFinish` path.
        completeSignIn(for: webView)
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
            dismiss(popup.window)
        }
    }

    /// The web view a popup window of ours is hosting, if this is one of ours.
    ///
    /// ⌘R needs it: routing "Reload Tab" through the main window's selected tab
    /// meant a Docs, print or sign-in popup could never be reloaded, and
    /// pressing ⌘R while one was focused silently reloaded a window the user
    /// was not even looking at.
    func popupWebView(in window: NSWindow?) -> WKWebView? {
        guard let window, popupWindows.values.contains(where: { $0.window === window }) else { return nil }
        return window.contentView as? WKWebView
    }

    private func closePopup(hosting webView: WKWebView) {
        guard let popup = popupWindows.removeValue(forKey: ObjectIdentifier(webView)) else { return }
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
            // The single place every per-webview record is forgotten, so no
            // popup teardown path can leave one behind.
            webViewWasDiscarded(popup)
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

    func downloadDidFinish(_ download: WKDownload) {
        downloads[ObjectIdentifier(download)] = nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads[ObjectIdentifier(download)] = nil
        Log.error("download failed: \(error.localizedDescription)")
    }

    /// Cancels every download still running on this account's data store.
    ///
    /// A download in flight holds the store exactly as a webview does, and
    /// nothing used to take it down: "click a Gmail attachment, then remove the
    /// account" deleted the account row while `remove(forIdentifier:)` kept
    /// failing, so the Google session stayed on disk — under a dialog that had
    /// just promised it was deleted.
    func cancelDownloads(for accountId: UUID) {
        for (key, active) in downloads where active.accountId == accountId {
            downloads[key] = nil
            active.download.cancel { _ in }
        }
    }
}
