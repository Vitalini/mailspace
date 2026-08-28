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

    // MARK: - Names longer than the filesystem accepts

    /// The failure that looked exactly like nothing happening.
    ///
    /// A path component may be 255 **bytes**, and UTF-8 spends two on every
    /// Cyrillic letter — so 264 of them is 528 bytes, `open(2)` refused it, and
    /// WebKit reported that back as `NSURLErrorCancelled (-999)`. The app read
    /// -999 as the user cancelling and said nothing. Measured on the owner's
    /// Mac at 204, 264 and 404 characters: the first landed, the other two
    /// vanished.
    ///
    /// Proved against the filesystem rather than against arithmetic: the file
    /// is actually written.
    func testAnOverLongNameIsTruncatedRatherThanFailing() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        for characters in [204, 264, 404] {
            for (script, letter) in [("Cyrillic", "и"), ("Latin", "a")] {
                let suggested = String(repeating: letter, count: characters) + ".pdf"
                let destination = try NavigationPolicy.downloadDestination(
                    suggestedFilename: suggested, in: base
                )
                let name = destination.lastPathComponent

                XCTAssertLessThanOrEqual(
                    name.utf8.count, LinkRouter.maxFilenameBytes,
                    "\(script) \(characters)"
                )
                XCTAssertEqual((name as NSString).pathExtension, "pdf", "\(script) \(characters)")
                // The one assertion that cannot be argued with.
                XCTAssertNoThrow(
                    try Data("bytes".utf8).write(to: destination),
                    "\(script) \(characters) could not be written"
                )
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    /// A name that already fits is left exactly as it is — truncation must not
    /// become a rename.
    func testANameThatFitsIsUntouched() throws {
        let fits = String(repeating: "и", count: 100) + ".pdf"
        XCTAssertEqual(
            try NavigationPolicy.downloadDestination(suggestedFilename: fits, in: base).lastPathComponent,
            fits
        )
    }

    /// Three over-long names that truncate to the same thing still get three
    /// files, and the collision marker survives the fit — take " (2)" out of the
    /// name that is being shortened and the loop can never terminate.
    func testOverLongNamesThatCollideStillGetSeparateFiles() throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var written: Set<String> = []

        for characters in [264, 300, 404] {
            let destination = try NavigationPolicy.downloadDestination(
                suggestedFilename: String(repeating: "и", count: characters) + ".pdf", in: base
            )
            try Data("bytes".utf8).write(to: destination)
            XCTAssertLessThanOrEqual(destination.lastPathComponent.utf8.count, LinkRouter.maxFilenameBytes)
            written.insert(destination.lastPathComponent)
        }
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path).count, 3)
    }

    /// Cut on a character boundary, never on a byte one: half a Cyrillic letter
    /// is not a filename, and `String` would turn it into U+FFFD rather than
    /// refuse.
    func testTruncationNeverSplitsACharacter() {
        let cut = LinkRouter.truncated(String(repeating: "и", count: 10), toBytes: 5)
        XCTAssertEqual(cut, String(repeating: "и", count: 2))
        XCTAssertFalse(cut.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(LinkRouter.truncated("🇺🇦🇺🇦", toBytes: 9), "🇺🇦")
    }

    /// The extension decides which app opens the file, so the room comes out of
    /// the name and never out of it.
    func testTheExtensionSurvivesEvenWhenTheNameDoesNot() {
        let fitted = LinkRouter.fittedFilename(
            base: String(repeating: "и", count: 400), extension: "docx"
        )
        XCTAssertTrue(fitted.hasSuffix(".docx"))
        XCTAssertLessThanOrEqual(fitted.utf8.count, LinkRouter.maxFilenameBytes)
    }

    /// A server can put anything after the last dot. An "extension" with no room
    /// left for a name is not one, and must not yield a file with no name.
    func testAnAbsurdExtensionCannotProduceANamelessFile() {
        let fitted = LinkRouter.fittedFilename(
            base: "report", extension: String(repeating: "z", count: 400)
        )
        XCTAssertLessThanOrEqual(fitted.utf8.count, LinkRouter.maxFilenameBytes)
        XCTAssertFalse(fitted.isEmpty)
        XCTAssertTrue(fitted.hasPrefix("report"))
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
