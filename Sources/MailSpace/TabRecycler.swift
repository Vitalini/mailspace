import AppKit
import WebKit

/// Whether one webview may be rebuilt on this tick, and why not when it may not.
///
/// All of the policy lives here as pure functions over plain values, the way
/// `AuthSurface`, `SSOEscort` and `CrashThrottle` already do, so every guard is
/// a unit test rather than a webview that has to sit around for twelve hours.
///
/// ## Why age and not a wall-clock hour
///
/// The measured failure — 2.3 GB of footprint and a Gmail tab that has silently
/// stopped syncing — is established at ~20 h of *document* life and absent at
/// low uptime. A fixed hour would recycle a page loaded sixty minutes ago and
/// spare one loaded twenty-three hours ago, fire every tab at once, and do
/// nothing at all on the nights the Mac is asleep at that hour. Age since the
/// current document committed is the quantity that actually tracks the growth,
/// and it is invariant to when the app was launched, slept or woken.
///
/// ## Why `didCommit` is the clock
///
/// Gmail and Calendar are single-page apps: they rewrite the fragment for hours
/// without ever committing a new document, and `didCommit` is main-frame-only
/// and is not fired by a fragment change. So age keeps climbing while the user
/// works, which is exactly the accumulation being measured. Stamping on
/// `didFinish` instead would be reset by same-document navigations and would
/// silently defeat the whole feature.
enum RecycleDecision {
    /// A page is rebuilt at least twice a day, which lands the recycle well
    /// before either measured symptom appears.
    static let minimumAge: TimeInterval = 12 * 3600

    /// The selected tab is rebuilt even while MailSpace is frontmost past this
    /// age. Without it the selected tab starves: a Mac that sleeps overnight
    /// fires no timers, and on wake the app is active and system idle is 0, so
    /// the ordinary opportunity gate below would never open.
    static let hardAge: TimeInterval = 24 * 3600

    /// Added to `minimumAge` once per tab slot. Deterministic, so it is
    /// testable, and it permanently breaks the lockstep created by every
    /// webview loading at t=0.
    static let slotStagger: TimeInterval = 5 * 60

    /// At most one recycle in the whole app per this many seconds. Stops a
    /// four-tab thundering herd after a long system sleep.
    static let globalSpacing: TimeInterval = 120

    /// Gmail issues actions optimistically; archiving a thread and immediately
    /// switching accounts can leave a request in flight in a tab that is now
    /// "background".
    static let deselectionHold: TimeInterval = 5 * 60

    /// How long an open panel that returned files blocks its webview. The only
    /// proxy there is for "a Drive upload is running" (see `G7` in the guard
    /// list).
    static let openPanelHold: TimeInterval = 10 * 60

    /// System idle required before the selected tab may be rebuilt on the
    /// ordinary path.
    static let idleRequirement: TimeInterval = 5 * 60

    /// Quiet required before the hard deadline may rebuild the selected tab
    /// while the user is in the app.
    static let inputQuietRequirement: TimeInterval = 90

    /// Everything the decision needs about one webview at one tick.
    ///
    /// A struct of plain values rather than the webview itself: that is what
    /// makes every guard testable without WebKit.
    struct Candidate: Equatable {
        /// The page the webview is on right now. Guard G1 reads it.
        var url: URL?
        var view: AccountView
        /// Position in the flattened tab list — the stagger index.
        var slot: Int
        /// When this webview's current document committed. `nil` means the
        /// webview has never committed a document and is ineligible.
        var committedAt: Date?
        var isSelected: Bool
        /// G9. A webview mid-load is already getting a fresh document.
        var isLoading: Bool
        /// G8. The crash throttle gave up on it; `tabBecameVisible` is the only
        /// way back and the recycler must never become a second retry engine.
        var isStalled: Bool
        /// G4. This webview, or any webview of its account, is mid sign-in.
        var isAuthenticating: Bool
        /// G5. Any popup window is open on this account's data store.
        var accountHasPopup: Bool
        /// G6. A download is running on this account's data store.
        var accountHasDownload: Bool
        /// The health monitor has this account in `SIGNED_OUT`. Reloading a
        /// login page reclaims nothing and would re-arm an `SSOEscort` pass on
        /// a schedule.
        var accountIsSignedOut: Bool
        /// G7. When an open panel last returned files into this webview.
        var lastOpenPanelAt: Date?
        /// G11. When this webview last stopped being the selected tab.
        var lastDeselectedAt: Date?

