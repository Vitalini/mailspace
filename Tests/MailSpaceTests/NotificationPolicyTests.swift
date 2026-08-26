import XCTest
@testable import MailSpace

/// Whether a web notification becomes a native one (A2, A3) and how it arrives
/// (B1).
///
/// The rule sits next to `NotificationOrigin.isTrusted`, never inside it: one
/// is a preference, the other is the boundary that stops a third-party frame
/// putting the user's account name on a macOS banner.
final class NotificationPolicyTests: XCTestCase {
    private func account(mail: Bool = true, calendar: Bool = true, notifyMail: Bool = true, notifyCalendar: Bool = true) -> Account {
        Account(
            name: "Work",
            mailEnabled: mail,
            calendarEnabled: calendar,
            notifyMail: notifyMail,
            notifyCalendar: notifyCalendar
        )
    }

    func testBothOnPostsBoth() {
        let account = account()
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    func testMutingMailLeavesCalendarAlone() {
        let account = account(notifyMail: false)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    func testMutingCalendarLeavesMailAlone() {
        let account = account(notifyCalendar: false)
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    func testBothMutedPostsNothing() {
        let account = account(notifyMail: false, notifyCalendar: false)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    /// A service the account does not offer has nothing to alert about,
    /// whatever the flag says.
    func testADisabledServiceNeverPosts() {
        let mailOnly = account(mail: true, calendar: false, notifyCalendar: true)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: mailOnly, view: .calendar))

        let calendarOnly = account(mail: false, calendar: true, notifyMail: true)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: calendarOnly, view: .mail))
    }

    // MARK: - B1

    func testTheTabOnScreenGetsNoBanner() {
        let tab = TabRef(accountId: UUID(), view: .mail)
        XCTAssertTrue(NotificationPolicy.suppressBanner(appIsActive: true, notification: tab, selection: tab))
    }

    func testAnotherTabStillBanners() {
        let accountId = UUID()
        let mail = TabRef(accountId: accountId, view: .mail)
        let calendar = TabRef(accountId: accountId, view: .calendar)
        let other = TabRef(accountId: UUID(), view: .mail)

        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: mail, selection: calendar))
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: other, selection: mail))
    }

    /// The point of a banner is to reach someone who is looking elsewhere.
    func testABackgroundedAppAlwaysBanners() {
        let tab = TabRef(accountId: UUID(), view: .mail)
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: false, notification: tab, selection: tab))
    }

    func testAnUnattributableNotificationAlwaysBanners() {
        let tab = TabRef(accountId: UUID(), view: .mail)
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: nil, selection: tab))
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: tab, selection: nil))
    }
}
