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
