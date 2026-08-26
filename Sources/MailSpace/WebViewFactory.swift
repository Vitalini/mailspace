import WebKit

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
        messageHandlers: [String: WKScriptMessageHandler] = [:]
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier)
        configuration.applicationNameForUserAgent = applicationName
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.isElementFullscreenEnabled = true

        let controller = WKUserContentController()
        for (name, handler) in messageHandlers {
            controller.add(handler, name: name)
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

    /// Deletes an account's browser session from disk. Only safe once every
    /// webview using the store has been released (see `AccountSession.detach`).
    static func destroyDataStore(for identifier: UUID, completion: (() -> Void)? = nil) {
        WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
            if let error {
                FileHandle.standardError.write(
                    Data("MailSpace: could not remove data store \(identifier): \(error)\n".utf8)
                )
            }
            completion?()
        }
    }
}
