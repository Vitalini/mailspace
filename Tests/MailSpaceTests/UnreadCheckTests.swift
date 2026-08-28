import XCTest
@testable import MailSpace

/// The URL the unread count comes from, and the rule that keeps a body from
/// anywhere else from being counted as the inbox.
///
/// The regression these are written against: v1.1.0's default scope asked for
/// `/mail/feed/atom/%5Esmartlabel_personal`. Anything after `/atom/` is a Gmail
/// *label* feed, and a label feed counts unread mail carrying that label
/// anywhere in the mailbox — archived included. An account with ~3,500 unread
/// sitting in archived labels and 2 in its inbox showed `999+` on its tab.
///
/// The test that shipped with the bug asserted the literal smart-label string,
/// so it stayed green for the whole regression: it only ever checked that the
/// app was asking the wrong question consistently.
final class UnreadFeedPathTests: XCTestCase {
    func testTheOnlyFeedEverRequestedIsTheInboxFeed() {
        XCTAssertEqual(UnreadPoller.feedPath, "/mail/feed/atom")
    }

    /// Same-origin, host-relative: the fetch runs inside the account's own
    /// Gmail page, which is what makes its cookies apply.
    func testTheFeedPathIsHostRelative() {
        XCTAssertTrue(UnreadPoller.feedPath.hasPrefix("/"))
    }

    /// The shape check, rather than the string: a label feed is the inbox feed
    /// plus one more segment, and that segment is the entire bug. This fails
    /// the moment anyone appends one again.
    func testTheFeedPathCarriesNoLabelSegment() {
        let segments = UnreadPoller.feedPath.split(separator: "/").map(String.init)
        XCTAssertEqual(segments, ["mail", "feed", "atom"])
        XCTAssertFalse(UnreadPoller.feedPath.contains("%5E"))
        XCTAssertFalse(UnreadPoller.feedPath.contains("smartlabel"))
    }

    // MARK: - Which bodies may be attributed to the inbox

    func testTheInboxFeedIsAccepted() {
        XCTAssertTrue(UnreadPoller.servesTheInboxFeed(host: "mail.google.com", path: "/mail/feed/atom"))
        XCTAssertTrue(UnreadPoller.servesTheInboxFeed(host: "mail.googlemail.com", path: "/mail/feed/atom"))
        XCTAssertTrue(UnreadPoller.servesTheInboxFeed(host: "MAIL.GOOGLE.COM", path: "/mail/feed/atom"))
        // A trailing slash is the same resource.
        XCTAssertTrue(UnreadPoller.servesTheInboxFeed(host: "mail.google.com", path: "/mail/feed/atom/"))
    }

    /// The multi-login profile form. `/mail/feed/atom` redirects here for an
    /// account signed into several Google profiles, and it is the same inbox.
    func testTheProfileFormOfTheInboxFeedIsAccepted() {
        for path in ["/mail/u/0/feed/atom", "/mail/u/1/feed/atom", "/mail/u/12/feed/atom"] {
            XCTAssertTrue(UnreadPoller.servesTheInboxFeed(host: "mail.google.com", path: path), path)
        }
    }

    /// The bug, as a rule rather than a URL: no label feed is the inbox, under
    /// any label name. `^sq_ig_i_personal` is in here on purpose — it is the
    /// plausible-looking "real Primary label" a later fix would reach for, and
    /// it is still a label feed and still not inbox-scoped.
    func testNoLabelFeedIsTheInboxFeed() {
        for path in [
            "/mail/feed/atom/%5Esmartlabel_personal",
            "/mail/feed/atom/%5Esq_ig_i_personal",
            "/mail/feed/atom/unread",
            "/mail/feed/atom/%5Eu",
            "/mail/u/0/feed/atom/%5Esmartlabel_personal"
        ] {
            XCTAssertFalse(UnreadPoller.servesTheInboxFeed(host: "mail.google.com", path: path), path)
        }
    }

