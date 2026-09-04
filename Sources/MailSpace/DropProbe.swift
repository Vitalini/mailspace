import AppKit
import WebKit

/// Proves, against a real `WKWebView` and the shipping `NavigationPolicy`, that
/// dropping a file on a page which does not want it leaves the tab exactly
/// where it was.
///
/// The bug this exists to stop coming back: WebKit's own drag controller, when
/// no part of the page accepts the drop, falls back to **loading** the dragged
/// file. A main-frame navigation arrives at `decidePolicyFor` carrying a
/// `file:` URL and `navigationType == .other`, `LinkRouter` read every non-web
/// scheme as "the page drives this itself" and allowed it, and the owner's
/// inbox was replaced by whatever he had dragged. His place was gone and the
/// tab had to be navigated back by hand.
///
/// This is not something `swift test` can settle. The routing rule is unit
/// tested; that the drag controller still does this, that a `.cancel` really
/// suppresses it, and that `webView.url` is untouched afterwards are facts
/// about WebKit, and only a real webview being really dropped on can report
/// them. So this probe drives the shipping delegate through an actual
/// `NSDraggingDestination` sequence and then looks at where the tab is.
///
/// ## The harness's drag
///
/// The page comes from a `WKURLSchemeHandler` on a scheme of this probe's own,
/// and the drop is a synthetic `NSDraggingInfo` carrying one file URL in a
/// temporary directory this probe made. **No network, no listening socket, no
/// Google host, no account, no mail, no synthesised input events** — nothing is
/// posted to the window server and no real pointer moves. The dragged file is
/// fifteen bytes this probe wrote itself.
///
/// The fixture page registers no `dragover`/`drop` handler at all, which is the
/// condition the fallback needs: a page that accepts the drop never reaches it.
/// That is also the honest model of the region the owner hit — Gmail's message
/// list takes no drops.
///
/// ## Nothing reaches a display
///
/// The activation policy is `.prohibited` and the content window is ordered out
/// before the run loop turns, as in every other probe here.
final class DropProbe: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    static let scheme = "msdrop"
    private static let host = "mail.fixture"
    /// The page that takes no drops, which is what makes WebKit fall back to
    /// loading the file. The honest model of Gmail's message list.
    private static let page = URL(string: "\(scheme)://\(host)/inbox")!
    private static let embedded = URL(string: "\(scheme)://\(host)/embed")!
    /// The page that *does* take the drop, which is the behaviour this fix must
    /// leave completely alone. Dropping a file into a compose window is
    /// something the owner may well want, and WebKit already builds a real
    /// `File` from the pasteboard for a page that asks for one.
    private static let accepting = URL(string: "\(scheme)://\(host)/compose")!
    private static let bridge = "mailspaceDropProbe"

    /// The line the delegate writes when it refuses a dropped file. Matched
    /// rather than counted through a hook, because the line is itself part of
    /// the fix: a drop that does nothing and says nothing is the failure mode
    /// this codebase keeps having to undo.
    private static let refusalMarker = "ignored a file dropped onto the page"

    private let settings = AppSettings(defaults: .standard)
    private let policy: NavigationPolicy
    private let account = Account(name: "MailSpace drop probe", calendarEnabled: false)
    private var session: AccountSession?
    private var window: NSWindow?

    private let dropDirectory: URL
    private let droppedFile: URL

    private var notes: [String] = []
    private var logLines: [String] = []
    private var previousSink: ((String) -> Void)?
    private var pageLoads = 0
    private var onPageLoad: (() -> Void)?
    private var expectedPage = DropProbe.page
    private var index = 0
    private var sequence = 7000
    private var finished = false

    /// What the accepting page's `drop` handler saw.
    private struct Delivery: Equatable {
        let count: Int
        let size: Int
        let type: String
        let text: String
        let isFile: Bool
        let types: String
    }

    private var delivered: Delivery?

    override init() {
        policy = NavigationPolicy(settings: settings)
        dropDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceDropProbe-\(UUID().uuidString)", isDirectory: true)
        droppedFile = dropDirectory.appendingPathComponent("dropped-fixture.txt")
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
        let body: String
        switch url.path {
        case Self.embedded.path: body = Self.embedHTML
        case Self.accepting.path: body = Self.acceptingHTML
        default: body = Self.outerHTML
        }
        task.didReceive(response)
        task.didReceive(Data(body.utf8))
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// What the accepting page saw in its own `drop` event.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.bridge, let payload = message.body as? [String: Any] else { return }
        delivered = Delivery(
            count: payload["count"] as? Int ?? 0,
            size: payload["size"] as? Int ?? 0,
            type: payload["type"] as? String ?? "",
            text: payload["text"] as? String ?? "",
            isFile: payload["isFile"] as? Bool ?? false,
            types: payload["types"] as? String ?? ""
        )
    }

    /// The outer page: no drop handlers, and an embed filling its bottom half so
    /// a drop can be aimed at a subframe instead of the main one.
    private static let outerHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>fixture</title></head>
    <body style="margin:0;background:#eee">
    <div style="position:fixed;left:0;right:0;top:0;height:50%">main frame, no drop handlers</div>
    <iframe id="embed" src="\(embedded.absoluteString)" style="position:fixed;left:0;right:0;bottom:0;\
    height:50%;width:100%;border:0"></iframe>
    </body></html>
    """

    private static let embedHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>embed</title></head>
    <body style="margin:0;background:#ccc">subframe, no drop handlers</body></html>
    """

    /// A page that takes the drop the way a compose window would: `dragover`
    /// and `drop` both `preventDefault`, and the file is read back through
    /// `FileReader`. What it reports is the whole point of the case — the fix
    /// must not have turned a real `File` into nothing.
    private static let acceptingHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><title>compose</title></head>
    <body style="margin:0;background:#dfd">drop zone
    <script>
    function report(o) { window.webkit.messageHandlers.\(bridge).postMessage(o); }
    document.addEventListener('dragover', function (e) { e.preventDefault(); }, false);
    document.addEventListener('drop', function (e) {
      e.preventDefault();
      // Read everything off the DataTransfer synchronously. It is only live for
      // the duration of the event, and reading `files.length` back inside the
      // FileReader callback reported zero for a file that had plainly arrived.
      var d = e.dataTransfer;
      var count = d.files ? d.files.length : 0;
      var types = Array.prototype.join.call(d.types || [], ',');
      var item = d.items && d.items[0];
      var isFile = !!item && item.kind === 'file';
      var f = d.files && d.files[0];
      if (!f) { report({count: count, size: 0, type: '', text: '', isFile: isFile, types: types}); return; }
      var size = f.size;
      var type = f.type;
      var reader = new FileReader();
      reader.onload = function () {
        report({count: count, size: size, type: type, text: reader.result, isFile: isFile, types: types});
      };
      reader.readAsText(f);
    }, false);
    </script></body></html>
    """

    // MARK: - The cases

    /// Where in the webview a drop is aimed, in the page's own terms.
    private enum Target {
        /// The top half of the page, which is the main frame's own content.
        case mainFrame
        /// The bottom half, which is the embedded subframe.
        case subFrame

        /// AppKit's y runs up from the bottom of the window, so the page's top
        /// half is the window's *upper* half.
        func point(in bounds: NSRect) -> NSPoint {
            switch self {
            case .mainFrame: return NSPoint(x: bounds.midX, y: bounds.height * 0.75)
            case .subFrame: return NSPoint(x: bounds.midX, y: bounds.height * 0.25)
            }
        }
    }

    /// What a drop on this page is supposed to do.
    private enum Outcome {
        /// The page declined it, WebKit tried to load the file instead, and the
        /// policy refused. The tab must not move.
        case refusedLoad
        /// The page took it. The file must arrive intact, and nothing must be
        /// refused or navigated.
        case deliveredToPage
    }

    private struct Step {
        let name: String
        let page: URL
        let target: Target
        let outcome: Outcome
    }

    private static let steps: [Step] = [
        // The shape the owner hit: a file dropped on the message list.
        Step(name: "mainframe", page: page, target: .mainFrame, outcome: .refusedLoad),
        // The same drop aimed at an embed. WebKit's fallback loads the main
        // frame either way in practice, but the rule must not depend on that.
        Step(name: "subframe", page: page, target: .subFrame, outcome: .refusedLoad),
        // Twice on the same tab, because "his place is gone" is about the
        // second drop as much as the first: a refusal must not be a one-shot.
        Step(name: "again", page: page, target: .mainFrame, outcome: .refusedLoad),
        // The control, and the reason this probe exists in the shape it does.
        // The fix cancels a navigation; it must not have touched the drag. A
        // page that wants the file still gets the file.
        Step(name: "accepted", page: accepting, target: .mainFrame, outcome: .deliveredToPage)
    ]

    /// How long a single drop may take to either be refused or commit before the
    /// run is called broken.
    private static let stepDeadline: TimeInterval = 15

    // MARK: - The run

    func run(timeout: TimeInterval = 120) {
        SelfTest.armWatchdog(timeout) { [weak self] in
            "drop result=TIMEOUT at=\(self?.currentStepName ?? "start") "
                + (self?.notes.joined(separator: " ") ?? "")
        }
        guard SelfTest.isSelfTestBundle else {
            SelfTest.finish("drop result=FAILED reason=not-the-self-test-bundle")
        }

        do {
            try FileManager.default.createDirectory(at: dropDirectory, withIntermediateDirectories: true)
            try Data("HELLO-DROP-1234".utf8).write(to: droppedFile)
        } catch {
            SelfTest.finish("drop result=FAILED reason=fixture-setup error=\(error.localizedDescription)")
        }

        // The routing half, against the shipping router: which schemes may take
        // over a frame, in both frame positions, and which may not.
        notes.append("routesSchemes=\(Self.schemeRoutingHolds ? 1 : 0)")

        previousSink = Log.sink
        let forward = Log.sink
        Log.sink = { [weak self] line in
            self?.logLines.append(line)
            forward(line)
        }

        AppSettings.registerDefaults(in: .standard)
        // Never a window on screen, and never a hand-off to a real browser: a
        // probe that reached `NSWorkspace` would open the owner's Chrome.
        policy.presentPopupWindow = { window in
            window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
            window.orderOut(nil)
        }
        policy.onDidFinish = { [weak self] webView in self?.pageDidLoad(webView) }

        let session = AccountSession(
            account: account,
            messageHandlers: [Self.bridge: self],
            schemeHandlers: [Self.scheme: self]
        )
        self.session = session
        session.setDelegates(policy)
        guard let webView = session.webView(for: .mail) else {
            SelfTest.finish("drop result=FAILED reason=no-webview")
        }
        window = SelfTest.headlessWindow(hosting: webView)
        next()
    }

    /// Every scheme that can reach `decidePolicyFor`, decided by the shipping
    /// router, in a main frame and in a subframe.
    ///
    /// Stated as "may this take over a frame", which is a different question
    /// from "may this be handed to `NSWorkspace`" — the one an earlier fix
    /// settled. `about:blank`, `blob:` and `data:` must still navigate, because
    /// the sign-in SPA, the popup path and the download path are built on them.
    private static var schemeRoutingHolds: Bool {
        func navigates(_ string: String, isMainFrameTarget: Bool) -> Bool {
            guard let url = URL(string: string) else { return false }
            if case .allowInApp = LinkRouter.destination(
                for: url,
                isMainFrameTarget: isMainFrameTarget,
                isSSOEscorted: false
            ) { return true }
            return false
        }
        let mayNavigate = [
            "about:blank",
            "blob:https://mail.google.com/9b1deb4d-0000-0000-0000-000000000000",
            "data:text/html,<b>x</b>",
            "javascript:void(0)",
            "https://mail.google.com/mail/u/0/#inbox"
        ]
        let mayNot = [
            "file:///etc/hosts",
            "file:///Users/someone/Desktop/report.pdf"
        ]
        for candidate in mayNavigate where !(navigates(candidate, isMainFrameTarget: true)
            && navigates(candidate, isMainFrameTarget: false)) {
            return false
        }
        for candidate in mayNot where navigates(candidate, isMainFrameTarget: true)
            || navigates(candidate, isMainFrameTarget: false) {
            return false
        }
        return true
    }

    private var currentStepName: String {
        index < Self.steps.count ? Self.steps[index].name : "report"
    }

    private var webView: WKWebView? { session?.webView(for: .mail) }

    private func pageDidLoad(_ webView: WKWebView) {
        pageLoads += 1
        guard webView === self.webView, webView.url?.path == expectedPage.path else { return }
        guard let completion = onPageLoad else { return }
        onPageLoad = nil
        DispatchQueue.main.async(execute: completion)
    }

    /// Drives one drop and then asks the only question that matters: is the tab
    /// still on the page it was on.
    private func next() {
        guard index < Self.steps.count, let webView else {
            report()
            return
        }

        let step = Self.steps[index]
        guard webView.url?.path == step.page.path else {
            onPageLoad = { [weak self] in self?.next() }
            expectedPage = step.page
            webView.load(URLRequest(url: step.page))
            return
        }

        let refusalsBefore = refusals
        delivered = nil
        drop(on: webView, at: step.target)

        // Settled when the thing the step is about has happened: the load was
        // refused, the page reported a file, or the tab left the page anyway.
        // A drop that produces none of the three runs out the deadline and is
        // reported as such.
        let settledYet: () -> Bool = { [weak self] in
            guard let self, let webView = self.webView else { return true }
            return self.refusals > refusalsBefore
                || self.delivered != nil
                || webView.url?.path != step.page.path
        }
        wait(for: settledYet, upTo: Self.stepDeadline) { [weak self] settled in
            guard let self else { return }
            // Where the tab actually is. The scheme only: never a path, even
            // this probe's own.
            let scheme = self.webView?.url?.scheme ?? "nothing"
            let stayedPut = self.webView?.url?.path == step.page.path
            let refused = self.refusals - refusalsBefore
            self.notes.append("\(step.name)=\(stayedPut ? "stayed" : "went-to-\(scheme)")")
            if !settled {
                self.notes.append("FAILED_\(step.name)=never-settled")
            }
            if !stayedPut {
                self.notes.append("FAILED_\(step.name)=navigated-away")
            }

            switch step.outcome {
            case .refusedLoad:
                if refused != 1 {
                    // Either the drop never reached WebKit's fallback, or it
                    // reached it and was allowed. Both are failures, and they
                    // read differently next to the note above.
                    self.notes.append("FAILED_\(step.name)=refusals-\(refused)")
                }
            case .deliveredToPage:
                self.notes.append("delivered=\(self.deliveredNote)")
                if refused != 0 {
                    self.notes.append("FAILED_\(step.name)=refused-a-drop-the-page-wanted")
                }
                if self.delivered != Self.expectedDelivery {
                    self.notes.append("FAILED_\(step.name)=file-did-not-arrive-intact")
                }
            }
            self.index += 1
            self.next()
        }
    }

    /// Exactly what a page that accepts the drop must receive: one real file,
    /// the fifteen bytes this probe wrote, announced to JS as a file.
    private static let expectedDelivery = Delivery(
        count: 1,
        size: 15,
        type: "text/plain",
        text: "HELLO-DROP-1234",
        isFile: true,
        types: "Files"
    )

    /// The delivery, as a report line: sizes and flags, never the bytes or the
    /// name. `bytes=1` means they matched what was written, not what they were.
    private var deliveredNote: String {
        guard let delivered else { return "nothing" }
        return "count-\(delivered.count)"
            + "/size-\(delivered.size)"
            + "/type-\(delivered.type.isEmpty ? "none" : delivered.type)"
            + "/isFile-\(delivered.isFile ? 1 : 0)"
            + "/types-\(delivered.types.isEmpty ? "none" : delivered.types)"
            + "/bytes-\(delivered.text == Self.expectedDelivery.text ? 1 : 0)"
    }

    /// How many dropped files the shipping delegate has refused so far.
    private var refusals: Int {
        logLines.filter { $0.contains(Self.refusalMarker) }.count
    }

    /// Performs the whole `NSDraggingDestination` sequence a real Finder drop
    /// performs, straight onto the webview.
    ///
    /// The webview is asked as a destination directly rather than through the
    /// window, so nothing is posted to the window server and no pointer is
    /// synthesised: this is the same set of calls AppKit would make, made in
    /// process.
    private func drop(on webView: WKWebView, at target: Target) {
        sequence += 1
        let pasteboard = NSPasteboard(name: .drag)
        pasteboard.clearContents()
        pasteboard.writeObjects([droppedFile as NSURL])

        let point = webView.convert(target.point(in: webView.bounds), to: nil)
        let info = SyntheticDrag(
            pasteboard: pasteboard,
            window: window,
            location: point,
            sequence: sequence
        )
        let destination: NSDraggingDestination = webView
        _ = destination.draggingEntered?(info)
        _ = destination.draggingUpdated?(info)
        _ = destination.prepareForDragOperation?(info)
        _ = destination.performDragOperation?(info)
        destination.concludeDragOperation?(info)
    }

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

    private func report() {
        guard !finished else { return }
        finished = true

        let expectedRefusals = Self.steps.filter { $0.outcome == .refusedLoad }.count
        notes.append("drops=\(Self.steps.count) refused=\(refusals) expected=\(expectedRefusals)")
        notes.append("pageLoads=\(pageLoads)")
        // The refusal is silent to the user by design, but never silent in the
        // log — and the line must not carry what the file was called.
        notes.append("namesInLog=\(logLines.contains { $0.contains("dropped-fixture") } ? 1 : 0)")

        var verdict = !notes.contains { $0.hasPrefix("FAILED_") }
        verdict = verdict && refusals == expectedRefusals
        verdict = verdict && delivered == Self.expectedDelivery
        verdict = verdict && notes.contains("routesSchemes=1")
        verdict = verdict && notes.contains("namesInLog=0")

        cleanUp { [weak self] removed in
            let notes = self?.notes ?? []
            let line = "drop result=\(verdict && removed ? "ok" : "FAILED") "
                + (notes + ["storeRemoved=\(removed ? 1 : 0)"]).joined(separator: " ")
            SelfTest.finish(line)
        }
    }

    private func cleanUp(then done: @escaping (Bool) -> Void) {
        if let previousSink { Log.sink = previousSink }
        policy.closePopups(for: account.id)
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
        let identifier = account.id
        session?.detach()
        session = nil
        try? FileManager.default.removeItem(at: dropDirectory)
        WebViewFactory.destroyDataStore(for: identifier, attempts: 60, retryDelay: 0.25) { error in
            done(error == nil)
        }
    }
}

/// The `NSDraggingInfo` AppKit would hand a view during a real drag, built by
/// hand so a drop can be delivered without a pointer, a window on screen, or a
/// single synthesised event.
///
/// Only the members WebKit's drag handling actually reads carry anything: the
/// pasteboard, the location, the destination window, the sequence number and
/// the enumeration. The rest satisfy the protocol.
private final class SyntheticDrag: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let window: NSWindow?
    private let location: NSPoint
    private let sequence: Int

    init(pasteboard: NSPasteboard, window: NSWindow?, location: NSPoint, sequence: Int) {
        self.pasteboard = pasteboard
        self.window = window
        self.location = location
        self.sequence = sequence
        super.init()
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .link, .move] }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { sequence }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    private var validItems = 1
    var numberOfValidItemsForDrop: Int {
        get { validItems }
        set { validItems = newValue }
    }

    private var formation: NSDraggingFormation = .default
    var draggingFormation: NSDraggingFormation {
        get { formation }
        set { formation = newValue }
    }

    private var animates = false
    var animatesToDestination: Bool {
        get { animates }
        set { animates = newValue }
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        guard let items = pasteboard.pasteboardItems else { return }
        for (offset, item) in items.enumerated() {
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            draggingItem.draggingFrame = NSRect(origin: location, size: NSSize(width: 32, height: 32))
            var stop: ObjCBool = false
            let shouldStop = withUnsafeMutablePointer(to: &stop) { pointer -> Bool in
                block(draggingItem, offset, pointer)
                return pointer.pointee.boolValue
            }
            if shouldStop { break }
        }
    }
}