        init(
            url: URL?,
            view: AccountView,
            slot: Int,
            committedAt: Date?,
            isSelected: Bool = false,
            isLoading: Bool = false,
            isStalled: Bool = false,
            isAuthenticating: Bool = false,
            accountHasPopup: Bool = false,
            accountHasDownload: Bool = false,
            accountIsSignedOut: Bool = false,
            lastOpenPanelAt: Date? = nil,
            lastDeselectedAt: Date? = nil
        ) {
            self.url = url
            self.view = view
            self.slot = slot
            self.committedAt = committedAt
            self.isSelected = isSelected
            self.isLoading = isLoading
            self.isStalled = isStalled
            self.isAuthenticating = isAuthenticating
            self.accountHasPopup = accountHasPopup
            self.accountHasDownload = accountHasDownload
            self.accountIsSignedOut = accountIsSignedOut
            self.lastOpenPanelAt = lastOpenPanelAt
            self.lastDeselectedAt = lastDeselectedAt
        }
    }

    /// The facts that are the same for every candidate on one tick.
    struct Environment: Equatable {
        var now: Date
        /// G14. `AppSettings.automaticTabRecycling`.
        var isEnabled: Bool = true
        var appIsActive: Bool = false
        /// The main window is on screen — not miniaturised, hidden or ordered
        /// out.
        var mainWindowIsVisible: Bool = true
        /// Seconds since the user last touched *this Mac*, from
        /// `CGEventSource.secondsSinceLastEventType` — a counter read, so no
        /// event tap, no TCC prompt and no administrator anything.
        var systemIdle: TimeInterval = 0
        /// When MailSpace itself last saw a key or mouse event, from a local
        /// `NSEvent` monitor.
        var lastLocalInputAt: Date?
        /// G12. `AccountEditor.run()` and the removal alert are `runModal`, and
        /// a `.common`-mode timer keeps firing under a modal session.
        var modalIsUp: Bool = false
        /// G13. When the app last recycled anything.
        var lastRecycleAt: Date?
    }

    /// Why a webview was left alone. Reported so a tab that is permanently
    /// blocked — a compose left open for days, a `sawSignIn` flag that never
    /// resolved — shows up in the log instead of silently retiring itself from
    /// recycling and restoring the original twenty-hour behaviour.
    enum Reason: String, Equatable {
        case featureOff
        case modal
        case globalSpacing
        case notSignedIn
        case signedOut
        case noCommit
        case tooYoung
        case stalled
        case loading
        case authenticating
        case popup
        case download
        case openPanel
        case compose
        case calendarEdit
        case recentlyDeselected
        case userIsLooking
    }

    enum Outcome: Equatable {
        case recycle
        case skip(Reason)
    }

    /// Whether this reason means a tab that is old enough is being held back by
    /// something that could, in principle, never clear — a compose left open
    /// for days, a download record that never went, a `sawSignIn` flag that
    /// never resolved.
    ///
    /// Every guard is an OR into "do not recycle", so a persistent false
    /// positive silently retires that tab from recycling forever and restores
    /// the original twenty-hour behaviour with no symptom until the memory
    /// grows again. These are the reasons worth a log line; a tab that is
    /// merely young, or one the user is looking at, is not.
    static func isPersistentBlock(_ reason: Reason) -> Bool {
        switch reason {
        case .compose, .calendarEdit, .authenticating, .popup, .download,
             .openPanel, .stalled, .loading, .recentlyDeselected, .signedOut:
            return true
        case .featureOff, .modal, .globalSpacing, .notSignedIn, .noCommit,
             .tooYoung, .userIsLooking:
            return false
        }
    }

    /// Why this webview is being rebuilt, for the one production log line.
    enum Trigger: String, Equatable {
        case background
        case idle
        case windowHidden
        case hardDeadline
    }

