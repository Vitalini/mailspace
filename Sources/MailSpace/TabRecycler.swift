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

    /// How long an answer from Google stays good as proof that a request can
    /// still reach it. Five poll cycles: long enough that one dropped probe
    /// does not stop recycling, short enough that a Wi-Fi drop is noticed
    /// before the next tab comes due.
    static let reachProofWindow: TimeInterval = 5 * 60

    /// Quiet required after the Mac wakes before anything is rebuilt.
    ///
    /// Waking is the single worst moment to reload: the interfaces are still
    /// coming up, DNS is cold, a VPN is mid-reconnect, and several tabs are
    /// overdue at once because no timer fired all night. Three minutes lets the
    /// network settle and lets the feed probe re-prove that Google is reachable
    /// before the first tab is touched.
    static let wakeSettle: TimeInterval = 180

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
        /// G17. A recycle has already been issued into this webview and has not
        /// settled. The retry ladder owns it until it does; a second recycle
        /// would race the first and lose the URL the retry has to go back to.
        ///
        /// This is what closes the hole where a failed recycle left a webview
        /// with a `nil` URL, which G1 then read as "not signed in" on every tick
        /// for the rest of the session — silently, because `.notSignedIn` is
        /// not a logged block. The outstanding recycle is seen first, and it is.
        var hasOutstandingRecycle: Bool
        /// G17. The ladder ran out with the network up: this tab is dead until
        /// something rescues it. Skipped *and* logged, and the tab wears the
        /// warning pill — the state that used to be invisible to every
        /// recovery path and to the health monitor at once.
        var loadFailed: Bool

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
            lastDeselectedAt: Date? = nil,
            hasOutstandingRecycle: Bool = false,
            loadFailed: Bool = false
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
            self.hasOutstandingRecycle = hasOutstandingRecycle
            self.loadFailed = loadFailed
        }
    }

    /// Whether a request issued right now could actually reach Google.
    ///
    /// Two sources, because they answer two different questions and only the
    /// second one is the question that matters:
    ///
    /// * `NWPathMonitor` says whether *this Mac* has an interface that could
    ///   carry a request. It is necessary and nowhere near sufficient — a
    ///   router with no upstream, a hotel portal before the login, and a VPN
    ///   mid-reconnect all report `.satisfied`.
    /// * The unread feed probe says whether *Google* answered. Every cycle it
    ///   gets a status, a redirect, anything at all, it has proved the path end
    ///   to end; a thrown fetch proves it has not. That is the only evidence in
    ///   the app about reachability to the thing being reloaded, so it is the
    ///   one that decides.
    enum Reachability: Equatable {
        /// No interface. Nothing can be loaded.
        case down
        /// The link is up and nothing has proved a request gets through. A
        /// captive portal is exactly this shape, and it is the shape that used
        /// to destroy every tab in the app: the load "succeeded" onto a splash
        /// page, so nothing retried and nothing complained.
        case unproven
        case up
    }

    /// The reachability verdict from the two sources.
    ///
    /// `probesAreRunning` is false when no account has Mail on, so nothing is
    /// asking Google anything. Withholding recycling forever on the strength of
    /// a probe that never runs would be worse than trusting the interface, so
    /// in that one case the link is the whole answer.
    static func reachability(
        pathIsSatisfied: Bool,
        lastReachedGoogleAt: Date?,
        probesAreRunning: Bool,
        now: Date
    ) -> Reachability {
        guard pathIsSatisfied else { return .down }
        guard probesAreRunning else { return .up }
        guard let reached = lastReachedGoogleAt,
              now.timeIntervalSince(reached) <= reachProofWindow else { return .unproven }
        return .up
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
        /// G15. Whether a request could reach Google right now.
        var reachability: Reachability = .up
        /// G16. When the Mac last woke from sleep.
        var lastWakeAt: Date?
    }

    /// Why a webview was left alone. Reported so a tab that is permanently
    /// blocked — a compose left open for days, a `sawSignIn` flag that never
    /// resolved — shows up in the log instead of silently retiring itself from
    /// recycling and restoring the original twenty-hour behaviour.
    enum Reason: String, Equatable {
        case featureOff
        case modal
        case globalSpacing
        /// G15. There is no network to reload onto.
        case offline
        /// G15. There is a network and nothing has proved it reaches Google.
        case unprovenNetwork
        /// G16. The Mac woke less than `wakeSettle` ago.
        case justWoke
        /// G17. A recycle is outstanding in this webview; the retry ladder has
        /// it.
        case awaitingRetry
        /// G17. The retry ladder ran out with the network up.
        case loadFailed
        /// G18. The page has a live editor in it — an inline reply, a chat
        /// message, a half-filled form — that the URL alone cannot see.
        case liveEditor
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
             .openPanel, .stalled, .loading, .recentlyDeselected, .signedOut,
             // A tab whose recycle load failed for good is the state this
             // whole failure policy exists to make impossible to miss. It is
             // the one block that must never be silent.
             .loadFailed,
             // An editor that is still "live" after 12 hours is a false
             // positive in the probe, not a person typing. The log is how that
             // shows up instead of quietly retiring the tab.
             .liveEditor:
            return true
        case .featureOff, .modal, .globalSpacing, .notSignedIn, .noCommit,
             .tooYoung, .userIsLooking,
             // Transient by construction, and all three are common: the
             // network comes back, the Mac finishes waking, the ladder settles.
             .offline, .unprovenNetwork, .justWoke, .awaitingRetry:
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

        // G15 — there has to be a network to reload onto.
        //
        // This is the guard the original fourteen were all missing. Every one
        // of them asks "is there work in this page?"; not one asked "can this
        // load succeed?" A recycle fires by *destroying* the page first, so a
        // recycle attempted with no network does not degrade — it throws the
        // page away and gets nothing back. Ten minutes of bad Wi-Fi walked the
        // whole tab list and left every tab blank.
        switch environment.reachability {
        case .down: return .skip(.offline)
        case .unproven: return .skip(.unprovenNetwork)
        case .up: break
        }

        // G16 — the Mac has just woken. The interfaces are still coming up and
        // every tab is overdue at once, which is the one moment the drip in
        // G13 is not enough on its own.
        if let wake = environment.lastWakeAt,
           environment.now.timeIntervalSince(wake) < wakeSettle {
            return .skip(.justWoke)
        }

        // G17 — the retry ladder already owns this webview, or has given up on
        // it. Ahead of G1 on purpose: after a failed provisional navigation a
        // fresh webview has no URL, and G1 would read that as "not signed in"
        // and skip it silently, for the rest of the session, on every tick.
        if candidate.loadFailed { return .skip(.loadFailed) }
        if candidate.hasOutstandingRecycle { return .skip(.awaitingRetry) }

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

    // MARK: - G18: a live editor the URL cannot see

    /// What the page said about editors in it. No text, ever: two booleans and
    /// a count, and the count is of *nodes*, computed in the page.
    struct EditorState: Equatable {
        /// The focused element is something you can type into.
        var focused: Bool
        /// How many editable boxes currently hold anything at all.
        var dirty: Int

        init(focused: Bool, dirty: Int) {
            self.focused = focused
            self.dirty = dirty
        }
    }

    /// Whether this page has work in it that G2 cannot see.
    ///
    /// G2 reads the URL, and Gmail's *inline* reply — the Reply box at the
    /// bottom of a thread, which is the common case, far more common than a
    /// popped-out compose — never puts `compose=` in the URL. Nor does the
    /// Tasks panel, a schedule-send sheet, or a half-typed Chat message. A
    /// background tab has no opportunity gate at all after G11 expires, so
    /// those were rebuilt out from under the user with nothing in the way.
    ///
    /// `nil` means the page could not answer — a wedged or crashed WebContent
    /// process. That is not a reason to spare it: a page that cannot run one
    /// line of DOM query in five seconds is not a page anybody is typing into,
    /// and it is exactly the page most in need of rebuilding.
    static func hasLiveEditor(_ state: EditorState?) -> Bool {
        guard let state else { return false }
        return state.focused || state.dirty > 0
    }

    // MARK: - Failure policy

    /// How long to wait before retrying a recycle load that failed, given how
    /// many attempts have already failed. `nil` means the ladder is spent.
    ///
    /// Five rungs over about fifty minutes, where there used to be two over
    /// six. Six minutes is inside the length of an ordinary Wi-Fi outage, a
    /// train tunnel or a hotel check-in, so the old ladder was routinely
    /// exhausted by events that are not faults at all.
    ///
    /// Length is only half of it, and the smaller half. The rule that actually
    /// makes an outage survivable is in `TabRecycler.retry`: **a rung is only
    /// spent when the network was up.** A retry that comes due while the path
    /// is down or unproven is re-armed at the same delay and the failure count
    /// does not move, so no amount of offline time can walk the ladder to its
    /// end. What ends it is five genuine failures against a network that was
    /// working — which is a real fault, and is reported as one.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval? {
        switch failures {
        case 1: return 30
        case 2: return 120
        case 3: return 300
        case 4: return 900
        case 5: return 1800
        default: return nil
        }
    }

    /// How many failures against a working network end the ladder.
    static let maximumFailures = 5

    /// What to do when a recycle load fails.
    ///
    /// Pure, because "an outage cannot exhaust the ladder" is the property the
    /// whole fix rests on and it should be a test rather than a promise.
    enum FailureAction: Equatable {
        /// Try again after this long, without spending a rung — the network
        /// was not up, so nothing was learned.
        case waitForNetwork(TimeInterval)
        /// Try again after this long. This attempt counted.
        case retry(after: TimeInterval, attempt: Int)
        /// The ladder is spent. The tab is dead until something rescues it, and
        /// it says so.
        case giveUp
    }

    static func failureAction(
        failuresSoFar: Int,
        reachability: Reachability
    ) -> FailureAction {
        // The load failed because there was nothing to load from. That is not
        // evidence about this tab, so it costs the tab nothing.
        guard reachability == .up else { return .waitForNetwork(retryDelay(afterFailures: 1) ?? 30) }

        let attempt = failuresSoFar + 1
        guard let delay = retryDelay(afterFailures: attempt) else { return .giveUp }
        return .retry(after: delay, attempt: attempt)
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
    /// Asks the page whether it has an editor with anything in it (G18). No
    /// text crosses back — see `RecycleDecision.EditorState`. `nil` when the
    /// page could not answer.
    func editorState(in webView: WKWebView, completion: @escaping (RecycleDecision.EditorState?) -> Void)
    /// Whether a request could reach Google right now.
    var reachability: RecycleDecision.Reachability { get }
    /// When the Mac last woke, or `nil` if it has not slept this session.
    var lastWakeAt: Date? { get }
    /// Hands a webview whose recycle load failed for good to the existing
    /// stall-recovery path, so selecting the tab or pressing ⌘R brings it back
    /// — the same way a webview the crash throttle gave up on comes back.
    func markRecycleStalled(_ webView: WKWebView, target url: URL)
    /// The set of accounts with a dead Mail tab changed: repaint the tab bar,
    /// the Dock badge, and notify once per episode.
    func recycleStallsChanged()
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

    /// The clock, and how a delayed retry is scheduled. Injected so the whole
    /// driver — the tick, the ladder, the stall, the recovery — is testable
    /// without waiting twelve hours or standing up WebKit. The runtime path
    /// used to have no seam at all and no coverage: its first real execution
    /// was twelve hours into the owner's uptime, on his live mail.
    var now: () -> Date = { Date() }
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// How a retry actually re-navigates. Injected for the same reason as the
    /// clock: a test of the ladder must not put a real request on the wire.
    var load: (WKWebView, URL) -> Void = { webView, url in
        webView.load(URLRequest(url: url))
    }

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
    ///
    /// This — not `recycling` — is what the retry ladder is keyed on. The busy
    /// flag clears itself after 60 s so the health monitor cannot freeze, and
    /// `URLRequest` also times out at 60 s, so the black-holed-network failure
    /// arrived at the same instant the flag was cleared and lost the race:
    /// `webViewDidFail` returned at its first line and the tab got *zero*
    /// retries. The aim outlives the busy flag, so the ladder cannot be raced
    /// out of existence.
    private var recycleTarget = WeakObjectMap<WKWebView, URL>()
    /// Webviews whose retry ladder ran out with the network up. Their tabs
    /// wear the warning pill and their accounts put the `!` on the Dock badge.
    private var deadTargets = WeakObjectMap<WKWebView, URL>()
    /// The account each dead webview belongs to, for the pill and the badge.
    /// Held by value because the webview it describes may already be gone.
    private var deadAccounts: Set<UUID> = []
    /// The same set at tab resolution, for the pill.
    private var deadTabs: Set<TabRef> = []
    /// Whether a retry is already armed for this webview, so a second failure
    /// callback for the same load cannot arm two.
    private var retryArmed = WeakObjectSet<WKWebView>()
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
    ///
    /// A commit is the one unambiguous proof that the page came back, so it is
    /// what clears the aim, the failure count and — if the tab had been given
    /// up on — the dead flag and everything that hangs off it.
    func webViewDidSettle(_ webView: WKWebView) {
        recycling.remove(webView)
        failures.removeValue(forKey: webView)
        recycleTarget.removeValue(forKey: webView)
        retryArmed.remove(webView)
        guard deadTargets.removeValue(forKey: webView) != nil else { return }
        refreshDeadAccounts()
    }

    /// A recycle load that failed.
    ///
    /// Keyed on the aim rather than on the busy flag, so the 60 s self-release
    /// of `recycling` cannot race the 60 s `URLRequest` timeout and swallow the
    /// whole ladder. A rung is spent only when the network was up; otherwise
    /// the attempt is re-armed for free, which is what makes an outage
    /// survivable however long it lasts.
    func webViewDidFail(_ webView: WKWebView) {
        guard let url = recycleTarget[webView] else { return }
        guard !retryArmed.contains(webView) else { return }
        recycling.remove(webView)

        let reachability = host?.reachability ?? .down
        let action = RecycleDecision.failureAction(
            failuresSoFar: failures[webView] ?? 0,
            reachability: reachability
        )

        switch action {
        case .waitForNetwork(let delay):
            Log.info(
                "recycle load failed with no network to load onto; "
                + "retrying in \(Int(delay))s without spending an attempt"
            )
            armRetry(webView, to: url, after: delay)

        case .retry(let delay, let attempt):
            failures[webView] = attempt
            Log.info("recycle load failed (attempt \(attempt) of \(RecycleDecision.maximumFailures)); retrying in \(Int(delay))s")
            armRetry(webView, to: url, after: delay)

        case .giveUp:
            giveUp(on: webView, target: url)
        }
    }

    private func armRetry(_ webView: WKWebView, to url: URL, after delay: TimeInterval) {
        retryArmed.insert(webView)
        schedule(delay) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.retryArmed.remove(webView)
            // The aim is cleared by a settle, so a load that succeeded while
            // this was pending must not be re-issued on top of it.
            guard self.recycleTarget[webView] != nil else { return }
            self.attemptLoad(webView, to: url)
        }
    }

    private func attemptLoad(_ webView: WKWebView, to url: URL) {
        // Still nothing to load onto: re-arm rather than burn the attempt on a
        // request that cannot succeed. This is the loop an outage sits in for
        // as long as it lasts, and it puts *nothing* on the wire — one timer
        // every 30 s per waiting tab, and the first pass that finds the network
        // up is the one that loads.
        guard host?.reachability == .up else {
            armRetry(webView, to: url, after: RecycleDecision.retryDelay(afterFailures: 1) ?? 30)
            return
        }
        recycling.insert(webView)
        load(webView, url)
        armBusyRelease(for: webView)
    }

    /// The ladder is spent. The tab is not abandoned — it is handed to the
    /// existing stall-recovery path *and* made visible.
    private func giveUp(on webView: WKWebView, target url: URL) {
        failures.removeValue(forKey: webView)
        retryArmed.remove(webView)
        deadTargets[webView] = url
        // `recoverIfStalled` is what `tabBecameVisible` and ⌘R already call, so
        // this puts the tab back on the one recovery path the user reaches by
        // hand. It was never reachable before: `stalled` was only ever set on a
        // WebContent process *termination*, and a navigation failure is not one.
        host?.markRecycleStalled(webView, target: url)
        Log.error(
            "recycle load failed \(RecycleDecision.maximumFailures) times with the network up; "
            + "\(url.host ?? "the tab") is not loading. Its tab is marked and will retry when the "
            + "network comes back or when you select it."
        )
        refreshDeadAccounts()
    }

    /// The network came back. Every tab that gave up gets one immediate go, and
    /// its ladder starts again from the top.
    ///
    /// This is what makes the terminal state impossible without the user doing
    /// anything: he closes the laptop on a train, opens it at the office, and
    /// the tabs come back on their own.
    func networkBecameReachable() {
        let pending = deadTargets.pairs()
        guard !pending.isEmpty else { return }
        Log.info("network is back; retrying \(pending.count) tab(s) whose recycle had given up")
        for (webView, url) in pending {
            deadTargets.removeValue(forKey: webView)
            failures.removeValue(forKey: webView)
            recycleTarget[webView] = url
            attemptLoad(webView, to: url)
        }
        refreshDeadAccounts()
    }

    /// The user selected a tab the ladder had given up on, and something else
    /// has already re-navigated it. The warning comes down and the ladder is
    /// reset — but the *aim* is kept, so if this attempt fails too the tab goes
    /// straight back onto the ladder rather than being left owned by nobody.
    ///
    /// Clearing the aim here instead would have been the same defect in a new
    /// place: a load with nothing watching it.
    func userIsRetrying(_ webView: WKWebView) {
        guard let url = deadTargets.removeValue(forKey: webView) else { return }
        failures.removeValue(forKey: webView)
        retryArmed.remove(webView)
        recycleTarget[webView] = url
        recycling.insert(webView)
        armBusyRelease(for: webView)
        refreshDeadAccounts()
    }

    /// Accounts with a tab that failed to load and has not come back. What the
    /// Dock badge's `!` is drawn from, so it stays per-account.
    var stalledAccounts: Set<UUID> { deadAccounts }

    /// The same fact at the resolution the tab bar needs: *which* tab is dead,
    /// not just which account. A Calendar tab that will not load is a Calendar
    /// tab problem, and marking its Mail sibling instead would point the user at
    /// a tab that is working.
    var stalledTabs: Set<TabRef> { deadTabs }

    /// Recomputed from the host's live tab list rather than tracked
    /// incrementally, so a webview that has been discarded cannot leave a
    /// permanent `!` on the Dock badge.
    private func refreshDeadAccounts() {
        var accounts: Set<UUID> = []
        var tabs: Set<TabRef> = []
        for target in host?.recycleTargets() ?? [] where deadTargets[target.webView] != nil {
            accounts.insert(target.accountId)
            tabs.insert(TabRef(accountId: target.accountId, view: target.view))
        }
        guard accounts != deadAccounts || tabs != deadTabs else { return }
        deadAccounts = accounts
        deadTabs = tabs
        host?.recycleStallsChanged()
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
        retryArmed.remove(webView)
        guard deadTargets.removeValue(forKey: webView) != nil else { return }
        refreshDeadAccounts()
    }

    /// The URL a recycle aimed this webview at, if one is still outstanding.
    ///
    /// `tabBecameVisible` recovers a failed recycle to *this* rather than to the
    /// view's generic entry point, so a rescued tab comes back on the label and
    /// thread the user was on rather than at the top of the inbox.
    func outstandingTarget(for webView: WKWebView) -> URL? {
        deadTargets[webView] ?? recycleTarget[webView]
    }

    /// Whether this webview's recycle load failed for good.
    func hasFailedLoad(_ webView: WKWebView) -> Bool { deadTargets[webView] != nil }

    /// Whether a recycle load is in flight in this webview — the flag
    /// `SessionHealth` reads as BUSY.
    func isRecycling(_ webView: WKWebView) -> Bool { recycling.contains(webView) }

    /// How old this webview's document is, for the tooltip and the log.
    func age(of webView: WKWebView, now: Date = Date()) -> TimeInterval? {
        lastCommittedAt[webView].map { now.timeIntervalSince($0) }
    }

    /// Whether MailSpace saw a key or a click in the last `seconds`.
    ///
    /// The recycler already runs the only local event monitor in the app, so
    /// the health monitor asks it rather than standing up a second one.
    func sawLocalInput(within seconds: TimeInterval) -> Bool {
        guard let last = lastLocalInputAt else { return false }
        return now().timeIntervalSince(last) < seconds
    }

    // MARK: - The tick

    /// Internal rather than private so the whole runtime path — the tick, the
    /// ladder, the stall, the recovery — is reachable from a test with a fake
    /// host and an injected clock, instead of being first executed twelve hours
    /// into the owner's uptime on his live mail.
    func tick() {
        guard let host else { return }
        let environment = makeEnvironment()

        for target in host.recycleTargets() {
            var candidate = host.recycleCandidate(for: target)
            candidate?.lastDeselectedAt = lastDeselectedAt[target.webView]
            candidate?.committedAt = lastCommittedAt[target.webView]
            candidate?.hasOutstandingRecycle = recycleTarget[target.webView] != nil
            candidate?.loadFailed = deadTargets[target.webView] != nil
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

            // G18 — the last question, and the only one that has to be asked of
            // the page rather than of its URL. Asynchronous, so the tick ends
            // here either way; a `recycle` that the page vetoes simply does not
            // happen and the next tick asks again.
            askAndRecycle(target, candidate: candidate, environment: environment)
            // One recycle per tick, whatever `globalSpacing` would allow: the
            // spacing rule is what drips them out after a long sleep.
            return
        }
    }

    /// Asks the page whether it has a live editor, then recycles if it does not.
    private func askAndRecycle(
        _ target: Target,
        candidate: RecycleDecision.Candidate,
        environment: RecycleDecision.Environment
    ) {
        guard let host else { return }
        // Reserved before the answer comes back. Without this the next tick,
        // 60 s later, could start a second recycle of the same tab while the
        // first is still waiting on the page.
        recycling.insert(target.webView)

        host.editorState(in: target.webView) { [weak self, weak host] state in
            guard let self else { return }
            self.recycling.remove(target.webView)
            guard host != nil else { return }

            if RecycleDecision.hasLiveEditor(state) {
                self.noteBlocked(target, reason: .liveEditor, now: self.now())
                return
            }
            self.recycle(target, candidate: candidate, environment: environment)
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
            now: now(),
            isEnabled: settings.automaticTabRecycling,
            appIsActive: NSApp.isActive,
            mainWindowIsVisible: host?.mainWindowIsVisible ?? false,
            systemIdle: Self.systemIdleSeconds(),
            lastLocalInputAt: lastLocalInputAt,
            modalIsUp: NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil,
            lastRecycleAt: lastRecycleAt,
            reachability: host?.reachability ?? .down,
            lastWakeAt: host?.lastWakeAt
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
        armBusyRelease(for: fresh)

        Log.info(
            "recycled account=\(target.accountName) view=\(target.view.rawValue) "
            + "age=\(Self.describe(age)) reason=\(trigger.rawValue)"
        )
    }

    /// The busy flag has to be able to end on its own. WebKit delivers a commit
    /// or a failure for every load, but a flag that only two callbacks can
    /// clear would, if either is ever missed, freeze the health monitor on this
    /// account for the rest of the session.
    ///
    /// It releases the *busy* flag and nothing else. It used to be the thing
    /// that raced `webViewDidFail` out of every one of its retries, because the
    /// ladder was keyed on this flag; the ladder is keyed on `recycleTarget`
    /// now, which this does not touch.
    private func armBusyRelease(for webView: WKWebView) {
        schedule(60) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.recycling.remove(webView)
        }
    }

    /// `12h04m`, for the log line that makes a week of uptime auditable in
    /// Console with no harness at all.
    static func describe(_ age: TimeInterval) -> String {
        let total = Int(max(age, 0))
        return String(format: "%dh%02dm", total / 3600, (total % 3600) / 60)
    }
}
