import AppKit
import XCTest
@testable import MailSpace

/// What the panel renders for a given catalogue. Everything here goes through
/// `ShortcutsWindowController.contentView(for:)`, which builds views and no
/// window — no `NSWindow` is created in this process, so nothing can reach a
/// display.
///
/// Esc, ⌘W, the close box, full-screen visibility, reopen-while-open and the
/// remembered position are manual checks (M2–M5, M12): they are window
/// behaviour, and proving them needs a window on a screen.
final class ShortcutsPanelContentTests: XCTestCase {
    private func groups(_ definitions: [(String, [(String, String)])]) -> [MenuShortcutGroup] {
        definitions.map { title, rows in
            MenuShortcutGroup(title: title, rows: rows.map { MenuShortcut(title: $0.0, keys: $0.1) })
        }
    }

    private func headers(_ view: ShortcutsContentView) -> [String] {
        view.list.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func rows(_ view: ShortcutsContentView) -> [NSStackView] {
        view.list.arrangedSubviews.compactMap { $0 as? NSStackView }
    }

    private func footer(_ view: ShortcutsContentView) -> NSTextField? {
        view.subviews.compactMap { $0 as? NSTextField }.first
    }

    private let sample = [
        ("View", [("Mail", "⇧⌘M"), ("Calendar", "⇧⌘K")]),
        ("Accounts", [("Work · Mail", "⌘1"), ("Work · Calendar", "⌘2")])
    ]

    func testEachGroupBecomesAHeaderFollowedByItsRows() {
        let view = ShortcutsWindowController.contentView(for: groups(sample))

        XCTAssertEqual(headers(view), ["View", "Accounts"])
        XCTAssertEqual(rows(view).count, 4)
        XCTAssertEqual(
            view.list.arrangedSubviews.map { $0 is NSTextField },
            [true, false, false, true, false, false]
        )
    }

    /// KTD6. The panel regenerates on every open, so the second open must
    /// replace the list rather than append to it.
    func testPopulatingTwiceReplacesTheRowsInsteadOfStackingThem() {
        let view = ShortcutsWindowController.contentView(for: groups(sample))
        let first = view.list.arrangedSubviews.count

        view.populate(with: groups(sample))

        XCTAssertEqual(view.list.arrangedSubviews.count, first)
        XCTAssertEqual(rows(view).count, 4)
    }

    /// R20. The footer is outside the scroll view and unconditional — with no
    /// shortcuts to show at all, the pointer to Gmail's own `?` is still the
    /// answer the reader came for.
    func testAnEmptyCatalogueLeavesNothingButTheFooter() {
        let view = ShortcutsWindowController.contentView(for: [])

        XCTAssertTrue(view.list.arrangedSubviews.isEmpty)
        XCTAssertEqual(footer(view)?.stringValue, ShortcutsContentView.footerText)
    }

    func testTheFooterSaysWhereTheGmailAndCalendarShortcutsAre() {
        let view = ShortcutsWindowController.contentView(for: groups(sample))

        XCTAssertEqual(
            footer(view)?.stringValue,
            "Gmail and Calendar have their own shortcuts. Press ? inside the page to see them."
        )
    }

    /// The glyphs land in the trailing label verbatim: the row is the walker's
    /// string, not a second rendering of the shortcut.
    func testARowShowsItsTitleLeadingAndItsGlyphsTrailing() {
        let view = ShortcutsWindowController.contentView(for: groups([("View", [("Mail", "⇧⌘M")])]))

        let labels = rows(view).first?.arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertEqual(labels, ["Mail", "⇧⌘M"])
    }

    /// The hard constraint, asserted rather than assumed: the seam these tests
    /// use builds views and nothing else — no window is constructed, so none
    /// can reach a display.
    func testBuildingTheContentCreatesNoWindow() {
        let view = ShortcutsWindowController.contentView(for: groups(sample))

        XCTAssertNil(view.window)
        XCTAssertNil(rows(view).first?.window)
    }
}
