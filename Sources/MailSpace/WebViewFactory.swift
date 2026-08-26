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

    /// WebKit's *class-level* data-store calls hand their result back through
    /// `WTF::RunLoop::main()`, and that run loop only exists once something in
    /// this process has instantiated a WebKit object. Call one before that and
    /// the completion dispatch dereferences a null run loop: EXC_BAD_ACCESS at
    /// 0x40 on `com.apple.WebKit.WebsiteDataStoreIO` — a thread the caller
    /// never touched, with nothing on the stack to point back here.
    ///
    /// Measured with throwaway bundles under `/private/tmp` (macOS 26.6.2):
    ///
    /// - With nothing instantiated, `fetchAllDataStoreIdentifiers` *and*
    ///   `remove(forIdentifier:)` both segfault — whether the bundle has stores
    ///   on disk, one store, or no `~/Library/WebKit` directory at all. What is
    ///   on disk is irrelevant; only the state of the process matters.
    /// - Instantiate any store first — a webview's, `.default()`,
    ///   `.nonPersistent()`, `WKWebsiteDataStore(forIdentifier:)` — and both
    ///   return normally.
    /// - And then `remove(forIdentifier:)` on an identifier with nothing behind
    ///   it reports success rather than crashing. The earlier reading, that it
    ///   segfaults on a store that is not on disk, was this same run-loop bug
    ///   seen through the only case that had been tried.
    ///
    /// Which is why this exists rather than a caller-side guard: the launch
    /// sweep is exactly the call that runs before any webview does. A first
    /// launch has no account to build one, and so does a launch after the last
    /// account was removed — the launch that has orphans to clean up.
    ///
    /// A non-persistent store is enough, writes nothing to disk, and the
    /// initialisation outlives it, so nothing is held onto here.
    private static let webKitInitialized: Void = {
        _ = WKWebsiteDataStore.nonPersistent()
    }()

    /// The identifiers of the data stores this app has on disk.
    ///
    /// Wrapped rather than called directly so no call site can reach the raw
    /// API without the initialisation above.
    static func dataStoreIdentifiers(completion: @escaping ([UUID]) -> Void) {
        webKitInitialized
        WKWebsiteDataStore.fetchAllDataStoreIdentifiers(completion)
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
    /// Three things had to be measured rather than assumed (probes under
    /// `/tmp`, macOS 15 and 26.6):
    ///
    /// - The call segfaults outright unless a WebKit object has already been
    ///   instantiated in this process; see `webKitInitialized`, which is why
    ///   this starts by touching it. Account removal always has a session to
    ///   have done that, the launch sweep does not.
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
        webKitInitialized
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
