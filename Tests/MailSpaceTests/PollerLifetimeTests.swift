import WebKit
import XCTest
@testable import MailSpace

/// A webview that reports a URL without loading anything.
///
/// The pollers gate on where the tab is — Gmail for the unread feed, Google
/// Calendar for the agenda — and these tests are about what happens when the
/// *answer* never arrives. Loading a real page to satisfy the gate would put a
/// request to Google in `swift test`; overriding the one property the gate reads
/// keeps the whole thing offline.
private final class StubWebView: WKWebView {
    /// Settable so a test can walk the tab through sign-in and back.
    var stub: URL?

    init(_ string: String) {
        stub = URL(string: string)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var url: URL? { stub }
}

/// An in-flight poll can never outlive the webview it was asked of.
///
/// The freeze: both pollers key "a poll is already running for this account" on
/// the account id, and cleared it only from the JavaScript completion handler.
/// Nothing else could. So when a callback went missing — and the recycler
/// replacing a webview mid-poll is the everyday way that happens, twice a day
/// per account, by design — the id stayed set and `guard !inFlight.contains`
/// skipped that account on every later cycle. Its Dock badge and its calendar
/// countdown then sat frozen on whatever they last said, with nothing on screen
/// to say so, until the app was relaunched.
///
/// Two endings now exist besides the answer, and each is tested here: a deadline
/// and the discard the recycler already announces.
final class UnreadPollerLifetimeTests: XCTestCase {
    private let gmail = "https://mail.google.com/mail/u/0/"

    /// The deadline. Nothing answers, ever, and the account is polled again on
    /// the next cycle regardless.
    func testAPollThatIsNeverAnsweredTimesOutInsteadOfFreezingTheAccount() {
        let poller = UnreadPoller(interval: 3600, timeout: 0.2)
        let accountId = UUID()
        let webView = StubWebView(gmail)
        poller.mailWebViews = { [(accountId: accountId, webView: webView)] }

        var asked = 0
        // The page is asked and simply never answers — a webview whose content
        // process went away mid-poll, and the shape a missing callback has.
        poller.ask = { _, _ in asked += 1 }

        let firstReturned = expectation(description: "the first poll comes back")
        poller.refresh(accountId: accountId) { firstReturned.fulfill() }
        wait(for: [firstReturned], timeout: 2)
        XCTAssertEqual(asked, 1)

        // The whole point: a second cycle asks again. Before the deadline
        // existed this call did nothing at all, for the life of the process.
        let secondReturned = expectation(description: "the account is polled again")
        poller.refresh(accountId: accountId) { secondReturned.fulfill() }
        wait(for: [secondReturned], timeout: 2)
        XCTAssertEqual(asked, 2)
    }

    /// A timed-out poll writes no count. Silence is not a zero — that
    /// distinction is the whole of `UnreadOutcome`.
    func testATimedOutPollKeepsThePreviousCountRatherThanZeroingIt() {
        let poller = UnreadPoller(interval: 3600, timeout: 0.2)
        let accountId = UUID()
        let webView = StubWebView(gmail)
        poller.mailWebViews = { [(accountId: accountId, webView: webView)] }
        poller.ask = { _, _ in }

        let returned = expectation(description: "the poll comes back")
        poller.refresh(accountId: accountId) { returned.fulfill() }
        wait(for: [returned], timeout: 2)

        XCTAssertNil(poller.count(for: accountId))
        XCTAssertEqual(poller.lastCheck(for: accountId), UnreadPoller.notAnswering)
    }

    /// The discard. The recycler already says when it throws a webview away;
    /// the poll asked of it dies there rather than half a minute later.
    func testAPollDiesWithTheWebViewItWasAskedOf() {
        // A deadline far longer than the test, so only the discard can free it.
        let poller = UnreadPoller(interval: 3600, timeout: 600)
        let accountId = UUID()
        var webView = StubWebView(gmail)
        poller.mailWebViews = { [(accountId: accountId, webView: webView)] }

        var asked = 0
        poller.ask = { _, _ in asked += 1 }

        let firstReturned = expectation(description: "the discarded poll comes back")
        poller.refresh(accountId: accountId) { firstReturned.fulfill() }
        XCTAssertEqual(asked, 1)

        // Exactly what `AccountSession.recycle` does: the old webview is torn
        // down and a fresh one takes the tab.
        let discarded = webView
        webView = StubWebView(gmail)
        poller.webViewWasDiscarded(discarded)
        // The caller waiting on that poll is let go rather than left hanging.
        wait(for: [firstReturned], timeout: 1)

        // And the slot is free: the rebuilt tab is polled on the next cycle
        // instead of being skipped for the life of the process.
        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked, 2)
    }

    /// Discarding some other account's webview must not cancel this one's poll.
    func testAnUnrelatedDiscardLeavesAPollAlone() {
        let poller = UnreadPoller(interval: 3600, timeout: 600)
        let accountId = UUID()
        let webView = StubWebView(gmail)
        poller.mailWebViews = { [(accountId: accountId, webView: webView)] }

        var asked = 0
        var answer: ((Result<Any, any Error>) -> Void)?
        poller.ask = { _, reply in
            asked += 1
            answer = reply
        }

        poller.refresh(accountId: accountId)
        poller.webViewWasDiscarded(StubWebView(gmail))
        // Still in flight, so a second cycle does not stack on it.
        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked, 1)

        // And the real answer is still the one that settles it.
        answer?(.success([:] as [String: Any]))
        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked, 2)
    }
}