    /// The age threshold this slot has to clear.
    static func threshold(forSlot slot: Int) -> TimeInterval {
        minimumAge + slotStagger * Double(max(slot, 0))
    }

    /// The whole rule, in guard order.
    ///
    /// Ordering is deliberate: the cheap app-wide gates first, then the master
    /// precondition and the age test — everything after that point is a genuine
    /// *block*, i.e. a tab that is old enough and would otherwise be rebuilt,
    /// which is what makes `Reason` worth logging.
    static func evaluate(_ candidate: Candidate, in environment: Environment) -> Outcome {
        // G14 — the feature is off.
        guard environment.isEnabled else { return .skip(.featureOff) }

        // G12 — a modal is up. `syncEnabledViews` may be about to run.
        guard !environment.modalIsUp else { return .skip(.modal) }

        // G13 — at most one recycle in the whole app per `globalSpacing`.
        if let last = environment.lastRecycleAt,
           environment.now.timeIntervalSince(last) < globalSpacing {
            return .skip(.globalSpacing)
        }

        // G1 — the master precondition. Only a webview already sitting on its
        // own signed-in app surface is ever rebuilt. This one test excludes
        // sign-in chains, consent screens, a Workspace IdP on an unknown host,
        // marketing pages, Meet, Gmail Chat, `about:blank` and a webview that
        // never loaded — and it is what makes the recycle→signed-out→recycle
        // loop impossible, because a recycle that lands on a signed-out page
        // takes that webview out of the recycler's reach entirely.
        guard AuthSurface.isSignedIn(candidate.url, for: candidate.view) else {
            return .skip(.notSignedIn)
        }

        // The health monitor's stale-inbox case: the URL still looks healthy
        // but the session behind it is dead. Rebuilding it throws away the page
        // the user's click is about to land on.
        guard !candidate.accountIsSignedOut else { return .skip(.signedOut) }

        guard let committedAt = candidate.committedAt else { return .skip(.noCommit) }
        let age = environment.now.timeIntervalSince(committedAt)
        guard age >= threshold(forSlot: candidate.slot) else { return .skip(.tooYoung) }

        // G8 — the crash throttle owns this webview.
        guard !candidate.isStalled else { return .skip(.stalled) }

        // G9 — already getting a fresh document; replacing it mid-load can cut
        // an SSO hop.
        guard !candidate.isLoading else { return .skip(.loading) }

        // G4 — a sign-in is in flight somewhere on this account, so
        // `reloadSignedOutViews` is about to run across the whole session.
        guard !candidate.isAuthenticating else { return .skip(.authenticating) }

        // G5 — a popup on this account: a popped-out compose, a print sheet, or
        // an OAuth window whose `window.opener` channel dies if the opener is
        // replaced.
        guard !candidate.accountHasPopup else { return .skip(.popup) }

        // G6 — a download in flight on this account's data store.
        guard !candidate.accountHasDownload else { return .skip(.download) }

        // G7 — an open panel returned files into this webview recently.
        if let panel = candidate.lastOpenPanelAt,
           environment.now.timeIntervalSince(panel) < openPanelHold {
            return .skip(.openPanel)
        }

        // G2/G3 — unsaved work, read from the URL alone.
        if let url = candidate.url {
            if hasOpenCompose(url) { return .skip(.compose) }
            if hasOpenCalendarEdit(url) { return .skip(.calendarEdit) }
        }

        // G11 — recently deselected.
        if let deselected = candidate.lastDeselectedAt,
           environment.now.timeIntervalSince(deselected) < deselectionHold {
            return .skip(.recentlyDeselected)
        }

        // A background webview is invisible: no further gate. Waiting for idle
        // to rebuild an invisible tab would routinely let it cross twenty
        // hours during a working day, which is the failure being fixed.
        guard candidate.isSelected else { return .recycle }

        // G10 — the page he is looking at right now.
        if age >= hardAge {
            let quiet = environment.lastLocalInputAt
                .map { environment.now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            return quiet >= inputQuietRequirement ? .recycle : .skip(.userIsLooking)
        }
        if !environment.mainWindowIsVisible { return .recycle }
        if !environment.appIsActive, environment.systemIdle >= idleRequirement { return .recycle }
        return .skip(.userIsLooking)
    }

    /// Which of the three openings let a recycle through, for the log line.
    static func trigger(_ candidate: Candidate, in environment: Environment) -> Trigger {
        guard candidate.isSelected else { return .background }
        if let committedAt = candidate.committedAt,
           environment.now.timeIntervalSince(committedAt) >= hardAge {
            return .hardDeadline
        }
        return environment.mainWindowIsVisible ? .idle : .windowHidden
    }

    // MARK: - G2: open compose / unsaved mail work

    /// URL-only, no DOM: nothing here can be wrong because Gmail renamed a CSS
    /// class, and nothing here reads a single word of the user's mail.
    ///
    /// A false positive costs one skipped cycle. A false negative costs a
    /// draft — so this is deliberately generous, and ends with a
    /// belt-and-braces substring test on the whole absolute string.
    static func hasOpenCompose(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), UnreadPoller.mailHosts.contains(host) else { return false }

        // (a)/(e) The fragment, split at its first `?`. Gmail keeps compose
        // state there: `#inbox?compose=new`, `#inbox?compose=<draft id>`, and
        // multi-draft `#inbox?compose=abc,def`.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let fragment = components?.percentEncodedFragment {
            let halves = fragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            if let path = halves.first, path.lowercased().hasPrefix("settings") { return true }
            if halves.count == 2 {
                var inner = URLComponents()
                inner.percentEncodedQuery = String(halves[1])
                if let items = inner.queryItems,
                   items.contains(where: { $0.name.lowercased() == "compose" && !($0.value ?? "").isEmpty }) {
                    return true
                }
            }
        }

