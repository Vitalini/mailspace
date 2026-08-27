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
        lastRecycle: Date? = nil
    ) -> RecycleDecision.Environment {
        RecycleDecision.Environment(
            now: epoch,
            isEnabled: enabled,
            appIsActive: appIsActive,
            mainWindowIsVisible: windowVisible,
            systemIdle: idle,
            lastLocalInputAt: lastInput,
            modalIsUp: modal,
            lastRecycleAt: lastRecycle
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

    // MARK: - Failure policy

    /// Two retries and then stop. The age was reset at issue time, so the next
    /// attempt is an ordinary one about twelve hours later — never a tight loop.
    func testAFailedRecycleRetriesTwiceAndStops() {
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 1), 60)
        XCTAssertEqual(RecycleDecision.retryDelay(afterFailures: 2), 300)
        XCTAssertNil(RecycleDecision.retryDelay(afterFailures: 3))
        XCTAssertNil(RecycleDecision.retryDelay(afterFailures: 9))
    }

    /// Every guard is an OR into "do not recycle", so a false positive that
    /// never clears silently retires that tab and restores the original
    /// twenty-hour behaviour. These are the reasons that get a log line.
    func testOnlyReasonsThatCouldNeverClearAreWorthALogLine() {
        for reason in [RecycleDecision.Reason.compose, .calendarEdit, .authenticating, .popup,
                       .download, .openPanel, .stalled, .loading, .recentlyDeselected, .signedOut] {
            XCTAssertTrue(RecycleDecision.isPersistentBlock(reason), reason.rawValue)
        }
        for reason in [RecycleDecision.Reason.featureOff, .modal, .globalSpacing,
                       .notSignedIn, .noCommit, .tooYoung, .userIsLooking] {
            XCTAssertFalse(RecycleDecision.isPersistentBlock(reason), reason.rawValue)
        }
    }

    func testTheAgeIsFormattedForTheLog() {
        XCTAssertEqual(TabRecycler.describe(12 * 3600 + 4 * 60), "12h04m")
        XCTAssertEqual(TabRecycler.describe(0), "0h00m")
        XCTAssertEqual(TabRecycler.describe(-5), "0h00m")
    }
}
