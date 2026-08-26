import WebKit

/// Resolves a live webview back to the account that owns it. Implemented by
/// the app delegate; used by the autofill, notification and polling layers.
protocol SessionLocating: AnyObject {
    func session(hosting webView: WKWebView) -> AccountSession?
    func account(for accountId: UUID) -> Account?
}

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
    private weak var delegate: (NSObject & WKNavigationDelegate & WKUIDelegate)?

    init(
        account: Account,
        userScripts: [WKUserScript] = [],
        messageHandlers: [String: WKScriptMessageHandler] = [:],
        replyHandlers: [String: WKScriptMessageHandlerWithReply] = [:]
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

    func setDelegates<D: NSObject & WKNavigationDelegate & WKUIDelegate>(_ delegate: D) {
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

    /// Tears the session down before its data store can be deleted. WebKit
    /// refuses to remove a store that is still in use, so every webview must
    /// stop loading, drop its delegates and unregister its message handlers
    /// first.
    func detach() {
        for webView in webViews {
            teardown(webView)
        }
        views.removeAll()
        configuration.userContentController.removeAllUserScripts()
        configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func teardown(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        webView.loadHTMLString("", baseURL: nil)
    }
}
