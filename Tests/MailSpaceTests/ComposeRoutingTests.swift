import XCTest
@testable import MailSpace

/// Which account a `mailto:` composes from (G1).
///
/// These replace `MailtoAccountTests`, which covered the deleted
/// `AppDelegate.mailtoAccount`: every case it asserted is now the `.current`
/// setting, which reproduces that rule exactly.
final class ComposeRoutingTests: XCTestCase {
    private func account(_ name: String, mail: Bool = true) -> Account {
        Account(name: name, mailEnabled: mail, calendarEnabled: true)
    }

    // MARK: - Follow the current tab (today's rule, kept)

    func testCurrentFollowsTheSelectedAccountWhenItHasMail() {
        let work = account("Work")
        let personal = account("Personal")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .current, selected: personal.id, accounts: [work, personal]),
            .account(personal.id)
        )
    }

    /// The regression the old code had: `selected ?? firstMailEnabled`
    /// short-circuits on any non-nil selection, so a `mailto:` arriving with a
    /// Calendar-only account selected was dropped on the floor.
    func testCurrentHandsACalendarOnlyAccountToTheFirstMailAccount() {
        let family = account("Family", mail: false)
        let work = account("Work")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .current, selected: family.id, accounts: [family, work]),
            .account(work.id)
        )
    }

    func testCurrentFallsBackToTheFirstMailAccountForAStaleSelection() {
        let work = account("Work")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .current, selected: UUID(), accounts: [work]),
            .account(work.id)
        )
        XCTAssertEqual(
            ComposeRouting.resolve(setting: .current, selected: nil, accounts: [work]),
            .account(work.id)
        )
    }

    func testNoMailAccountAnywhereMeansNowhereToCompose() {
        let family = account("Family", mail: false)

        XCTAssertEqual(ComposeRouting.resolve(setting: .current, selected: family.id, accounts: [family]), .none)
        XCTAssertEqual(ComposeRouting.resolve(setting: .ask, selected: nil, accounts: []), .none)
        XCTAssertEqual(ComposeRouting.resolve(setting: .fixed(UUID()), selected: nil, accounts: []), .none)
    }

    // MARK: - Ask

    func testAskWithOneMailAccountDoesNotAsk() {
        let work = account("Work")
        let family = account("Family", mail: false)

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .ask, selected: family.id, accounts: [family, work]),
            .account(work.id)
        )
    }

    func testAskWithTwoMailAccountsOffersBothInTabOrder() {
        let work = account("Work")
        let personal = account("Personal")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .ask, selected: personal.id, accounts: [work, personal]),
            .ask([work.id, personal.id])
        )
    }

    // MARK: - A fixed account

    func testFixedComposesThereWhateverTabIsOnScreen() {
        let work = account("Work")
        let personal = account("Personal")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .fixed(work.id), selected: personal.id, accounts: [work, personal]),
            .account(work.id)
        )
    }

    func testADeletedFixedAccountDegradesToTheCurrentTabRule() {
        let work = account("Work")
        let personal = account("Personal")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .fixed(UUID()), selected: personal.id, accounts: [work, personal]),
            .account(personal.id)
        )
    }

    func testAFixedAccountThatLostMailDegradesToTheCurrentTabRule() {
        let family = account("Family", mail: false)
        let work = account("Work")

        XCTAssertEqual(
            ComposeRouting.resolve(setting: .fixed(family.id), selected: nil, accounts: [family, work]),
            .account(work.id)
        )
    }
}
