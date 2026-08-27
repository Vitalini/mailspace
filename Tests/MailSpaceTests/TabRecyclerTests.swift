import WebKit
import XCTest
@testable import MailSpace

/// The automatic-recycling rule, guard by guard.
///
/// Everything `RecycleDecision` decides is a pure function over plain values,
/// which is the point: a rule about twelve-hour-old webviews is not something
/// you can wait for, and every guard here protects either unsaved work or the
/// page the user is looking at.
final class RecycleDecisionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    /// A background mail tab, old enough, with nothing wrong with it.
    private func eligible(
        age: TimeInterval = 13 * 3600,
        slot: Int = 0,
        view: AccountView = .mail,
        page: String = "https://mail.google.com/mail/u/0/#inbox"
    ) -> RecycleDecision.Candidate {
        RecycleDecision.Candidate(
            url: url(page),
            view: view,
            slot: slot,
            committedAt: epoch.addingTimeInterval(-age)
        )
    }

    private func environment(
        enabled: Bool = true,
        appIsActive: Bool = false,
        windowVisible: Bool = true,
        idle: TimeInterval = 0,
        lastInput: Date? = nil,
        modal: Bool = false,
        lastRecycle: Date? = nil,
        reachability: RecycleDecision.Reachability = .up,
        lastWake: Date? = nil
    ) -> RecycleDecision.Environment {
        RecycleDecision.Environment(
            now: epoch,
            isEnabled: enabled,
            appIsActive: appIsActive,
            mainWindowIsVisible: windowVisible,
            systemIdle: idle,
            lastLocalInputAt: lastInput,
            modalIsUp: modal,
            lastRecycleAt: lastRecycle,
            reachability: reachability,
            lastWakeAt: lastWake
        )
    }

    private func decide(
        _ candidate: RecycleDecision.Candidate,
        _ environment: RecycleDecision.Environment
    ) -> RecycleDecision.Outcome {
        RecycleDecision.evaluate(candidate, in: environment)
    }

    // MARK: - The trigger

    func testABackgroundTabPastTwelveHoursIsRecycled() {
        XCTAssertEqual(decide(eligible(), environment()), .recycle)
    }

    func testAYoungTabIsLeftAlone() {
        XCTAssertEqual(decide(eligible(age: 11 * 3600), environment()), .skip(.tooYoung))
    }

    /// Slot stagger: five minutes per position, so four webviews that all
    /// loaded at t=0 never come due in lockstep again.
    func testTheStaggerPushesLaterSlotsOut() {
        let age = RecycleDecision.minimumAge + 60
        XCTAssertEqual(decide(eligible(age: age, slot: 0), environment()), .recycle)
        XCTAssertEqual(decide(eligible(age: age, slot: 1), environment()), .skip(.tooYoung))
        XCTAssertEqual(
            decide(eligible(age: age + RecycleDecision.slotStagger, slot: 1), environment()),
            .recycle
        )
    }

    /// A webview that has never committed a document has no age and is
    /// ineligible — which is also what keeps a crashed-on-first-load tab away
    /// from the recycler.
    func testAWebViewThatNeverCommittedIsIneligible() {
        var candidate = eligible()
        candidate.committedAt = nil
        XCTAssertEqual(decide(candidate, environment()), .skip(.noCommit))
    }

    /// The whole reason the tick is 60s and the threshold is an age: sleep
    /// counts, and everything is eligible on wake. The spacing rule is what
    /// drips them out.
    func testOneRecycleInTheWholeAppPerTwoMinutes() {
        let recent = epoch.addingTimeInterval(-30)
        XCTAssertEqual(decide(eligible(), environment(lastRecycle: recent)), .skip(.globalSpacing))
        let older = epoch.addingTimeInterval(-RecycleDecision.globalSpacing - 1)
        XCTAssertEqual(decide(eligible(), environment(lastRecycle: older)), .recycle)
    }

    // MARK: - G14, G12

    func testTheFeatureCanBeSwitchedOff() {
        XCTAssertEqual(decide(eligible(), environment(enabled: false)), .skip(.featureOff))
    }

    /// `AccountEditor.run()` and the removal alert are `runModal`, and a
    /// `.common`-mode timer keeps firing under a modal session.
    func testAModalStopsTheWholeCycle() {
        XCTAssertEqual(decide(eligible(), environment(modal: true)), .skip(.modal))
    }

    // MARK: - G1, the master precondition

    func testOnlyItsOwnSignedInAppSurfaceIsEverRecycled() {
        let cases = [
            "https://accounts.google.com/v3/signin/identifier",
            "https://consent.google.com/c",
            "https://meet.google.com/abc-defg-hij",
            "https://idp.customer.example/login",
            "https://www.google.com/gmail/about/",
            "about:blank"
        ]
        for page in cases {
            XCTAssertEqual(decide(eligible(page: page), environment()), .skip(.notSignedIn), page)
        }
        var never = eligible()
        never.url = nil
        XCTAssertEqual(decide(never, environment()), .skip(.notSignedIn))
    }

    /// Gmail Chat classifies as `.other`, so it never reaches the recycler —
    /// and a Calendar page in a mail webview is not that webview's own surface.
    func testTheSurfaceMustBelongToThisView() {
        XCTAssertEqual(
            decide(eligible(page: "https://mail.google.com/chat/u/0/#chat/home"), environment()),
            .skip(.notSignedIn)
        )
        XCTAssertEqual(
            decide(eligible(view: .calendar, page: "https://mail.google.com/mail/u/0/"), environment()),
            .skip(.notSignedIn)
        )
        XCTAssertEqual(
            decide(eligible(view: .calendar, page: "https://calendar.google.com/calendar/u/0/r/week"), environment()),
            .recycle
        )
    }

    /// The stale-inbox variant: the URL still looks healthy, but the health
    /// monitor has proved the session behind it is dead. Rebuilding it reclaims
    /// nothing and throws away the page the user's click is about to land on.
    func testASignedOutAccountIsNeverRecycled() {
        var candidate = eligible()
        candidate.accountIsSignedOut = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.signedOut))
    }

    // MARK: - G2, open compose

    func testAnOpenComposeBlocksTheTab() {
        let pages = [
            "https://mail.google.com/mail/u/0/#inbox?compose=new",
            "https://mail.google.com/mail/u/0/#inbox?compose=CllgCJZbjLxKQZmm",
            "https://mail.google.com/mail/u/0/#inbox?compose=abc,def",
            "https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1&to=someone@example.com",
            "https://mail.google.com/mail/u/0/?extsrc=mailto&url=mailto%3Aa%40b.c",
            "https://mail.google.com/mail/u/0/?compose=new#inbox",
            "https://mail.google.com/mail/u/0/#settings/general"
        ]
        for page in pages {
            XCTAssertEqual(decide(eligible(page: page), environment()), .skip(.compose), page)
        }
    }

    /// Gmail clears the fragment when the compose closes, so the block clears
    /// itself. An ordinary label, a search and an open thread are all fine.
    func testOrdinaryGmailPagesAreNotReadAsCompose() {
        let pages = [
            "https://mail.google.com/mail/u/0/",
            "https://mail.google.com/mail/u/0/#inbox",
            "https://mail.google.com/mail/u/0/#inbox/FMfcgzQbfWXKlrjvhBmVGpvNxTVzZbHl",
            "https://mail.google.com/mail/u/0/#search/from%3Aboss",
            "https://mail.google.com/mail/u/0/#label/Receipts"
        ]
        for page in pages {
            XCTAssertEqual(decide(eligible(page: page), environment()), .recycle, page)
        }
    }

    /// The compose test is a Gmail-host test: a calendar URL that happens to
    /// carry the word must not be read as mail work by this guard.
    func testTheComposeGuardIsScopedToGmailHosts() {
        XCTAssertFalse(RecycleDecision.hasOpenCompose(url("https://calendar.google.com/calendar/u/0/r?compose=new")))
        XCTAssertTrue(RecycleDecision.hasOpenCompose(url("https://mail.googlemail.com/mail/u/0/#inbox?compose=new")))
    }

    // MARK: - G3, calendar edit

    func testAnUnsavedCalendarEventBlocksTheTab() {
        let pages = [
            "https://calendar.google.com/calendar/u/0/r/eventedit",
            "https://calendar.google.com/calendar/u/0/r/eventedit/NGZ0aTk",
            "https://calendar.google.com/calendar/u/0/r/eventedit/NGZ0aTk/bWU?authuser=0",
            "https://calendar.google.com/calendar/u/0/r/settings/notifications"
        ]
        for page in pages {
            XCTAssertEqual(
                decide(eligible(view: .calendar, page: page), environment()),
                .skip(.calendarEdit),
                page
            )
        }
        XCTAssertEqual(
            decide(eligible(view: .calendar, page: "https://calendar.google.com/calendar/u/0/r/week/2026/8/27"), environment()),
            .recycle
        )
    }

    // MARK: - G4 to G9

    func testASignInInFlightBlocksTheAccount() {
        var candidate = eligible()
        candidate.isAuthenticating = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.authenticating))
    }

    func testAPopupBlocksEveryWebViewOfTheAccount() {
        var candidate = eligible()
        candidate.accountHasPopup = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.popup))
    }

    func testADownloadBlocksEveryWebViewOfTheAccount() {
        var candidate = eligible()
        candidate.accountHasDownload = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.download))
    }

    /// G7's only real coverage for a Drive upload: ten minutes after an open
    /// panel handed files to the page.
    func testAnOpenPanelBlocksItsWebViewForTenMinutes() {
        var candidate = eligible()
        candidate.lastOpenPanelAt = epoch.addingTimeInterval(-60)
        XCTAssertEqual(decide(candidate, environment()), .skip(.openPanel))
        candidate.lastOpenPanelAt = epoch.addingTimeInterval(-RecycleDecision.openPanelHold - 1)
        XCTAssertEqual(decide(candidate, environment()), .recycle)
    }

    /// The boundary that stops the recycler becoming a second retry engine
    /// racing the crash throttle.
    func testAStalledWebViewIsNeverRecycled() {
        var candidate = eligible()
        candidate.isStalled = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.stalled))
    }

    func testAWebViewMidLoadIsLeftAlone() {
        var candidate = eligible()
        candidate.isLoading = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.loading))
    }

    // MARK: - G11

    func testATabIsHeldForFiveMinutesAfterBeingDeselected() {
        var candidate = eligible()
        candidate.lastDeselectedAt = epoch.addingTimeInterval(-120)
        XCTAssertEqual(decide(candidate, environment()), .skip(.recentlyDeselected))
        candidate.lastDeselectedAt = epoch.addingTimeInterval(-RecycleDecision.deselectionHold - 1)
        XCTAssertEqual(decide(candidate, environment()), .recycle)
    }

    // MARK: - G10, the page he is looking at

    func testTheSelectedTabIsNotRebuiltWhileHeIsInTheApp() {
        var candidate = eligible()
        candidate.isSelected = true
        XCTAssertEqual(
            decide(candidate, environment(appIsActive: true, windowVisible: true)),
            .skip(.userIsLooking)
        )
    }

    func testTheSelectedTabIsRebuiltOnceHeHasLeftTheMacAlone() {
        var candidate = eligible()
        candidate.isSelected = true
        XCTAssertEqual(
            decide(candidate, environment(appIsActive: false, idle: 4 * 60)),
            .skip(.userIsLooking)
        )
        XCTAssertEqual(
            decide(candidate, environment(appIsActive: false, idle: RecycleDecision.idleRequirement)),
            .recycle
        )
    }

    func testAHiddenWindowIsOpportunityEnough() {
        var candidate = eligible()
        candidate.isSelected = true
        XCTAssertEqual(
            decide(candidate, environment(appIsActive: true, windowVisible: false)),
            .recycle
        )
    }

    /// Without the hard deadline the selected tab starves: a Mac that sleeps
    /// overnight fires no timers, and on wake the app is frontmost and system
    /// idle is zero, so the ordinary gate never opens.
    func testTheHardDeadlineRebuildsTheSelectedTabAfterTwentyFourHours() {
        var candidate = eligible(age: RecycleDecision.hardAge + 60)
        candidate.isSelected = true
        let busy = environment(appIsActive: true, windowVisible: true, lastInput: epoch.addingTimeInterval(-10))
        XCTAssertEqual(decide(candidate, busy), .skip(.userIsLooking))

        let quiet = environment(
            appIsActive: true,
            windowVisible: true,
            lastInput: epoch.addingTimeInterval(-RecycleDecision.inputQuietRequirement)
        )
        XCTAssertEqual(decide(candidate, quiet), .recycle)
    }

    /// No input has ever been seen — a session where he has not touched the
    /// app at all — counts as quiet.
    func testNoRecordedInputCountsAsQuietForTheHardDeadline() {
        var candidate = eligible(age: RecycleDecision.hardAge + 60)
        candidate.isSelected = true
        XCTAssertEqual(decide(candidate, environment(appIsActive: true)), .recycle)
    }

    /// The hard deadline is a deadline, not an override: unsaved work still
    /// wins. Where the two designs disagree, the guard that protects the user's
    /// work is the one that holds.
    func testTheHardDeadlineStillYieldsToAnOpenCompose() {
        var candidate = eligible(
            age: RecycleDecision.hardAge + 3600,
            page: "https://mail.google.com/mail/u/0/#inbox?compose=new"
        )
        candidate.isSelected = true
        XCTAssertEqual(decide(candidate, environment(appIsActive: true)), .skip(.compose))
    }

    // MARK: - Trigger naming, for the one production log line

    func testTheTriggerNamesWhichOpeningLetItThrough() {
        XCTAssertEqual(RecycleDecision.trigger(eligible(), in: environment()), .background)

        var selected = eligible()
        selected.isSelected = true
        XCTAssertEqual(RecycleDecision.trigger(selected, in: environment(idle: 600)), .idle)
        XCTAssertEqual(RecycleDecision.trigger(selected, in: environment(windowVisible: false)), .windowHidden)

        var old = eligible(age: RecycleDecision.hardAge + 1)
        old.isSelected = true
        XCTAssertEqual(RecycleDecision.trigger(old, in: environment()), .hardDeadline)
    }

    // MARK: - G15: is there a network to reload onto?

    /// The guard the original fourteen were missing. Every one of them asks
    /// "is there work in this page?"; none asked "can this load succeed?" — and
    /// a recycle destroys the page *first*, so a recycle with no network does
    /// not degrade, it deletes.
    func testAnOfflineTabIsNeverRecycledHoweverOldItIs() {
        XCTAssertEqual(
            decide(eligible(age: 40 * 3600), environment(reachability: .down)),
            .skip(.offline)
        )
        var selected = eligible(age: 40 * 3600)
        selected.isSelected = true
        // Not even the hard deadline, which overrides every other opportunity
        // gate, gets past it.
        XCTAssertEqual(
            decide(selected, environment(reachability: .down, lastWake: nil)),
            .skip(.offline)
        )
    }

    /// A link that is up is not a path to Google. This is the captive-portal
    /// case, and it is the one that used to be worst: the load "succeeded" onto
    /// a splash page, so nothing retried and nothing complained.
    func testALinkThatCannotReachGoogleIsNotAReasonToRecycle() {
        XCTAssertEqual(
            decide(eligible(age: 40 * 3600), environment(reachability: .unproven)),
            .skip(.unprovenNetwork)
        )
    }

    /// The two sources, and which one decides.
    func testReachabilityPrefersProofOverTheInterface() {
        // No interface: nothing else matters.
        XCTAssertEqual(
            RecycleDecision.reachability(
                pathIsSatisfied: false, lastReachedGoogleAt: epoch, probesAreRunning: true, now: epoch
            ),
            .down
        )
        // Interface up, Google answered a moment ago.
        XCTAssertEqual(
            RecycleDecision.reachability(
                pathIsSatisfied: true,
                lastReachedGoogleAt: epoch.addingTimeInterval(-60),
                probesAreRunning: true,
                now: epoch
            ),
            .up
        )
        // Interface up, and nothing has got through in a while. A router with
        // no upstream, a portal, a VPN mid-reconnect all look like this.
        XCTAssertEqual(
            RecycleDecision.reachability(
                pathIsSatisfied: true,
                lastReachedGoogleAt: epoch.addingTimeInterval(-RecycleDecision.reachProofWindow - 1),
                probesAreRunning: true,
                now: epoch
            ),
            .unproven
        )
        // Interface up and nothing has *ever* got through.
        XCTAssertEqual(
            RecycleDecision.reachability(
                pathIsSatisfied: true, lastReachedGoogleAt: nil, probesAreRunning: true, now: epoch
            ),
            .unproven
        )
        // Calendar-only: nothing is asking Google anything, so the interface is
        // the whole answer. Withholding recycling forever on a probe that never
        // runs would be worse than trusting it.
        XCTAssertEqual(
            RecycleDecision.reachability(
                pathIsSatisfied: true, lastReachedGoogleAt: nil, probesAreRunning: false, now: epoch
            ),
            .up
        )
    }

    // MARK: - G16: waking up

    /// Waking is when every tab is overdue at once and the network is least
    /// ready. Three minutes of quiet first.
    func testNothingIsRebuiltInTheFirstMinutesAfterAWake() {
        XCTAssertEqual(
            decide(eligible(age: 40 * 3600), environment(lastWake: epoch.addingTimeInterval(-10))),
            .skip(.justWoke)
        )
        XCTAssertEqual(
            decide(
                eligible(age: 40 * 3600),
                environment(lastWake: epoch.addingTimeInterval(-RecycleDecision.wakeSettle - 1))
            ),
            .recycle
        )
    }

    // MARK: - G17: a recycle that is already outstanding

    /// The hole that made a failed recycle permanent. A failed *provisional*
    /// navigation leaves a fresh webview with no URL, and G1 read that as "not
    /// signed in" — a reason that is deliberately not logged — on every tick for
    /// the rest of the session. The outstanding recycle is seen first now.
    func testAWebViewWithARecycleOutstandingIsNotRecycledAgainOrMisreadAsSignedOut() {
        var candidate = eligible()
        candidate.url = nil
        candidate.hasOutstandingRecycle = true
        XCTAssertEqual(decide(candidate, environment()), .skip(.awaitingRetry))

        var dead = eligible()
        dead.url = nil
        dead.loadFailed = true
        XCTAssertEqual(decide(dead, environment()), .skip(.loadFailed))
        // And unlike `.notSignedIn`, this one is loud.
        XCTAssertTrue(RecycleDecision.isPersistentBlock(.loadFailed))
    }

    // MARK: - G18: a live editor the URL cannot see

    /// Gmail's inline reply — the Reply box at the bottom of a thread, far more
    /// common than a popped-out compose — never puts `compose=` in the URL, and
    /// a background tab has no opportunity gate at all once G11 expires.
    func testAPageWithAnEditorInItIsSpared() {
        XCTAssertTrue(RecycleDecision.hasLiveEditor(.init(focused: true, dirty: 0)))
        XCTAssertTrue(RecycleDecision.hasLiveEditor(.init(focused: false, dirty: 1)))
        XCTAssertFalse(RecycleDecision.hasLiveEditor(.init(focused: false, dirty: 0)))
    }

    /// A page that cannot answer is a wedged page, and a wedged page is the one
    /// most in need of rebuilding — so silence is "no editor", not "leave this
    /// tab alone forever".
    func testAPageThatCannotAnswerIsNotSparedForever() {
        XCTAssertFalse(RecycleDecision.hasLiveEditor(nil))
    }

    // MARK: - Failure policy

    /// Five rungs over about fifty minutes, where there used to be two over six
    /// — six minutes being inside the length of an ordinary Wi-Fi outage.
    func testTheRetryLadderOutlastsAnOrdinaryOutage() {
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 1), 30)
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 2), 120)
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 3), 300)
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 4), 900)
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 5), 1800)
        XCTAssertNil(RecycleDecision.retryDelay(afterFailures: 6))
        XCTAssertNil(RecycleDecision.retryDelay(afterFailures: 99))

        let total = (1...5).compactMap { RecycleDecision.retryDelay(afterFailures: $0) }.reduce(0, +)
        XCTAssertGreaterThan(total, 45 * 60)
    }

    /// The rule the whole fix rests on: **a rung is only spent when the network
    /// was up.** Ladder length alone would not save the tab — an outage long
    /// enough would still walk it to the end. Nothing is learned from a load
    /// that had nothing to load from, so nothing is charged for it.
    func testAnOutageCannotExhaustTheLadderHoweverLongItLasts() {
        for reachability in [RecycleDecision.Reachability.down, .unproven] {
            for failures in 0...50 {
                XCTAssertEqual(
                    RecycleDecision.failureAction(failuresSoFar: failures, reachability: reachability),
                    .waitForNetwork(30),
                    "\(reachability) after \(failures)"
                )
            }
        }
    }

    /// Five genuine failures against a working network is a real fault, and
    /// that is what ends the ladder.
    func testFiveFailuresAgainstAWorkingNetworkEndTheLadder() {
        XCTAssertEqual(
            RecycleDecision.failureAction(failuresSoFar: 0, reachability: .up),
            .retry(after: 30, attempt: 1)
        )
        XCTAssertEqual(
            RecycleDecision.failureAction(failuresSoFar: 4, reachability: .up),
            .retry(after: 1800, attempt: 5)
        )
        XCTAssertEqual(
            RecycleDecision.failureAction(failuresSoFar: 5, reachability: .up),
            .giveUp
        )
    }

    /// Every guard is an OR into "do not recycle", so a false positive that
    /// never clears silently retires that tab and restores the original
    /// twenty-hour behaviour. These are the reasons that get a log line.
    func testOnlyReasonsThatCouldNeverClearAreWorthALogLine() {
        for reason in [RecycleDecision.Reason.compose, .calendarEdit, .authenticating, .popup,
                       .download, .openPanel, .stalled, .loading, .recentlyDeselected, .signedOut,
                       .loadFailed, .liveEditor] {
            XCTAssertTrue(RecycleDecision.isPersistentBlock(reason), reason.rawValue)
        }
        for reason in [RecycleDecision.Reason.featureOff, .modal, .globalSpacing,
                       .notSignedIn, .noCommit, .tooYoung, .userIsLooking,
                       .offline, .unprovenNetwork, .justWoke, .awaitingRetry] {
            XCTAssertFalse(RecycleDecision.isPersistentBlock(reason), reason.rawValue)
        }
    }

    // MARK: - The guards that were already there

    /// The whole point of the new guards is that they add to the old ones
    /// rather than replacing them. G2 and G3 still stop a rebuild at any age,
    /// with the network up and nothing else in the way.
    func testTheNewGuardsDidNotWeakenTheOldOnes() {
        let composing = eligible(age: 40 * 3600, page: "https://mail.google.com/mail/u/0/#inbox?compose=new")
        XCTAssertEqual(decide(composing, environment(reachability: .up)), .skip(.compose))

        let editing = eligible(
            age: 40 * 3600,
            view: .calendar,
            page: "https://calendar.google.com/calendar/u/0/r/eventedit/abc"
        )
        XCTAssertEqual(decide(editing, environment(reachability: .up)), .skip(.calendarEdit))
    }

    func testTheAgeIsFormattedForTheLog() {
        XCTAssertEqual(TabRecycler.describe(12 * 3600 + 4 * 60), "12h04m")
        XCTAssertEqual(TabRecycler.describe(0), "0h00m")
        XCTAssertEqual(TabRecycler.describe(-5), "0h00m")
    }
}

