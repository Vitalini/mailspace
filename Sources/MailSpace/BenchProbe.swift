import AppKit
import WebKit

/// Proves — rather than asserts — what an automatic recycle reclaims.
///
/// The one way `TabRecycler` could fail invisibly is by rebuilding pages twice
/// a day and reclaiming nothing, so the pass mark is fixed here in advance and
/// in code: **a recycle works iff the sustained footprint after it is no more
/// than 1.25 × the footprint of a freshly loaded page.**
///
/// Everything about this is offline and synthetic. The page under test is a
/// `loadFileURL` document in a temporary directory that grows a deterministic
/// heap — roughly 200k DOM nodes plus 600 MB of retained typed arrays, half of
/// which is then released — so the experiment is repeatable and contains none
/// of anybody's mail. It runs under the throwaway self-test bundle identity,
/// with no activation policy and a deferred window that is ordered out before
/// the run loop turns.
///
/// Attribution uses no SPI and no privileges: the set of
/// `com.apple.WebKit.WebContent` pids is snapshotted before the harness creates
/// its webview and again after `didFinish`, and the difference is the harness's
/// own process. A MailSpace the user is already running is in the *first*
/// snapshot, so it can never be sampled by mistake.
///
/// Two arms, run separately via `MAILSPACE_BENCH_ARM`:
///
/// * **a** — `webView.reload()`, the cheaper option, run so the difference is a
///   number rather than an argument.
/// * **b** — the shipping implementation: replace the webview and re-navigate
///   it to the URL it was on. This arm additionally asserts that the old
///   WebContent process exits and a new one appears.
final class BenchProbe: NSObject, WKNavigationDelegate {
    private enum Phase {
        case loading
        case growing
        case recycling
        case settling
    }

    private let arm: String
    private let growSeconds: TimeInterval
    private let settleSeconds: TimeInterval
    private let sampleInterval: TimeInterval

    private let configuration: WKWebViewConfiguration
    private var webView: WKWebView
    private var window: NSWindow?
    private var pageURL: URL?
    private var directory: URL?

    private var phase = Phase.loading
    private var pidsBefore: Set<Int32> = []
    private var pid: Int32?
    private var oldPid: Int32?

    /// Footprint of the freshly loaded page.
    private var fresh: Double?
    /// Peak reached while growing.
    private var peak: Double = 0
    private var settleSamples: [Double] = []
    private var phaseStartedAt = Date()
    private var timer: Timer?

