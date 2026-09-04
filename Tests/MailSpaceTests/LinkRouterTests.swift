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

    /// The three things MailSpace hosts: the account's own two surfaces, the
    /// sign-in chain that keeps them signed in, and the assets they load.
    func testOwnSurfacesSignInAndAssetsStayInApp() {
        for candidate in [
            // The surfaces themselves, and navigation inside them.
            "https://mail.google.com/mail/u/0/",
            "https://mail.google.com/mail/u/0/#inbox/FMfcgz",
            "https://mail.google.com/mail/u/0/#search/from%3Aboss",
            "https://mail.googlemail.com/mail/u/0/",
            "https://calendar.google.com/calendar/u/0/r",
            "https://calendar.google.com/calendar/u/0/r/day/2026/8/27",
            "https://calendar.google.com/calendar/u/0/r/eventedit/abc123",
            // The modal popups that are the mail UI in a second window, not a
            // destination: print preview, "show original", attachment view,
            // compose in a new window. All of them read the account's session,
            // which exists only in this app's data store.
            "https://mail.google.com/mail/u/0/?ui=2&ik=abc&view=pt&search=inbox",
            "https://mail.google.com/mail/u/0/?ui=2&ik=abc&view=om",
            "https://mail.google.com/mail/u/0/?ui=2&ik=abc&view=att&disp=safe",
            "https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1",
            // The sign-in chain. The browser cannot see this account's data
            // store, so sending any of this away strands the sign-in.
            "https://accounts.google.com/ServiceLogin",
            "https://accounts.google.com/v3/signin/identifier?continue=https://mail.google.com/mail/u/0/",
            "https://accounts.google.com/signin/challenge/totp",
            "https://accounts.google.co.uk/ServiceLogin",
            "https://gds.google.com/web/challenge",
            "https://consent.google.com/m?continue=https://mail.google.com/",
            "https://accounts.youtube.com/accounts/SetSID",
            // Payloads rather than pages: an attachment body, an inline image,
            // a stylesheet, an XHR endpoint.
            "https://mail-attachment.googleusercontent.com/attachment/u/0/?view=att",
            "https://lh3.googleusercontent.com/avatar.png",
            "https://ssl.gstatic.com/ui/v1/icons/mail.png",
            "https://www.googleapis.com/gmail/v1/users/me/messages",
            "https://mail.googlemail.com/"
        ] {
            XCTAssertTrue(LinkRouter.isInApp(url(candidate)), "expected in-app: \(candidate)")
        }
    }

    /// The complaint this rule exists for: a calendar event's links are mostly
    /// *Google* links, and "is Google, keep in-app" put every one of them in an
    /// in-app popup window with no address bar instead of the browser.
    func testOtherGoogleProductsGoToTheBrowser() {
        for candidate in [
            "https://meet.google.com/abc-defg-hij",
            "https://docs.google.com/document/d/1a2b3c/edit",
            "https://docs.google.com/spreadsheets/d/1a2b3c/edit#gid=0",
            "https://docs.google.com/presentation/d/1a2b3c/edit",
            "https://drive.google.com/file/d/1a2b3c/view",
            "https://drive.google.com/drive/folders/1a2b3c",
            "https://maps.google.com/?q=1600+Amphitheatre",
            "https://www.google.com/maps/place/Kyiv",
            "https://groups.google.com/g/team/c/thread",
            "https://mail.google.com/chat/u/0/#chat/home",
            "https://photos.google.com/share/abc",
            "https://keep.google.com/#NOTE/1a2b",
            "https://tasks.google.com/embed/list/~default",
            "https://www.youtube.com/watch?v=abc",
            "https://myaccount.google.com/security",
            "https://www.google.com/search?q=weather",
            "https://www.google.co.uk/search?q=weather",
            "https://drive.google.de/",
            "https://google.com",
            // Marketing and help pages on the surfaces' own hosts.
            "https://mail.google.com/mail/about/",
            "https://calendar.google.com/calendar/about/",
            "https://mail.google.com/mail/help/intro.html"
        ] {
            XCTAssertFalse(LinkRouter.isInApp(url(candidate)), "expected the browser: \(candidate)")
            XCTAssertEqual(
                LinkRouter.destination(for: url(candidate)),
                .openExternally(url(candidate)),
                "expected the browser: \(candidate)"
            )
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

    /// A look-alike must not become in-app by wearing an app surface's path, its
    /// host as user-info, or a suffix that is somebody else's domain.
    func testLookalikeSurfacesAreNeverInApp() {
        for candidate in [
            "https://mail.google.com.evil.example/mail/u/0/",
            "https://calendar.google.com.evil.example/calendar/u/0/r",
            "https://accounts.google.com.evil.example/signin",
            "https://notgoogle.com/mail/u/0/",
            "https://mail.notgoogle.com/mail/u/0/",
            // User-info: the host is evil.example, whatever precedes the @.
            "https://mail.google.com@evil.example/mail/u/0/",
            "https://accounts.google.com@evil.example/signin",
            "https://mail.google.ev.io/mail/u/0/",
            "https://accounts.google.ev.io/signin",
            "https://mail.googleusercontent.com.evil.example/attachment"
        ] {
            XCTAssertFalse(LinkRouter.isInApp(url(candidate)), "must not be in-app: \(candidate)")
            XCTAssertEqual(
                LinkRouter.destination(for: url(candidate)),
                .openExternally(url(candidate)),
                "must go to the browser: \(candidate)"
            )
        }
    }

    /// The broad "is the tab still on Google" test the sign-in provenance and
    /// the SSO escort turn on. Deliberately wider than `isInApp`.
    func testGooglePropertyIsBroaderThanInApp() {
        for candidate in [
            "https://drive.google.com/file/d/abc/preview",
            "https://myaccount.google.com/security",
            "https://www.google.com/gmail/about/",
            "https://mail.google.com/mail/u/0/",
            "https://ssl.gstatic.com/ui/v1/icons/mail.png"
        ] {
            XCTAssertTrue(LinkRouter.isGoogleProperty(url(candidate)), "expected a Google page: \(candidate)")
        }
        for candidate in [
            "https://idp.company.example/saml/sso",
            "https://notgoogle.com/",
            "https://google.com.evil.example/",
            "https://www.youtube.com/watch?v=abc",
            "about:blank"
        ] {
            XCTAssertFalse(LinkRouter.isGoogleProperty(url(candidate)), "must not be a Google page: \(candidate)")
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

    /// The wrapper is what a calendar event's links actually look like, and the
    /// destination behind it is usually Google's. It leaves too — unwrapped, so
    /// the browser gets the real page rather than a redirect through Google.
    func testWrappedGoogleProductLinkGoesToTheBrowserUnwrapped() {
        for (wrapped, destination) in [
            ("https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&source=calendar",
             "https://meet.google.com/abc-defg-hij"),
            ("https://www.google.com/url?q=https://docs.google.com/document/d/1a2b/edit",
             "https://docs.google.com/document/d/1a2b/edit"),
            ("https://www.google.com/url?q=https://www.google.com/maps/place/Kyiv",
             "https://www.google.com/maps/place/Kyiv")
        ] {
            XCTAssertEqual(
                LinkRouter.destination(for: url(wrapped)),
                .openExternally(url(destination)),
                "expected the browser, unwrapped: \(wrapped)"
            )
        }
    }

    /// …while a wrapper around the app's own surface still stays: that is the
    /// account's own mail or calendar, wherever the link came from.
    func testWrappedOwnSurfaceStaysInApp() {
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://www.google.com/url?q=https://calendar.google.com/calendar/u/0/r")),
            .allowInApp
        )
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://www.google.com/url?q=https://accounts.google.com/ServiceLogin")),
            .allowInApp
        )
    }

    /// In-page navigation on either surface never leaves, whatever drove it.
    func testInPageNavigationOnTheSurfacesStaysInApp() {
        for candidate in [
            "https://mail.google.com/mail/u/0/#inbox",
            "https://mail.google.com/mail/u/0/#sent",
            "https://calendar.google.com/calendar/u/0/r/month",
            "https://calendar.google.com/calendar/u/0/r/eventedit"
        ] {
            for isMainFrame in [true, false] {
                XCTAssertEqual(
                    LinkRouter.destination(for: url(candidate), isMainFrameTarget: isMainFrame, isSSOEscorted: false),
                    .allowInApp,
                    "must stay in-app: \(candidate)"
                )
            }
        }
    }

    /// A Google product opened in the main frame or as a new window leaves; the
    /// same URL as a subframe stays, or every embed would open a window.
    func testGoogleProductLeavesTheMainFrameButNotASubframe() {
        let meet = url("https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(
            LinkRouter.destination(for: meet, isMainFrameTarget: true, isSSOEscorted: false),
            .openExternally(meet)
        )
        XCTAssertEqual(
            LinkRouter.destination(for: meet, isMainFrameTarget: false, isSSOEscorted: false),
            .allowInApp
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
        XCTAssertEqual(LinkRouter.destination(for: url("sms:+15551234")), .allowInApp)
    }

    // MARK: - What a scheme may do to a frame

    /// The schemes the page legitimately drives itself. Every one of these is
    /// load-bearing: the sign-in SPA opens `about:blank` popups and iframes,
    /// the download path is built on `blob:`, and refusing any of them here
    /// would take popups or downloads with it.
    ///
    /// Checked in both frame positions, because the frame only ever decides the
    /// external hand-off — never whether a scheme may navigate at all.
    func testThePageDrivenSchemesStillNavigateEitherFrame() {
        for candidate in [
            "about:blank",
            "about:srcdoc",
            "blob:https://mail.google.com/9b1deb4d-0000-0000-0000-000000000000",
            "data:text/html,<b>x</b>",
            "javascript:void(0)"
        ] {
            for isMainFrame in [true, false] {
                XCTAssertEqual(
                    LinkRouter.destination(for: url(candidate), isMainFrameTarget: isMainFrame, isSSOEscorted: false),
                    .allowInApp,
                    "must still navigate: \(candidate) mainFrame=\(isMainFrame)"
                )
            }
        }
    }

    /// A `file:` URL never takes over a frame, in either position.
    ///
    /// Nobody links to one. It arrives because WebKit's drag controller falls
    /// back to *loading* a dropped file when no part of the page accepts the
    /// drop — a main-frame navigation, `navigationType == .other` — and
    /// allowing it replaced the inbox with whatever was dragged onto it.
    /// WebKit's own cross-scheme protection does not stop this: the load comes
    /// from the drag controller rather than from script, so an `https` page is
    /// no safer than any other.
    func testADroppedFileNeverNavigatesAFrame() {
        for candidate in [
            "file:///etc/hosts",
            "file:///Users/someone/Desktop/quarterly.pdf",
            "file:///Users/someone/Desktop/a%20file%20with%20spaces.png",
            "file://localhost/etc/hosts",
            "file:///"
        ] {
            for isMainFrame in [true, false] {
                XCTAssertEqual(
                    LinkRouter.destination(for: url(candidate), isMainFrameTarget: isMainFrame, isSSOEscorted: false),
                    .refuse,
                    "must be refused: \(candidate) mainFrame=\(isMainFrame)"
                )
            }
        }
    }

    /// The scheme is read case-insensitively, like every other scheme test
    /// here — `FILE:` is the same scheme.
    func testFileSchemeIsRefusedWhateverItsCase() {
        XCTAssertEqual(LinkRouter.destination(for: url("FILE:///etc/hosts")), .refuse)
        XCTAssertEqual(LinkRouter.destination(for: url("File:///etc/hosts")), .refuse)
    }

    /// A refusal is not an escort's business: no `SSOEscort` pass, and no
    /// redirect wrapper, can turn a local file into something that may load.
    func testNoEscortOrRedirectWrapperCanLetAFileLoad() {
        let file = url("file:///etc/hosts")
        XCTAssertEqual(
            LinkRouter.destination(for: file, isMainFrameTarget: true, isSSOEscorted: true),
            .refuse
        )
        XCTAssertFalse(LinkRouter.needsEscort(for: file, isMainFrameTarget: true))
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://www.google.com/url?q=file:///etc/hosts")),
            .refuse
        )
    }

    /// The two surfaces and the browser hand-off are untouched by the scheme
    /// guard: it sits in front of the http(s) path, not inside it.
    func testTheWebSchemesAreUnaffected() {
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://mail.google.com/mail/u/0/#inbox")),
            .allowInApp
        )
        XCTAssertEqual(
            LinkRouter.destination(for: url("https://example.com/article")),
            .openExternally(url("https://example.com/article"))
        )
        XCTAssertEqual(
            LinkRouter.destination(for: url("mailto:a@b.com")),
            .compose(url("mailto:a@b.com"))
        )
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

    // MARK: - Which Google account the browser should use

    /// The browser resolves a Google link against whichever account it is
    /// signed into, which need not be the one the mail arrived in. The link
    /// says which account it wants.
    func testGoogleLinksCarryTheAccountToTheBrowser() {
        XCTAssertEqual(
            LinkRouter.forBrowser(url("https://docs.google.com/document/d/1a2b/edit"), accountEmail: "me@example.com"),
            url("https://docs.google.com/document/d/1a2b/edit?authuser=me@example.com")
        )
        // An existing query and a fragment both survive.
        XCTAssertEqual(
            LinkRouter.forBrowser(url("https://meet.google.com/abc-defg-hij?hs=1"), accountEmail: "me@example.com"),
            url("https://meet.google.com/abc-defg-hij?hs=1&authuser=me@example.com")
        )
        XCTAssertEqual(
            LinkRouter.forBrowser(
                url("https://docs.google.com/spreadsheets/d/1a2b/edit#gid=0"),
                accountEmail: "me@example.com"
            ),
            url("https://docs.google.com/spreadsheets/d/1a2b/edit?authuser=me@example.com#gid=0")
        )
    }

    /// `+` is a legal query character, so an untouched address would reach
    /// Google as a space.
    func testTheAddressIsPercentEncoded() {
        XCTAssertEqual(
            LinkRouter.forBrowser(url("https://drive.google.com/drive/my-drive"), accountEmail: "a+tag@example.com"),
            url("https://drive.google.com/drive/my-drive?authuser=a%2Btag@example.com")
        )
    }

    /// A link that already names an account keeps what it says — Google's own
    /// `authuser=` and `/u/N/` are better information than ours.
    func testLinksThatAlreadyNameAnAccountAreLeftAlone() {
        for candidate in [
            "https://docs.google.com/document/d/1a2b/edit?authuser=1",
            "https://docs.google.com/document/d/1a2b/edit?AuthUser=me@example.com",
            "https://drive.google.com/drive/u/1/my-drive",
            "https://docs.google.com/document/u/2/d/1a2b/edit",
            "https://mail.google.com/mail/u/0/"
        ] {
            XCTAssertEqual(
                LinkRouter.forBrowser(url(candidate), accountEmail: "me@example.com"),
                url(candidate),
                "must be left alone: \(candidate)"
            )
        }
    }

    /// The address is the user's. It goes to a Google *product* or nowhere.
    ///
    /// "A Google host" was the wrong test and is not the one any more.
    /// `isGoogleProperty` is host-shape only, so every `*.google.com` name
    /// passed it — including the ones that serve third-party code.
    /// `script.google.com` is the concrete case: anybody can deploy an Apps
    /// Script web app that anyone can access, mail or calendar-invite the
    /// link, and read `e.parameter.authuser` server-side in `doGet`. Clicking
    /// it told the attacker exactly which MailSpace account opened his link —
    /// a fact the click would not otherwise have carried.
    /// `sites.google.com` is the same shape through an embedded gadget.
    func testTheAddressNeverTravelsToANonGoogleHost() {
        for candidate in [
            "https://example.com/article",
            "https://google.com.evil.example/document",
            "https://notgoogle.com/",
            "https://google.ev.io/document",
            "https://docs.google.com@evil.example/document",
            "https://www.youtube.com/watch?v=abc",
            // Google hosts that serve somebody else's code.
            "https://script.google.com/macros/s/AKfycb/exec",
            "https://sites.google.com/view/someones-page",
            "https://script.googleusercontent.com/macros/echo"
        ] {
            XCTAssertEqual(
                LinkRouter.forBrowser(url(candidate), accountEmail: "me@example.com"),
                url(candidate),
                "must not carry the address: \(candidate)"
            )
        }
    }

    /// And the products it is actually for still get it — the allowlist is a
    /// tightening, not a removal.
    func testTheProductHostsStillCarryTheAddress() {
        for candidate in [
            "https://docs.google.com/document/d/1a2b/edit",
            "https://drive.google.com/drive/my-drive",
            "https://meet.google.com/abc-defg-hij",
            "https://calendar.google.com/calendar/r/eventedit",
            "https://groups.google.com/g/some-group",
            "https://keep.google.com/",
            "https://photos.google.com/",
            "https://chat.google.com/",
            "https://contacts.google.com/",
            "https://tasks.google.com/"
        ] {
            XCTAssertEqual(
                LinkRouter.forBrowser(url(candidate), accountEmail: "me@example.com").query,
                "authuser=me@example.com",
                "must resolve to the right identity: \(candidate)"
            )
        }
    }

    func testNoAccountMeansNoTagging() {
        let target = url("https://docs.google.com/document/d/1a2b/edit")
        XCTAssertEqual(LinkRouter.forBrowser(target, accountEmail: nil), target)
        XCTAssertEqual(LinkRouter.forBrowser(target, accountEmail: ""), target)
        XCTAssertEqual(LinkRouter.forBrowser(target, accountEmail: "   "), target)
    }

    // MARK: - The window a popup leaves behind

    /// `window.open()` then `location = …`: WebKit asks for the window before
    /// the page says where it is going, so a link that belongs in the browser
    /// leaves an empty window behind unless it is closed.
    func testAnEmptyPopupIsClosedWhenItsLinkGoesToTheBrowser() {
        XCTAssertTrue(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true,
            hasShownAPage: false,
            isMainFrameTarget: true
        ))
        // A popup showing print preview or an attachment keeps its window.
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true,
            hasShownAPage: true,
            isMainFrameTarget: true
        ))
        // A subframe inside a popup is not the popup's reason to exist.
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: true,
            hasShownAPage: false,
            isMainFrameTarget: false
        ))
        // And a tab is never closed by a link leaving.
        XCTAssertFalse(NavigationPolicy.shouldCloseEmptyPopup(
            isPopup: false,
            hasShownAPage: false,
            isMainFrameTarget: true
        ))
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

    // MARK: - Attachments are downloads, not destinations

    /// The routing half of "I click and nothing". v1.1.0 correctly stopped
    /// keeping every Google host in-app — but a Gmail attachment is not always
    /// served from `mail.google.com` or `googleusercontent.com`. A
    /// Drive-hosted or large attachment comes from these, and they fell through
    /// to a background Chrome tab that cannot fetch them: the session lives
    /// only in this app's data store.
    func testTheEndpointsAnAttachmentIsServedFromAreDownloads() {
        for candidate in [
            "https://drive.usercontent.google.com/download?id=abc&export=download",
            "https://drive.usercontent.google.com/uc?id=abc",
            "https://drive.google.com/uc?export=download&id=abc",
            "https://drive.google.com/u/0/uc?id=abc&export=download",
            "https://docs.google.com/document/d/abc/export?format=pdf",
            "https://docs.google.com/spreadsheets/d/abc/export?format=xlsx",
            "https://chat.google.com/api/get_attachment_url?url_type=DOWNLOAD_URL"
        ] {
            XCTAssertEqual(
                LinkRouter.destination(for: url(candidate)),
                .download(url(candidate)),
                "should download: \(candidate)"
            )
        }
    }

    /// And the rule is not "Drive stays": the pages around those endpoints are
    /// still the browser's, exactly as v1.1.0 made them.
    func testThePagesAroundThoseEndpointsStillLeave() {
        for candidate in [
            "https://drive.google.com/file/d/abc/view",
            "https://drive.google.com/drive/my-drive",
            "https://docs.google.com/document/d/abc/edit",
            "https://chat.google.com/room/abc",
            "https://meet.google.com/abc-defg-hij",
            // A look-alike must never be read as a Google download endpoint.
            "https://drive.usercontent.google.com.evil.example/download?export=download",
            "https://notgoogle.com/uc?export=download"
        ] {
            XCTAssertEqual(
                LinkRouter.destination(for: url(candidate)),
                .openExternally(url(candidate)),
                "should leave: \(candidate)"
            )
        }
    }

    /// The attachments that never broke, and must not start: Gmail serves these
    /// itself, in-app, on the account's own session.
    func testGmailsOwnAttachmentSurfacesAreUnchanged() {
        for candidate in [
            "https://mail.google.com/mail/u/0/?ui=2&ik=abc&view=att&disp=attd&attid=0.1",
            "https://mail.google.com/mail/u/0/?ui=2&view=att&disp=inline",
            "https://mail-attachment.googleusercontent.com/attachment/u/0/?view=att&disp=attd"
        ] {
            XCTAssertEqual(
                LinkRouter.destination(for: url(candidate)),
                .allowInApp,
                "should stay in-app: \(candidate)"
            )
        }
    }

    /// A download is a download whatever frame asked for it — an attachment
    /// fetched by a hidden frame is the shape Gmail actually uses.
    func testAFrameCannotTurnADownloadIntoAPage() {
        let attachment = url("https://drive.usercontent.google.com/download?id=abc&export=download")
        for isMainFrame in [true, false] {
            XCTAssertEqual(
                LinkRouter.destination(for: attachment, isMainFrameTarget: isMainFrame, isSSOEscorted: false),
                .download(attachment)
            )
        }
    }

    /// A download never spends a sign-in escort pass: it is not a page leaving
    /// Google, and the budget belongs to a real sign-in.
    func testADownloadNeedsNoEscort() {
        XCTAssertFalse(LinkRouter.needsEscort(
            for: url("https://drive.usercontent.google.com/download?id=abc"),
            isMainFrameTarget: true
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceDownloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
