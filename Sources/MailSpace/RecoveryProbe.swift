import AppKit
import WebKit

/// Proves, against a real `WKWebView`, that a recycle whose load fails is
/// always recoverable — and that the tab comes back **on its own** when the
/// network does.
///
/// The claim being settled is the one the adversarial pass called fatal: ten
/// minutes of bad network used to kill every mail tab permanently, with no
/// pill, no notification, no log line and no automatic way back. Unit tests
/// settle the rules; this settles the wiring, end to end, with a real webview
/// really failing to load and really loading again afterwards.
///
/// ## The harness's "network"
///
/// A `WKURLSchemeHandler` on a scheme of this probe's own. Nothing about this
/// Mac's connectivity is touched: `down` fails the task with
/// `NSURLErrorNotConnectedToInternet` — the exact error WebKit reports for a
/// genuinely offline load, which is what makes the delegate path under test the
/// real one — and `up` serves a small page. Same URL either way, so what
/// changes between the two phases is only whether the load can succeed.
///
/// Time is compressed: the recycler's `schedule` seam runs each retry after
/// 20 ms instead of 30 s…30 min. The *order and count* of the rungs are what is
/// under test, and those are unchanged; the wall clock is not.
final class RecoveryProbe: NSObject, TabRecyclerHost, WKNavigationDelegate {
    /// The harness's network. Held by the scheme handler and flipped by the
    /// probe between phases.
    final class Link {
        var isUp = false
        private(set) var refusedLoads = 0
        private(set) var servedLoads = 0

        func refuse() { refusedLoads += 1 }
        func serve() { servedLoads += 1 }
    }

    /// Answers a navigation the way the harness's network currently would.
    final class Handler: NSObject, WKURLSchemeHandler {
        private let link: Link
        init(link: Link) { self.link = link }

        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard link.isUp else {
                link.refuse()
                task.didFailWithError(
                    NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
                )
                return
            }
            link.serve()
            let body = Data("<!DOCTYPE html><html><body>inbox</body></html>".utf8)
            let response = URLResponse(
                url: task.request.url ?? RecoveryProbe.page,
                mimeType: "text/html",
                expectedContentLength: body.count,
                textEncodingName: "utf-8"
            )
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }

    static let scheme = "msharness"
    /// Where every load in this probe actually goes. Served by `Handler`, in
    /// process; no packet leaves this Mac and Google is never contacted.
    static let page = URL(string: "\(scheme)://inbox/mail/u/0/")!
    /// What the *guards* see. `AuthSurface.classify` requires http or https, so
    /// a custom scheme could never satisfy G1 — and G1 is one of the guards the
    /// tick has to run for this to be a test of the real chain. So the decision
    /// is made about the page the tab is really on, and only the destination of
    /// the load is substituted, through the recycler's own `load` seam.
    static let signedInPage = URL(string: "https://mail.google.com/mail/u/0/#inbox")!

    private let link = Link()
    private let recycler = TabRecycler()
    private let accountId = UUID()
    private var window: NSWindow?
    private var webView: WKWebView
    private var slot = 0

    /// What each phase observed, in order, for the report line.
    private var notes: [String] = []
    private var stallSignals = 0
    private var markedStalled = 0
    private var finished = false

    override init() {
        webView = RecoveryProbe.makeWebView(link: link)
        super.init()
        webView.navigationDelegate = self
    }

    private static func makeWebView(link: Link) -> WKWebView {
        let configuration = SelfTest.makeProbeConfiguration()
        configuration.setURLSchemeHandler(Handler(link: link), forURLScheme: scheme)
        return WKWebView(frame: .zero, configuration: configuration)
    }

    // MARK: - TabRecyclerHost

    var reachability: RecycleDecision.Reachability = .down
    var lastWakeAt: Date?
    var mainWindowIsVisible: Bool { false }

    func recycleTargets() -> [TabRecycler.Target] {
        [
            TabRecycler.Target(
                accountId: accountId,
                accountName: "harness",
                view: .mail,
                slot: slot,
                webView: webView
            )
        ]
    }

    func recycleCandidate(for target: TabRecycler.Target) -> RecycleDecision.Candidate? {
        RecycleDecision.Candidate(url: Self.signedInPage, view: .mail, slot: target.slot, committedAt: nil)
    }