    /// Deterministic, and deliberately crude: this is a memory experiment, not
    /// a page. `__grow` builds the DOM and the retained graph, then drops half
    /// the graph so the process has genuinely-freed memory to hand back.
    private static let page = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>bench</title></head>
    <body><div id="host"></div><script>
      window.__grow = function () {
        var host = document.getElementById('host');
        var batch = document.createDocumentFragment();
        for (var i = 0; i < 200000; i++) {
          var node = document.createElement('span');
          node.textContent = 'node ' + i;
          batch.appendChild(node);
        }
        host.appendChild(batch);
        window.__heap = [];
        for (var j = 0; j < 600; j++) {
          var block = new Uint8Array(1024 * 1024);
          block.fill(j & 255);
          window.__heap.push(block);
        }
        window.__heap.length = 300;
        return document.querySelectorAll('#host span').length;
      };
    </script></body></html>
    """

    override init() {
        arm = (ProcessInfo.processInfo.environment["MAILSPACE_BENCH_ARM"] ?? "b").lowercased()
        growSeconds = SelfTest.environmentDouble("MAILSPACE_BENCH_GROW", default: 600)
        settleSeconds = SelfTest.environmentDouble("MAILSPACE_BENCH_SETTLE", default: 300)
        sampleInterval = SelfTest.environmentDouble("MAILSPACE_BENCH_SAMPLE", default: 10)
        configuration = SelfTest.makeProbeConfiguration()
        webView = WebViewFactory.makeWebView(configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func run() {
        // Generous: the whole run is grow + settle plus load and teardown.
        SelfTest.armWatchdog(growSeconds + settleSeconds + 180) { [weak self] in
            self?.line(result: "timeout") ?? "bench result=timeout"
        }

        guard let pageURL = writePage() else {
            SelfTest.finish("bench arm=\(arm) result=setup-failed reason=could-not-write-page")
        }
        self.pageURL = pageURL

        // Phase 0 — baseline: no webview of ours exists yet, so every
        // WebContent process on this Mac right now belongs to somebody else.
        pidsBefore = SelfTest.webContentPids()
        window = SelfTest.headlessWindow(hosting: webView)
        phase = .loading
        webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    private func writePage() -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mailspace-bench-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil
        else { return nil }
        self.directory = directory
        let url = directory.appendingPathComponent("bench.html")
        guard (try? Data(Self.page.utf8).write(to: url)) != nil else { return nil }
        return url
    }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch phase {
        case .loading:
            resolvePid()
            guard let pid else {
                SelfTest.finish("bench arm=\(arm) result=no-webcontent-pid-attributed")
            }
            fresh = SelfTest.footprintMB(pid: pid)
            startGrowing()
        case .recycling:
            resolvePid()
            startSettling()
        case .growing, .settling:
            break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        SelfTest.finish("bench arm=\(arm) result=navigation-failed error=\(error.localizedDescription)")
    }

    /// The set difference *is* the attribution.
    private func resolvePid() {
        let after = SelfTest.webContentPids()
        if let mine = after.subtracting(pidsBefore).first {
            pid = mine
        }
    }

    // MARK: - Phases

    private func startGrowing() {
        phase = .growing
        phaseStartedAt = Date()
        peak = fresh ?? 0
        // `.page`, not `.defaultClient`: `__grow` is defined by the document's
        // own script, and a client world cannot see the page's globals. Run in
        // the wrong world the call fails silently and the "grown" page never
        // grows — which is exactly what the first run of this harness measured.
        webView.callAsyncJavaScript("return window.__grow();", arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                Log.error("bench: grow failed: \(error.localizedDescription)")
            }
        }
        startSampling()
    }

    private func startSampling() {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
        guard let pid, let value = SelfTest.footprintMB(pid: pid) else { return }
        let elapsed = Date().timeIntervalSince(phaseStartedAt)

        switch phase {
        case .growing:
            peak = max(peak, value)
            if elapsed >= growSeconds { startRecycle() }
        case .settling:
            settleSamples.append(value)
            if elapsed >= settleSeconds { report() }
        case .loading, .recycling:
            break
        }
    }

    /// The two arms differ only here.
    private func startRecycle() {
        timer?.invalidate()
        timer = nil
        phase = .recycling
        oldPid = pid
        // The new process is the one that is not in this snapshot.
        pidsBefore = SelfTest.webContentPids()

        guard let pageURL else { return }

        if arm == "a" {
            // Arm A: the cheaper option — an in-process reload. Same webview,
            // same WebContent process; whatever comes back does so on JSC's and
            // libpas's own schedule.
            pidsBefore.remove(oldPid ?? -1)
            webView.reload()
            return
        }

        // Arm B: the shipping implementation. A fresh webview on the same
        // configuration, the old one torn down exactly the way
        // `AccountSession.recycle` tears one down, and a re-navigation to the
        // URL the old one was on.
        let old = webView
        let fresh = WebViewFactory.makeWebView(configuration: configuration)
        fresh.navigationDelegate = self
        webView = fresh

        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()

        window = SelfTest.headlessWindow(hosting: fresh)
        fresh.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
    }

    private func startSettling() {
        phase = .settling
        phaseStartedAt = Date()
        settleSamples = []
        startSampling()
    }

    // MARK: - Report

    private func report() -> Never {
        timer?.invalidate()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        SelfTest.finish(line(result: nil))
    }

    /// The pass mark.
    ///
    /// `sustained` alone was not enough, and the gap was the exact regression
    /// this benchmark exists to catch. `resolvePid` re-snapshots the live
    /// WebContent processes at recycle time and takes the set difference, so
    /// `sustained` is the footprint of the *new* process only. A change that
    /// retained the old webview would leave it alive at 700-odd MB beside a
    /// fresh 11 MB one — and score PASS on the 11.
    ///
    /// So arm B has to prove both halves of what a replacement is: the new
    /// process is small, *and* the old one is gone. `oldPidExited` was already
    /// printed; it just had no vote. Now it does.
    ///
    /// Pure and static so the rule is a unit test rather than a benchmark run
    /// that takes seven minutes and needs a webview.
    static func verdict(
        arm: String,
        freshMB: Double,
        sustainedMB: Double,
        sampleCount: Int,
        oldPidExited: Bool?
    ) -> String {
        guard sampleCount > 0, freshMB > 0 else { return "INCONCLUSIVE" }
        guard sustainedMB <= freshMB * 1.25 else { return "FAIL" }
        // Arm A never replaces anything, so it has no old process to account
        // for. Arm B does, and a run that could not tell is not a pass.
        guard arm == "b" else { return "PASS" }
        guard let oldPidExited else { return "INCONCLUSIVE" }
        return oldPidExited ? "PASS" : "FAIL"
    }

    private func line(result: String?) -> String {
        let freshValue = fresh ?? 0
        let sustained = settleSamples.min() ?? 0
        let worst = settleSamples.max() ?? 0
        let limit = freshValue * 1.25

        // Arm B additionally has to show that the old WebContent process really
        // went and a new one really arrived.
        var processNote = ""
        var oldPidExited: Bool?
        if arm == "b", let oldPid {
            let live = SelfTest.webContentPids()
            oldPidExited = !live.contains(oldPid)
            processNote = " oldPid=\(oldPid) oldPidExited=\(oldPidExited == true ? 1 : 0) newPid=\(pid.map(String.init) ?? "none")"
        }

        let verdict = result ?? Self.verdict(
            arm: arm,
            freshMB: freshValue,
            sustainedMB: sustained,
            sampleCount: settleSamples.count,
            oldPidExited: oldPidExited
        )

        return String(
            format: "bench arm=%@ result=%@ freshMB=%.0f peakMB=%.0f sustainedMB=%.0f worstMB=%.0f limitMB=%.0f samples=%d%@",
            arm, verdict, freshValue, peak, sustained, worst, limit, settleSamples.count, processNote
        )
    }
}

/// Settles the three platform behaviours the recycling guards rest on, before
/// any of it ships. All three are cheap to test and each would silently break a
/// guard.
///
/// 1. Does `WKWebView.url` track a Gmail-style same-document fragment change
///    (`#inbox` → `#inbox?compose=new`)? If it does not, the compose guard is
///    worthless and the feature has to be reduced to background-only recycling
///    with a differently designed compose test.
/// 2. Does a local `NSEvent` monitor see a key event delivered while a
///    `WKWebView` is first responder? That is what feeds the hard deadline's
///    90-second input-quiet requirement.
/// 3. Does the G18 editor probe actually see a Gmail-shaped inline reply — a
///    `contenteditable` div with text in it and nothing about it in the URL —
///    and stay quiet on an inbox that has none? G18 is the only guard standing
///    between a background tab and a rebuilt-away reply, and a selector that
///    matched nothing would fail open with no symptom at all.
///
/// Offline: the document is `loadHTMLString` against a Gmail base URL, so
/// nothing is fetched and no account is involved.
final class AssumptionProbe: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var window: NSWindow?
    private var monitor: Any?
    private var sawEvent = false
    private var finished = false

    override init() {
        webView = WebViewFactory.makeWebView(configuration: SelfTest.makeProbeConfiguration())
        super.init()
        webView.navigationDelegate = self
    }

    func run(timeout: TimeInterval = 45) {
        SelfTest.armWatchdog(timeout) { "assume result=timeout" }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.sawEvent = true
            return event
        }
        window = SelfTest.headlessWindow(hosting: webView)
        webView.loadHTMLString(
            "<!DOCTYPE html><html><body>bench<script>location.hash = 'inbox';</script></body></html>",
            baseURL: URL(string: "https://mail.google.com/mail/u/0/")!
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        finished = true
        let before = webView.url?.absoluteString ?? "none"

        // A same-document fragment change, exactly the shape Gmail uses when a
        // compose window opens.
        webView.evaluateJavaScript("location.hash = 'inbox?compose=new';") { [weak self] _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.finishReport(before: before)
            }
        }
    }

    private func finishReport(before: String) {
        let after = webView.url
        let tracked = after.map { RecycleDecision.hasOpenCompose($0) } ?? false

        // A synthesized key event posted into this app's own queue: a local
        // monitor sits ahead of window dispatch, so this is a fair test of
        // where the monitor sits, run with the webview as first responder.
        window?.makeFirstResponder(webView)
        if let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) {
            NSApp.postEvent(event, atStart: true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if let monitor = self.monitor { NSEvent.removeMonitor(monitor) }
            self.checkEditorProbe(tracked: tracked, before: before, after: after)
        }
    }

    /// Assumption 3. The page is the shape of a Gmail thread with the Reply box
    /// open: a `contenteditable` div carrying text, and — the whole point —
    /// nothing in the URL that says so.
    private func checkEditorProbe(tracked: Bool, before: String, after: URL?) {
        // Back to a plain thread URL first: assumption 1 left `compose=new` in
        // the hash, and the point of this one is that an inline reply puts
        // *nothing* there.
        let quiet = """
        location.hash = 'inbox/FMfcgz';
        document.body.innerHTML =
          '<div id="t">a thread</div>' +
          '<div contenteditable="true" style="width:400px;height:80px"></div>' +
          '<div role="textbox" style="display:none">offscreen template text</div>';
        """
        webView.evaluateJavaScript(quiet) { [weak self] _, _ in
            guard let self else { return }
            self.runEditorProbe { empty in
                // An empty reply box, and a hidden template that must not count.
                let quietOK = !RecycleDecision.hasLiveEditor(empty)

                self.webView.evaluateJavaScript(
                    "document.querySelector('[contenteditable]').textContent = 'thanks, will do';"
                ) { _, _ in
                    self.runEditorProbe { typed in
                        let seesReply = RecycleDecision.hasLiveEditor(typed)
                        let urlIsSilent = (self.webView.url).map { !RecycleDecision.hasOpenCompose($0) } ?? false
                        let ok = tracked && self.sawEvent && quietOK && seesReply && urlIsSilent
                        SelfTest.finish(
                            "assume result=\(ok ? "ok" : "PROBLEM") "
                            + "fragmentTracked=\(tracked ? 1 : 0) localMonitorSawKey=\(self.sawEvent ? 1 : 0) "
                            + "quietPageHasNoEditor=\(quietOK ? 1 : 0) "
                            + "inlineReplySeen=\(seesReply ? 1 : 0) "
                            + "inlineReplyInvisibleToTheUrl=\(urlIsSilent ? 1 : 0) "
                            + "before=\(before) after=\(after?.absoluteString ?? "none")"
                        )
                    }
                }
            }
        }
    }

    private func runEditorProbe(_ completion: @escaping (RecycleDecision.EditorState?) -> Void) {
        webView.callAsyncJavaScript(
            AppDelegate.editorProbeScript,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { result in
            guard let payload = (try? result.get()) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(
                RecycleDecision.EditorState(
                    focused: (payload["focused"] as? Bool) ?? false,
                    dirty: (payload["dirty"] as? Int) ?? 0
                )
            )
        }
    }
}

/// Renders the tab bar offscreen and writes it to a PNG, so the signed-out
/// signal can be reviewed without a window ever reaching a display.
final class TabShotProbe {
    func run() {
        NSApp.setActivationPolicy(.prohibited)
        let path = ProcessInfo.processInfo.environment["MAILSPACE_TABSHOT_PATH"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("tab-bar.png").path

        let personal = Account(name: "Personal", email: "personal@example.com", color: .purple)
        let work = Account(name: "Talkable", email: "work@example.com", color: .teal)
        let side = Account(name: "Side Project", email: "side@example.com", color: .orange)
        let accounts = [personal, work, side]

        let bar = AccountTabBar()
        bar.frame = NSRect(x: 0, y: 0, width: 720, height: AccountTabBar.height)
        // One of each warning beside a healthy tab, so the shot shows that both
        // fit the uniform width rather than squeezing their labels.
        bar.rebuild(
            accounts: accounts,
            selection: MainWindowController.Selection(accountId: personal.id, view: .mail),
            signedOut: [work.id],
            stalled: [side.id]
        )
        bar.layoutSubtreeIfNeeded()

        let window = NSWindow(
            contentRect: bar.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        // R9: MailSpace's chrome stays light whatever the system appearance is,
        // so the shot has to be taken the way he actually sees it.
        window.appearance = NSAppearance(named: .aqua)
        window.contentView?.addSubview(bar)
        window.orderOut(nil)
        bar.layoutSubtreeIfNeeded()
        window.contentView?.display()

        guard
            let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds)
        else { SelfTest.finish("tabshot result=no-bitmap") }
        bar.cacheDisplay(in: bar.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            SelfTest.finish("tabshot result=no-png")
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            SelfTest.finish("tabshot result=write-failed error=\(error.localizedDescription)")
        }
        SelfTest.finish("tabshot result=ok path=\(path) bytes=\(data.count)")
    }
}
