import XCTest
@testable import MailSpace

/// Where the unread feed can actually be read from.
///
/// The regression this covers: a signed-out account's mail webview sits on
/// `accounts.google.com`, where the feed fetch is cross-origin, gets no CORS
/// headers and rejects. The script reported that as a failed poll, the
/// completion's guard kept the previous count, and the Dock badge carried a
/// stale unread number for as long as the account stayed signed out — nothing
/// cleared it. "Not on Gmail" has to mean zero, while a genuine network blip
/// still keeps the last known count.
final class UnreadPollerOriginTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    func testGmailOriginsCanBePolled() {
        XCTAssertTrue(UnreadPoller.canPoll(url("https://mail.google.com/mail/u/0/")))
        XCTAssertTrue(UnreadPoller.canPoll(url("https://mail.google.com/mail/u/0/#inbox")))
        // Host-relative fetch, so a googlemail host is same-origin too.
        XCTAssertTrue(UnreadPoller.canPoll(url("https://mail.googlemail.com/mail/u/0/")))
        XCTAssertTrue(UnreadPoller.canPoll(url("https://MAIL.GOOGLE.COM/mail/u/0/")))
    }

    /// The signed-out case: a definite zero, not a failed poll.
    func testTheSignInPageCannotBePolled() {
        XCTAssertFalse(UnreadPoller.canPoll(url("https://accounts.google.com/v3/signin/identifier")))
        XCTAssertFalse(UnreadPoller.canPoll(url("https://www.google.com/gmail/about/")))
    }

    func testAnUnloadedOrNonWebViewCannotBePolled() {
        XCTAssertFalse(UnreadPoller.canPoll(nil))
        XCTAssertFalse(UnreadPoller.canPoll(url("about:blank")))
        XCTAssertFalse(UnreadPoller.canPoll(url("http://mail.google.com/mail/u/0/")))
    }

    func testLookalikeHostsCannotBePolled() {
        XCTAssertFalse(UnreadPoller.canPoll(url("https://mail.google.com.evil.example/mail/u/0/")))
        XCTAssertFalse(UnreadPoller.canPoll(url("https://notmail.google.com/mail/u/0/")))
    }
}

/// "Definite zero" versus "no answer".
///
/// The boolean this replaces read *any* non-Gmail URL as a definite zero, so an
/// account zeroed its Dock contribution for the moment it happened to be
/// mid-reload — and automatic recycling makes that happen twice a day per
/// account by design. The distinction that actually matters is signed out
/// (a real zero, and the only thing the original comment was ever about) versus
/// not answering right now (keep the last count, exactly as a failed fetch
/// already does), bounded so silence cannot become permanent staleness.
final class UnreadPollerReadingTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    func testGmailIsPolled() {
        XCTAssertEqual(UnreadPoller.reading(for: url("https://mail.google.com/mail/u/0/#inbox")), .poll)
        XCTAssertEqual(UnreadPoller.reading(for: url("https://mail.googlemail.com/mail/u/0/")), .poll)
    }

    /// The one real zero: Google itself has the tab on its login page.
    func testTheSignInChainIsADefiniteZero() {
        XCTAssertEqual(
            UnreadPoller.reading(for: url("https://accounts.google.com/v3/signin/identifier")),
            .definiteZero
        )
        XCTAssertEqual(UnreadPoller.reading(for: url("https://consent.google.com/c")), .definiteZero)
    }

    /// Everything else keeps the previous count. A mid-recycle webview is
    /// exactly this case, and it used to blink the badge down.
    func testEverythingElseIsNoAnswer() {
        let pages = [
            "about:blank",
            "https://www.google.com/gmail/about/",
            "https://calendar.google.com/calendar/u/0/r",
            "https://mail.google.com/chat/u/0/#chat/home",
            "https://idp.customer.example/login",
            "http://mail.google.com/mail/u/0/"
        ]
        for page in pages {
            XCTAssertEqual(UnreadPoller.reading(for: url(page)), .noAnswer, page)
        }
        XCTAssertEqual(UnreadPoller.reading(for: nil), .noAnswer)
    }

    /// …but "keep the previous count" is bounded at ten cycles, so it cannot
    /// become "stale forever" — the failure the original definite-zero rule was
    /// written to prevent.
    func testSilenceIsBoundedAtTenCycles() {
        XCTAssertEqual(UnreadPoller.contribution(previous: 12, unansweredCycles: 1), 12)
        XCTAssertEqual(UnreadPoller.contribution(previous: 12, unansweredCycles: 9), 12)
        XCTAssertEqual(UnreadPoller.contribution(previous: 12, unansweredCycles: 10), 0)
        XCTAssertEqual(UnreadPoller.contribution(previous: nil, unansweredCycles: 10), 0)
    }

    /// The script's answer, as the health monitor reads it. A payload that never
    /// arrived at all is a thrown fetch by another name.
    func testTheProbeIsReadOffTheScriptPayload() {
        let healthy = UnreadPoller.probe(from: [
            "ok": true,
            "feed": "<feed><fullcount>4</fullcount></feed>",
            "status": 200,
            "type": "basic",
            "reached": true
        ])
        XCTAssertEqual(
            healthy,
            SessionHealth.Probe(ok: true, parsed: true, status: 200, type: "basic", reached: true)
        )
        XCTAssertEqual(SessionHealth.observation(for: healthy), .healthy)

        let redirected = UnreadPoller.probe(from: [
            "ok": false, "feed": "", "status": 0, "type": "opaqueredirect", "reached": true
        ])
        XCTAssertEqual(SessionHealth.observation(for: redirected), .authFailedWeak)

        XCTAssertEqual(
            UnreadPoller.probe(from: nil),
            SessionHealth.Probe(ok: false, parsed: false, status: -1, type: "error", reached: false)
        )
    }

    /// The Dock badge stops lying by omission: a signed-out account used to be
    /// dropped from the sum, so the number silently shrank and still read as a
    /// confident total. One `!` however many accounts are out.
    func testTheBadgeSaysWhenAnAccountIsOut() {
        XCTAssertNil(UnreadPoller.badgeLabel(total: 0, anySignedOut: false))
        XCTAssertEqual(UnreadPoller.badgeLabel(total: 12, anySignedOut: false), "12")
        XCTAssertEqual(UnreadPoller.badgeLabel(total: 12, anySignedOut: true), "12!")
        XCTAssertEqual(UnreadPoller.badgeLabel(total: 0, anySignedOut: true), "!")
    }
}

