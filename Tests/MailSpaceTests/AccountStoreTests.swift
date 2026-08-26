import XCTest
@testable import MailSpace

final class AccountStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var accountsFile: URL {
        directory.appendingPathComponent("accounts.json")
    }

    func testStartsEmptyWhenNoFileExists() {
        let store = AccountStore(directory: directory)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testRoundTripPreservesIdsNamesAndOrder() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")
        let personal = store.add(name: "Personal")

        let reloaded = AccountStore(directory: directory)
        XCTAssertEqual(reloaded.accounts.map(\.id), [work.id, personal.id])
        XCTAssertEqual(reloaded.accounts.map(\.name), ["Work", "Personal"])
    }

    func testRemoveDropsAccountFromDisk() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")
        let personal = store.add(name: "Personal")

        store.remove(id: work.id)

        let reloaded = AccountStore(directory: directory)
        XCTAssertEqual(reloaded.accounts.map(\.id), [personal.id])
        XCTAssertNil(reloaded.account(id: work.id))
    }

    func testLastViewPersists() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")
        XCTAssertEqual(work.lastView, .mail)

        store.setLastView(.calendar, for: work.id)

        let reloaded = AccountStore(directory: directory)
        XCTAssertEqual(reloaded.account(id: work.id)?.lastView, .calendar)
    }

    func testRenamePersists() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        store.rename(id: work.id, to: "Day Job")

        XCTAssertEqual(AccountStore(directory: directory).account(id: work.id)?.name, "Day Job")
    }

    func testCorruptFileStartsEmptyWithoutCrashing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json at all".utf8).write(to: accountsFile)

        let store = AccountStore(directory: directory)
        XCTAssertTrue(store.accounts.isEmpty)

        // The store must still be usable after recovering from a corrupt file.
        let recovered = store.add(name: "Work")
        XCTAssertEqual(AccountStore(directory: directory).accounts.map(\.id), [recovered.id])
    }

    func testUnknownFieldsAndMissingLastViewDecodeToDefault() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"Legacy","unexpected":true}]
        """
        try Data(json.utf8).write(to: accountsFile)

        let store = AccountStore(directory: directory)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.lastView, .mail)
    }

    /// One hand-edited record must not take the whole file with it: decoding
    /// `[Account]` in one go used to throw on the first bad enum value, empty
    /// the store, and make the loss permanent on the next save.
    func testOneUnreadableRecordDoesNotDropTheOthers() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = UUID()
        let broken = UUID()
        let personal = UUID()
        let json = """
        [{"id":"\(work.uuidString)","name":"Work","lastView":"mail","color":"blue"},
         {"id":"\(broken.uuidString)","name":"Broken","lastView":"notes","color":"chartreuse"},
         {"id":"\(personal.uuidString)","name":"Personal","lastView":"calendar","color":"green"}]
        """
        try Data(json.utf8).write(to: accountsFile)

        let store = AccountStore(directory: directory)
        XCTAssertEqual(store.accounts.map(\.id), [work, personal])
        XCTAssertEqual(store.accounts.map(\.name), ["Work", "Personal"])
        XCTAssertNil(store.account(id: broken))

        // And the survivors are still there after the rewrite.
        XCTAssertEqual(AccountStore(directory: directory).accounts.map(\.id), [work, personal])
    }

    func testRemovingUnknownIdIsANoOp() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        store.remove(id: UUID())

        XCTAssertEqual(store.accounts.map(\.id), [work.id])
    }

    // MARK: - Alert and badge flags (A2, A3, A4)

    func testANewAccountAlertsAndCountsByDefault() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        XCTAssertTrue(work.notifyMail)
        XCTAssertTrue(work.notifyCalendar)
        XCTAssertTrue(work.countInBadge)
    }

    func testTheThreeFlagsRoundTripThroughTheFile() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        store.setFlag(.notifyMail, to: false, for: work.id)
        store.setFlag(.countInBadge, to: false, for: work.id)

        let reloaded = AccountStore(directory: directory).account(id: work.id)
        XCTAssertEqual(reloaded?.notifyMail, false)
        XCTAssertEqual(reloaded?.notifyCalendar, true)
        XCTAssertEqual(reloaded?.countInBadge, false)
    }

    /// An `accounts.json` written before this change has none of the three
    /// fields, and must keep behaving exactly as it did — alerts on, counted.
    func testAFileFromBeforeTheseFlagsDecodesWithAllThreeOn() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","name":"Personal","email":"a@b.com","mailEnabled":true,
          "calendarEnabled":true,"lastView":"mail","color":"blue","mailOrder":0,"calendarOrder":1}]
        """
        try Data(json.utf8).write(to: accountsFile)

        let account = try XCTUnwrap(AccountStore(directory: directory).account(id: id))
        XCTAssertTrue(account.notifyMail)
        XCTAssertTrue(account.notifyCalendar)
        XCTAssertTrue(account.countInBadge)
    }

    /// The account dialog knows nothing about the three flags, so editing an
    /// account must not quietly switch its alerts back on.
    func testEditingAnAccountCarriesTheFlagsAcross() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")
        store.setFlag(.notifyMail, to: false, for: work.id)
        store.setFlag(.notifyCalendar, to: false, for: work.id)
        store.setFlag(.countInBadge, to: false, for: work.id)

        store.update(
            id: work.id,
            name: "Day Job",
            email: "work@example.com",
            mailEnabled: true,
            calendarEnabled: true,
            color: .green
        )

        let updated = store.account(id: work.id)
        XCTAssertEqual(updated?.name, "Day Job")
        XCTAssertEqual(updated?.notifyMail, false)
        XCTAssertEqual(updated?.notifyCalendar, false)
        XCTAssertEqual(updated?.countInBadge, false)
    }

    func testSettingAFlagOnAnUnknownAccountIsANoOp() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        store.setFlag(.countInBadge, to: false, for: UUID())

        XCTAssertEqual(store.account(id: work.id)?.countInBadge, true)
    }
}
