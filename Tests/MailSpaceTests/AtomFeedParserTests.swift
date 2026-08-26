import XCTest
@testable import MailSpace

final class AtomFeedParserTests: XCTestCase {
    private func feed(fullcount: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed version="0.3" xmlns="http://purl.org/atom/ns#">
          <title>Gmail - Inbox for someone@gmail.com</title>
          <fullcount>\(fullcount)</fullcount>
          <link rel="alternate" href="https://mail.google.com/mail" type="text/html" />
          <entry><title>Hello</title></entry>
        </feed>
        """
    }

    func testReadsFullcount() {
        XCTAssertEqual(AtomFeedParser.unreadCount(from: feed(fullcount: "7")), 7)
    }

    func testZeroIsZeroNotNil() {
        XCTAssertEqual(AtomFeedParser.unreadCount(from: feed(fullcount: "0")), 0)
    }

    func testToleratesWhitespaceAroundTheValue() {
        XCTAssertEqual(AtomFeedParser.unreadCount(from: feed(fullcount: "\n  12\n  ")), 12)
    }

    func testLargeCountParses() {
        XCTAssertEqual(AtomFeedParser.unreadCount(from: feed(fullcount: "4921")), 4921)
    }

    func testMissingFullcountIsNil() {
        let withoutCount = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed><title>Gmail - Inbox</title></feed>
        """
        XCTAssertNil(AtomFeedParser.unreadCount(from: withoutCount))
    }

    func testLoginPageIsNil() {
        let html = "<!DOCTYPE html><html><body>Sign in to continue to Gmail</body></html>"
        XCTAssertNil(AtomFeedParser.unreadCount(from: html))
    }

    func testEmptyStringIsNil() {
        XCTAssertNil(AtomFeedParser.unreadCount(from: ""))
    }

    func testNonNumericFullcountIsNil() {
        XCTAssertNil(AtomFeedParser.unreadCount(from: feed(fullcount: "many")))
    }

    func testUnterminatedTagIsNil() {
        XCTAssertNil(AtomFeedParser.unreadCount(from: "<feed><fullcount>7"))
    }

    func testNegativeCountIsRejected() {
        XCTAssertNil(AtomFeedParser.unreadCount(from: feed(fullcount: "-3")))
    }
}
