import XCTest
@testable import MailSpace

final class SemanticVersionTests: XCTestCase {
    func testParsesThreeParts() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
    }

    func testAcceptsATagWithTheLeadingV() {
        XCTAssertEqual(SemanticVersion("v10.0.4"), SemanticVersion(10, 0, 4))
    }

    /// The version this app shipped with before the VERSION file existed.
    func testReadsATwoPartVersionAsPatchZero() {
        XCTAssertEqual(SemanticVersion("1.0"), SemanticVersion(1, 0, 0))
    }

    func testTrimsWhitespace() {
        XCTAssertEqual(SemanticVersion(" 2.0.1\n"), SemanticVersion(2, 0, 1))
    }

    func testRejectsNonNumbers() {
        XCTAssertNil(SemanticVersion("nightly"))
        XCTAssertNil(SemanticVersion("1.x.0"))
        XCTAssertNil(SemanticVersion("1"))
        XCTAssertNil(SemanticVersion("1.2.3.4"))
        XCTAssertNil(SemanticVersion(""))
        XCTAssertNil(SemanticVersion("1..3"))
    }

    /// Dropping the suffix would make 2.0.0-beta.1 compare equal to 2.0.0, and
    /// then a pre-release would install itself over the real thing.
    func testRejectsPreReleaseAndBuildMetadata() {
        XCTAssertNil(SemanticVersion("2.0.0-beta.1"))
        XCTAssertNil(SemanticVersion("2.0.0+build7"))
    }

    func testOrdersByComponentNotByString() {
        XCTAssertTrue(SemanticVersion(1, 10, 0) > SemanticVersion(1, 9, 0))
        XCTAssertTrue(SemanticVersion(1, 2, 0) < SemanticVersion(1, 10, 0))
        XCTAssertTrue(SemanticVersion(2, 0, 0) > SemanticVersion(1, 99, 99))
        XCTAssertTrue(SemanticVersion(1, 0, 1) > SemanticVersion(1, 0, 0))
        XCTAssertFalse(SemanticVersion(1, 0, 0) > SemanticVersion(1, 0, 0))
    }

    func testDescriptionIsAlwaysThreeParts() {
        XCTAssertEqual(SemanticVersion("1.0")?.description, "1.0.0")
    }
}
