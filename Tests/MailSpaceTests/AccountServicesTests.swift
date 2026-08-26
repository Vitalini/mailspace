import XCTest
@testable import MailSpace

/// Per-account service toggles: an account offers Mail, Calendar, or both, and
/// a disabled service must never become the active view.
final class AccountServicesTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceServices-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Model

    func testBothServicesEnabledByDefault() {
        let account = Account(name: "Work")
        XCTAssertEqual(account.enabledViews, [.mail, .calendar])
        XCTAssertEqual(account.effectiveView, .mail)
    }

    func testCalendarOnlyAccountExposesOnlyCalendar() {
        let account = Account(name: "Family", mailEnabled: false, calendarEnabled: true)
        XCTAssertEqual(account.enabledViews, [.calendar])
        XCTAssertFalse(account.isEnabled(.mail))
        XCTAssertEqual(account.effectiveView, .calendar)
    }

    func testEffectiveViewFallsBackWhenRememberedViewIsDisabled() {
        let account = Account(name: "Family", mailEnabled: false, calendarEnabled: true, lastView: .mail)
        XCTAssertEqual(account.effectiveView, .calendar)
    }

    func testDisablingBothServicesFallsBackToMail() {
        let account = Account(name: "Empty", mailEnabled: false, calendarEnabled: false)
        XCTAssertTrue(account.mailEnabled)
        XCTAssertEqual(account.effectiveView, .mail)
    }

    // MARK: - Store

    func testAddCalendarOnlyAccountPersistsTogglesAndLandsOnCalendar() {
        let store = AccountStore(directory: directory)
        let account = store.add(name: "Family", email: "family@gmail.com", mailEnabled: false, calendarEnabled: true)

        XCTAssertEqual(account.lastView, .calendar)

        let reloaded = AccountStore(directory: directory).account(id: account.id)
        XCTAssertEqual(reloaded?.email, "family@gmail.com")
        XCTAssertEqual(reloaded?.mailEnabled, false)
        XCTAssertEqual(reloaded?.calendarEnabled, true)
    }

    func testDisablingTheActiveServiceMovesLastViewToWhatRemains() {
        let store = AccountStore(directory: directory)
        let account = store.add(name: "Work")
        store.setLastView(.calendar, for: account.id)
        XCTAssertEqual(store.account(id: account.id)?.lastView, .calendar)

        store.update(id: account.id, name: "Work", email: "", mailEnabled: true, calendarEnabled: false, color: .blue)

        XCTAssertEqual(store.account(id: account.id)?.lastView, .mail)
        XCTAssertEqual(AccountStore(directory: directory).account(id: account.id)?.lastView, .mail)
    }

    func testSetLastViewIgnoresADisabledService() {
        let store = AccountStore(directory: directory)
        let account = store.add(name: "Family", mailEnabled: false, calendarEnabled: true)

        store.setLastView(.mail, for: account.id)

        XCTAssertEqual(store.account(id: account.id)?.lastView, .calendar)
    }

    func testUpdateFallsBackToTheEmailAsNameWhenNameIsCleared() {
        let store = AccountStore(directory: directory)
        let account = store.add(name: "Work", email: "old@gmail.com")

        let updated = store.update(id: account.id, name: "  ", email: "new@gmail.com", mailEnabled: true, calendarEnabled: true, color: .green)

        XCTAssertEqual(updated?.name, "new@gmail.com")
        XCTAssertEqual(updated?.email, "new@gmail.com")
        XCTAssertEqual(updated?.color, .green)
    }

    func testAddNamesTheAccountAfterItsEmailWhenNoNameIsGiven() {
        let store = AccountStore(directory: directory)
        XCTAssertEqual(store.add(name: "", email: "solo@gmail.com").name, "solo@gmail.com")
    }

    func testLegacyAccountsWithoutServiceFieldsDefaultToBoth() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"Legacy","lastView":"calendar"}]
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("accounts.json"))

        let account = AccountStore(directory: directory).account(id: id)
        XCTAssertEqual(account?.mailEnabled, true)
        XCTAssertEqual(account?.calendarEnabled, true)
        XCTAssertEqual(account?.email, "")
        XCTAssertEqual(account?.effectiveView, .calendar)
    }

    func testStoredAccountNeverCarriesAPassword() throws {
        let store = AccountStore(directory: directory)
        store.add(name: "Work", email: "work@gmail.com")

        let raw = try String(contentsOf: directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        XCTAssertFalse(raw.lowercased().contains("password"))
    }
}
