import AppKit
import WebKit

/// Proves, against a real `WKWebView` and the shipping `NavigationPolicy`, that
/// clicking a file actually puts a file on disk — through every shape a Gmail
/// download arrives in, once more on a webview the recycler has replaced, and
/// that a download which *cannot* proceed says so instead of doing nothing.
///
/// The bug this exists to stop coming back: the download path had no test that
/// looked at the disk. `decidePolicyFor navigationResponse` decided
/// download-versus-display on `canShowMIMEType` alone, so an attachment WebKit
/// could render was rendered — into the hidden frame Gmail points at the
/// attachment URL, where it is indistinguishable from nothing happening. Every
/// unit test in the suite passed throughout. So this probe asserts on **files**,
/// and on the cases that must produce none: a response nobody asked to save, and
/// a download that cannot be written anywhere.
///
/// Every step waits on the thing it is about — a file landing, a render
/// finishing, a refusal being reported — never on a fixed sleep. A probe whose
/// answer depends on how busy the Mac is teaches people to ignore a red run.
///
/// ## The harness's server
///
/// The page comes from a `WKURLSchemeHandler` on a scheme of this probe's own,
/// and every download is a `Blob` the page mints. **No network, no listening
/// socket, no Google host, no account, no mail**; nothing about this Mac's
/// connectivity, firewall or hosts file is touched.
///
/// Blobs rather than a fixture server because they are the only transport that
/// carries a real `WKDownload` without one: WebKit rebuilds a custom scheme's
/// response and will not turn one into a download at all (measured), and a
/// loopback HTTP server would need App Transport Security relaxed in the
/// shipping `Info.plist` plus a listening socket on the owner's daily-driver
/// Mac. A blob load goes through the same `decidePolicyFor navigationResponse`
/// → `didBecome download` → `decideDestinationUsing` → `downloadDidFinish`
/// path a real attachment does, which is the path that broke.
///
/// What a blob cannot carry is a header, so the `Content-Disposition` half of
/// the rule is settled in `swift test` (`NavigationResponsePolicyTests`) and
/// asserted here directly against the shipping predicate — the `attachmentRule`
/// field in the report line.
///
/// ## Nothing reaches a display
///
/// The activation policy is `.prohibited`, the content window is ordered out
/// before the run loop turns, and the two seams that would otherwise draw —
/// `NavigationPolicy.presentPopupWindow` and `NavigationPolicy.reportFailure` —
/// are replaced with recording stubs. The failure stub is an assertion in its
/// own right: the last case proves a refused download reports itself.
final class DownloadProbe: NSObject, WKURLSchemeHandler {
    static let scheme = "msattachment"
    private static let host = "mail.fixture"
    private static let page = URL(string: "\(scheme)://\(host)/inbox")!

    /// A blob of a type nothing renders, so the response alone decides.
    private static let fileBlob =
        "URL.createObjectURL(new Blob(['fixture bytes'], {type: 'application/octet-stream'}))"
    /// A blob WebKit is perfectly happy to render, and nothing asks it to save.
    private static let renderableBlob =
        "URL.createObjectURL(new Blob(['%PDF-1.4\\n%%EOF\\n'], {type: 'application/pdf'}))"

    private let settings = AppSettings(defaults: .standard)
    private let policy: NavigationPolicy
    private let account = Account(name: "MailSpace download probe", calendarEnabled: false)
    private var session: AccountSession?
    private var window: NSWindow?

    private let downloadDirectory: URL
    private let lockedDirectory: URL

    /// What each case observed, in order, for the report line.
    private var notes: [String] = []
    private var announced = 0
    private var popupsPresented = 0
    private var popupsClosed = 0
    private var failureReports: [String] = []
    private var logLines: [String] = []
    private var previousSink: ((String) -> Void)?
    private var pageLoads = 0
    private var onPageLoad: (() -> Void)?
    private var index = 0
    private var reloads = 0
    private var finished = false