    func testAnotherHostIsNeverTheInboxFeed() {
        XCTAssertFalse(UnreadPoller.servesTheInboxFeed(host: "accounts.google.com", path: "/mail/feed/atom"))
        XCTAssertFalse(UnreadPoller.servesTheInboxFeed(host: "mail.google.com.evil.example", path: "/mail/feed/atom"))
        XCTAssertFalse(UnreadPoller.servesTheInboxFeed(host: "", path: "/mail/feed/atom"))
    }

    func testAnotherPathIsNeverTheInboxFeed() {
        for path in ["/mail/u/0/", "/mail/feed", "/feed/atom", "/mail/u/x/feed/atom", "/mail/u//feed/atom", ""] {
            XCTAssertFalse(UnreadPoller.servesTheInboxFeed(host: "mail.google.com", path: path), path)
        }
    }
}

/// Every response shape the poller now handles, against synthetic bodies.
///
/// The invariant under test, in one sentence: an answer either carries a count
/// this app can stand behind or it carries `nil`, and `nil` is never rendered
/// as a zero. v1.1.0 had one path — parse, then `?? 0` — so "Gmail refused this
/// feed" and "your inbox is empty" were the same number on the tab.
final class UnreadCheckAnswerTests: XCTestCase {
    private let inbox = UnreadPoller.feedPath

