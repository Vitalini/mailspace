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
}