    func performRecycle(_ target: TabRecycler.Target, to url: URL) -> WKWebView? {
        // The real `AccountSession.recycle`: a brand-new webview, the old one
        // dropped. The probe holds the new one exactly as the session does.
        let fresh = Self.makeWebView(link: link)
        fresh.navigationDelegate = self
        webView = fresh
        window?.contentView?.subviews.forEach { $0.removeFromSuperview() }
        window?.contentView?.addSubview(fresh)
        fresh.load(URLRequest(url: Self.page))
        return fresh
    }

    func editorState(in webView: WKWebView, completion: @escaping (RecycleDecision.EditorState?) -> Void) {
        completion(RecycleDecision.EditorState(focused: false, dirty: 0))
    }

    func markRecycleStalled(_ webView: WKWebView, target url: URL) { markedStalled += 1 }

    func recycleStallsChanged() { stallSignals += 1 }

    // MARK: - Navigation

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        recycler.webViewDidCommit(webView)
        recycler.webViewDidSettle(webView)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        recycler.webViewDidFail(webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recycler.webViewDidFail(webView)
    }

    // MARK: - The run

    func run(timeout: TimeInterval = 60) {
        SelfTest.armWatchdog(timeout) { "recovery result=timeout" }
        guard SelfTest.isSelfTestBundle else {
            SelfTest.finish("recovery result=FAILED reason=not-the-self-test-bundle")
        }

        window = SelfTest.headlessWindow(hosting: webView)
        recycler.host = self
        // Retries in milliseconds rather than minutes. The ladder's shape is
        // what is under test; its wall clock is not.
        recycler.schedule = { _, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
        // Every retry goes to the harness's own page, never to Google.
        recycler.load = { webView, _ in webView.load(URLRequest(url: Self.page)) }
        // The document is twelve hours old and the tab is due.
        recycler.webViewDidCommit(webView)
        recycler.now = { Date().addingTimeInterval(40 * 3600) }

        // PHASE 1 — the network is down. The recycler must not touch the tab.
        reachability = .down
        for _ in 0..<5 { recycler.tick() }
        notes.append("p1_recycled=\(link.refusedLoads + link.servedLoads == 0 ? 1 : 0)")

        // PHASE 2 — the network looks up, so a recycle is allowed; but every
        // load fails. This is the fatal scenario: the page is destroyed first,
        // and the load that was meant to replace it never lands.
        reachability = .up
        link.isUp = false
        recycler.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.phaseThree() }
    }

    /// PHASE 3 — the ladder has run out. The tab must be *visible*, not silent.
    private func phaseThree() {
        let dead = recycler.hasFailedLoad(webView)
        notes.append("p2_loadsAttempted=\(link.refusedLoads)")
        notes.append("p2_tabIsDead=\(dead ? 1 : 0)")
        notes.append("p2_markedStalled=\(markedStalled > 0 ? 1 : 0)")
        notes.append("p2_accountFlagged=\(recycler.stalledAccounts.contains(accountId) ? 1 : 0)")
        notes.append("p2_uiToldOnce=\(stallSignals > 0 ? 1 : 0)")

        // PHASE 4 — the network comes back. Nothing is asked of the user.
        link.isUp = true
        recycler.networkBecameReachable()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in self?.report() }
    }

    private func report() {
        guard !finished else { return }
        finished = true

        let served = link.servedLoads
        let stillDead = recycler.hasFailedLoad(webView)
        let flagged = recycler.stalledAccounts.contains(accountId)
        notes.append("p3_pageServed=\(served)")
        notes.append("p3_cameBackByItself=\(!stillDead && served > 0 ? 1 : 0)")
        notes.append("p3_warningCleared=\(flagged ? 0 : 1)")
        notes.append("p3_url=\(webView.url?.absoluteString ?? "none")")

        let recovered = !stillDead && served > 0 && !flagged
        let wasDead = notes.contains("p2_tabIsDead=1")
        let wasQuietWhileOffline = notes.contains("p1_recycled=1")
        let result = (recovered && wasDead && wasQuietWhileOffline) ? "ok" : "FAILED"

        window?.orderOut(nil)
        SelfTest.finish("recovery result=\(result) " + notes.joined(separator: " "))
    }
}
