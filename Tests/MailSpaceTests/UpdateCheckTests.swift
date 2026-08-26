import XCTest
@testable import MailSpace

final class UpdateCheckTests: XCTestCase {
    private let current = SemanticVersion(1, 0, 0)

    private func feed(tag: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag,
            "body": "notes",
            "assets": [[
                "name": "MailSpace.zip",
                "browser_download_url": "https://example.invalid/a.zip",
                "size": 5
            ]]
        ])
    }

    func testANewerReleaseIsAvailable() {
        guard case .available(let release) = UpdateCheck.classify(status: 200, body: feed(tag: "v1.1.0"), currentVersion: current) else {
            return XCTFail("expected an available update")
        }
        XCTAssertEqual(release.version, SemanticVersion(1, 1, 0))
    }

    func testTheSameVersionIsUpToDate() {
        guard case .upToDate(let running, let latest) = UpdateCheck.classify(status: 200, body: feed(tag: "v1.0.0"), currentVersion: current) else {
            return XCTFail("expected up to date")
        }
        XCTAssertEqual(running, current)
        XCTAssertEqual(latest, current)
    }

    /// A rolled-back release must never be offered as an update.
    func testAnOlderReleaseIsUpToDateNotAvailable() {
        guard case .upToDate = UpdateCheck.classify(status: 200, body: feed(tag: "v0.9.0"), currentVersion: current) else {
            return XCTFail("expected up to date")
        }
    }

    /// The failure this whole design exists to prevent: while the repository is
    /// private, GitHub answers 404, and reporting that as "up to date" would
    /// make a completely broken feed look like a working one.
    func testA404IsAFailureAndSaysWhy() {
        guard case .failed(let failure) = UpdateCheck.classify(status: 404, body: nil, currentVersion: current) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(failure.summary.contains("no releases"))
        XCTAssertTrue(failure.detail.contains("private"))
    }

    func testRateLimitingIsItsOwnFailure() {
        for status in [403, 429] {
            guard case .failed(let failure) = UpdateCheck.classify(status: status, body: nil, currentVersion: current) else {
                return XCTFail("expected a failure for \(status)")
            }
            XCTAssertTrue(failure.summary.contains("rate-limit"))
        }
    }

    func testServerErrorsAreAFailure() {
        guard case .failed = UpdateCheck.classify(status: 503, body: nil, currentVersion: current) else {
            return XCTFail("expected a failure")
        }
    }

    func testUnexpectedStatusIsAFailure() {
        guard case .failed = UpdateCheck.classify(status: 302, body: nil, currentVersion: current) else {
            return XCTFail("expected a failure")
        }
    }

    func testMalformedBodyIsAFailureNotAnUpdate() {
        guard case .failed(let failure) = UpdateCheck.classify(status: 200, body: Data("{".utf8), currentVersion: current) else {
            return XCTFail("expected a failure")
        }
        XCTAssertFalse(failure.detail.isEmpty)
    }

    func testAnEmptyBodyIsAFailure() {
        guard case .failed = UpdateCheck.classify(status: 200, body: nil, currentVersion: current) else {
            return XCTFail("expected a failure")
        }
    }

    func testOfflineIsPhrasedAsUnreachable() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(UpdateCheck.transportFailure(error).summary.contains("could not reach GitHub"))
    }
}

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNothingHappensWhenAutomaticCheckingIsOff() {
        XCTAssertFalse(UpdateController.shouldCheckInBackground(enabled: false, lastCheck: nil, now: now))
    }

    func testTheFirstCheckIsAlwaysDue() {
        XCTAssertTrue(UpdateController.shouldCheckInBackground(enabled: true, lastCheck: nil, now: now))
    }

    func testAsecondCheckInsideTheIntervalIsSkipped() {
        let recent = now.addingTimeInterval(-3600)
        XCTAssertFalse(UpdateController.shouldCheckInBackground(enabled: true, lastCheck: recent, now: now))
    }

    func testACheckIsDueOnceTheIntervalHasPassed() {
        let old = now.addingTimeInterval(-UpdateController.backgroundInterval - 1)
        XCTAssertTrue(UpdateController.shouldCheckInBackground(enabled: true, lastCheck: old, now: now))
    }

    /// A clock that jumped backwards must not make every launch check.
    func testAFutureLastCheckIsNotDue() {
        XCTAssertFalse(UpdateController.shouldCheckInBackground(enabled: true, lastCheck: now.addingTimeInterval(9999), now: now))
    }
}

final class AppSettingsTests: XCTestCase {
    private func scratchDefaults() -> UserDefaults {
        let suite = "MailSpaceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAutomaticCheckingIsOnByDefault() {
        let defaults = scratchDefaults()
        AppSettings.registerDefaults(in: defaults)
        XCTAssertTrue(AppSettings(defaults: defaults).automaticallyChecksForUpdates)
    }

    func testTheCheckboxRoundTrips() {
        let defaults = scratchDefaults()
        AppSettings.registerDefaults(in: defaults)
        let settings = AppSettings(defaults: defaults)
        settings.automaticallyChecksForUpdates = false
        XCTAssertFalse(AppSettings(defaults: defaults).automaticallyChecksForUpdates)
        settings.automaticallyChecksForUpdates = true
        XCTAssertTrue(AppSettings(defaults: defaults).automaticallyChecksForUpdates)
    }

    func testTheLastCheckStartsUnsetAndRoundTrips() {
        let defaults = scratchDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.lastUpdateCheck)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        settings.lastUpdateCheck = when
        XCTAssertEqual(AppSettings(defaults: defaults).lastUpdateCheck, when)
    }
}
