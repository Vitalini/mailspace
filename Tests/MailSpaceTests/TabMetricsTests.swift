import AppKit
import XCTest
@testable import MailSpace

/// Every tab in the bar is the same width, and the widest one's content decides
/// what that width is. These are the arithmetic of that rule — the AppKit
/// layout that applies it is not what breaks.
final class TabMetricsTests: XCTestCase {
    private let chrome = TabMetrics.horizontalPadding * 2
        + TabMetrics.iconSize
        + TabMetrics.iconLabelSpacing

    // MARK: - What one tab asks for

    func testNaturalWidthIsPaddingIconGapAndLabel() {
        XCTAssertEqual(TabMetrics.naturalWidth(labelWidth: 100), chrome + 100)
    }

    func testNaturalWidthCarriesPaddingOnBothSides() {
        // The complaint this change answers: the label used to sit 11pt from
        // one edge and 12pt from the other. Both sides are now the same, and
        // wider.
        XCTAssertEqual(TabMetrics.horizontalPadding, 16)
        XCTAssertEqual(
            TabMetrics.naturalWidth(labelWidth: 0),
            32 + TabMetrics.iconSize + TabMetrics.iconLabelSpacing
        )
    }

    func testNaturalWidthRoundsUpSoTheWidestLabelStillFits() {
        XCTAssertEqual(TabMetrics.naturalWidth(labelWidth: 100.2), chrome + 101)
    }

    // MARK: - The optional trailing accessory (U10's unread pill)

    func testNoAccessoryCostsNeitherWidthNorGap() {
        XCTAssertEqual(
            TabMetrics.naturalWidth(labelWidth: 100, accessoryWidth: nil),
            TabMetrics.naturalWidth(labelWidth: 100)
        )
    }

    func testAnAccessoryAddsItsOwnWidthAndTheGapBeforeIt() {
        XCTAssertEqual(
            TabMetrics.naturalWidth(labelWidth: 100, accessoryWidth: 24),
            chrome + 100 + TabMetrics.accessorySpacing + 24
        )
    }

    /// The point of measuring the accessory rather than overlaying it: a tab
    /// that gains an unread pill gets wider, and so does every tab beside it.
    /// The label keeps exactly the room it had.
    func testAnAccessoryOnOneTabWidensThemAllRatherThanSqueezingTheLabel() {
        let plain = TabMetrics.naturalWidth(labelWidth: 100)
        let withPill = TabMetrics.naturalWidth(labelWidth: 100, accessoryWidth: 26)
        let pillCost = TabMetrics.accessorySpacing + 26

        let before = TabMetrics.uniformWidth(naturalWidths: [plain, plain], available: 2000)
        let after = TabMetrics.uniformWidth(naturalWidths: [withPill, plain], available: 2000)

        XCTAssertEqual(after, before + pillCost)
        XCTAssertEqual(after - chrome - pillCost, 100, "the label's own room is untouched")
    }

    // MARK: - One width for all of them

    func testWidestContentSetsTheWidthForEveryTab() {
        let widths = [200.0, 140.0, 173.0] as [CGFloat]
        XCTAssertEqual(TabMetrics.uniformWidth(naturalWidths: widths, available: 2000), 200)
    }

    func testNoTabsMeansNoWidth() {
        XCTAssertEqual(TabMetrics.uniformWidth(naturalWidths: [], available: 2000), 0)
    }

    func testAShortNameStillGetsTheMinimumWidth() {
        XCTAssertEqual(
            TabMetrics.uniformWidth(naturalWidths: [40, 30], available: 2000),
            TabMetrics.minimumWidth
        )
    }

    func testOneVeryLongNameCannotPushItsSiblingsOffTheBar() {
        XCTAssertEqual(
            TabMetrics.uniformWidth(naturalWidths: [900, 120], available: 4000),
            TabMetrics.maximumWidth
        )
    }

    func testBeforeTheBarIsLaidOutTabsGetWhatTheyAskedFor() {
        // available == 0 is "no constraint known yet", not "no room" — sizing
        // to the floor here would show a row of stubs for one frame.
        XCTAssertEqual(TabMetrics.uniformWidth(naturalWidths: [200, 140], available: 0), 200)
    }

    // MARK: - Overflow: shrink together, then scroll

    func testTabsTooWideToFitShrinkEquallyUntilTheyDo() {
        // Three tabs want 200pt each; 500pt is all there is, and 12pt of that
        // goes between them: (500 - 12) / 3 = 162.
        let width = TabMetrics.uniformWidth(naturalWidths: [200, 180, 200], available: 500)

        XCTAssertEqual(width, 162)
        XCTAssertLessThanOrEqual(width * 3 + TabMetrics.spacing * 2, 500)
        XCTAssertGreaterThan(width, TabMetrics.minimumWidth)
    }

    func testShrinkingStopsAtTheFloorAndTheBarScrollsInstead() {
        // Twelve tabs in a narrow bar: below the floor a label says nothing, so
        // the tabs keep the floor width and the bar scrolls horizontally.
        let width = TabMetrics.uniformWidth(
            naturalWidths: Array(repeating: 200, count: 12),
            available: 400
        )
        XCTAssertEqual(width, TabMetrics.minimumWidth)
    }

    func testShrinkingNeverGoesBelowTheFloorEvenForOneTab() {
        XCTAssertEqual(TabMetrics.uniformWidth(naturalWidths: [200], available: 20),
                       TabMetrics.minimumWidth)
    }

    // MARK: - The real bar, at the real minimum window size

    /// The window cannot be dragged narrower than 860pt. Four tabs — two
    /// accounts with Mail and Calendar each — must still show their full names
    /// there, or the equal-width rule would be trading truncation for tidiness.
    func testFourRealTabsFitUntruncatedAtTheMinimumWindowWidth() {
        let labels = [
            "Personal · Mail", "Personal · Calendar",
            "Talkable · Mail", "Talkable · Calendar"
        ]
        let naturals = labels.map {
            TabMetrics.naturalWidth(
                labelWidth: TabMetrics.textWidth($0, font: TabMetrics.measurementFont)
            )
        }

        let available = AccountTabBar.availableTabWidth(inBarWidth: 860)
        let width = TabMetrics.uniformWidth(naturalWidths: naturals, available: available)

        XCTAssertEqual(width, naturals.max())
        XCTAssertLessThan(width, TabMetrics.maximumWidth)
    }

    func testTheBarLeavesRoomForTheAddButtonAndItsOwnInsets() {
        // 860 - 34 (+ button) - 10 (its inset) - 4 (gap) - 20 (stack insets).
        XCTAssertEqual(AccountTabBar.availableTabWidth(inBarWidth: 860), 792)
        XCTAssertEqual(AccountTabBar.availableTabWidth(inBarWidth: 10), 0)
    }
}
