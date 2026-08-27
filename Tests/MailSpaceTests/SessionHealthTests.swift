import XCTest
@testable import MailSpace

/// "This account is signed out and MailSpace has stopped getting its mail" —
/// the debounce, and the four things that must never trip it.
///
/// The requirement "a normal sign-in chain must not trigger it" is not really
/// about counting cycles; a slow 2FA outlasts any count. It is about activity:
/// Google commits a page at every step of a sign-in, while an expired session
/// commits once and then sits still for hours. So the count absorbs one
/// anomalous cycle and the commit reset does the real work.
final class SessionHealthTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    /// Feeds `count` observations spaced a minute apart and returns the last
    /// change.
    @discardableResult
    private func feed(
        _ monitor: inout SessionHealth.Monitor,
        _ observation: SessionHealth.Observation,
        times count: Int,
        from start: TimeInterval = 0
    ) -> SessionHealth.Change {
        var change = SessionHealth.Change.unchanged
        for index in 0..<count {
            change = monitor.record(observation, now: epoch.addingTimeInterval(start + Double(index) * 60))
        }
        return change
    }

    // MARK: - Turning a probe into an observation

    func testTheProbeVerdicts() {
        func observe(ok: Bool, parsed: Bool, status: Int, type: String) -> SessionHealth.Observation {
            SessionHealth.observation(for: SessionHealth.Probe(ok: ok, parsed: parsed, status: status, type: type))
        }
        XCTAssertEqual(observe(ok: true, parsed: true, status: 200, type: "basic"), .healthy)
        XCTAssertEqual(observe(ok: false, parsed: false, status: 401, type: "basic"), .authFailedStrong)
        XCTAssertEqual(observe(ok: false, parsed: false, status: 403, type: "basic"), .authFailedStrong)
        // The whole technical unlock: `redirect: 'manual'` turns Google's "go
        // and sign in" from a CORS exception into an inspectable response.
        XCTAssertEqual(observe(ok: false, parsed: false, status: 0, type: "opaqueredirect"), .authFailedWeak)
        XCTAssertEqual(observe(ok: false, parsed: false, status: 429, type: "basic"), .throttled)
        XCTAssertEqual(observe(ok: false, parsed: false, status: 503, type: "basic"), .throttled)
        // A thrown fetch — Wi-Fi off, a captive portal breaking TLS, the 20s
        // abort — is never evidence of anything.
        XCTAssertEqual(observe(ok: false, parsed: false, status: -1, type: "error"), .unreachable)
        // A 200 with no `<fullcount>` in it is not zero and not signed out.
        XCTAssertEqual(observe(ok: true, parsed: false, status: 200, type: "basic"), .unreachable)
    }

    /// Google having already moved the tab onto its login page needs no
    /// inference at all — and no probe.
    func testTheUrlIsConsultedBeforeTheProbe() {
        XCTAssertEqual(
            SessionHealth.observation(url: url("https://accounts.google.com/v3/signin/identifier"), probe: nil),
            .authFailedStrong
        )
        XCTAssertEqual(
            SessionHealth.observation(
                url: url("https://mail.google.com/mail/u/0/#inbox"),
                probe: SessionHealth.Probe(ok: true, parsed: true, status: 200, type: "basic")
            ),
            .healthy
        )
        // A Google page that is neither the chain nor the inbox: never
        // evidence. The indicator's absence is not proof of health.
        XCTAssertEqual(SessionHealth.observation(url: url("https://myaccount.google.com/"), probe: nil), .unreachable)
        XCTAssertEqual(SessionHealth.observation(url: nil, probe: nil), .unreachable)
    }

    // MARK: - Confirmation

    func testThreeStrongObservationsOverThreeMinutesConfirm() {
        var monitor = SessionHealth.Monitor()
        XCTAssertEqual(monitor.record(.authFailedStrong, now: epoch), .unchanged)
        XCTAssertEqual(monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(60)), .unchanged)
        // Third observation, but only two minutes of wall clock so far.
        XCTAssertEqual(monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(120)), .unchanged)
        XCTAssertEqual(
            monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(180)),
            .signedOut(shouldNotify: true)
        )
        XCTAssertEqual(monitor.state, .signedOut)
    }

    /// The weakest evidence in the design: six cycles, and never a notification.
    func testOpaqueRedirectNeedsSixCyclesAndNeverNotifies() {
        var monitor = SessionHealth.Monitor()
        let change = feed(&monitor, .authFailedWeak, times: 5)
        XCTAssertEqual(change, .unchanged)
        XCTAssertEqual(
            monitor.record(.authFailedWeak, now: epoch.addingTimeInterval(300)),
            .signedOut(shouldNotify: false)
        )
    }

    /// One weak observation downgrades the whole streak, so a captive portal
    /// mixed in with real 401s cannot escalate to a banner.
    func testAWeakObservationDowngradesAStrongStreak() {
        var monitor = SessionHealth.Monitor()
        _ = monitor.record(.authFailedStrong, now: epoch)
        _ = monitor.record(.authFailedWeak, now: epoch.addingTimeInterval(60))
        XCTAssertEqual(monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(180)), .unchanged)
    }

    // MARK: - The four things that must not trip it

    /// A live sign-in chain: Google commits a page at every step.
    func testALiveSignInChainNeverConfirms() {
        var monitor = SessionHealth.Monitor()
        for step in 0..<12 {
            let now = epoch.addingTimeInterval(Double(step) * 60)
            XCTAssertEqual(monitor.record(.authFailedStrong, now: now), .unchanged)
            monitor.didCommit()
        }
        XCTAssertEqual(monitor.state, .healthy)
    }

    /// Waking from sleep: coalesced timer fires arrive together and must not
    /// advance a streak.
    func testACoalescedBurstCannotAdvanceTheStreak() {
        var monitor = SessionHealth.Monitor()
        for offset in [0.0, 1.0, 2.0, 3.0, 4.0, 5.0] {
            _ = monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(offset))
        }
        XCTAssertEqual(monitor.streak, 1)
        XCTAssertEqual(monitor.state, .healthy)
    }

    /// No network, and a recycle or a load in flight: frozen, not reset.
    /// A session that expired before the network dropped is still reported once
    /// it comes back.
    func testUnreachableAndBusyFreezeRatherThanReset() {
        var monitor = SessionHealth.Monitor()
        _ = monitor.record(.authFailedStrong, now: epoch)
        _ = monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(60))
        XCTAssertEqual(monitor.record(.unreachable, now: epoch.addingTimeInterval(120)), .unchanged)
        XCTAssertEqual(monitor.record(.busy, now: epoch.addingTimeInterval(180)), .unchanged)
        XCTAssertEqual(monitor.streak, 2)
        XCTAssertEqual(
            monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(240)),
            .signedOut(shouldNotify: true)
        )
    }

    /// Google rate-limiting is never read as an auth failure, and two of them
    /// in a row halve the poll rate for that account.
    func testThrottlingIsNeverEvidenceAndBacksOff() {
        var monitor = SessionHealth.Monitor()
        XCTAssertEqual(monitor.record(.throttled, now: epoch), .unchanged)
        XCTAssertFalse(monitor.isBackingOff)
        XCTAssertEqual(monitor.record(.throttled, now: epoch.addingTimeInterval(60)), .unchanged)
        XCTAssertTrue(monitor.isBackingOff)
        XCTAssertEqual(monitor.state, .healthy)
        _ = monitor.record(.healthy, now: epoch.addingTimeInterval(120))
        XCTAssertFalse(monitor.isBackingOff)
    }

    // MARK: - Recovery

    /// One healthy observation is the whole recovery. There is no manual
    /// dismissal — a dismissable warning about a condition that is still true
    /// is a lie.
    func testOneHealthyObservationRecovers() {
        var monitor = SessionHealth.Monitor()
        feed(&monitor, .authFailedStrong, times: 4)
        XCTAssertEqual(monitor.state, .signedOut)
        XCTAssertEqual(monitor.record(.healthy, now: epoch.addingTimeInterval(300)), .recovered)
        XCTAssertEqual(monitor.state, .healthy)
        XCTAssertEqual(monitor.streak, 0)
    }

    /// One notification per episode; a reminder only after twelve hours.
    func testTheNotificationFiresOncePerEpisodeAndThenTwiceADayAtMost() {
        var monitor = SessionHealth.Monitor()
        feed(&monitor, .authFailedStrong, times: 4)
        XCTAssertEqual(
            monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(600)),
            .signedOut(shouldNotify: false)
        )
        XCTAssertEqual(
            monitor.record(.authFailedStrong, now: epoch.addingTimeInterval(SessionHealth.reminderInterval + 600)),
            .signedOut(shouldNotify: true)
        )
    }

    // MARK: - The tracker

    func testTheTrackerReportsWhichAccountsAreOut() {
        let tracker = SessionHealthTracker()
        let out = UUID()
        let fine = UUID()
        var changes: [UUID: SessionHealth.Change] = [:]
        tracker.onChange = { changes[$0] = $1 }

        for step in 0..<4 {
            tracker.record(.authFailedStrong, for: out, now: epoch.addingTimeInterval(Double(step) * 60))
            tracker.record(.healthy, for: fine, now: epoch.addingTimeInterval(Double(step) * 60))
        }
        XCTAssertEqual(tracker.signedOutAccounts, [out])
        XCTAssertTrue(tracker.isSignedOut(out))
        XCTAssertFalse(tracker.isSignedOut(fine))
        XCTAssertEqual(changes[out], .signedOut(shouldNotify: true))

        tracker.forget(out)
        XCTAssertTrue(tracker.signedOutAccounts.isEmpty)
    }

    /// Selecting a signed-out tab re-navigates it once per episode — and never
    /// when the tab is holding an unsent draft. A missed sign-in prompt is
    /// recoverable; a lost draft is not.
    func testTheClickToRecoverRenavigationIsOncePerEpisodeAndNeverOverADraft() {
        let tracker = SessionHealthTracker()
        let account = UUID()
        for step in 0..<4 {
            tracker.record(.authFailedStrong, for: account, now: epoch.addingTimeInterval(Double(step) * 60))
        }

        let inbox = url("https://mail.google.com/mail/u/0/#inbox")
        let composing = url("https://mail.google.com/mail/u/0/#inbox?compose=new")
        XCTAssertFalse(tracker.shouldRenavigate(accountId: account, url: composing))
        XCTAssertTrue(tracker.shouldRenavigate(accountId: account, url: inbox))
        XCTAssertFalse(tracker.shouldRenavigate(accountId: account, url: inbox))

        // A healthy account is never re-navigated at all.
        tracker.record(.healthy, for: account, now: epoch.addingTimeInterval(600))
        XCTAssertFalse(tracker.shouldRenavigate(accountId: account, url: inbox))
    }

    /// Weak evidence raises the pill but must never throw a page away.
    ///
    /// Six opaque redirects confirm a signed-out verdict, and a proxy or a
    /// captive portal produces exactly that shape on a perfectly live account.
    /// The pill appears — it is a question worth asking — but the click it asks
    /// for used to reload the tab out of whatever thread, search or reply was
    /// open on it.
    func testAWeakVerdictShowsThePillButNeverRenavigates() {
        let tracker = SessionHealthTracker()
        let account = UUID()
        for step in 0..<7 {
            tracker.record(.authFailedWeak, for: account, now: epoch.addingTimeInterval(Double(step) * 60))
        }

        XCTAssertTrue(tracker.isSignedOut(account), "the pill still goes up")
        XCTAssertFalse(tracker.hasStrongEvidence(account))
        XCTAssertFalse(
            tracker.shouldRenavigate(accountId: account, url: url("https://mail.google.com/mail/u/0/#inbox")),
            "and nothing of his is thrown away to check it"
        )
    }

    /// A sign-in that is actually in progress must not be reloaded back to its
    /// first step. Google `pushState`s through identifier, password and 2FA
    /// rather than committing a document per step, so the `didCommit` streak
    /// reset does not cover a slow one — a security key or a phone prompt.
    func testATabAlreadyOnTheSignInChainIsNeverRenavigated() {
        let tracker = SessionHealthTracker()
        let account = UUID()
        for step in 0..<4 {
            tracker.record(.authFailedStrong, for: account, now: epoch.addingTimeInterval(Double(step) * 60))
        }

        XCTAssertFalse(
            tracker.shouldRenavigate(
                accountId: account,
                url: url("https://accounts.google.com/v3/signin/challenge/totp")
            ),
            "he is halfway through signing in; this would send him back to step one"
        )
        // The same account, on the inbox, still recovers.
        XCTAssertTrue(
            tracker.shouldRenavigate(accountId: account, url: url("https://mail.google.com/mail/u/0/#inbox"))
        )
    }

    /// An inline reply is invisible to `hasOpenCompose`, so the page is asked
    /// as well as the URL — the same question G18 asks before a recycle.
    func testALiveEditorStopsTheRenavigationToo() {
        let tracker = SessionHealthTracker()
        let account = UUID()
        for step in 0..<4 {
            tracker.record(.authFailedStrong, for: account, now: epoch.addingTimeInterval(Double(step) * 60))
        }

        let inbox = url("https://mail.google.com/mail/u/0/#inbox")
        XCTAssertFalse(tracker.shouldRenavigate(accountId: account, url: inbox, hasLiveEditor: true))
        XCTAssertTrue(tracker.shouldRenavigate(accountId: account, url: inbox, hasLiveEditor: false))
    }

    /// Losing the network is not being signed out, and the probe now says which
    /// is which. A thrown fetch never reached Google; an opaque redirect did,
    /// and so did every status.
    func testOnlyAThrownFetchMeansGoogleWasNotReached() {
        XCTAssertFalse(
            SessionHealth.Probe(ok: false, parsed: false, status: -1, type: "error", reached: false).reached
        )
        XCTAssertTrue(
            SessionHealth.Probe(ok: false, parsed: false, status: 0, type: "opaqueredirect", reached: true).reached
        )
        XCTAssertTrue(
            SessionHealth.Probe(ok: true, parsed: true, status: 200, type: "basic", reached: true).reached
        )
    }

    /// A multi-login profile whose feed redirects same-origin to `/mail/u/N/`
    /// is signed *in*. `redirect: 'manual'` turned that into an opaque redirect
    /// — weak signed-out evidence on a live account, and an unanswered cycle on
    /// the Dock badge. Following it once tells the two apart: this one resolves.
    func testAFollowedSameOriginRedirectIsHealthyNotSignedOut() {
        let followed = UnreadPoller.probe(from: [
            "ok": true,
            "feed": "<feed><fullcount>3</fullcount></feed>",
            "status": 200,
            "type": "redirect-followed",
            "reached": true
        ])
        XCTAssertEqual(SessionHealth.observation(for: followed), .healthy)
    }
}
