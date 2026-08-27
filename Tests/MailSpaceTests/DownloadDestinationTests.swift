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