        // (b)/(c)/(d) The real query: a popped-out compose window
        // (`?view=cm&fs=1&tf=1&to=…`), the `mailto:` hand-off URL
        // `AppDelegate.composeURL` builds before Gmail rewrites it, and a bare
        // `compose` item.
        if let items = components?.queryItems {
            for item in items {
                let name = item.name.lowercased()
                let value = item.value?.lowercased()
                if name == "compose" { return true }
                if name == "view", value == "cm" { return true }
                if name == "extsrc", value == "mailto" { return true }
            }
        }

        // Belt and braces. Whatever shape Gmail invents next, these two strings
        // are what compose has always looked like.
        let absolute = url.absoluteString.lowercased()
        return absolute.contains("compose=") || absolute.contains("view=cm")
    }

    // MARK: - G3: unsaved calendar event edit

    /// `/calendar/u/0/r/eventedit`, `/r/eventedit/<id>`,
    /// `/r/eventedit/<id>/<cal>?…`, and the settings pages where an unsaved
    /// notification rule or working-hours change is real work.
    static func hasOpenCalendarEdit(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "calendar.google.com" else { return false }
        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        return segments.contains("eventedit") || segments.contains("settings")
    }

    // MARK: - Failure policy

    /// How long to wait before retrying a recycle load that failed, given how
    /// many attempts have already failed. `nil` stops.
    ///
    /// Never a tight loop: the webview's age was reset at issue time, so once
    /// the two retries are spent the next attempt is an ordinary one about
    /// twelve hours later.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case 1: return 60
        case 2: return 300
        default: return nil
        }
    }
}

/// What the recycler needs of the app around it.
protocol TabRecyclerHost: AnyObject {
    /// Every live tab webview, with the account and slot it belongs to.
    func recycleTargets() -> [TabRecycler.Target]
    /// The facts only the app can answer about one target.
    func recycleCandidate(for target: TabRecycler.Target) -> RecycleDecision.Candidate?
    /// Replaces the webview and re-navigates it to the URL it was on. Returns
    /// the fresh webview, or `nil` if the replacement could not happen.
    func performRecycle(_ target: TabRecycler.Target, to url: URL) -> WKWebView?
    /// Whether the main window is actually on screen.
    var mainWindowIsVisible: Bool { get }
}

