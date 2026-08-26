import XCTest
@testable import MailSpace

final class ReleaseNotesTests: XCTestCase {
    func testHeadingsBulletsAndParagraphs() {
        let notes = """
        ### Added
        - Settings window on ⌘,
        - A second thing

        ### Fixed
        - The badge no longer lies.
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [
            .heading("Added"),
            .bullet("Settings window on ⌘,"),
            .bullet("A second thing"),
            .heading("Fixed"),
            .bullet("The badge no longer lies.")
        ])
    }

    func testWrappedProseJoinsIntoOneParagraph() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "This release\nis mostly\nfixes.\n\nAnd one more."), [
            .paragraph("This release is mostly fixes."),
            .paragraph("And one more.")
        ])
    }

    func testAsterisksAndPlusesAlsoStartBullets() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "* one\n+ two"), [.bullet("one"), .bullet("two")])
    }

    func testCarriageReturnsFromAWindowsAuthoredBodyDoNotLeak() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "### Added\r\n- one\r\n"), [.heading("Added"), .bullet("one")])
    }

    func testEmptyNotesProduceNoBlocks() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "   \n\n"), [])
    }

    func testHeadingLevelDoesNotMatter() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "# One\n## Two\n### Three"), [
            .heading("One"), .heading("Two"), .heading("Three")
        ])
    }

    func testInlineBoldAndCode() {
        XCTAssertEqual(ReleaseNotes.runs(in: "a **bold** and `code` bit"), [
            .plain("a "), .strong("bold"), .plain(" and "), .code("code"), .plain(" bit")
        ])
    }

    /// An unclosed marker must stay literal instead of eating the line.
    func testUnclosedMarkersStayLiteral() {
        XCTAssertEqual(ReleaseNotes.runs(in: "2 ** 3 is not bold"), [.plain("2 ** 3 is not bold")])
        XCTAssertEqual(ReleaseNotes.runs(in: "a `backtick"), [.plain("a `backtick")])
    }

    func testPlainTextIsOneRun() {
        XCTAssertEqual(ReleaseNotes.runs(in: "nothing special"), [.plain("nothing special")])
    }

    func testRenderingKeepsTheWordsAndMarksTheBullets() {
        let rendered = ReleaseNotes.attributed("### Fixed\n- The **badge** no longer lies.").string
        XCTAssertTrue(rendered.contains("Fixed"))
        XCTAssertTrue(rendered.contains("•"))
        XCTAssertTrue(rendered.contains("The badge no longer lies."))
        XCTAssertFalse(rendered.contains("**"))
        XCTAssertFalse(rendered.contains("###"))
    }

    /// A release published with an empty body still has to render something.
    func testEmptyNotesRenderAnExplanation() {
        XCTAssertEqual(ReleaseNotes.attributed("").string, "This release came with no notes.")
    }
}