/// What the number counts (A5) and whose numbers are added up (A4).
final class UnreadBadgeTests: XCTestCase {
    // MARK: - Scope

    /// The default. The badge used to count Promotions and Social, which is why
    /// it disagreed with Gmail's own `Inbox (N)`.
    func testPrimaryScopeAsksForTheSmartLabelFeed() {
        XCTAssertEqual(
            UnreadPoller.feedPath(scope: .primary, usePlainFeed: false),
            "/mail/feed/atom/%5Esmartlabel_personal"
        )
    }

    func testEverythingScopeAsksForTheWholeInbox() {
        XCTAssertEqual(UnreadPoller.feedPath(scope: .everything, usePlainFeed: false), "/mail/feed/atom")
    }

    /// The `UnreadUsePlainFeed` valve wins over the pop-up — the way out for
    /// the day Gmail retires the smart label.
    func testThePlainFeedValveOverridesTheScope() {
        XCTAssertEqual(UnreadPoller.feedPath(scope: .primary, usePlainFeed: true), "/mail/feed/atom")
        XCTAssertEqual(UnreadPoller.feedPath(scope: .everything, usePlainFeed: true), "/mail/feed/atom")
    }

    /// Same-origin, host-relative: the fetch runs inside the account's own
    /// Gmail page, which is what makes its cookies apply.
    func testEveryFeedPathIsHostRelative() {
        for scope in BadgeScope.allCases {
            XCTAssertTrue(UnreadPoller.feedPath(scope: scope, usePlainFeed: false).hasPrefix("/"))
        }
    }

    // MARK: - Participation

    func testOnlyParticipatingAccountsAddUp() {
        let work = UUID()
        let personal = UUID()
        let counts = [work: 3, personal: 44]

        XCTAssertEqual(UnreadPoller.dockTotal(counts, participants: [work, personal]), 47)
        XCTAssertEqual(UnreadPoller.dockTotal(counts, participants: [work]), 3)
        XCTAssertEqual(UnreadPoller.dockTotal(counts, participants: []), 0)
    }

    func testAnAccountWithNoCountYetContributesNothing() {
        let work = UUID()
        XCTAssertEqual(UnreadPoller.dockTotal([:], participants: [work]), 0)
        XCTAssertEqual(UnreadPoller.dockTotal([work: 2], participants: [work, UUID()]), 2)
    }

    /// S15, in one assertion: an account left out of the Dock total is still
    /// polled and still holds its own number. Leaving it out of the *polling*
    /// filter instead is what would blank its own tab.
    func testAnExcludedAccountKeepsItsOwnCount() {
        let work = UUID()
        let personal = UUID()
        let counts = [work: 3, personal: 44]

        XCTAssertEqual(UnreadPoller.dockTotal(counts, participants: [work]), 3)
        XCTAssertEqual(counts[personal], 44)
    }

    // MARK: - What the tabs read (U10)

    /// An account the poller has never seen has no number, which the tab draws
    /// as nothing — the same as a definite zero, so no caller has to tell the
    /// two apart.
    func testAnUnknownAccountHasNoCount() {
        XCTAssertNil(UnreadPoller().count(for: UUID()))
    }

    /// The tabs are told wherever the counts settle, which is the one place the
    /// Dock badge is written. That is what keeps the badge and the pills from
    /// ever disagreeing: they are the same number on the same pass (KTD-S7).
    func testTheCountsSettlingTellsTheTabs() {
        let poller = UnreadPoller()
        var told = 0
        poller.onCountsChanged = { told += 1 }

        poller.updateBadge()
        XCTAssertEqual(told, 1)

        // Removing an account settles them too, so a tab cannot outlive its
        // number by a poll cycle.
        poller.forget(accountId: UUID())
        XCTAssertEqual(told, 2)
    }
}
