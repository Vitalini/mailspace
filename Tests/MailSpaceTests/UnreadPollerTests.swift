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
