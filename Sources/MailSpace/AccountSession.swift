import WebKit

/// One account's live browser session: an isolated `WKWebsiteDataStore` plus
/// the Mail and Calendar webviews built on top of it.
///
/// Both webviews are created and loaded eagerly at launch and kept alive for
/// the process lifetime (KTD8). A background account has to keep receiving web
/// notifications and answering unread-feed polls, so switching accounts swaps
/// retained views rather than creating or reloading them.
final class AccountSession {
    let accountId: UUID
    private(set) var displayName: String

    private let configuration: WKWebViewConfiguration
    let mailWebView: WKWebView
    let calendarWebView: WKWebView

    init(
        account: Account,
        userScripts: [WKUserScript] = [],
        messageHandlers: [String: WKScriptMessageHandler] = [:]
    ) {
        self.accountId = account.id
        self.displayName = account.name
        self.configuration = WebViewFactory.makeConfiguration(
            dataStoreIdentifier: account.id,
            userScripts: userScripts,
            messageHandlers: messageHandlers
        )
        self.mailWebView = WebViewFactory.makeWebView(configuration: configuration)
        self.calendarWebView = WebViewFactory.makeWebView(configuration: configuration)
    }

    var webViews: [WKWebView] { [mailWebView, calendarWebView] }

    func webView(for view: AccountView) -> WKWebView {
        switch view {
        case .mail: return mailWebView
        case .calendar: return calendarWebView
        }
    }

    func view(for webView: WKWebView) -> AccountView? {
        if webView === mailWebView { return .mail }
        if webView === calendarWebView { return .calendar }
        return nil
    }

    func setDelegates<D: WKNavigationDelegate & WKUIDelegate>(_ delegate: D) {
        for webView in webViews {
            webView.navigationDelegate = delegate
            webView.uiDelegate = delegate
        }
    }

    func rename(to name: String) {
        displayName = name
    }

    /// Kicks off the initial load of both views. Safe to call more than once —
    /// a webview that already has a URL is left alone.
    func loadIfNeeded() {
        for view in AccountView.allCases {
            let webView = self.webView(for: view)
            guard webView.url == nil else { continue }
            webView.load(URLRequest(url: view.url))
        }
    }

    /// Tears the session down before its data store can be deleted. WebKit
    /// refuses to remove a store that is still in use, so every webview must
    /// stop loading, drop its delegates and unregister its message handlers
    /// first.
    func detach() {
        for webView in webViews {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            webView.loadHTMLString("", baseURL: nil)
        }
        configuration.userContentController.removeAllUserScripts()
        configuration.userContentController.removeAllScriptMessageHandlers()
    }
}
