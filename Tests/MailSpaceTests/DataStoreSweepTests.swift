import XCTest
@testable import MailSpace

/// The launch sweep that deletes stored Google sessions no account claims.
///
/// Account removal can fail — a download still running, a popup that would not
/// go — and the removal dialog has already promised the session is gone. This
/// is what comes back for it.
final class DataStoreSweepTests: XCTestCase {
    private func account(_ id: UUID) -> Account {
        Account(id: id, name: "Test", email: "test@example.com")
    }

    func testOnlyUnclaimedStoresAreSwept() {
        let kept = UUID()
        let orphan = UUID()

        XCTAssertEqual(
            AppDelegate.orphanedStores(onDisk: [kept, orphan], claimedBy: [account(kept)]),
            [orphan]
        )
    }

    func testEveryClaimedStoreIsLeftAlone() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(
            AppDelegate.orphanedStores(onDisk: [first, second], claimedBy: [account(first), account(second)]),
            []
        )
    }

    /// A store an account claims but that is not on disk is not swept — and
    /// must never be handed to `remove(forIdentifier:)`, which segfaults on an
    /// identifier with nothing behind it.
    func testAnIdentifierThatIsNotOnDiskIsNeverReturned() {
        let onDisk = UUID()
        let neverCreated = UUID()

        XCTAssertEqual(
            AppDelegate.orphanedStores(onDisk: [onDisk], claimedBy: [account(neverCreated)]),
            [onDisk]
        )
        XCTAssertFalse(
            AppDelegate.orphanedStores(onDisk: [onDisk], claimedBy: [account(neverCreated)]).contains(neverCreated)
        )
    }

    func testNoAccountsMeansEveryStoreIsAnOrphan() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            AppDelegate.orphanedStores(onDisk: [first, second], claimedBy: []),
            [first, second]
        )
    }
}

/// …which is precisely why the sweep is gated on `accounts.json` having been
/// read in full. An unreadable file leaves an empty account list, and sweeping
/// against that would delete every session on the Mac.
final class AccountStoreLoadIntegrityTests: XCTestCase {
    private func makeStore(contents: String?) throws -> AccountStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        if let contents {
            try contents.write(
                to: directory.appendingPathComponent("accounts.json"),
                atomically: true,
                encoding: .utf8
            )
        }
        return AccountStore(directory: directory)
    }

    func testAFirstRunWithNoFileIsClean() throws {
        let store = try makeStore(contents: nil)
        XCTAssertTrue(store.didLoadCleanly)
        XCTAssertEqual(store.accounts.count, 0)
    }

    func testAWellFormedFileIsClean() throws {
        let id = UUID().uuidString
        let store = try makeStore(contents: """
        [{"id":"\(id)","name":"Work","email":"a@b.com","mailEnabled":true,"calendarEnabled":true,"lastView":"mail"}]
        """)
        XCTAssertTrue(store.didLoadCleanly)
        XCTAssertEqual(store.accounts.count, 1)
    }

    func testAFileThatCannotBeParsedAtAllIsNotClean() throws {
        let store = try makeStore(contents: "{ not json")
        XCTAssertFalse(store.didLoadCleanly)
        XCTAssertEqual(store.accounts.count, 0)
    }

    /// One skipped record means `accounts` is not the whole list — and the
    /// account behind that record still owns a session on disk.
    func testASkippedRecordIsNotClean() throws {
        let id = UUID().uuidString
        let store = try makeStore(contents: """
        [{"id":"\(id)","name":"Work"},{"name":"No id at all"}]
        """)
        XCTAssertFalse(store.didLoadCleanly)
        XCTAssertEqual(store.accounts.count, 1)
    }
}
