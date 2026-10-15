import XCTest
@testable import MailSpace

/// The 1 s race between the page lookup and the deadline (KTD19, R29). The
/// lookup and the clock are both driven by hand.
final class JoinLookupTests: XCTestCase {
    private let meet = "https://meet.google.com/abc-defg-hij"

    /// Holds what `start` was handed, so a test can fire either side when it
    /// wants to.
    private final class Harness {
        var answerLookup: ((MeetingLink.Match?) -> Void)?
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

    func testTheDeadlineIsOneSecond() {
        let harness = Harness()
        harness.start()
        XCTAssertEqual(harness.scheduledDelay, 1)
    }

    func testAnAnswerBeforeTheDeadlinePostsOnceWithTheURL() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(MeetingLink.Match(url: meet, links: 1, fallback: false))
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
        harness.answerLookup?(MeetingLink.Match(url: meet, links: 1, fallback: false))

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .timeout, links: 0)])
    }

    func testANilAnswerPostsAtOnceWithoutAURL() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(nil)

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .none, links: 0)])
    }

    /// The bridge's allow-list is the authority, whatever the page said.
    func testAURLThatFailsTheAllowListIsNoURL() {
        let harness = Harness()
        harness.start()

        harness.answerLookup?(MeetingLink.Match(url: "https://meet.google.com.evil.example/x", links: 1, fallback: false))

        XCTAssertEqual(harness.posted, [JoinLookup.Outcome(url: nil, source: .none, links: 1)])
    }

    func testTheSourceAndLinkCountReachTheOutcome() {
        XCTAssertEqual(
            JoinLookup.outcome(for: MeetingLink.Match(url: meet, links: 1, fallback: true)),
            JoinLookup.Outcome(url: meet, source: .pageFallback, links: 1)
        )
        XCTAssertEqual(
            JoinLookup.outcome(for: MeetingLink.Match(url: nil, links: 2, fallback: false)),
            JoinLookup.Outcome(url: nil, source: .none, links: 2)
        )
    }

    // MARK: - Before the lookup

    func testOneAllowListedDataLinkNeedsNoLookup() {
        XCTAssertEqual(
            JoinLookup.immediate(dataLink: meet, hasWebView: true),
            JoinLookup.Outcome(url: meet, source: .data, links: 0)
        )
    }

    func testADataLinkThatFailsTheAllowListFallsThroughToTheLookup() {
        XCTAssertNil(JoinLookup.immediate(dataLink: "https://zoom.us/webinar/1", hasWebView: true))
        XCTAssertNil(JoinLookup.immediate(dataLink: nil, hasWebView: true))
    }

    func testNoWebViewPostsWithoutALookup() {
        XCTAssertEqual(
            JoinLookup.immediate(dataLink: nil, hasWebView: false),
            JoinLookup.Outcome(url: nil, source: .noWebView, links: 0)
        )
    }

    // MARK: - The script's payload

    func testTheScriptPayloadBecomesAMatch() {
        let payload: [String: Any] = ["ok": true, "url": meet, "links": 1, "fallback": false]
        XCTAssertEqual(
            NotificationBridge.meetingMatch(from: .success(payload)),
            MeetingLink.Match(url: meet, links: 1, fallback: false)
        )
        XCTAssertEqual(
            NotificationBridge.meetingMatch(from: .success(["ok": true, "url": NSNull(), "links": 0, "fallback": false])),
            MeetingLink.Match.nothing
        )
    }

    func testAFailedScriptIsNoMatch() {
        XCTAssertNil(NotificationBridge.meetingMatch(from: .success(["ok": false])))
        XCTAssertNil(NotificationBridge.meetingMatch(from: .failure(NSError(domain: "WKErrorDomain", code: 4))))
    }
}
