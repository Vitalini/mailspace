import UserNotifications
import XCTest
@testable import MailSpace

/// The self-test bundle identity, and what it is allowed to ask macOS for.
///
/// This exists because of a real incident: a smoke run launched the real app,
/// macOS raised the notification permission prompt, the run exited five seconds
/// later without answering it, and macOS recorded the silence as a denial — the
/// user lost banners in the app he was using. The rule these tests pin down is
/// that a permission prompt can only ever come from the user launching the real
/// app; no self-test can produce one, whichever bundle it is run from.
final class SelfTestIdentityTests: XCTestCase {
    private let realBundleId = "com.vitalii.MailSpace"

    func testSelfTestIdentifierIsASeparateBundle() {
        XCTAssertNotEqual(SelfTest.bundleIdentifier, realBundleId)
        XCTAssertTrue(SelfTest.bundleIdentifier.hasPrefix(realBundleId + "."))
    }

    func testOnlyTheSelfTestIdentifierCountsAsTheSelfTestBundle() {
        XCTAssertTrue(SelfTest.isSelfTestBundle(SelfTest.bundleIdentifier))
        XCTAssertFalse(SelfTest.isSelfTestBundle(realBundleId))
        XCTAssertFalse(SelfTest.isSelfTestBundle(nil))
        XCTAssertFalse(SelfTest.isSelfTestBundle("com.vitalii.MailSpace.SelfTest.Other"))
    }

    // MARK: - What may be asked of UNUserNotificationCenter

    private func options(bundleIdentifier: String?, selfTestActive: Bool) -> UNAuthorizationOptions? {
        NotificationBridge.authorizationOptions(
            bundleIdentifier: bundleIdentifier,
            selfTestActive: selfTestActive
        )
    }

    func testRealAppAsksInteractivelyOnANormalLaunch() {
        let options = options(bundleIdentifier: realBundleId, selfTestActive: false)
        XCTAssertEqual(options, [.alert, .sound, .badge])
        XCTAssertFalse(options?.contains(.provisional) ?? true)
    }

    func testSelfTestBundleOnlyEverAsksProvisionally() {
        // Provisional authorization is granted silently — no prompt is drawn —
        // and the notifications are still delivered, so the probe can read them
        // back out of Notification Center.
        for active in [true, false] {
            let options = options(bundleIdentifier: SelfTest.bundleIdentifier, selfTestActive: active)
            XCTAssertEqual(options, [.provisional, .alert, .sound, .badge])
        }
    }

    func testSelfTestUnderTheRealIdentityAsksForNothing() {
        // The belt to the AppDelegate's braces: even if a self-test somehow ran
        // inside the real bundle, it must not touch that bundle's permission.
        XCTAssertNil(options(bundleIdentifier: realBundleId, selfTestActive: true))
        XCTAssertNil(options(bundleIdentifier: nil, selfTestActive: true))
        XCTAssertNil(options(bundleIdentifier: "com.vitalii.MailSpace.Other", selfTestActive: true))
    }

    // MARK: - The user's data is out of a probe's reach

    func testSelfTestKeepsItsOwnAccountsFolder() {
        XCTAssertEqual(AccountStore.folderName(isSelfTest: false), "MailSpace")
        XCTAssertNotEqual(
            AccountStore.folderName(isSelfTest: true),
            AccountStore.folderName(isSelfTest: false)
        )
    }

    func testSelfTestKeepsItsOwnKeychainService() {
        XCTAssertEqual(KeychainStore.service(isSelfTest: false), KeychainStore.defaultService)
        XCTAssertNotEqual(
            KeychainStore.service(isSelfTest: true),
            KeychainStore.service(isSelfTest: false)
        )
    }

    func testTestBundleIsNotTreatedAsTheSelfTestBundle() {
        // The unit tests run under XCTest's own identifier, so the production
        // defaults must be the ones in force here.
        XCTAssertFalse(SelfTest.isSelfTestBundle)
        XCTAssertEqual(KeychainStore.shared.service, KeychainStore.defaultService)
    }
}
