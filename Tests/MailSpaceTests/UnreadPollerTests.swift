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
            "type": "basic"
        ])
        XCTAssertEqual(healthy, SessionHealth.Probe(ok: true, parsed: true, status: 200, type: "basic"))
        XCTAssertEqual(SessionHealth.observation(for: healthy), .healthy)

        let redirected = UnreadPoller.probe(from: ["ok": false, "feed": "", "status": 0, "type": "opaqueredirect"])
        XCTAssertEqual(SessionHealth.observation(for: redirected), .authFailedWeak)

        XCTAssertEqual(
            UnreadPoller.probe(from: nil),
            SessionHealth.Probe(ok: false, parsed: false, status: -1, type: "error")
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
