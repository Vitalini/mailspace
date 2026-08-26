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

    // MARK: - Hard-wrapped bullets
    //
    // `CHANGELOG.md` wraps at 80 columns and `scripts/release.sh` publishes it
    // verbatim, so nearly every bullet the update window renders arrives as two
    // or three lines. Each of these was a paragraph of its own once.

    func testAWrappedBulletStaysOneBullet() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- The badge carries the unread count\nacross every account."), [
            .bullet("The badge carries the unread count across every account.")
        ])
    }

    func testAnIndentedContinuationJoinsTheBulletAboveIt() {
        let notes = """
        - Gmail and Calendar in one window, as a flat row of tabs — one tab per
          account and service.
        - The badge carries the unread count.
        """
        XCTAssertEqual(ReleaseNotes.blocks(from: notes), [
            .bullet("Gmail and Calendar in one window, as a flat row of tabs — one tab per account and service."),
            .bullet("The badge carries the unread count.")
        ])
    }

    func testAThirdLineJoinsTheSameBullet() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- one\n  two\n  three"), [.bullet("one two three")])
    }

    /// A blank line closes the list, so what follows is prose and not the tail
    /// of the last item.
    func testABlankLineEndsTheList() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- one\n  still one\n\nA sentence of its own."), [
            .bullet("one still one"),
            .paragraph("A sentence of its own.")
        ])
    }

    func testABulletNeedsNoBlankLineAfterAHeading() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "### Fixed\n- one\n  wrapped\n### Added\n- two"), [
            .heading("Fixed"), .bullet("one wrapped"), .heading("Added"), .bullet("two")
        ])
    }

    func testTwoBlankLinesAreNotAnEmptyBlock() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- one\n\n\n- two"), [.bullet("one"), .bullet("two")])
    }

    /// An indented marker is a nested item in Markdown. It flattens to a plain
    /// bullet here — nesting is lost, but the item never glues itself onto the
    /// text above it.
    func testAnIndentedMarkerIsAFlatBulletNotAContinuation() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- one\n  - nested"), [.bullet("one"), .bullet("nested")])
    }

    /// The space after the marker is the whole difference.
    func testAHyphenWithoutASpaceIsNotABullet() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- It gets cold:\n-5 degrees overnight."), [
            .bullet("It gets cold: -5 degrees overnight.")
        ])
    }

    func testHashesWithoutASpaceAreNotAHeading() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- It charted:\n#1 for a week."), [
            .bullet("It charted: #1 for a week.")
        ])
        XCTAssertEqual(ReleaseNotes.blocks(from: "####### seven hashes"), [.paragraph("####### seven hashes")])
    }

    /// A wrapped line that starts with inline code keeps the item together —
    /// the hyphens inside the code span are not a marker.
    func testInlineCodeWithHyphensDoesNotSplitTheItem() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- Publishing takes\n`--dry-run` first."), [
            .bullet("Publishing takes `--dry-run` first.")
        ])
    }

    func testTrailingWhitespaceDoesNotSurviveTheJoin() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- one   \n  two\t\n   \n- three  "), [
            .bullet("one two"), .bullet("three")
        ])
    }

    func testCarriageReturnsSurviveInsideAWrappedBullet() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "### Added\r\n- one\r\n  wrapped\r\n\r\nProse.\r\n"), [
            .heading("Added"), .bullet("one wrapped"), .paragraph("Prose.")
        ])
    }

    func testAMarkerWithNothingAfterItRendersNothing() {
        XCTAssertEqual(ReleaseNotes.blocks(from: "- \n\n- real"), [.bullet("real")])
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

    // MARK: - The body GitHub actually serves

    /// Fixtures written by hand are what let the wrapping bug ship: every bullet
    /// in them was one line long. This is the body of the published v1.0.0
    /// release, fetched with
    /// `gh release view v1.0.0 --repo Vitalini/mailspace --json body` and kept
    /// verbatim — twelve bullets, ten of them wrapped.
    func testThePublishedReleaseBodyKeepsEveryBulletWhole() throws {
        let body = try publishedReleaseBody()

        // If someone unwraps the fixture, this test stops testing anything.
        let continuations = body.split(separator: "\n").filter { $0.hasPrefix("  ") }
        XCTAssertGreaterThanOrEqual(continuations.count, 10, "the fixture has to stay hard-wrapped")

        let blocks = ReleaseNotes.blocks(from: body)
        let bullets: [String] = blocks.compactMap {
            if case .bullet(let text) = $0 { return text } else { return nil }
        }
        let paragraphs = blocks.filter { if case .paragraph = $0 { return true } else { return false } }

        XCTAssertEqual(paragraphs, [], "a wrapped line became a paragraph of its own")
        XCTAssertEqual(bullets.count, 12)
        XCTAssertEqual(blocks.count, 14, "two headings and twelve bullets, nothing else")
        XCTAssertEqual(blocks.first, .heading("Added"))
        XCTAssertEqual(blocks.firstIndex(of: .heading("Fixed")), 9, "eight items under Added")

        // Wrapped across three source lines, and one bullet on the other side.
        XCTAssertEqual(
            bullets.first,
            "Gmail and Google Calendar in one window, as a flat row of tabs — one tab per "
                + "account and service, switchable with ⌘1…⌘9 or ⇧⌘M and ⇧⌘K."
        )
        for bullet in bullets {
            XCTAssertTrue(bullet.hasSuffix("."), "cut mid-sentence: \(bullet)")
            XCTAssertFalse(bullet.contains("  "), "a double space at a wrap seam: \(bullet)")
            XCTAssertFalse(bullet.contains("\n"), "a line break survived into the text: \(bullet)")
        }
    }

    /// The bug was visible rather than structural: the second line of an item
    /// lost the bullet's indent and sat at the left margin.
    func testAContinuationCarriesTheBulletIndentWhenRendered() throws {
        let attributed = ReleaseNotes.attributed(try publishedReleaseBody())
        XCTAssertEqual(attributed.string.filter { $0 == "•" }.count, 12)

        let continuation = (attributed.string as NSString).range(of: "account and service")
        XCTAssertNotEqual(continuation.location, NSNotFound)
        let style = attributed.attribute(.paragraphStyle, at: continuation.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 16)
    }

    private func publishedReleaseBody() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "release-body-v1.0.0", withExtension: "md", subdirectory: "Fixtures"),
            "the published release body is missing from the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
