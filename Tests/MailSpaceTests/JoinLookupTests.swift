import XCTest
@testable import MailSpace

/// The 3 s race between the page lookup and the deadline (KTD19, R29). The
/// lookup and the clock are both driven by hand.
final class JoinLookupTests: XCTestCase {
    private let meet = "https://meet.google.com/abc-defg-hij"

    /// Holds what `start` was handed, so a test can fire either side when it
    /// wants to.
    private final class Harness {
        var answerLookup: ((JoinLookup.Answer) -> Void)?
        var fireDeadline: (() -> Void)?
        var scheduledDelay: TimeInterval?
        var posted: [JoinLookup.Outcome] = []

        func start() {
            JoinLookup.start(
                lookup: { self.answerLookup = $0 },
                schedule: { delay, fire in
                    self.scheduledDelay = delay
                    self.fireDeadline = fire
                },
                post: { self.posted.append($0) }
            )
        }
    }

    /// The fetch fallback takes up to 1.4 s, so the page path gets 3 s.
    func testTheDeadlineIsThreeSeconds() {
        let harness = Harness()
        harness.start()
        XCTAssertEqual(harness.scheduledDelay, 3)
    }

    func testAnAnswerBeforeTheDeadlinePostsOnceWithTheURL() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(.match(MeetingLink.Match(url: meet, links: 1, fetched: false)))
        harness.fireDeadline?()

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: meet, source: .page, links: 1)])
    }

    func testNoAnswerPostsOnceWithoutAURLWhenTheDeadlineFires() {
        let harness = Harness()
        harness.start()
        XCTAssertTrue(harness.posted.isEmpty)

        harness.fireDeadline?()

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .timeout, links: 0)])
    }

    func testALateAnswerIsIgnored() {
        let harness = Harness()
        harness.start()

        harness.fireDeadline?()
        harness.answerLookup?(.match(MeetingLink.Match(url: meet, links: 1, fetched: false)))

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .timeout, links: 0)])
    }

    /// Review #7: a failed script is `error`, not `none`.
    func testAFailedScriptPostsAtOnceAsAnError() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(.failed)
        harness.fireDeadline?()

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .error, links: 0)])
    }

    /// Review #7: a released webview is `no-webview`, not `none`.
    func testAGoneWebViewPostsAtOnceAsNoWebView() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(.noWebView)

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .noWebView, links: 0)])
    }

    /// The bridge's allow-list is the authority, whatever the page said.
    func testAURLThatFailsTheAllowListIsNoURL() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(.match(MeetingLink.Match(url: "https://meet.google.com.evil.example/x", links: 1, fetched: false)))

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .none, links: 1)])
    }

    func testTheSourceAndLinkCountReachTheOutcome() {
        XCTAssertEqual(
            JoinLookup.outcome(for: .match(MeetingLink.Match(url: meet, links: 1, fetched: false))),
            JoinLookup.Outcome(url: meet, source: .page, links: 1)
        )
        XCTAssertEqual(
            JoinLookup.outcome(for: .match(MeetingLink.Match(url: meet, links: 1, fetched: true))),
            JoinLookup.Outcome(url: meet, source: .fetch, links: 1)
        )
        XCTAssertEqual(
            JoinLookup.outcome(for: .match(MeetingLink.Match(url: nil, links: 2, fetched: true))),
            JoinLookup.Outcome(url: nil, source: .none, links: 2)
        )
    }

    // MARK: - Before the lookup

    func testOneAllowListedDataLinkNeedsNoLookup() {
        XCTAssertEqual(
            JoinLookup.immediate(dataLink: meet),
            JoinLookup.Outcome(url: meet, source: .data, links: 0)
        )
    }

    func testADataLinkThatFailsTheAllowListFallsThroughToTheLookup() {
        XCTAssertNil(JoinLookup.immediate(dataLink: "https://zoom.us/webinar/1"))
        XCTAssertNil(JoinLookup.immediate(dataLink: nil))
    }

    // MARK: - The script's payload

    func testTheScriptPayloadBecomesAMatch() {
        let payload: [String: Any] = ["ok": true, "url": meet, "links": 1, "fetched": true]
        XCTAssertEqual(
            NotificationBridge.meetingAnswer(from: .success(payload)),
            .match(MeetingLink.Match(url: meet, links: 1, fetched: true))
        )
        XCTAssertEqual(
            NotificationBridge.meetingAnswer(from: .success(["ok": true, "url": NSNull(), "links": 0, "fetched": false])),
            .match(.nothing)
        )
    }

    func testAFailedScriptIsAFailure() {
        XCTAssertEqual(NotificationBridge.meetingAnswer(from: .success(["ok": false])), .failed)
        XCTAssertEqual(NotificationBridge.meetingAnswer(from: .success("not a payload")), .failed)
        XCTAssertEqual(NotificationBridge.meetingAnswer(from: .failure(NSError(domain: "WKErrorDomain", code: 4))), .failed)
    }
}
