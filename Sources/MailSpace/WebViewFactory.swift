import WebKit

/// A reply-capable script message handler together with the content world it
/// is registered in.
///
/// The world is part of the registration rather than a call-site argument on
/// purpose: it is the only thing standing between a handler and every script
/// the page runs. A handler registered in `.page` is reachable as
/// `window.webkit.messageHandlers.<name>` by any script in any frame of any
/// page the webview loads.
struct ScriptReplyHandler {
    let name: String
    let handler: WKScriptMessageHandlerWithReply
    let contentWorld: WKContentWorld
}

/// Builds the per-account WebKit configuration and the webviews on top of it.
enum WebViewFactory {
    /// Safari 17.6 desktop user agent.
    ///
    /// Google refuses `accounts.google.com` sign-in to user agents it reads as
    /// an embedded browser (`disallowed_useragent`). The engine here genuinely
    /// *is* WebKit, so presenting Safari's UA is accurate rather than a spoof.
    /// If Google tightens detection, bump this one constant first.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    /// The `applicationNameForUserAgent` suffix WebKit also exposes to pages
    /// that sniff it separately from `navigator.userAgent`.
    static let applicationName = "Version/17.6 Safari/605.1.15"

    /// One configuration per account. Mail and Calendar share it (and therefore
    /// the same `WKWebsiteDataStore`), so one Google sign-in covers both.
    static func makeConfiguration(
        dataStoreIdentifier: UUID,
        userScripts: [WKUserScript] = [],
        messageHandlers: [String: WKScriptMessageHandler] = [:],
        replyHandlers: [ScriptReplyHandler] = []
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        configuration.applicationNameForUserAgent = applicationName
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true

        let controller = WKUserContentController()
        // The notification shim has to live in the page's own world — it
        // replaces `window.Notification`, which page scripts must see — so its
        // handler is reachable from page JS and guards the caller's origin
        // itself (see `NotificationBridge`).
        for (name, handler) in messageHandlers {
            controller.add(handler, name: name)
        }
        for registration in replyHandlers {
            controller.addScriptMessageHandler(
                registration.handler,
                contentWorld: registration.contentWorld,
                name: registration.name
            )
        }
        for script in userScripts {
            controller.addUserScript(script)
        }
        configuration.userContentController = controller

        return configuration
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = userAgent
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }

    /// Deletes an account's browser session from disk, and reports whether it
    /// really went.
    ///
    /// Two things had to be measured rather than assumed (probe under
    /// `/tmp`, macOS 15):
    ///
    /// - While anything still references the store — and
    ///   `AccountSession.configuration` does, for the object's whole lifetime
    ///   — every attempt fails with "Data store is in use (by network
    ///   process)", and retrying does not help. The session must be *released*,
    ///   not merely detached.
    /// - Even with every reference gone the first attempt still fails; the one
    ///   half a second later succeeds. So this retries, and only calls the
    ///   removal lost once the whole budget is spent.
    ///
    /// The completion carries the error because the caller has just told the
    /// user their Google session was deleted from this Mac. A stderr line is
    /// not an answer to that.
    static func destroyDataStore(
        for identifier: UUID,
        attempts: Int = 8,
        retryDelay: TimeInterval = 0.5,
        completion: ((Error?) -> Void)? = nil
    ) {
        func attempt(remaining: Int) {
            WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                guard let error else {
                    completion?(nil)
                    return
                }
                guard remaining > 1 else {
                    Log.error("could not remove data store \(identifier): \(error)")
                    completion?(error)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                    attempt(remaining: remaining - 1)
                }
            }
        }
        attempt(remaining: max(attempts, 1))
    }
}
