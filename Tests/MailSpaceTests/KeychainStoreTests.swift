import Security
import XCTest
@testable import MailSpace

/// Runs entirely inside a throwaway `service` namespace — never the real
/// "MailSpace" one — so a test run can neither read nor damage the user's
/// stored Google passwords.
final class KeychainStoreTests: XCTestCase {
    private var store: KeychainStore!
    private var email: String!

    override func setUpWithError() throws {
        store = KeychainStore(service: "MailSpaceTests-\(UUID().uuidString)")
        email = "probe-\(UUID().uuidString)@example.com"
        // A test that touched the real namespace would be worse than no test.
        XCTAssertNotEqual(store.service, KeychainStore.defaultService)
    }

    override func tearDownWithError() throws {
        store.deletePassword(for: email)
        store = nil
        email = nil
    }

    func testRoundTrip() {
        XCTAssertFalse(store.hasPassword(for: email))

        XCTAssertTrue(store.setPassword("correct horse", for: email))

        XCTAssertEqual(store.password(for: email), "correct horse")
        XCTAssertTrue(store.hasPassword(for: email))
    }

    func testSecondSetPasswordUpdatesTheExistingItem() {
        XCTAssertTrue(store.setPassword("first", for: email))
        XCTAssertTrue(store.setPassword("second", for: email))

        XCTAssertEqual(store.password(for: email), "second")
        XCTAssertEqual(itemCount(), 1, "the second write must update, not insert a duplicate")
    }

    func testDeleteIsIdempotent() {
        XCTAssertTrue(store.setPassword("gone soon", for: email))

        XCTAssertTrue(store.deletePassword(for: email))
        // Deleting what is no longer there is success, not a failure to report.
        XCTAssertTrue(store.deletePassword(for: email))

        XCTAssertNil(store.password(for: email))
        XCTAssertEqual(itemCount(), 0)
    }

    func testEmptyEmailIsRejectedEverywhere() {
        XCTAssertFalse(store.setPassword("something", for: ""))
        XCTAssertNil(store.password(for: ""))
        XCTAssertFalse(store.hasPassword(for: ""))
        XCTAssertFalse(store.deletePassword(for: ""))
        XCTAssertEqual(itemCount(), 0)
    }

    func testEmptyPasswordIsRejected() {
        XCTAssertFalse(store.setPassword("", for: email))
        XCTAssertNil(store.password(for: email))
        XCTAssertEqual(itemCount(), 0)
    }

    func testWritesStayOutOfTheRealService() {
        XCTAssertTrue(store.setPassword("test only", for: email))

        XCTAssertNil(KeychainStore.shared.password(for: email))
    }

    /// Items currently held under this test's service name.
    private func itemCount() -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return 0 }
        return (result as? [Any])?.count ?? 0
    }
}
