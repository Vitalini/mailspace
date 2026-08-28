import XCTest
@testable import MailSpace

/// The settings domain: documented defaults, round-trips, and what a
/// hand-edited value does.
///
/// Every case runs against a scratch suite, so nothing here can read or write
/// the preferences of the app the user runs.
final class AppSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "MailSpaceTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func settings(registered: Bool = true) -> AppSettings {
        if registered { AppSettings.registerDefaults(in: defaults) }
        return AppSettings(defaults: defaults)
    }

    // MARK: - Defaults

    func testRegisterDefaultsProducesTheDocumentedValues() {
        let settings = settings()

        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        XCTAssertEqual(settings.composeFrom, .ask)
        XCTAssertTrue(settings.openLinksInBackground)
        XCTAssertTrue(settings.usesSystemDownloadDirectory)
        XCTAssertEqual(settings.downloadDirectory, AppSettings.systemDownloadDirectory)
        XCTAssertEqual(settings.downloadFinishedAction, .notify)
        XCTAssertTrue(settings.showsCalendarCountdown)
        XCTAssertEqual(settings.unreadPollSeconds, 60)
        XCTAssertFalse(settings.disableSignInAutofill)
    }

    /// A domain written before this change has none of the new keys. Nothing
    /// may read as a false-shaped zero: `false` for a checkbox that defaults on,
    /// or a 0-second poll interval.
    func testADomainFromBeforeThisChangeMigratesToTheDefaults() {
        // Exactly what v1.0.1 wrote.
        defaults.set(true, forKey: AppSettings.Key.automaticallyChecksForUpdates)
        defaults.set(Date(timeIntervalSince1970: 1), forKey: AppSettings.Key.lastUpdateCheck)

        let settings = settings()
        XCTAssertEqual(settings.composeFrom, .ask)
        XCTAssertTrue(settings.openLinksInBackground)
        // On by default. A domain written before G6 existed must not read it as
        // a false-shaped `false`.
        XCTAssertTrue(settings.showsCalendarCountdown)
        XCTAssertEqual(settings.unreadPollSeconds, 60)
        // And the values that were already there are untouched.
        XCTAssertTrue(settings.automaticallyChecksForUpdates)
        XCTAssertEqual(settings.lastUpdateCheck, Date(timeIntervalSince1970: 1))
    }

    /// A key deleted by hand (`defaults delete …`) reads as the default, not as
    /// zero — the registration domain is what makes that true.
    func testAnUnsetValveReadsItsDocumentedDefault() {
        let settings = settings()
        defaults.removeObject(forKey: AppSettings.Key.unreadPollSeconds)
        XCTAssertEqual(settings.unreadPollSeconds, 60)
    }

    // MARK: - Round trips

    func testComposeFromRoundTripsThroughItsRawString() {
        let settings = settings()
        let id = UUID()

        for value in [ComposeFrom.ask, .current, .fixed(id)] {
            settings.composeFrom = value
            XCTAssertEqual(settings.composeFrom, value)
        }
    }

    func testEveryEnumRoundTripsThroughItsRawString() {
        let settings = settings()

        for action in DownloadFinishedAction.allCases {
            settings.downloadFinishedAction = action
            XCTAssertEqual(settings.downloadFinishedAction, action)
        }
    }

    func testTheCalendarCountdownSwitchRoundTrips() {
        let settings = settings()
        settings.showsCalendarCountdown = false
        XCTAssertFalse(settings.showsCalendarCountdown)
        settings.showsCalendarCountdown = true
        XCTAssertTrue(settings.showsCalendarCountdown)
    }

    func testAnUnknownStoredValueFallsBackRatherThanCrashing() {
        let settings = settings()
        defaults.set("mailplane", forKey: AppSettings.Key.composeFrom)
        defaults.set("shred", forKey: AppSettings.Key.downloadFinishedAction)

        XCTAssertEqual(settings.composeFrom, .ask)
        XCTAssertEqual(settings.downloadFinishedAction, .notify)
    }

    /// A5's key is gone. A domain that still carries the old `BadgeScope`
    /// value — every domain written by 1.0.3 through 1.1.0 does — is simply
    /// ignored, rather than being migrated into a scope that no longer exists.
    func testALeftoverBadgeScopeValueIsIgnored() {
        let settings = settings()
        defaults.set("primary", forKey: "BadgeScope")
        defaults.set(true, forKey: "UnreadUsePlainFeed")

        XCTAssertEqual(settings.unreadPollSeconds, 60)
        XCTAssertEqual(settings.downloadFinishedAction, .notify)
    }

    // MARK: - Download folder

    func testChoosingAFolderStoresItAndUsingDownloadsClearsIt() {
        let settings = settings()
        let chosen = URL(fileURLWithPath: "/tmp/mailspace-downloads", isDirectory: true)

        settings.downloadDirectory = chosen
        XCTAssertFalse(settings.usesSystemDownloadDirectory)
        XCTAssertEqual(settings.downloadDirectory.path, chosen.path)

        settings.useSystemDownloadDirectory()
        XCTAssertTrue(settings.usesSystemDownloadDirectory)
        XCTAssertEqual(settings.downloadDirectory, AppSettings.systemDownloadDirectory)
    }

    func testATildePathIsExpanded() {
        let settings = settings()
        defaults.set("~/Desktop/Attachments", forKey: AppSettings.Key.downloadDirectoryPath)
        XCTAssertFalse(settings.downloadDirectory.path.contains("~"))
        XCTAssertTrue(settings.downloadDirectory.path.hasSuffix("/Desktop/Attachments"))
    }
}