/// The thin driver: a 60 s tick, the per-webview commit clock, and the one log
/// line per recycle. All the judgement lives in `RecycleDecision`.
///
/// Modelled on `UnreadPoller` — same timer shape, same `.common` run-loop mode,
/// same "the provider re-reads the session on every call" contract, so a
/// webview this class replaces is picked up by everything else for free.
final class TabRecycler {
    struct Target {
        let accountId: UUID
        let accountName: String
        let view: AccountView
        let slot: Int
        let webView: WKWebView
    }

    private let interval: TimeInterval
    private let settings: AppSettings
    private var timer: Timer?
    private var inputMonitor: Any?

    weak var host: TabRecyclerHost?

    /// When each webview's current document committed. Weak-keyed because
    /// `ObjectIdentifier` is the object's address and the allocator reuses
    /// addresses — a stamp must never outlive the webview it describes.
    private var lastCommittedAt = WeakObjectMap<WKWebView, Date>()
    /// When each webview last stopped being the selected tab (G11).
    private var lastDeselectedAt = WeakObjectMap<WKWebView, Date>()
    /// Webviews with a recycle load in flight. `SessionHealth` reads this as
    /// BUSY, so a recycle can never manufacture a signed-out verdict.
    private var recycling = WeakObjectSet<WKWebView>()
    /// Consecutive failed loads per recycled webview, for the retry ladder.
    private var failures = WeakObjectMap<WKWebView, Int>()
    /// Where a recycle load was aimed. Kept because a failed *provisional*
    /// navigation can leave `webView.url` nil or on the previous document, and
    /// the retry has to go to the page the user was actually on.
    private var recycleTarget = WeakObjectMap<WKWebView, URL>()
    /// When a guard holding this webview back was last written to the log.
    private var lastBlockLogAt = WeakObjectMap<WKWebView, Date>()
    private var lastRecycleAt: Date?
    /// When MailSpace itself last saw an event. A *local* monitor: events
    /// already being delivered to this app, so no permission is involved.
    private var lastLocalInputAt: Date?