    override init() {
        policy = NavigationPolicy(settings: settings)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceDownloadProbe-\(UUID().uuidString)", isDirectory: true)
        downloadDirectory = root.appendingPathComponent("downloads", isDirectory: true)
        lockedDirectory = root.appendingPathComponent("locked", isDirectory: true)
        super.init()
    }

    // MARK: - The fixture server

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url ?? Self.page
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        ) else {
            task.didFailWithError(NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown))
            return
        }
        task.didReceive(response)
        task.didReceive(Data(Self.html.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// The page every case is driven from. Synthetic throughout: no mail, no
    /// account, no real filename.
    private static let html = "<!DOCTYPE html><html><body>fixture</body></html>"

    // MARK: - The cases

    /// What the run had reached when a step was started, so the step can be
    /// judged on what *it* changed.
    private struct Snapshot {
        let files: Int
        let announced: Int
        let failures: Int
        let pageLoads: Int
    }

    /// One driven shape. `expectsFile` is what the owner would call "it worked".
    ///
    /// `settled` is the condition the step is *about*, and waiting on it rather
    /// than on a clock is the difference between a probe and a coin toss. The
    /// fixed two-second window this replaces attributed a download that landed
    /// at 2.1s to the following step: one case read zero files, the next read
    /// two, and `make smoke` went red for reasons that had nothing to do with
    /// downloads. A red run nobody believes is worse than no run at all.
    private struct Step {
        let name: String
        let expectsFile: Bool
        let action: (DownloadProbe) -> Void
        /// Default: the file this step exists to produce has arrived *and* been
        /// announced. Both, because WebKit creates the file while it is still
        /// writing it, so the directory alone is true too early.
        var settled: (DownloadProbe, Snapshot) -> Bool = { probe, before in
            probe.announced > before.announced && probe.savedFiles() > before.files
        }
    }

    /// Clicks a freshly made link, optionally into a new window.
    private static func clickScript(target: String? = nil, download: String? = nil) -> String {
        """
        var a = document.createElement('a');
        a.href = \(fileBlob);
        \(target.map { "a.target = '\($0)';" } ?? "")
        \(download.map { "a.download = '\($0)';" } ?? "")
        a.textContent = 'file';
        document.body.appendChild(a);
        a.click();
        """
    }

    /// A suggested filename of `characters` Cyrillic letters plus `.pdf`.
    ///
    /// Cyrillic because the limit that bit is **255 bytes**, not 255
    /// characters, and UTF-8 spends two bytes on each of these — so 264 of them
    /// is 528 bytes and the write failed, with WebKit reporting it as
    /// `NSURLErrorCancelled (-999)`, which the app then read as the user
    /// cancelling. No file, no message. Synthetic throughout: the letter is
    /// repeated, and nothing here came out of anyone's mail.
    private static func longName(_ characters: Int) -> String {
        String(repeating: "и", count: characters) + ".pdf"
    }

    private static let steps: [Step] = [
        // The plain click.
        Step(name: "link", expectsFile: true) { $0.run(script: clickScript()) },
        // target="_blank": WebKit asks for a window first, and the navigation
        // in it turns out to be a file.
        Step(name: "blank", expectsFile: true) { $0.run(script: clickScript(target: "_blank")) },
        // window.open, which must get a window back rather than null.
        Step(name: "windowopen", expectsFile: true) { $0.run(script: "window.open(\(fileBlob))") },
        // A scripted navigation carrying no disposition at all — no click, no
        // `download` attribute, nothing but the response to decide on.
        Step(name: "nodisposition", expectsFile: true) { $0.run(script: "location.href = \(fileBlob)") },
        // The shape the owner actually hit: an invisible frame. Rendering here
        // is indistinguishable from nothing happening.
        Step(name: "hiddenframe", expectsFile: true) {
            $0.run(script: """
            var f = document.createElement('iframe');
            f.style.display = 'none';
            f.src = \(fileBlob);
            document.body.appendChild(f);
            """)
        },
        // The three names the owner measured. 204 characters landed; 264 and
        // 404 disappeared with nothing said, because the destination was longer
        // than a path component may be and WebKit called that a cancellation.
        Step(name: "long204", expectsFile: true) { $0.run(script: clickScript(download: longName(204))) },
        Step(name: "long264", expectsFile: true) { $0.run(script: clickScript(download: longName(264))) },
        Step(name: "long404", expectsFile: true) { $0.run(script: clickScript(download: longName(404))) },
        // The recycler's replacement webview. Nothing is re-wired by hand: this
        // is `AccountSession.recycle`, the call the tick makes at twelve hours.
        Step(name: "recycled", expectsFile: false, action: { $0.recycle() }, settled: { probe, _ in
            probe.webView != nil
        }),
        Step(name: "recycledlink", expectsFile: true) { $0.run(script: clickScript()) },
        // The control. Renderable, and nothing asked for it to be saved, so this
        // one must open — a policy that downloaded everything would otherwise
        // pass this probe.
        // Settled on the render *finishing*, not on the URL committing. The
        // next step puts the tab back on the fixture page, and issuing that
        // load into a half-rendered PDF cancels it — which took the WebContent
        // process with it often enough to make one run in ten fail somewhere
        // else entirely. A step is over when the thing it is testing has
        // happened, not when it has started.
        Step(
            name: "renders",
            expectsFile: false,
            action: { $0.run(script: "location.href = \(renderableBlob)") },
            settled: { probe, before in
                probe.pageLoads > before.pageLoads
                    && (probe.webView?.url?.absoluteString.hasPrefix("blob:") ?? false)
            }
        ),
        // And the one that must never be silent: a download that cannot be
        // written anywhere. No file, and the user is told in words.
        Step(
            name: "refused",
            expectsFile: false,
            action: {
                $0.settings.downloadDirectory = $0.lockedDirectory
                $0.run(script: clickScript())
            },
            settled: { probe, before in probe.failureReports.count > before.failures }
        )
    ]

    /// How many files the run as a whole must put on disk. Every step that
    /// expects one, counted once — checked at the end as well as per step, so a
    /// file that arrives late cannot be credited to the wrong case.
    private static var expectedFiles: Int { steps.filter(\.expectsFile).count }

    /// The longest a single step may take before the run is called broken.
    /// Every one of them settles in well under a second in practice; this is
    /// only here so a wedged step reports rather than hangs.
    private static let stepDeadline: TimeInterval = 15

    // MARK: - The run

    func run(timeout: TimeInterval = 120) {
        SelfTest.armWatchdog(timeout) { [weak self] in
            "downloads result=TIMEOUT at=\(self?.currentStepName ?? "start") "
                + (self?.notes.joined(separator: " ") ?? "")
        }
        guard SelfTest.isSelfTestBundle else {
            SelfTest.finish("downloads result=FAILED reason=not-the-self-test-bundle")
        }

        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: lockedDirectory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDirectory.path)
        } catch {
            SelfTest.finish("downloads result=FAILED reason=fixture-setup error=\(error.localizedDescription)")
        }

        // The header half of the rule, against the shipping predicate and a real
        // `HTTPURLResponse`. See the note about blobs above.
        notes.append("attachmentRule=\(Self.attachmentRuleHolds ? 1 : 0)")
        // And the routing half: a Drive-hosted attachment is a download, while
        // the Drive pages around it are still the browser's.
        notes.append("routesAttachments=\(Self.attachmentRoutingHolds ? 1 : 0)")
        // The privacy half. A failed download's log line carries the shape of
        // the name and never the name, whatever a person called the file.
        notes.append("redactsNames=\(Self.redactionHolds ? 1 : 0)")

        previousSink = Log.sink
        let forward = Log.sink
        Log.sink = { [weak self] line in
            self?.logLines.append(line)
            forward(line)
        }
        NavigationPolicy.reportFailure = { [weak self] title, _ in self?.failureReports.append(title) }

        AppSettings.registerDefaults(in: .standard)
        settings.downloadDirectory = downloadDirectory
        // G4's default, stated rather than assumed: the announcement is a
        // finished download's only feedback, so it is what "it worked" reads
        // from here.
        settings.downloadFinishedAction = .notify
        policy.notifyDownloadFinished = { [weak self] _ in self?.announced += 1 }
        // Never a window on screen. The popup path itself stays the real one.
        policy.presentPopupWindow = { [weak self] window in
            self?.popupsPresented += 1
            window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
            window.orderOut(nil)
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in self?.popupsClosed += 1 }
        }
        policy.onDidFinish = { [weak self] webView in self?.pageDidLoad(webView) }

        let session = AccountSession(account: account, schemeHandlers: [Self.scheme: self])
        self.session = session
        session.setDelegates(policy)
        guard let webView = session.webView(for: .mail) else {
            SelfTest.finish("downloads result=FAILED reason=no-webview")
        }
        window = SelfTest.headlessWindow(hosting: webView)
        next()
    }

    /// The response rule the regression lives in, through the same two
    /// functions the delegate calls.
    private static var attachmentRuleHolds: Bool {
        func decision(_ headers: [String: String]) -> WKNavigationResponsePolicy {
            let response = HTTPURLResponse(
                url: URL(string: "https://mail-attachment.googleusercontent.com/attachment/u/0/")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )
            return NavigationPolicy.responsePolicy(
                isAttachment: NavigationPolicy.isAttachment(
                    contentDisposition: response?.value(forHTTPHeaderField: "Content-Disposition")
                ),
                canShowMIMEType: true
            )
        }
        let attachment = ["Content-Type": "application/pdf", "Content-Disposition": "attachment; filename=\"x.pdf\""]
        return decision(attachment) == .download && decision(["Content-Type": "application/pdf"]) == .allow
    }

    /// The routing half: the endpoints a Drive-hosted attachment is served from
    /// are downloads, and the Drive pages around them still leave for the
    /// browser.
    private static var attachmentRoutingHolds: Bool {
        func isDownload(_ string: String) -> Bool {
            if case .download = LinkRouter.destination(for: URL(string: string)!) { return true }
            return false
        }
        func leaves(_ string: String) -> Bool {
            if case .openExternally = LinkRouter.destination(for: URL(string: string)!) { return true }
            return false
        }
        return isDownload("https://drive.usercontent.google.com/download?id=abc&export=download")
            && isDownload("https://drive.google.com/uc?export=download&id=abc")
            && leaves("https://drive.google.com/file/d/abc/view")
            && leaves("https://docs.google.com/document/d/abc/edit")
    }

    /// What a failed download says about itself, against the shipping function.
    ///
    /// The line has to be useful — the extension and the size that made the
    /// write fail — while carrying nothing anybody wrote. `os_log` output is
    /// world-readable on this Mac and keeps for days; an attachment's name is
    /// mail content, and interpolating one into a message marked `.public` put
    /// it there for anything that runs `log show`.
    private static var redactionHolds: Bool {
        let name = longName(264)
        let line = NavigationPolicy.downloadFailureLine(
            filename: name,
            error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        return !line.contains("и")
            && line.contains(".pdf")
            && line.contains("\(name.utf8.count) bytes")
            && line.contains("-999")
    }

    private var currentStepName: String {
        index < Self.steps.count ? Self.steps[index].name : "report"
    }

    private var webView: WKWebView? { session?.webView(for: .mail) }

    private func loadPage(into webView: WKWebView, then completion: @escaping () -> Void) {
        onPageLoad = completion
        webView.load(URLRequest(url: Self.page))
    }

    /// Only the fixture page finishing resumes the run.
    ///
    /// Anything else that finishes — a popup, the renderable blob still on its
    /// way in when the reload was issued — used to hand the next step a tab
    /// that was not on the page the step assumes.
    private func pageDidLoad(_ webView: WKWebView) {
        pageLoads += 1
        guard webView === self.webView, webView.url?.path == Self.page.path else { return }
        guard let completion = onPageLoad else { return }
        onPageLoad = nil
        DispatchQueue.main.async(execute: completion)
    }

    private func run(script: String) {
        webView?.evaluateJavaScript(script) { [weak self] _, error in
            // Only a real script failure counts. `window.open` and
            // `appendChild` hand back objects `evaluateJavaScript` cannot
            // serialise, which is not a failure to drive the case.
            guard
                let error = error as NSError?,
                error.code != WKError.javaScriptResultTypeIsUnsupported.rawValue
            else { return }
            self?.notes.append("FAILED_script_\(self?.currentStepName ?? "?")=\(error.code)")
        }
    }

    /// The production replacement, delegates and all. The page comes back on
    /// its own: `next()` puts every case back on the fixture page first.
    private func recycle() {
        guard let fresh = session?.recycle(.mail) else {
            notes.append("FAILED_recycle=no-webview")
            return
        }
        // The wiring a recycled tab depends on, checked on the object the
        // session actually handed back.
        notes.append("recycledDelegates=\(fresh.navigationDelegate === policy && fresh.uiDelegate === policy ? 1 : 0)")
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        window?.contentView?.addSubview(fresh)
        fresh.frame = window?.contentView?.bounds ?? .zero
        fresh.translatesAutoresizingMaskIntoConstraints = true
    }

    /// Drives one step, waits for the thing it is about to actually happen, and
    /// records what landed on disk.
    ///
    /// Every step starts from the fixture page: a case that legitimately
    /// navigates the tab (`renders`) must not decide the next one.
    private func next() {
        guard index < Self.steps.count, let webView else {
            settleAndReport()
            return
        }
        guard webView.url?.path == Self.page.path else {
            reloads += 1
            loadPage(into: webView) { [weak self] in self?.next() }
            return
        }

        let step = Self.steps[index]
        let before = Snapshot(
            files: savedFiles(),
            announced: announced,
            failures: failureReports.count,
            pageLoads: pageLoads
        )
        step.action(self)

        let settledYet: () -> Bool = { [weak self] in
            guard let self else { return true }
            return step.settled(self, before)
        }
        wait(for: settledYet, upTo: Self.stepDeadline) { [weak self] settled in
            guard let self else { return }
            let landed = self.savedFiles() - before.files
            self.notes.append("\(step.name)=\(landed)")
            if !settled {
                // Where the tab actually was when the step gave up. The scheme
                // only — this is the probe's own fixture, but the habit is the
                // point: nothing about a page goes into a report.
                let at = self.webView?.url?.scheme ?? "nothing"
                self.notes.append("FAILED_\(step.name)=never-settled-on-\(at)")
            }
            if step.expectsFile, landed < 1 {
                self.notes.append("FAILED_\(step.name)=no-file")
            }
            if !step.expectsFile, landed > 0 {
                self.notes.append("FAILED_\(step.name)=unexpected-file")
            }
            // A download must not take the mail tab with it.
            if step.expectsFile, self.webView?.url?.path != Self.page.path {
                self.notes.append("FAILED_\(step.name)=navigated-away")
            }
            if step.name == "renders" {
                let shown = self.webView?.url?.absoluteString.hasPrefix("blob:") ?? false
                self.notes.append("rendered=\(shown ? 1 : 0)")
            }
            if step.name == "refused" {
                self.notes.append("refusedWasReported=\(self.failureReports.count - before.failures)")
            }
            self.index += 1
            self.next()
        }
    }

    /// Waits on a condition rather than on a clock, polling the run loop.
    ///
    /// Recursive `asyncAfter` rather than a `Timer`, so it works the same in a
    /// process that never activates and never draws.
    private func wait(
        for condition: @escaping () -> Bool,
        upTo remaining: TimeInterval,
        step: TimeInterval = 0.02,
        then done: @escaping (Bool) -> Void
    ) {
        if condition() { return done(true) }
        guard remaining > 0 else { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { [weak self] in
            guard let self else { return done(false) }
            self.wait(for: condition, upTo: remaining - step, step: step, then: done)
        }
    }

    private func savedFiles() -> Int {
        savedNames().count
    }

    private func savedNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: downloadDirectory.path)) ?? []
    }

    /// Every popup this run opened had to close itself, and the last one may
    /// still be on its way out — closing is deliberately deferred past the
    /// navigation callback that decided it. Waited on, not slept through, and
    /// then asserted: an open popup is not just an empty window, it is a
    /// permanent veto on that account's tab recycling.
    private func settleAndReport() {
        wait(for: { [weak self] in
            guard let self else { return true }
            return self.popupsClosed == self.popupsPresented
        }, upTo: Self.stepDeadline) { [weak self] _ in
            self?.report()
        }
    }

    private func report() {
        guard !finished else { return }
        finished = true

        // The longest name that actually reached the disk, in bytes. The
        // filesystem's own limit is 255, and a name over it is what used to
        // fail as a cancellation. Lengths only — never a name.
        let longest = savedNames().map(\.utf8.count).max() ?? 0
        let total = savedFiles()
        notes.append("files=\(total) longestName=\(longest)")
        notes.append("pageLoads=\(pageLoads) reloads=\(reloads)")
        notes.append("announced=\(announced)")
        notes.append("popups=\(popupsPresented) closed=\(popupsClosed)")
        notes.append("popupVeto=\(policy.hasPopup(for: account.id) ? 1 : 0)")
        notes.append("refusalLogged=\(logLines.contains { $0.contains("not writable") } ? 1 : 0)")
        // Nothing the app writes about a download may carry the name of one.
        notes.append("namesInLog=\(logLines.contains { $0.contains("и") } ? 1 : 0)")

        var verdict = !notes.contains { $0.hasPrefix("FAILED_") }
        verdict = verdict && announced == Self.expectedFiles
        verdict = verdict && total == Self.expectedFiles
        // Every name the filesystem accepted, including the 404-character one.
        verdict = verdict && longest > 0 && longest <= LinkRouter.maxFilenameBytes
        // Every window opened for a download had nothing to show and went away,
        // so nothing is left vetoing the recycler.
        verdict = verdict && popupsPresented > 0 && popupsClosed == popupsPresented
        verdict = verdict && notes.contains("popupVeto=0")
        // The refused download told the user, once, and left a line to read.
        verdict = verdict && failureReports.count == 1
        verdict = verdict && logLines.contains { $0.contains("not writable") }
        verdict = verdict && notes.contains("namesInLog=0")
        verdict = verdict && notes.contains("recycledDelegates=1")
        verdict = verdict && notes.contains("rendered=1")
        verdict = verdict && notes.contains("attachmentRule=1")
        verdict = verdict && notes.contains("routesAttachments=1")
        verdict = verdict && notes.contains("redactsNames=1")

        cleanUp { [weak self] removed in
            let notes = self?.notes ?? []
            let line = "downloads result=\(verdict && removed ? "ok" : "FAILED") "
                + (notes + ["storeRemoved=\(removed ? 1 : 0)"]).joined(separator: " ")
            SelfTest.finish(line)
        }
    }

    /// Puts the Mac back exactly as the run found it, and says whether it
    /// managed to.
    ///
    /// The data store is the part that used to be silent: `remove(forIdentifier:)`
    /// answered "in use by network process" and the error was thrown away, so
    /// every run of `make smoke` orphaned a store under `~/Library/WebKit` for
    /// good. What holds one is not obvious — a popup window, a download still
    /// running and the window the webview sits in all do — so they go first, and
    /// the answer is reported rather than assumed.
    private func cleanUp(then done: @escaping (Bool) -> Void) {
        if let previousSink { Log.sink = previousSink }
        settings.useSystemDownloadDirectory()
        policy.closePopups(for: account.id)
        policy.cancelDownloads(for: account.id)
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        let identifier = account.id
        // The same shape as account removal: detach, then let the session go,
        // or the store stays in use and cannot be deleted.
        session?.detach()
        session = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDirectory.path)
        try? FileManager.default.removeItem(at: downloadDirectory.deletingLastPathComponent())
        // A longer ladder than account removal's: this run leaves nine finished
        // downloads and two popups behind it, and the network process takes
        // correspondingly longer to let go. `destroyDataStore` is also the one
        // call that guarantees WebKit is initialised first — without it the
        // class-level API dereferences a null run loop.
        WebViewFactory.destroyDataStore(for: identifier, attempts: 60, retryDelay: 0.25) { error in
            done(error == nil)
        }
    }
}