    private func feed(_ count: Int, title: String = "Gmail - Inbox for someone@gmail.com") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed version="0.3" xmlns="http://purl.org/atom/ns#">
          <title>\(title)</title>
          <fullcount>\(count)</fullcount>
        </feed>
        """
    }

    private func payload(
        ok: Bool,
        feed: String = "",
        status: Int,
        type: String,
        host: String = "mail.google.com",
        path: String? = nil
    ) -> [String: Any] {
        [
            "ok": ok, "feed": feed, "status": status, "type": type,
            "reached": true, "host": host, "path": path ?? UnreadPoller.feedPath
        ]
    }

    private func answer(_ payload: [String: Any]?) -> UnreadFeedAnswer {
        UnreadCheck.answer(from: payload, requestedPath: inbox)
    }

    // MARK: - The answers that carry a number

    func testTheInboxFeedYieldsItsCount() {
        let result = answer(payload(ok: true, feed: feed(2), status: 200, type: "basic"))
        XCTAssertEqual(result.outcome, .ok)
        XCTAssertEqual(result.count, 2)
    }

    /// A real zero stays a zero, and stays distinguishable from every failure
    /// below — which is the whole point of the split.
    func testAnEmptyInboxIsADefiniteZero() {
        let result = answer(payload(ok: true, feed: feed(0), status: 200, type: "basic"))
        XCTAssertEqual(result.outcome, .ok)
        XCTAssertEqual(result.count, 0)
    }

    /// The one 4xx that is a real zero: Google saying the session is gone, from
    /// its own origin.
    func testAnAuthFailureIsADefiniteZero() {
        for status in [401, 403] {
            let result = answer(payload(ok: true, status: status, type: "basic"))
            XCTAssertEqual(result.outcome, .signedOut, "\(status)")
            XCTAssertEqual(result.count, 0, "\(status)")
        }
    }

    /// The multi-login redirect: same inbox, different profile prefix.
    func testAFollowedRedirectToTheProfileFeedIsStillTheInbox() {
        let result = answer(payload(
            ok: true, feed: feed(9), status: 200, type: "redirect-followed",
            path: "/mail/u/1/feed/atom"
        ))
        XCTAssertEqual(result.outcome, .ok)
        XCTAssertEqual(result.count, 9)
    }

    // MARK: - The answers that carry no number

    /// The fixture that explains the screenshot. ~3,480 unread across archived
    /// labels, 2 in the inbox, and a body that parses perfectly — the number is
    /// real, it just counts another set. Even handed to the app by a redirect
    /// it is refused rather than shown as the inbox.
    func testALabelFeedBodyIsNeverCountedAsTheInbox() {
        let result = answer(payload(
            ok: true, feed: feed(3480, title: "Gmail - ^smartlabel_personal"),
            status: 200, type: "redirect-followed",
            path: "/mail/feed/atom/%5Esmartlabel_personal"
        ))
        XCTAssertEqual(result.outcome, .wrongFeed)
        XCTAssertNil(result.count)
        // And the line says where it came from, so it is diagnosable rather
        // than merely suppressed.
        XCTAssertTrue(result.text.contains("/mail/feed/atom/%5Esmartlabel_personal"))
    }

    /// The silent-zero hole. A 404 used to arrive as `feed: ''`, parse to `nil`
    /// and land as a confident 0, so "this feed does not exist" was
    /// indistinguishable from "nothing unread".
    func testANonAuthFourHundredIsRefusedRatherThanZero() {
        for status in [400, 404, 410, 429] {
            let result = answer(payload(ok: status < 500, status: status, type: "basic"))
            XCTAssertNotEqual(result.outcome, .ok, "\(status)")
            XCTAssertNil(result.count, "\(status)")
        }
        XCTAssertEqual(answer(payload(ok: true, status: 404, type: "basic")).outcome, .refused)
    }

    /// A 200 that is not a feed — a sign-in page, an error interstitial.
    func testATwoHundredWithNoCountInItIsNotUnderstood() {
        let html = "<!DOCTYPE html><html><body>Sign in to continue to Gmail</body></html>"
        let result = answer(payload(ok: true, feed: html, status: 200, type: "basic"))
        XCTAssertEqual(result.outcome, .notUnderstood)
        XCTAssertNil(result.count)
    }

    func testAServerErrorIsNoAnswer() {
        let result = answer(payload(ok: false, status: 503, type: "basic"))
        XCTAssertEqual(result.outcome, .noAnswer)
        XCTAssertNil(result.count)
    }

    func testAThrownOrAbortedFetchIsNoAnswer() {
        XCTAssertEqual(answer(nil).outcome, .noAnswer)
        XCTAssertNil(answer(nil).count)
        let thrown = answer(payload(ok: false, status: -1, type: "error", host: "", path: ""))
        XCTAssertEqual(thrown.outcome, .noAnswer)
        XCTAssertNil(thrown.count)
    }

    func testAnUnfollowableRedirectIsNoAnswer() {
        let result = answer(payload(ok: false, status: 0, type: "opaqueredirect", host: "", path: ""))
        XCTAssertEqual(result.outcome, .noAnswer)
        XCTAssertNil(result.count)
    }

    func testAPageThatIsNotGmailIsNoAnswer() {
        let result = answer([
            "ok": true, "feed": "", "status": -1, "type": "not-gmail",
            "reached": false, "host": "", "path": ""
        ])
        XCTAssertEqual(result.outcome, .notMail)
        XCTAssertNil(result.count)
    }

    /// The rule, stated once over every outcome: only `ok` and `signedOut` may
    /// produce a number, and nothing else may produce a zero.
    func testOnlyAnAnsweredCountIsEverANumber() {
        let shapes: [(UnreadOutcome, [String: Any]?)] = [
            (.ok, payload(ok: true, feed: feed(5), status: 200, type: "basic")),
            (.signedOut, payload(ok: true, status: 401, type: "basic")),
            (.refused, payload(ok: true, status: 404, type: "basic")),
            (.notUnderstood, payload(ok: true, feed: "<html></html>", status: 200, type: "basic")),
            (.wrongFeed, payload(
                ok: true, feed: feed(3480), status: 200, type: "redirect-followed",
                path: "/mail/feed/atom/unread"
            )),
            (.noAnswer, payload(ok: false, status: 500, type: "basic")),
            (.notMail, ["ok": true, "feed": "", "status": -1, "type": "not-gmail", "reached": false]),
            (.noAnswer, nil)
        ]
        for (expected, shape) in shapes {
            let result = answer(shape)
            XCTAssertEqual(result.outcome, expected, "\(expected)")
            switch expected {
            case .ok, .signedOut:
                XCTAssertNotNil(result.count, "\(expected)")
            default:
                XCTAssertNil(result.count, "\(expected)")
            }
        }
    }

    /// The poller's own two answers, settled without asking Gmail anything, so
    /// the diagnostic covers them rather than reading "not checked yet" for an
    /// account that is plainly signed out.
    func testTheOffFeedAnswersKeepTheSameContract() {
        XCTAssertEqual(UnreadPoller.signedOutOnThePage.outcome, .signedOut)
        XCTAssertEqual(UnreadPoller.signedOutOnThePage.count, 0)
        XCTAssertEqual(UnreadPoller.notOnMail.outcome, .notMail)
        XCTAssertNil(UnreadPoller.notOnMail.count)
    }
}

/// The Settings ▸ Accounts diagnostic: what the last check requested, what it
/// got back, and the number derived — counts and shapes only.
///
/// It exists because the regression was unfalsifiable from the outside. The tab
/// said `999+` and nothing on screen said which URL that came from.
final class UnreadCheckReportTests: XCTestCase {
    private func report(_ lines: [UnreadCheckReport.Line], checked: Bool = true) -> UnreadCheckReport {
        UnreadCheckReport(
            requestedPath: UnreadPoller.feedPath,
            checkedAt: checked ? Date(timeIntervalSince1970: 0) : nil,
            lines: lines
        )
    }

    private func line(_ name: String, _ answer: UnreadFeedAnswer?) -> UnreadCheckReport.Line {
        UnreadCheckReport.Line(name: name, answer: answer)
    }

    func testItNamesTheFeedItAskedForAndTheNumberItDerived() {
        let text = report([
            line("Personal", UnreadFeedAnswer(
                outcome: .ok, count: 248, status: 200, type: "basic", servedPath: UnreadPoller.feedPath
            )),
            line("Talkable", UnreadFeedAnswer(
                outcome: .ok, count: 2, status: 200, type: "basic", servedPath: UnreadPoller.feedPath
            ))
        ]).text

        XCTAssertTrue(text.contains("/mail/feed/atom"))
        XCTAssertTrue(text.contains("Personal — HTTP 200 basic, inbox feed — 248 unread"))
        XCTAssertTrue(text.contains("Talkable — HTTP 200 basic, inbox feed — 2 unread"))
    }

    func testNothingCheckedAndNoMailAccountsReadDifferently() {
        XCTAssertEqual(report([], checked: true).text, "No account has Mail switched on.")
        XCTAssertEqual(report([line("Personal", nil)], checked: false).text, "Not checked yet.")
        XCTAssertTrue(report([line("Personal", nil)]).text.contains("Personal — not checked yet"))
    }

    /// Only the three outcomes that mean the count cannot be read at all turn
    /// the line red. A no-answer and a tab that is not on Gmail are ordinary.
    func testOnlyAnUnreadableSourceCountsAsBroken() {
        func broken(_ outcome: UnreadOutcome) -> Bool {
            report([line("A", UnreadFeedAnswer(outcome: outcome, count: nil, status: 200, type: "basic"))])
                .isBroken
        }
        XCTAssertTrue(broken(.refused))
        XCTAssertTrue(broken(.notUnderstood))
        XCTAssertTrue(broken(.wrongFeed))
        XCTAssertFalse(broken(.ok))
        XCTAssertFalse(broken(.signedOut))
        XCTAssertFalse(broken(.noAnswer))
        XCTAssertFalse(broken(.notMail))
        XCTAssertFalse(report([line("A", nil)]).isBroken)
    }

    /// Every line is a status, a shape and a number. Nothing that came out of a
    /// message may reach this string — the feed body is never carried past
    /// `UnreadCheck.answer`.
    func testALineCarriesNoPartOfTheFeedBody() {
        let body = "<feed><title>Gmail - Inbox</title><entry><title>Payroll</title></entry>"
            + "<fullcount>3</fullcount></feed>"
        let answer = UnreadCheck.answer(
            from: [
                "ok": true, "feed": body, "status": 200, "type": "basic",
                "reached": true, "host": "mail.google.com", "path": UnreadPoller.feedPath
            ],
            requestedPath: UnreadPoller.feedPath
        )
        let text = report([line("Personal", answer)]).text
        XCTAssertTrue(text.contains("3 unread"))
        XCTAssertFalse(text.contains("Payroll"))
        XCTAssertFalse(text.contains("<"))
    }
}
