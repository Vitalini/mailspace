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

    /// The regression: `hasSuffix("google.com")` has no dot boundary, so a
    /// look-alike domain's `/url?q=` unwrapped to a Google target — and since
    /// the webview then navigates to the *original* URL, the look-alike loaded
    /// inside the account's session, cookies and injected handlers included.
    func testUnwrapIgnoresLookalikeHosts() {
        for candidate in [
            "https://notgoogle.com/url?q=https://mail.google.com/mail/u/0/",
            "https://mygoogle.com/url?q=https://mail.google.com/mail/u/0/",
            "https://google.com.evil.example/url?q=https://mail.google.com/mail/u/0/",
            "https://evilgooglemail.com/url?q=https://mail.google.com/mail/u/0/"
        ] {
            let wrapped = url(candidate)
            XCTAssertEqual(LinkRouter.unwrapRedirect(wrapped), wrapped, "must not unwrap: \(candidate)")
            XCTAssertEqual(
                LinkRouter.destination(for: wrapped),
                .openExternally(wrapped),
                "must go to the browser as itself: \(candidate)"
            )
        }
    }

    /// …while Gmail's own wrapper, on a real Google host, still unwraps.
    func testUnwrapStillWorksForRealGoogleHosts() {
        for host in ["www.google.com", "google.com", "www.google.co.uk", "mail.googlemail.com"] {
            let wrapped = url("https://\(host)/url?q=https://example.com/x")
            XCTAssertEqual(
                LinkRouter.unwrapRedirect(wrapped).absoluteString,
                "https://example.com/x",
                "must unwrap: \(host)"
            )
        }
    }

    func testHostMatchingRequiresADotBoundary() {
        XCTAssertTrue(LinkRouter.matches(host: "google.com", domain: "google.com"))
        XCTAssertTrue(LinkRouter.matches(host: "mail.google.com", domain: "google.com"))
        XCTAssertFalse(LinkRouter.matches(host: "notgoogle.com", domain: "google.com"))
        XCTAssertFalse(LinkRouter.matches(host: "google.com.evil.example", domain: "google.com"))
    }

    // MARK: - What counts as a Google domain

    func testGoogleDomainAcceptsGoogleAndItsCountryVariants() {
        for host in [
            "google.com",
            "www.google.com",
            "mail.google.com",
            "accounts.google.com",
            "google.de",
            "google.co",
            "drive.google.de",
            "google.co.uk",
            "accounts.google.co.uk",
            "google.com.au",
            "www.google.com.br",
            // A fully-qualified name carries the root dot and is the same host.
            "mail.google.com."
        ] {
            XCTAssertTrue(LinkRouter.isGoogleDomain(host), "expected a Google domain: \(host)")
        }
    }

    /// The regression: the suffix test was "up to six letters and dots", which
    /// is not "a Google country variant" — it is "anything short". Anyone who
    /// owns `ev.io` can serve `google.ev.io`, and MailSpace loaded it inside
    /// the account's session.
    func testGoogleDomainRejectsShortSuffixesThatAreSomebodyElsesDomain() {
        for host in [
            "google.ev.io",
            "google.hax.io",
            "google.a.io",
            "accounts.google.ev.io",
            "google.b.co",
            "google.x.y.z"
        ] {
            XCTAssertFalse(LinkRouter.isGoogleDomain(host), "must not be a Google domain: \(host)")
            XCTAssertFalse(LinkRouter.isInApp(url("https://\(host)/signin")), "must not be in-app: \(host)")
            XCTAssertNotEqual(
                AuthSurface.classify(url("https://\(host)/signin")),
                .signIn,
                "must not be a sign-in host: \(host)"
            )
        }
    }

    func testGoogleDomainStillRejectsLookalikes() {
        for host in [
            "notgoogle.com",
            "mygoogle.com",
            "google.com.evil.example",
            "google.com.phishing.example",
            "googleusercontent.com.evil.example",
            "google.info",
            "google.evil.co"
        ] {
            XCTAssertFalse(LinkRouter.isGoogleDomain(host), "must not be a Google domain: \(host)")
        }
    }

    // MARK: - Which navigations an SSO escort has any say over

    func testOnlyForeignMainFrameNavigationsNeedAnEscort() {
        XCTAssertTrue(LinkRouter.needsEscort(for: url("https://idp.company.example/saml"), isMainFrameTarget: true))
        // Already staying in-app on its own merits: a pass must not be spent.
        XCTAssertFalse(LinkRouter.needsEscort(for: url("https://mail.google.com/mail/u/0/"), isMainFrameTarget: true))
        XCTAssertFalse(LinkRouter.needsEscort(for: url("about:blank"), isMainFrameTarget: true))
        XCTAssertFalse(LinkRouter.needsEscort(for: url("mailto:a@b.com"), isMainFrameTarget: true))
        // A subframe cannot navigate the page the user is looking at.
        XCTAssertFalse(LinkRouter.needsEscort(for: url("https://doubleclick.net/ad"), isMainFrameTarget: false))
    }

    // MARK: - Frame-aware routing

    /// The regression: only `.linkActivated` navigations left for the browser,
    /// so a 302, a `window.location =` or a form POST rendered an arbitrary
    /// site inside the account's cookie jar. The frame decides now, not the
    /// navigation type.
    func testForeignMainFrameNavigationLeavesWhateverDroveIt() {
        XCTAssertEqual(
            LinkRouter.destination(
                for: url("https://attacker.example/landing"),
                isMainFrameTarget: true,
                isSSOEscorted: false
            ),
            .openExternally(url("https://attacker.example/landing"))
        )
    }

    /// A new window (`targetFrame == nil`, passed as a main-frame target) is a
    /// whole page too.
    func testForeignNewWindowLeaves() {
        XCTAssertEqual(
            LinkRouter.destination(
                for: url("https://www.google.com/url?q=https://attacker.example/"),
                isMainFrameTarget: true,
                isSSOEscorted: false
            ),
            .openExternally(url("https://attacker.example/"))
        )
    }

    /// Gmail and Calendar embed foreign subframes — ads, maps, tracked images.
    /// Those must stay in the page, or every embed opens a browser window.
    func testForeignSubframesStayInPage() {
        XCTAssertEqual(
            LinkRouter.destination(
                for: url("https://doubleclick.net/ad?id=1"),
                isMainFrameTarget: false,
                isSSOEscorted: false
            ),
            .allowInApp
        )
    }

    /// A Workspace account signs in through its own identity provider, on a
    /// host MailSpace has never heard of. Booting that to the browser would
    /// leave the sign-in unfinishable — the browser cannot see this account's
    /// data store. Whether a pass exists at all is `SSOEscort`'s decision.
    func testForeignHostStaysInAppWhileEscorted() {
        XCTAssertEqual(
            LinkRouter.destination(
                for: url("https://idp.company.example/saml/sso"),
                isMainFrameTarget: true,
                isSSOEscorted: true
            ),
            .allowInApp
        )
    }

    func testGoogleHostsAndMailtoAreUnaffectedByTheFrameRules() {
        for isMainFrame in [true, false] {
            XCTAssertEqual(
                LinkRouter.destination(
                    for: url("https://mail.google.com/mail/u/0/"),
                    isMainFrameTarget: isMainFrame,
                    isSSOEscorted: false
                ),
                .allowInApp
            )
            // A mailto: still composes wherever it was clicked.
            XCTAssertEqual(
                LinkRouter.destination(
                    for: url("mailto:a@b.com"),
                    isMainFrameTarget: isMainFrame,
                    isSSOEscorted: false
                ),
                .compose(url("mailto:a@b.com"))
            )
            // And a page-driven scheme never reaches NSWorkspace.
            XCTAssertEqual(
                LinkRouter.destination(
                    for: url("about:blank"),
                    isMainFrameTarget: isMainFrame,
                    isSSOEscorted: true
                ),
                .allowInApp
            )
        }
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

    /// `suggestedFilename` is whatever the server's `Content-Disposition` said.
    /// A path in it used to resolve straight out of ~/Downloads, and the
    /// collision loop never caught it because the escaped path was new.
    func testSuggestedFilenameCannotEscapeTheDownloadDirectory() throws {
        let directory = try makeTemporaryDirectory()
        for hostile in [
            "../../Library/LaunchAgents/x.plist",
            "../x.plist",
            "/etc/cron.d/x",
            "/../../x",
            "subdir/x.plist",
            "..",
            ".",
            "/",
            "",
            "   "
        ] {
            let destination = LinkRouter.uniqueDestination(in: directory, filename: hostile)
            XCTAssertEqual(
                destination.deletingLastPathComponent().standardizedFileURL,
                directory.standardizedFileURL,
                "escaped ~/Downloads with: \(hostile)"
            )
            XCTAssertFalse(destination.lastPathComponent.contains("/"), "kept a separator: \(hostile)")
        }
    }

    func testSafeFilenameKeepsTheLastComponentAndFallsBackSensibly() {
        XCTAssertEqual(LinkRouter.safeFilename("report.pdf"), "report.pdf")
        XCTAssertEqual(LinkRouter.safeFilename("../../Library/LaunchAgents/x.plist"), "x.plist")
        XCTAssertEqual(LinkRouter.safeFilename("/etc/hosts"), "hosts")
        XCTAssertEqual(LinkRouter.safeFilename("  spaced.txt  "), "spaced.txt")
        for empty in ["", "   ", ".", "..", "...", "/"] {
            XCTAssertEqual(LinkRouter.safeFilename(empty), "download", "expected the fallback for: \(empty)")
        }
    }

    /// A traversing name still collides properly once it has been reduced.
    func testSanitizedNameStillGetsTheCollisionSuffix() throws {
        let directory = try makeTemporaryDirectory()
        try Data().write(to: directory.appendingPathComponent("x.plist"))
        XCTAssertEqual(
            LinkRouter.uniqueDestination(in: directory, filename: "../../x.plist").lastPathComponent,
            "x (2).plist"
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
