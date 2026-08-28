import XCTest
@testable import MailSpace

/// Where a download lands once the folder is the user's to choose (G3, B5).
final class DownloadDestinationTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceDownloads-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // Put the permissions back before deleting, or the unwritable case
        // leaves a directory nothing can clean up.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
        try? FileManager.default.removeItem(at: base)
    }

    func testAConfiguredFolderIsCreatedAndUsed() throws {
        let destination = try NavigationPolicy.downloadDestination(suggestedFilename: "report.pdf", in: base)

        XCTAssertEqual(destination.deletingLastPathComponent().path, base.path)
        XCTAssertEqual(destination.lastPathComponent, "report.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }

    /// The path-escape guard is more load-bearing with a user-chosen folder,
    /// not less: `Content-Disposition` is whatever the server said.
    func testAHostileFilenameCannotEscapeTheConfiguredFolder() throws {
        for hostile in ["../../Library/LaunchAgents/x.plist", "/etc/passwd", "..", "."] {
            let destination = try NavigationPolicy.downloadDestination(suggestedFilename: hostile, in: base)
            XCTAssertEqual(
                destination.deletingLastPathComponent().standardizedFileURL.path,
                base.standardizedFileURL.path,
                "escaped with \(hostile)"
            )
        }
    }

    func testACollisionGetsASuffixRatherThanOverwriting() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: base.appendingPathComponent("report.pdf"))

        let destination = try NavigationPolicy.downloadDestination(suggestedFilename: "report.pdf", in: base)
        XCTAssertEqual(destination.lastPathComponent, "report (2).pdf")
    }

    /// B5. The one place a download could vanish with zero feedback: this used
    /// to be `try?` followed by handing WebKit a destination regardless.
    func testAnUnwritableFolderThrowsInsteadOfProducingAPath() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: base.path)

        XCTAssertThrowsError(try NavigationPolicy.downloadDestination(suggestedFilename: "report.pdf", in: base))
    }

    // MARK: - The folder nobody ever chose

    /// The owner's Mac has no download key in its preferences at all, so this
    /// is the resolution that was actually running when he clicked: registered
    /// defaults only. It had to be ruled out before the real cause could be
    /// believed, and a change here would silently move where his files land.
    func testWithNothingStoredTheFolderIsTheSystemDownloadsFolder() throws {
        let suite = "download-destination-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        AppSettings.registerDefaults(in: defaults)

        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.usesSystemDownloadDirectory)
        XCTAssertEqual(
            settings.downloadDirectory.standardizedFileURL,
            AppSettings.systemDownloadDirectory.standardizedFileURL
        )
        XCTAssertEqual(settings.downloadDirectory.lastPathComponent, "Downloads")

        // And a name resolves inside it rather than anywhere else. Nothing is
        // created and nothing is written: this is the same call the delegate
        // makes, minus the folder check.
        let destination = LinkRouter.uniqueDestination(
            in: settings.downloadDirectory, filename: "report.pdf"
        )
        XCTAssertEqual(
            destination.deletingLastPathComponent().standardizedFileURL,
            AppSettings.systemDownloadDirectory.standardizedFileURL
        )
    }

    /// A folder that does not exist yet is created rather than refused — the
    /// other way a chosen folder could swallow a download.
    func testAFolderThatDoesNotExistYetIsCreated() throws {
        let fresh = base.appendingPathComponent("not-yet", isDirectory: true)
        let destination = try NavigationPolicy.downloadDestination(suggestedFilename: "report.pdf", in: fresh)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL, fresh.standardizedFileURL)
    }

    // MARK: - G2

    func testTheCheckboxDecidesWhetherTheBrowserComesForward() {
        XCTAssertFalse(NavigationPolicy.activatesBrowser(openInBackground: true, commandHeld: false))
        XCTAssertTrue(NavigationPolicy.activatesBrowser(openInBackground: false, commandHeld: false))
    }

    /// ⌘-click can only ever force the quieter direction.
    func testCommandClickAlwaysKeepsMailSpaceForward() {
        XCTAssertFalse(NavigationPolicy.activatesBrowser(openInBackground: false, commandHeld: true))
        XCTAssertFalse(NavigationPolicy.activatesBrowser(openInBackground: true, commandHeld: true))
    }
}