/// A `TabRecyclerHost` that answers from plain values, so the *driver* can be
/// tested and not just the rule.
///
/// The runtime path — the tick, the ladder, the stall, the recovery — had no
/// coverage and no seam to give it any: `makeEnvironment` called `Date()`
/// directly and the retry armed a real `asyncAfter`. Its first execution was
/// twelve hours into the owner's uptime, on his live mail. The clock, the
/// scheduler and the loader are injected now, and this is what drives them.
final class FakeRecyclerHost: TabRecyclerHost {
    var targets: [TabRecycler.Target] = []
    var candidates: [ObjectIdentifier: RecycleDecision.Candidate] = [:]
    var reachability: RecycleDecision.Reachability = .up
    var lastWakeAt: Date?
    var mainWindowIsVisible = true
    var editorAnswer: RecycleDecision.EditorState?

    /// What the recycler asked for, in order.
    private(set) var recycled: [String] = []
    private(set) var markedStalled: [URL] = []
    private(set) var stallChanges = 0
    /// Every fresh webview handed back, kept alive for the test's duration.
    private(set) var replacements: [WKWebView] = []

    func recycleTargets() -> [TabRecycler.Target] { targets }

    func recycleCandidate(for target: TabRecycler.Target) -> RecycleDecision.Candidate? {
        candidates[ObjectIdentifier(target.webView)]
    }

