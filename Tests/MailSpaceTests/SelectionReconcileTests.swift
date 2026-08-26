import XCTest
@testable import MailSpace

/// `MainWindowController.reconciledSelection` — the rule that keeps the
/// in-memory selection in step with the store.
final class SelectionReconcileTests: XCTestCase {
    private func account(
        name: String,
        mail: Bool = true,
        calendar: Bool = true,
        lastView: AccountView = .mail
    ) -> Account {
        Account(name: name, mailEnabled: mail, calendarEnabled: calendar, lastView: lastView)
    }

    func testValidSelectionIsLeftAlone() {
        let work = account(name: "Work")
        let selection = MainWindowController.Selection(accountId: work.id, view: .calendar)

        XCTAssertEqual(MainWindowController.reconciledSelection(selection, accounts: [work]), selection)
    }

    /// The regression: switching Mail off for the active account used to leave
    /// the selection pointing at Mail, which dropped the window into the
    /// zero-accounts empty state even though Calendar was still there.
    func testDisablingTheSelectedServiceFallsBackToTheSameAccount() {
        let work = account(name: "Work")
        let selection = MainWindowController.Selection(accountId: work.id, view: .mail)
        let calendarOnly = Account(
            id: work.id,
            name: "Work",
            mailEnabled: false,
            calendarEnabled: true,
            lastView: .calendar
        )

        let resolved = MainWindowController.reconciledSelection(selection, accounts: [calendarOnly])

        XCTAssertEqual(resolved, MainWindowController.Selection(accountId: work.id, view: .calendar))
    }

    func testRemovedAccountFallsBackToTheFirstRemainingAccount() {
        let personal = account(name: "Personal", mail: false, calendar: true, lastView: .calendar)
        let selection = MainWindowController.Selection(accountId: UUID(), view: .mail)

        let resolved = MainWindowController.reconciledSelection(selection, accounts: [personal])

        XCTAssertEqual(resolved, MainWindowController.Selection(accountId: personal.id, view: .calendar))
    }

    func testNoSelectionPicksTheFirstAccountsEffectiveView() {
        let work = account(name: "Work", lastView: .calendar)
        let personal = account(name: "Personal")

        let resolved = MainWindowController.reconciledSelection(nil, accounts: [work, personal])

        XCTAssertEqual(resolved, MainWindowController.Selection(accountId: work.id, view: .calendar))
    }

    func testNoAccountsMeansNoSelection() {
        XCTAssertNil(MainWindowController.reconciledSelection(nil, accounts: []))
        let stale = MainWindowController.Selection(accountId: UUID(), view: .mail)
        XCTAssertNil(MainWindowController.reconciledSelection(stale, accounts: []))
    }
}
