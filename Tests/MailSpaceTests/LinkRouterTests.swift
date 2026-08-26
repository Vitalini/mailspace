import XCTest
@testable import MailSpace

final class LinkRouterTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    // MARK: - In-app classification

    func testGoogleHostsStayInApp() {
        for candidate in [
            "https://mail.google.com/mail/u/0/",
            "https://calendar.google.com/calendar/u/0/r",
            "https://accounts.google.com/ServiceLogin",
            "https://google.com",
            "https://www.google.co.uk/search",
            "https://drive.google.de/",
            "https://lh3.googleusercontent.com/avatar.png",
            "https://ssl.gstatic.com/ui/v1/icons/mail.png",
            "https://mail.googlemail.com/"
        ] {
            XCTAssertTrue(LinkRouter.isInApp(url(candidate)), "expected in-app: \(candidate)")
        }
    }

    func testNonGoogleHostsGoExternal() {
        for candidate in [
            "https://example.com/article",
            "https://www.youtube.com/watch?v=abc",
            "https://notgoogle.com/",
            "https://google.com.phishing.example/",
            "https://mygoogle.com/",
            "https://github.com/Vitalini/mailspace"
        ] {
            XCTAssertFalse(LinkRouter.isInApp(url(candidate)), "expected external: \(candidate)")
        }
    }

    func testNonWebSchemesAreNeverInApp() {
        XCTAssertFalse(LinkRouter.isInApp(url("mailto:someone@google.com")))
        XCTAssertFalse(LinkRouter.isInApp(url("tel:+15551234")))
        XCTAssertFalse(LinkRouter.isInApp(url("file:///etc/hosts")))
    }

    // MARK: - Routing decisions

    /// Google's sign-in SPA opens about:blank popups and iframes. Handing any
    /// of those to NSWorkspace makes macOS put up "There is no application set
    /// to open the URL about:blank".
    func testPageDrivenSchemesNeverLeaveTheApp() {
        for candidate in [
            "about:blank",
            "about:srcdoc",
            "blob:https://accounts.google.com/2b4f-1",
            "data:text/html,<p>hi</p>",
            "javascript:void(0)"
        ] {
            XCTAssertEqual(LinkRouter.destination(for: url(candidate)), .allowInApp, "must stay in-app: \(candidate)")
        }
    }

    func testHttpUrlWithoutAHostStaysInApp() {
        XCTAssertEqual(LinkRouter.destination(for: url("https:///relative")), .allowInApp)
    }

    func testGooglePagesStayInApp() {
        XCTAssertEqual(LinkRouter.destination(for: url("https://accounts.google.com/signin")), .allowInApp)
    }

    func testRealExternalPageGoesToTheBrowser() {
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://example.com/article")),
            .openExternally(url("https://example.com/article"))
        )
    }

    func testWrappedExternalLinkGoesToTheBrowserUnwrapped() {
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://www.google.com/url?q=https://example.com/x")),
            .openExternally(url("https://example.com/x"))
        )
    }

    /// A mailto: link must reach our own compose, never the system default mail
    /// app — which could be MailSpace itself.
    func testMailtoRoutesToOurOwnCompose() {
        XCTAssertEqual(
            LinkRouter.destination(for: url("mailto:a@b.com?subject=Hi")),
            .compose(url("mailto:a@b.com?subject=Hi"))
        )
    }

    func testOtherSystemSchemesStayInAppRatherThanPoppingADialog() {
        XCTAssertEqual(LinkRouter.destination(for: url("tel:+15551234")), .allowInApp)
        XCTAssertEqual(LinkRouter.destination(for: url("file:///etc/hosts")), .allowInApp)
    }

    // MARK: - Gmail's outbound redirect wrapper

    func testUnwrapsGmailRedirectToRealDestination() {
        let wrapped = url("https://www.google.com/url?q=https://example.com/article&source=gmail")
        XCTAssertEqual(LinkRouter.unwrapRedirect(wrapped).absoluteString, "https://example.com/article")
        XCTAssertFalse(LinkRouter.isInApp(LinkRouter.unwrapRedirect(wrapped)))
    }

    func testUnwrapsUrlParameterVariant() {
        let wrapped = url("https://www.google.com/url?url=https://example.com/&rct=j")
        XCTAssertEqual(LinkRouter.unwrapRedirect(wrapped).absoluteString, "https://example.com/")
    }

    func testUnwrapLeavesOrdinaryGoogleUrlsAlone() {
        let plain = url("https://mail.google.com/mail/u/0/#inbox")
        XCTAssertEqual(LinkRouter.unwrapRedirect(plain), plain)

        let noTarget = url("https://www.google.com/url?source=gmail")
        XCTAssertEqual(LinkRouter.unwrapRedirect(noTarget), noTarget)
    }

    func testUnwrappedGoogleDestinationStaysInApp() {
        let wrapped = url("https://www.google.com/url?q=https://calendar.google.com/calendar")
        XCTAssertTrue(LinkRouter.isInApp(LinkRouter.unwrapRedirect(wrapped)))
    }

    // MARK: - Download destinations

    func testUniqueDestinationUsesSuggestedNameWhenFree() throws {
        let directory = try makeTemporaryDirectory()
        let destination = LinkRouter.uniqueDestination(in: directory, filename: "report.pdf")
        XCTAssertEqual(destination.lastPathComponent, "report.pdf")
    }

    func testUniqueDestinationSuffixesOnCollision() throws {
        let directory = try makeTemporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("report.pdf"))
        XCTAssertEqual(
            LinkRouter.uniqueDestination(in: directory, filename: "report.pdf").lastPathComponent,
            "report (2).pdf"
        )

        try Data().write(to: directory.appendingPathComponent("report (2).pdf"))
        XCTAssertEqual(
            LinkRouter.uniqueDestination(in: directory, filename: "report.pdf").lastPathComponent,
            "report (3).pdf"
        )
    }

    func testUniqueDestinationHandlesExtensionlessAndEmptyNames() throws {
        let directory = try makeTemporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("LICENSE"))
        XCTAssertEqual(
            LinkRouter.uniqueDestination(in: directory, filename: "LICENSE").lastPathComponent,
            "LICENSE (2)"
        )
        XCTAssertEqual(
            LinkRouter.uniqueDestination(in: directory, filename: "").lastPathComponent,
            "download"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceDownloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
