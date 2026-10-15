import XCTest
@testable import MailSpace

final class NotificationContentTests: XCTestCase {
    func testTitleFallsBackToTheAccountName() {
        XCTAssertEqual(NotificationContent.title(payloadTitle: "", accountName: "Work"), "Work")
        XCTAssertEqual(NotificationContent.title(payloadTitle: "2 new", accountName: "Work"), "2 new")
    }

    func testSameTagInOneAccountReplacesItself() {
        let account = UUID()

        XCTAssertEqual(
            NotificationContent.identifier(tag: "thread-7", accountId: account),
            NotificationContent.identifier(tag: "thread-7", accountId: account)
        )
    }

    /// Web `tag` is replace-not-stack, so an unscoped tag would let one
    /// account's notification silently replace another's.
    func testSameTagInDifferentAccountsStaysSeparate() {
        XCTAssertNotEqual(
            NotificationContent.identifier(tag: "thread-7", accountId: UUID()),
            NotificationContent.identifier(tag: "thread-7", accountId: UUID())
        )
    }

    func testUntaggedNotificationsNeverReplaceEachOther() {
        let account = UUID()

        XCTAssertNotEqual(
            NotificationContent.identifier(tag: "", accountId: account),
            NotificationContent.identifier(tag: "", accountId: account)
        )
    }

    // MARK: - Copy Code

    func testAMailCodeGetsTheCopyCodeCategory() {
        let action = NotificationContent.action(view: .mail, title: "Acme", body: "Your verification code is 482913")

        XCTAssertEqual(action?.category, .oneTimeCode)
        XCTAssertEqual(action?.userInfo, [NotificationCategory.InfoKey.code: "482913"])
    }

    /// R5: Calendar never gets the action, whatever its text says (AE3).
    func testCalendarNeverGetsCopyCode() {
        XCTAssertNil(NotificationContent.action(view: .calendar, title: "Door", body: "PIN 4821 for the door"))
    }

    /// Two codes are no code (AE2).
    func testAnAmbiguousMailGetsNothing() {
        XCTAssertNil(NotificationContent.action(
            view: .mail, title: "Acme", body: "Your code is 123456 or use backup code 654321"
        ))
    }

    func testTheSessionHealthNotificationGetsNothing() {
        XCTAssertNil(NotificationContent.action(
            view: .mail,
            title: "Work — Mail is signed out",
            body: "MailSpace stopped receiving mail for this account. Click to sign in."
        ))
    }

    func testACodeInTheTitleAloneCounts() {
        let action = NotificationContent.action(view: .mail, title: "Your code is 482913", body: "")

        XCTAssertEqual(action?.category, .oneTimeCode)
        XCTAssertEqual(action?.userInfo, [NotificationCategory.InfoKey.code: "482913"])
    }

    // MARK: - Join

    /// AE9.
    func testACalendarReminderWithAMeetingLinkGetsJoin() {
        let url = "https://meet.google.com/abc-defg-hij"
        let action = NotificationContent.action(view: .calendar, title: "Weekly sync", body: "10:00", meetingURL: url)

        XCTAssertEqual(action?.category, .meetingJoin)
        XCTAssertEqual(action?.userInfo, [NotificationCategory.InfoKey.meetingURL: url])
    }

    /// AE12: no link, no button; the reminder is posted as before.
    func testACalendarReminderWithoutALinkGetsNothing() {
        XCTAssertNil(NotificationContent.action(view: .calendar, title: "Weekly sync", body: "10:00"))
    }

    /// AE11: the content decision applies the allow-list again.
    func testACalendarReminderWithAForeignLinkGetsNothing() {
        XCTAssertNil(NotificationContent.action(
            view: .calendar, title: "Weekly sync", body: "", meetingURL: "https://meet.google.com.evil.example/x"
        ))
    }

    /// R33: Mail is exactly as stream 1 left it, with or without a link.
    func testMailIgnoresAMeetingLink() {
        let action = NotificationContent.action(
            view: .mail, title: "Acme", body: "Your verification code is 482913",
            meetingURL: "https://meet.google.com/abc-defg-hij"
        )
        XCTAssertEqual(action?.category, .oneTimeCode)
        XCTAssertNil(NotificationContent.action(
            view: .mail, title: "Lunch", body: "See you", meetingURL: "https://meet.google.com/abc-defg-hij"
        ))
    }
}
