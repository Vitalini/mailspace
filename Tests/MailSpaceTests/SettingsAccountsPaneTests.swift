import XCTest
@testable import MailSpace

/// The rules under the account table (A1): which buttons are live, and where
/// the pane's own selection lands after a removal.
///
/// Layout is not tested — this is the logic that decides whether a click can
/// happen at all.
final class SettingsAccountsPaneTests: XCTestCase {
    typealias Buttons = SettingsAccountsPane.Buttons

    func testAddIsAlwaysLive() {
        XCTAssertTrue(Buttons.addEnabled())
    }

    func testRemoveAndEditNeedASelectedRow() {
        XCTAssertTrue(Buttons.removeEnabled(selectedRow: 0, rowCount: 2))
        XCTAssertTrue(Buttons.editEnabled(selectedRow: 1, rowCount: 2))
    }

    /// `NSTableView` reports −1 for "nothing selected", which is what clicking
    /// a blank area produces.
    func testNothingSelectedGreysBoth() {
        XCTAssertFalse(Buttons.removeEnabled(selectedRow: -1, rowCount: 2))
        XCTAssertFalse(Buttons.editEnabled(selectedRow: -1, rowCount: 2))
    }

    func testAnEmptyTableGreysBoth() {
        XCTAssertFalse(Buttons.removeEnabled(selectedRow: 0, rowCount: 0))
        XCTAssertFalse(Buttons.editEnabled(selectedRow: 0, rowCount: 0))
    }

    /// A stale row index — the list shrank underneath the selection — must not
    /// leave a live button pointing at nothing.
    func testARowIndexPastTheEndGreysBoth() {
        XCTAssertFalse(Buttons.removeEnabled(selectedRow: 2, rowCount: 2))
        XCTAssertFalse(Buttons.editEnabled(selectedRow: 5, rowCount: 2))
    }

    // MARK: - Selection after a removal

    func testSelectionLandsOnTheRowThatTookThePlaceOfTheRemovedOne() {
        XCTAssertEqual(Buttons.selectionAfterRemoval(removedRow: 0, newRowCount: 2), 0)
        XCTAssertEqual(Buttons.selectionAfterRemoval(removedRow: 1, newRowCount: 3), 1)
    }

    func testRemovingTheLastRowSelectsTheNewLastRow() {
        XCTAssertEqual(Buttons.selectionAfterRemoval(removedRow: 2, newRowCount: 2), 1)
    }

    func testRemovingTheOnlyRowSelectsNothing() {
        XCTAssertNil(Buttons.selectionAfterRemoval(removedRow: 0, newRowCount: 0))
    }
}
