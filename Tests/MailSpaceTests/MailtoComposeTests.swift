import XCTest
@testable import MailSpace

/// A `mailto:` link has to reach Gmail's compose window intact — subject,
/// body and multiple recipients included.
final class MailtoComposeTests: XCTestCase {
    private func compose(_ mailto: String) throws -> URL {
        let url = try XCTUnwrap(URL(string: mailto))
        return try XCTUnwrap(AppDelegate.composeURL(for: url))
    }

    func testWrapsThePayloadForGmail() throws {
        let composed = try compose("mailto:a@b.com")
        XCTAssertEqual(composed.host, "mail.google.com")
        XCTAssertTrue(composed.absoluteString.hasPrefix("https://mail.google.com/mail/u/0/?extsrc=mailto&url="))
    }

    func testSubjectAndBodySurviveEncoding() throws {
        let original = "mailto:a@b.com?subject=Hi%20there&body=Line%20one"
        let composed = try compose(original)

        let encoded = try XCTUnwrap(composed.absoluteString.components(separatedBy: "&url=").last)
        XCTAssertEqual(encoded.removingPercentEncoding, original)
    }

    func testReservedCharactersAreEscapedNotPassedThrough() throws {
        let composed = try compose("mailto:a@b.com?subject=A&B")
        // The inner ampersand must not read as another Gmail parameter.
        XCTAssertEqual(composed.absoluteString.components(separatedBy: "&").count, 2)
    }

    func testMultipleRecipientsSurvive() throws {
        let original = "mailto:one@x.com,two@y.com?cc=three@z.com"
        let encoded = try XCTUnwrap(try compose(original).absoluteString.components(separatedBy: "&url=").last)
        XCTAssertEqual(encoded.removingPercentEncoding, original)
    }

    func testEmptyMailtoStillProducesACompose() throws {
        XCTAssertNoThrow(try compose("mailto:"))
    }
}

/// Which account a `mailto:` is composed in.
final class MailtoAccountTests: XCTestCase {
    private func account(_ name: String, mail: Bool) -> Account {
        Account(name: name, mailEnabled: mail, calendarEnabled: true)
    }

    func testTheSelectedAccountComposesWhenItHasMail() {
        let work = account("Work", mail: true)
        let personal = account("Personal", mail: true)

        XCTAssertEqual(
            AppDelegate.mailtoAccount(selected: personal.id, accounts: [work, personal]),
            personal.id
        )
    }

    /// The regression: `selected ?? firstMailEnabled` short-circuits on any
    /// non-nil selection, and one is always installed while an account exists.
    /// So a `mailto:` arriving with a Calendar-only account selected was
    /// dropped — the window just came to the front.
    func testACalendarOnlyAccountHandsOffToTheFirstMailAccount() {
        let family = account("Family", mail: false)
        let work = account("Work", mail: true)

        XCTAssertEqual(
            AppDelegate.mailtoAccount(selected: family.id, accounts: [family, work]),
            work.id
        )
    }

    func testAStaleSelectionFallsBackToTheFirstMailAccount() {
        let work = account("Work", mail: true)

        XCTAssertEqual(AppDelegate.mailtoAccount(selected: UUID(), accounts: [work]), work.id)
        XCTAssertEqual(AppDelegate.mailtoAccount(selected: nil, accounts: [work]), work.id)
    }

    func testNoMailAccountAnywhereMeansNoCompose() {
        let family = account("Family", mail: false)

        XCTAssertNil(AppDelegate.mailtoAccount(selected: family.id, accounts: [family]))
        XCTAssertNil(AppDelegate.mailtoAccount(selected: nil, accounts: []))
    }
}
