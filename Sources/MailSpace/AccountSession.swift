import WebKit

/// Resolves a live webview back to the account that owns it. Implemented by
/// the app delegate; used by the autofill, notification and polling layers.
protocol SessionLocating: AnyObject {
    func session(hosting webView: WKWebView) -> AccountSession?
    func account(for accountId: UUID) -> Account?
}

/// Told when a webview is being discarded, so per-webview state the delegate
/// keeps does not outlive it.
///
/// `ObjectIdentifier` is the object's address, and the allocator reuses
/// addresses: without this, a webview that exhausted its crash budget would
/// hand that exhausted budget to whatever webview is allocated there next.
protocol WebViewDiscarding: AnyObject {
    func webViewWasDiscarded(_ webView: WKWebView)
}

/// What `AccountSession` needs of the object driving its webviews.
typealias AccountSessionDelegate = NSObject & WKNavigationDelegate & WKUIDelegate & WebViewDiscarding

/// One account's live browser session: an isolated `WKWebsiteDataStore` plus a
/// webview for each service the account has enabled.
///
/// Webviews are created and loaded eagerly and kept alive for the process
/// lifetime (KTD8). A background account has to keep receiving web
/// notifications and answering unread-feed polls, so switching accounts swaps
/// retained views rather than creating or reloading them. A service the
/// account has switched off gets no webview at all — and therefore no
/// notifications and no feed polling.
final class AccountSession {
    let accountId: UUID
    private(set) var displayName: String

    private let configuration: WKWebViewConfiguration
    private var views: [AccountView: WKWebView] = [:]
    private weak var delegate: AccountSessionDelegate?

    init(
        account: Account,
        userScripts: [WKUserScript] = [],
        messageHandlers: [String: WKScriptMessageHandler] = [:],
        replyHandlers: [ScriptReplyHandler] = []
    ) {
        self.accountId = account.id
        self.displayName = account.name
        self.configuration = WebViewFactory.makeConfiguration(
            dataStoreIdentifier: account.id,
            userScripts: userScripts,
            messageHandlers: messageHandlers,
            replyHandlers: replyHandlers
        )
        syncEnabledViews(with: account)
    }

    var webViews: [WKWebView] { AccountView.allCases.compactMap { views[$0] } }

    var enabledViews: [AccountView] { AccountView.allCases.filter { views[$0] != nil } }

    func webView(for view: AccountView) -> WKWebView? {
        views[view]
    }

    func view(for webView: WKWebView) -> AccountView? {
        views.first { $0.value === webView }?.key
    }

    func hosts(_ webView: WKWebView) -> Bool {
        views.values.contains { $0 === webView }
    }

    func setDelegates<D: AccountSessionDelegate>(_ delegate: D) {
        self.delegate = delegate
        for webView in webViews {
            webView.navigationDelegate = delegate
            webView.uiDelegate = delegate
        }
    }

    /// Brings the live webviews in line with the account's current settings:
    /// creates one for a newly enabled service and tears down a disabled one.
    func syncEnabledViews(with account: Account) {
        displayName = account.name

        for view in AccountView.allCases {
            switch (account.isEnabled(view), views[view]) {
            case (true, nil):
                let webView = WebViewFactory.makeWebView(configuration: configuration)
                if let delegate {
                    webView.navigationDelegate = delegate
                    webView.uiDelegate = delegate
                }
                views[view] = webView
            case (false, .some(let webView)):
                teardown(webView)
                views[view] = nil
            default:
                break
            }
        }
    }

    /// Kicks off the initial load of every enabled view. Safe to call more than
    /// once — a webview that already has a URL is left alone.
    func loadIfNeeded() {
        for (view, webView) in views where webView.url == nil {
            webView.load(URLRequest(url: view.url))
        }
    }

    /// After a sign-in on this account's shared data store, brings every view
    /// that is still on a signed-out page onto its real surface. Cookies are
    /// already shared; Gmail and Calendar simply never re-ask for a session
    /// once their signed-out page has rendered.
    ///
    /// A view already on its own app surface is never touched — that is where
    /// an unsent draft lives, and skipping it is also what stops this from
    /// looping: the test for "needs bringing back" is the same test that says
    /// sign-in is done.
    func reloadSignedOutViews() {
        for (view, webView) in views where !AuthSurface.isSignedIn(webView.url, for: view) {
            webView.load(URLRequest(url: view.url))
        }
    }

    /// Replaces one view's webview with a fresh one on the same configuration,
    /// and hands the new object back.
    ///
    /// Replacement rather than `reload()` on purpose. 68% of the measured 2.3 GB
    /// is WebKit malloc inside the WebContent processes, and an in-process
    /// reload hands that back on JSC's and libpas's own schedule, into a process
    /// that has already grown its high-water mark. Dropping the webview releases
    /// the process outright and the new page starts from baseline, so the saving
    /// is guaranteed by construction rather than hoped for. It is also the
    /// stronger fix for the second symptom: a dead long-poll or a wedged service
    /// worker in a twenty-hour page is exactly the kind of state that survives an
    /// in-process reload.
    ///
    /// The caller navigates the returned webview to the URL the old one was on,
    /// so the label and the open thread survive just as they would under
    /// `reload()`.
    ///
    /// Re-using `teardown` is not an implementation detail: that call is what
    /// fires `webViewWasDiscarded(old)`, and the crash budget, the stall token,
    /// the sign-in provenance flag and the `SSOEscort` pass are all keyed by
    /// object identity — an address the allocator is free to hand to the fresh
    /// webview next.
    func recycle(_ view: AccountView) -> WKWebView? {
        guard let old = views[view] else { return nil }

        let fresh = WebViewFactory.makeWebView(configuration: configuration)
        if let delegate {
            fresh.navigationDelegate = delegate
            fresh.uiDelegate = delegate
        }
        views[view] = fresh
        teardown(old)
        return fresh
    }

    /// Tears the session down before its data store can be deleted.
    ///
    /// WebKit refuses to remove a store anything still references, and this
    /// object is one of those things: `configuration` holds the store for the
    /// session's whole lifetime. Dropping the webviews is therefore not
    /// enough — the configuration is pointed at a throwaway in-memory store as
    /// well, and the caller has to let the session itself go (see
    /// `AppDelegate.requestRemoveAccount`).
    func detach() {
        for webView in webViews {
            teardown(webView)
        }
        views.removeAll()
        configuration.userContentController.removeAllUserScripts()
        configuration.userContentController.removeAllScriptMessageHandlers()
        configuration.websiteDataStore = .nonPersistent()
    }

    private func teardown(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        // Deliberately no final load: this webview is on its way out, and
        // starting a fresh one would put the account's data store back in use
        // at the exact moment the caller is trying to delete it.
        delegate?.webViewWasDiscarded(webView)
    }
}
