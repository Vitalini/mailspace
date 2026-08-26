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

    func testRemovingUnknownIdIsANoOp() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        store.remove(id: UUID())

        XCTAssertEqual(store.accounts.map(\.id), [work.id])
    }
}