    func performRecycle(_ target: TabRecycler.Target, to url: URL) -> WKWebView? {
        recycled.append(target.accountName)
        let fresh = WKWebView()
        replacements.append(fresh)
        // The app swaps the tab's webview for the fresh one, so the fake does
        // too — otherwise the next tick would still be looking at the old one.
        targets = targets.map { existing in
            guard existing.webView === target.webView else { return existing }
            return TabRecycler.Target(
                accountId: existing.accountId,
                accountName: existing.accountName,
                view: existing.view,
                slot: existing.slot,
                webView: fresh
            )
        }
        candidates[ObjectIdentifier(fresh)] = candidates[ObjectIdentifier(target.webView)]
        return fresh
    }

    func editorState(in webView: WKWebView, completion: @escaping (RecycleDecision.EditorState?) -> Void) {
        completion(editorAnswer)
    }

    func markRecycleStalled(_ webView: WKWebView, target url: URL) {
        markedStalled.append(url)
    }

    func recycleStallsChanged() { stallChanges += 1 }
}

/// The recycler's runtime path: what actually happens to a tab, on the clock.
final class TabRecyclerDriverTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let page = URL(string: "https://mail.google.com/mail/u/0/#inbox")!

    private var host: FakeRecyclerHost!
    private var recycler: TabRecycler!
    private var clock: Date!
    /// Delays the recycler asked to be woken after, and the work it wanted run.
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var loads: [URL] = []

    override func setUp() {
        super.setUp()
        clock = epoch
        host = FakeRecyclerHost()
        scheduled = []
        loads = []

        recycler = TabRecycler(settings: AppSettings(defaults: isolatedDefaults()))
        recycler.host = host
        recycler.now = { [unowned self] in self.clock }
        recycler.schedule = { [unowned self] delay, work in
            self.scheduled.append((delay: delay, work: work))
        }
        recycler.load = { [unowned self] _, url in self.loads.append(url) }
    }

    override func tearDown() {
        recycler = nil
        host = nil
        super.tearDown()
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "recycler-driver-\(UUID().uuidString)")!
        AppSettings.registerDefaults(in: suite)
        return suite
    }

    /// Runs whatever the recycler last asked to be scheduled.
    private func fireScheduled(matching delay: TimeInterval? = nil) {
        let due = scheduled.filter { delay == nil || $0.delay == delay }
        scheduled.removeAll { entry in due.contains { $0.delay == entry.delay } }
        for entry in due { entry.work() }
    }

    private func addTab(
        _ name: String,
        slot: Int,
        age: TimeInterval = 13 * 3600
    ) -> WKWebView {
        let webView = WKWebView()
        let target = TabRecycler.Target(
            accountId: UUID(),
            accountName: name,
            view: .mail,
            slot: slot,
            webView: webView
        )
        host.targets.append(target)
        host.candidates[ObjectIdentifier(webView)] = RecycleDecision.Candidate(
            url: page,
            view: .mail,
            slot: slot,
            committedAt: nil
        )
        recycler.webViewDidCommit(webView)
        // `webViewDidCommit` stamps `now()`, so wind the clock back to give the
        // document the age the test wants.
        clock = epoch.addingTimeInterval(age)
        return webView
    }

    // MARK: - The tick

    func testATickRecyclesOneOverdueTabAndStopsThere() {
        _ = addTab("work", slot: 0)
        _ = addTab("personal", slot: 1)
        clock = epoch.addingTimeInterval(40 * 3600)

        recycler.tick()
        XCTAssertEqual(host.recycled, ["work"])
    }

    /// The reachability guard, through the driver rather than the rule: a tick
    /// with no network touches nothing at all. This is the ten-minutes-of-bad-
    /// Wi-Fi scenario, and it used to walk the whole tab list.
    func testATickWithNoNetworkDestroysNothing() {
        for (index, name) in ["work", "personal", "side"].enumerated() {
            _ = addTab(name, slot: index)
        }
        clock = epoch.addingTimeInterval(40 * 3600)
        host.reachability = .down

        for _ in 0..<20 { recycler.tick() }
        XCTAssertEqual(host.recycled, [])

        host.reachability = .unproven
        for _ in 0..<20 { recycler.tick() }
        XCTAssertEqual(host.recycled, [])
    }

    /// Several tabs overdue at once, which is exactly the state a night of
    /// sleep produces, and the wake is what used to fire them all into a
    /// network that was not up yet.
    func testWakingWithEveryTabOverdueDoesNotStampede() {
        for (index, name) in ["work", "personal", "side", "old"].enumerated() {
            _ = addTab(name, slot: index)
        }
        clock = epoch.addingTimeInterval(40 * 3600)
        host.lastWakeAt = clock

        // The first three minutes: nothing, however overdue.
        for _ in 0..<10 { recycler.tick() }
        XCTAssertEqual(host.recycled, [])

        // Settled. One tab, and then the global spacing holds the rest back.
        clock = clock.addingTimeInterval(RecycleDecision.wakeSettle + 1)
        recycler.tick()
        recycler.tick()
        recycler.tick()
        XCTAssertEqual(host.recycled.count, 1, "the spacing rule should drip, not flood")

        // Past the spacing, the next one goes — one at a time, still.
        clock = clock.addingTimeInterval(RecycleDecision.globalSpacing + 1)
        recycler.tick()
        XCTAssertEqual(host.recycled.count, 2)
    }

    /// G18 through the driver: the page says it has an editor, so the recycle
    /// that every pure guard allowed does not happen.
    func testAPageThatSaysItHasAnEditorIsNotRebuilt() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        host.editorAnswer = RecycleDecision.EditorState(focused: true, dirty: 0)

        recycler.tick()
        XCTAssertEqual(host.recycled, [], "an inline reply is work, and the URL cannot see it")

        host.editorAnswer = RecycleDecision.EditorState(focused: false, dirty: 0)
        recycler.tick()
        XCTAssertEqual(host.recycled, ["work"])
    }

    // MARK: - The retry ladder

    /// The race that swallowed every retry. The busy flag releases itself after
    /// 60 s and `URLRequest` also times out at 60 s, so the black-holed-network
    /// failure arrived exactly as the flag was cleared and `webViewDidFail`
    /// returned at its first line. The ladder is keyed on the recycle *target*
    /// now, which the busy release does not touch.
    func testAFailureAfterTheBusyFlagSelfReleasesStillRetries() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        // The 60 s busy release fires first, as it does in the failure that
        // matters.
        fireScheduled(matching: 60)
        XCTAssertFalse(recycler.isRecycling(fresh))

        recycler.webViewDidFail(fresh)
        XCTAssertEqual(scheduled.map(\.delay), [30], "the first rung, not silence")
    }

    /// An outage cannot exhaust the ladder, driven end to end: fifty failures
    /// with no network, and the tab is still alive and still trying.
    func testAnOutageNeverKillsTheTab() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        host.reachability = .down
        for _ in 0..<50 {
            recycler.webViewDidFail(fresh)
            fireScheduled()
        }

        XCTAssertFalse(recycler.hasFailedLoad(fresh), "an outage is not the tab's fault")
        XCTAssertEqual(host.markedStalled, [])
        XCTAssertTrue(recycler.stalledAccounts.isEmpty)
        XCTAssertNotNil(recycler.outstandingTarget(for: fresh), "the aim is still held")
    }

    /// Five failures against a working network is a real fault. The tab is
    /// given up on — and says so, three ways at once.
    func testAGenuinelyDeadTabIsVisibleRatherThanSilent() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        for _ in 0..<RecycleDecision.maximumFailures {
            recycler.webViewDidFail(fresh)
            fireScheduled()
        }
        recycler.webViewDidFail(fresh)

        XCTAssertTrue(recycler.hasFailedLoad(fresh))
        XCTAssertEqual(host.markedStalled, [page], "handed to the stall-recovery path")
        XCTAssertEqual(recycler.stalledAccounts.count, 1, "and to the tab bar and the Dock badge")
        XCTAssertGreaterThan(host.stallChanges, 0)
    }

    /// The property the whole fix exists for: the tab comes back **on its own**
    /// when the network does, with nothing asked of the user.
    func testADeadTabComesBackByItselfWhenTheNetworkReturns() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        for _ in 0...RecycleDecision.maximumFailures {
            recycler.webViewDidFail(fresh)
            fireScheduled()
        }
        XCTAssertTrue(recycler.hasFailedLoad(fresh))

        loads = []
        recycler.networkBecameReachable()

        XCTAssertEqual(loads, [page], "re-navigated to the page it was on, not to a generic inbox")
        XCTAssertFalse(recycler.hasFailedLoad(fresh))
        XCTAssertTrue(recycler.stalledAccounts.isEmpty, "the pill and the ! go away")
    }

    /// A retry that comes due while the network is still down re-arms instead
    /// of putting a request on the wire that cannot succeed.
    func testARetryThatComesDueOfflineDefersRatherThanFires() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        recycler.webViewDidFail(fresh)
        host.reachability = .down
        loads = []
        fireScheduled()

        XCTAssertEqual(loads, [], "nothing on the wire")
        XCTAssertEqual(scheduled.map(\.delay), [30], "and armed again for later")
    }

    /// A commit is the proof the page came back, and it clears everything the
    /// failure put in place.
    func testACommitClearsTheDeadStateAndItsWarnings() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        for _ in 0...RecycleDecision.maximumFailures {
            recycler.webViewDidFail(fresh)
            fireScheduled()
        }
        XCTAssertFalse(recycler.stalledAccounts.isEmpty)

        recycler.webViewDidSettle(fresh)
        XCTAssertFalse(recycler.hasFailedLoad(fresh))
        XCTAssertTrue(recycler.stalledAccounts.isEmpty)
        XCTAssertNil(recycler.outstandingTarget(for: fresh))
    }

    /// Selecting a dead tab clears its warning and resets its ladder — but the
    /// aim is kept, so a rescue that fails too goes straight back onto the
    /// ladder instead of leaving the tab owned by nobody. Clearing the aim here
    /// would have been the same defect in a new place: a load with nothing
    /// watching it.
    func testAUserRescueThatAlsoFailsGoesBackOntoTheLadder() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        guard let fresh = host.replacements.first else { return XCTFail("no recycle happened") }

        for _ in 0...RecycleDecision.maximumFailures {
            recycler.webViewDidFail(fresh)
            fireScheduled()
        }
        XCTAssertTrue(recycler.hasFailedLoad(fresh))

        recycler.userIsRetrying(fresh)
        XCTAssertFalse(recycler.hasFailedLoad(fresh), "the warning comes down")
        XCTAssertTrue(recycler.stalledAccounts.isEmpty)

        // …and the rescue fails as well.
        scheduled = []
        recycler.webViewDidFail(fresh)
        XCTAssertEqual(scheduled.map(\.delay), [30], "back on the ladder at the first rung")
    }

    /// A tab the ladder still owns is not recycled again underneath it — the
    /// second recycle would lose the URL the retry has to go back to.
    func testATabTheLadderOwnsIsNotRecycledAgain() {
        _ = addTab("work", slot: 0)
        clock = epoch.addingTimeInterval(40 * 3600)
        recycler.tick()
        XCTAssertEqual(host.recycled.count, 1)

        clock = clock.addingTimeInterval(40 * 3600)
        recycler.tick()
        recycler.tick()
        XCTAssertEqual(host.recycled.count, 1, "still one; the outstanding recycle is seen first")
    }
}
