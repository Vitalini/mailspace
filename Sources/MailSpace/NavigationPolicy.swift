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
        "googleapis.com",
        "googleusercontent.com"
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

    static func isInApp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }

        if inAppHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return true }
        return isGoogleDomain(host)
    }

    /// True for `google.com` and its country variants (`google.co.uk`,
    /// `google.de`) plus any subdomain of them.
    private static func isGoogleDomain(_ host: String) -> Bool {
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

/// The single navigation/UI delegate shared by every account webview.
///
/// - non-Google links leave for the default browser (R12)
/// - Google popups (sign-in, print) open as in-app child windows on the same
///   session, using the exact configuration WebKit hands over (KTD7)
/// - downloads land in `~/Downloads` (R13)
final class NavigationPolicy: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private var popupWindows: [ObjectIdentifier: NSWindow] = [:]

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

        let url = LinkRouter.unwrapRedirect(requested)

        // Non-web schemes (mailto:, tel:, …) always belong to the system.
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        // Only user-initiated navigation leaves the app: a redirect or a
        // subframe load inside Gmail must not be hijacked.
        let userInitiated = navigationAction.navigationType == .linkActivated
        if userInitiated && !LinkRouter.isInApp(url) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
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

    /// KTD8: macOS may reclaim a background account's WebContent process under
    /// memory pressure. Reload so notifications and unread polling resume
    /// instead of dying silently.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    // MARK: - WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A blank target (window.open() then location=…) has no URL yet, so it
        // gets the benefit of the doubt and opens in-app.
        if let requested = navigationAction.request.url, !requested.absoluteString.isEmpty {
            let url = LinkRouter.unwrapRedirect(requested)
            guard LinkRouter.isInApp(url) else {
                NSWorkspace.shared.open(url)
                return nil
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
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = popup
        window.center()
        window.makeKeyAndOrderFront(nil)

        popupWindows[ObjectIdentifier(popup)] = window
        return popup
    }

    private func closePopup(hosting webView: WKWebView) {
        guard let window = popupWindows.removeValue(forKey: ObjectIdentifier(webView)) else { return }
        window.contentView = nil
        window.close()
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
        FileHandle.standardError.write(Data("MailSpace: download failed: \(error.localizedDescription)\n".utf8))
    }
}
