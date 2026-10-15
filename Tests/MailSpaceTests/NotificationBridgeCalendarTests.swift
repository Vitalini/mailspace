import UserNotifications
import WebKit
import XCTest
@testable import MailSpace

/// The Calendar branch of the bridge, end to end through its seams: the page
/// script is answered by hand through `askMeetingLink`, the deadline is fired
/// by hand, and a stand-in for Notification Center records every request.
final class NotificationBridgeCalendarTests: XCTestCase {
    private let meet = "https://meet.google.com/abc-defg-hij"
    private let title = "Weekly sync with the placeholder team"
    private let body = "10:00 - 10:30"

    private var logged: [String] = []
    private var previousSink: ((String) -> Void)!

    override func setUp() {
        super.setUp()
        logged = []
        previousSink = Log.sink
        Log.sink = { [weak self] in self?.logged.append($0) }
    }

    override func tearDown() {
        Log.sink = previousSink
        super.tearDown()
    }

    private final class Harness {
        let bridge = NotificationBridge()
        var requests: [UNNotificationRequest] = []
        var askedTitles: [String] = []
        var answerScript: ((Result<Any, any Error>) -> Void)?
        var fireDeadline: (() -> Void)?

        init() {
            bridge.addRequest = { [unowned self] in self.requests.append($0) }
            bridge.askMeetingLink = { [unowned self] _, title, answer in
                self.askedTitles.append(title)
                self.answerScript = answer
            }
            bridge.scheduleDeadline = { [unowned self] _, fire in self.fireDeadline = fire }
        }
    }

    private func deliver(_ harness: Harness, payload extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "title": title, "body": body, "tag": "placeholder-tag",
            "optionKeys": ["body", "tag", "data"], "dataKeys": ["eventId"], "actionCount": 0
        ]
        payload.merge(extra) { _, new in new }
        harness.bridge.deliver(payload: payload, from: WKWebView(), account: Account(name: "Work"), view: .calendar)
    }

    private var calendarLines: [String] {
        logged.filter { $0.hasPrefix("calendar notification ") }
    }

    /// The R32 line carries names and counts only.
    private func assertOneCleanLine(join: String, links: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(calendarLines.count, 1, file: file, line: line)
        let written = calendarLines.first ?? ""
        XCTAssertTrue(written.hasSuffix("join=\(join) links=\(links)"), written, file: file, line: line)
        for secret in [title, body, "placeholder-tag", meet, "meet.google.com", "Weekly"] {
            XCTAssertFalse(written.contains(secret), secret, file: file, line: line)
        }
    }

    func testALinkFromThePageGivesTheJoinCategory() throws {
        let harness = Harness()
        deliver(harness)

        XCTAssertEqual(harness.askedTitles, [title])
        XCTAssertTrue(harness.requests.isEmpty, "nothing is posted before the page answers")
        harness.answerScript?(.success(["ok": true, "url": meet, "links": 1, "fetched": false]))
        harness.fireDeadline?()

        XCTAssertEqual(harness.requests.count, 1)
        let content = try XCTUnwrap(harness.requests.first?.content)
        XCTAssertEqual(content.categoryIdentifier, NotificationCategory.meetingJoin.identifier)
        XCTAssertEqual(content.userInfo[NotificationCategory.InfoKey.meetingURL] as? String, meet)
        XCTAssertEqual(content.title, title)
        assertOneCleanLine(join: "page", links: 1)
    }

    func testALinkFromTheFetchedPageIsLoggedAsFetch() {
        let harness = Harness()
        deliver(harness)

        harness.answerScript?(.success(["ok": true, "url": meet, "links": 1, "fetched": true]))

        XCTAssertEqual(harness.requests.first?.content.categoryIdentifier, NotificationCategory.meetingJoin.identifier)
        assertOneCleanLine(join: "fetch", links: 1)
    }

    /// AE12: no link, no category, one post.
    func testNoLinkPostsOnceWithoutACategory() {
        let harness = Harness()
        deliver(harness)

        harness.answerScript?(.success(["ok": true, "url": NSNull(), "links": 0, "fetched": false]))
        harness.fireDeadline?()

        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(harness.requests.first?.content.categoryIdentifier, "")
        XCTAssertNil(harness.requests.first?.content.userInfo[NotificationCategory.InfoKey.meetingURL])
        assertOneCleanLine(join: "none", links: 0)
    }

    func testAFailedScriptPostsOnceAsAnError() {
        let harness = Harness()
        deliver(harness)

        harness.answerScript?(.failure(NSError(domain: "WKErrorDomain", code: 4)))
        harness.fireDeadline?()

        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(harness.requests.first?.content.categoryIdentifier, "")
        assertOneCleanLine(join: "error", links: 0)
    }

    func testTheDeadlinePostsOnceAndALateAnswerIsIgnored() {
        let harness = Harness()
        deliver(harness)

        harness.fireDeadline?()
        harness.answerScript?(.success(["ok": true, "url": meet, "links": 1, "fetched": false]))

        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(harness.requests.first?.content.categoryIdentifier, "")
        assertOneCleanLine(join: "timeout", links: 0)
    }

    /// The reminder's own `data` link skips the page entirely.
    func testADataLinkNeedsNoPage() {
        let harness = Harness()
        deliver(harness, payload: ["dataLink": meet])

        XCTAssertTrue(harness.askedTitles.isEmpty)
        XCTAssertNil(harness.fireDeadline)
        XCTAssertEqual(harness.requests.first?.content.categoryIdentifier, NotificationCategory.meetingJoin.identifier)
        assertOneCleanLine(join: "data", links: 0)
    }

    /// Mail never waits and never asks the page.
    func testMailPostsAtOnce() {
        let harness = Harness()
        harness.bridge.deliver(
            payload: ["title": "Lunch", "body": "See you"], from: WKWebView(), account: Account(name: "Work"), view: .mail
        )

        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertTrue(harness.askedTitles.isEmpty)
        XCTAssertTrue(calendarLines.isEmpty)
    }
}