/// What a poll on every finished Gmail load relies on: coming back from a
/// sign-in or SSO page, the next poll on Gmail asks the page once and writes
/// the fresh count, and a poll already running is not doubled.
final class UnreadPollerReloginTests: XCTestCase {
    private let inbox = "https://mail.google.com/mail/u/0/#inbox"

    private func answer(_ count: Int) -> [String: Any] {
        let feed = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed version="0.3" xmlns="http://purl.org/atom/ns#">
          <title>Gmail - Inbox for someone@example.com</title>
          <fullcount>\(count)</fullcount>
        </feed>
        """
        return [
            "ok": true, "feed": feed, "status": 200, "type": "basic",
            "reached": true, "host": "mail.google.com", "path": UnreadPoller.feedPath
        ]
    }

    /// The poller, one account on `webView`, and a page that answers `next`.
    private func makePoller(
        on webView: StubWebView, answering next: @escaping () -> Int
    ) -> (UnreadPoller, UUID, () -> Int) {
        let poller = UnreadPoller(interval: 3600, timeout: 600)
        let accountId = UUID()
        poller.mailWebViews = { [(accountId: accountId, webView: webView)] }
        var asked = 0
        poller.ask = { [answer] _, reply in
            asked += 1
            reply(.success(answer(next())))
        }
        return (poller, accountId, { asked })
    }

    func testSigningBackInWritesTheFreshCount() {
        let webView = StubWebView(inbox)
        var unread = 7
        let (poller, accountId, asked) = makePoller(on: webView) { unread }
        poller.refresh(accountId: accountId)
        XCTAssertEqual(poller.count(for: accountId), 7)

        webView.stub = URL(string: "https://accounts.google.com/v3/signin/identifier")
        poller.refresh(accountId: accountId)
        XCTAssertEqual(poller.count(for: accountId), 0)

        unread = 3
        webView.stub = URL(string: inbox)
        let before = asked()
        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked() - before, 1)
        XCTAssertEqual(poller.count(for: accountId), 3)
    }

    func testComingBackFromSSOReplacesTheKeptCount() {
        let webView = StubWebView(inbox)
        var unread = 7
        let (poller, accountId, asked) = makePoller(on: webView) { unread }
        poller.refresh(accountId: accountId)

        webView.stub = URL(string: "https://idp.customer.example/login")
        poller.refresh(accountId: accountId)
        poller.refresh(accountId: accountId)
        XCTAssertEqual(poller.count(for: accountId), 7)

        unread = 2
        webView.stub = URL(string: inbox)
        let before = asked()
        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked() - before, 1)
        XCTAssertEqual(poller.count(for: accountId), 2)
    }

    func testAFinishWhileAPollIsRunningAsksOnce() {
        let poller = UnreadPoller(interval: 3600, timeout: 600)
        let accountId = UUID()
        let webView = StubWebView(inbox)
        poller.mailWebViews = { [(accountId: accountId, webView: webView)] }
        var asked = 0
        poller.ask = { _, _ in asked += 1 }

        poller.refresh(accountId: accountId)
        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked, 1)
    }
}

/// The calendar twin, freezing the countdown rather than the badge.
final class NextEventPollerLifetimeTests: XCTestCase {
    private let calendar = "https://calendar.google.com/calendar/u/0/r"

    private func makeSettings() -> AppSettings {
        let suite = "poller-lifetime-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("no defaults")
            return AppSettings()
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        AppSettings.registerDefaults(in: defaults)
        return AppSettings(defaults: defaults)
    }

    func testAFetchThatIsNeverAnsweredTimesOutInsteadOfFreezingTheCountdown() {
        let poller = NextEventPoller(
            settings: makeSettings(), fetchInterval: 3600, fetchTimeout: 0.2
        )
        let accountId = UUID()
        let webView = StubWebView(calendar)
        poller.calendarWebViews = { [(accountId: accountId, calendarId: "a@example.com", webView: webView)] }

        var asked = 0
        poller.ask = { _, _, _ in asked += 1 }

        let firstReturned = expectation(description: "the first fetch comes back")
        poller.refresh(accountId: accountId) { firstReturned.fulfill() }
        wait(for: [firstReturned], timeout: 2)
        XCTAssertEqual(asked, 1)

        let secondReturned = expectation(description: "the account is fetched again")
        poller.refresh(accountId: accountId) { secondReturned.fulfill() }
        wait(for: [secondReturned], timeout: 2)
        XCTAssertEqual(asked, 2)

        // No answer means no countdown, never a wrong one.
        XCTAssertNil(poller.secondsUntilNextEvent(for: accountId))
    }

    func testAFetchDiesWithTheWebViewItWasAskedOf() {
        let poller = NextEventPoller(
            settings: makeSettings(), fetchInterval: 3600, fetchTimeout: 600
        )
        let accountId = UUID()
        var webView = StubWebView(calendar)
        poller.calendarWebViews = { [(accountId: accountId, calendarId: "a@example.com", webView: webView)] }

        var asked = 0
        poller.ask = { _, _, _ in asked += 1 }

        let firstReturned = expectation(description: "the discarded fetch comes back")
        poller.refresh(accountId: accountId) { firstReturned.fulfill() }
        XCTAssertEqual(asked, 1)

        let discarded = webView
        webView = StubWebView(calendar)
        poller.webViewWasDiscarded(discarded)
        wait(for: [firstReturned], timeout: 1)

        poller.refresh(accountId: accountId)
        XCTAssertEqual(asked, 2)
    }
}
