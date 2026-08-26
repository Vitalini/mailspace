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
}