    init(interval: TimeInterval = 60, settings: AppSettings = .shared) {
        self.interval = interval
        self.settings = settings
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        startInputMonitor()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startInputMonitor() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.lastLocalInputAt = Date()
            return event
        }
    }

    // MARK: - The clock

    /// Stamped from `NavigationPolicy.webView(_:didCommit:)`, which is
    /// main-frame-only and is not fired by a fragment change.
    func webViewDidCommit(_ webView: WKWebView) {
        lastCommittedAt[webView] = Date()
    }

    /// Set at issue time by `recycle`, and cleared when the load settles.
    func webViewDidSettle(_ webView: WKWebView) {
        recycling.remove(webView)
        failures.removeValue(forKey: webView)
        recycleTarget.removeValue(forKey: webView)
    }

    /// A recycle load that failed. Retries once after 60 s and once more after
    /// 5 min, then stops.
    func webViewDidFail(_ webView: WKWebView) {
        guard recycling.contains(webView) else { return }
        let count = (failures[webView] ?? 0) + 1
        failures[webView] = count
        let url = recycleTarget[webView]
        guard let delay = RecycleDecision.retryDelay(afterFailures: count), let url else {
            recycling.remove(webView)
            failures.removeValue(forKey: webView)
            recycleTarget.removeValue(forKey: webView)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
            guard let webView else { return }
            webView.load(URLRequest(url: url))
        }
    }

    /// Stamped from `MainWindowController.select` before the selection moves.
    func webViewWasDeselected(_ webView: WKWebView) {
        lastDeselectedAt[webView] = Date()
    }

    /// Object-identity records must not outlive their webview.
    func webViewWasDiscarded(_ webView: WKWebView) {
        lastCommittedAt.removeValue(forKey: webView)
        lastDeselectedAt.removeValue(forKey: webView)
        failures.removeValue(forKey: webView)
        recycleTarget.removeValue(forKey: webView)
        lastBlockLogAt.removeValue(forKey: webView)
        recycling.remove(webView)
    }

    /// Whether a recycle load is in flight in this webview — the flag
    /// `SessionHealth` reads as BUSY.
    func isRecycling(_ webView: WKWebView) -> Bool { recycling.contains(webView) }

    /// How old this webview's document is, for the tooltip and the log.
    func age(of webView: WKWebView, now: Date = Date()) -> TimeInterval? {
        lastCommittedAt[webView].map { now.timeIntervalSince($0) }
    }

    // MARK: - The tick

    private func tick() {
        guard let host else { return }
        let environment = makeEnvironment()

        for target in host.recycleTargets() {
            var candidate = host.recycleCandidate(for: target)
            candidate?.lastDeselectedAt = lastDeselectedAt[target.webView]
            candidate?.committedAt = lastCommittedAt[target.webView]
            guard let candidate else { continue }
            // A recycle already in flight in this webview is one recycle too
            // many (G13, per-webview half).
            guard !recycling.contains(target.webView) else { continue }

            switch RecycleDecision.evaluate(candidate, in: environment) {
            case .skip(let reason):
                noteBlocked(target, reason: reason, now: environment.now)
                continue
            case .recycle:
                lastBlockLogAt.removeValue(forKey: target.webView)
            }
            recycle(target, candidate: candidate, environment: environment)
            // One recycle per tick, whatever `globalSpacing` would allow: the
            // spacing rule is what drips them out after a long sleep.
            return
        }
    }

    /// One line per webview per twelve hours while a guard is holding an
    /// otherwise-eligible tab back. A tab that is still blocked after 36 hours
    /// is a defect to investigate, never something to force.
    private func noteBlocked(_ target: Target, reason: RecycleDecision.Reason, now: Date) {
        guard RecycleDecision.isPersistentBlock(reason) else {
            lastBlockLogAt.removeValue(forKey: target.webView)
            return
        }
        if let last = lastBlockLogAt[target.webView], now.timeIntervalSince(last) < 12 * 3600 { return }
        lastBlockLogAt[target.webView] = now
        let age = lastCommittedAt[target.webView].map { now.timeIntervalSince($0) } ?? 0
        Log.info(
            "recycle blocked account=\(target.accountName) view=\(target.view.rawValue) "
            + "age=\(Self.describe(age)) reason=\(reason.rawValue)"
        )
    }

    private func makeEnvironment() -> RecycleDecision.Environment {
        RecycleDecision.Environment(
            now: Date(),
            isEnabled: settings.automaticTabRecycling,
            appIsActive: NSApp.isActive,
            mainWindowIsVisible: host?.mainWindowIsVisible ?? false,
            systemIdle: Self.systemIdleSeconds(),
            lastLocalInputAt: lastLocalInputAt,
            modalIsUp: NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil,
            lastRecycleAt: lastRecycleAt
        )
    }

    /// Seconds since the user last touched this Mac. A counter read on the
    /// combined session state — not an event tap — so it raises no TCC prompt
    /// and needs no privileges.
    static func systemIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
    }

    private func recycle(
        _ target: Target,
        candidate: RecycleDecision.Candidate,
        environment: RecycleDecision.Environment
    ) {
        guard let host, let url = candidate.url else { return }

        let trigger = RecycleDecision.trigger(candidate, in: environment)
        let age = candidate.committedAt.map { environment.now.timeIntervalSince($0) } ?? 0
        guard let fresh = host.performRecycle(target, to: url) else { return }

        lastRecycleAt = environment.now
        // Stamped at issue time, before the load returns. This single line is
        // what prevents an infinite recycle loop: if the load never commits,
        // the age does not stay pinned at the old document's timestamp and
        // re-fire on every tick.
        lastCommittedAt[fresh] = environment.now
        recycling.insert(fresh)
        recycleTarget[fresh] = url
        webViewWasDiscarded(target.webView)

        Log.info(
            "recycled account=\(target.accountName) view=\(target.view.rawValue) "
            + "age=\(Self.describe(age)) reason=\(trigger.rawValue)"
        )
    }

    /// `12h04m`, for the log line that makes a week of uptime auditable in
    /// Console with no harness at all.
    static func describe(_ age: TimeInterval) -> String {
        let total = Int(max(age, 0))
        return String(format: "%dh%02dm", total / 3600, (total % 3600) / 60)
    }
}
