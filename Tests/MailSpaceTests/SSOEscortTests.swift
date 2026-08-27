import XCTest
@testable import MailSpace

/// The carve-out that lets a Google sign-in finish through a customer's
/// identity provider, and lets nothing else off Google.
///
/// The two tests that matter are `testAttackerRedirectUriAfterAGenuineConsentPageIsNotAllowedInApp`
/// and `testWorkspaceSSOBounceThroughAForeignIdPStillCompletes`; everything
/// else here is one rule of the pass, isolated.
final class SSOEscortTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    /// Replays a chain the way `NavigationPolicy` does: `commit` for every page
    /// that renders, `navigate` for every main-frame navigation, each answering
    /// exactly what the app would answer.
    private struct Tab {
        var pass: SSOEscort.Pass?
        var now: Date

        mutating func commit(_ url: URL) {
            pass = SSOEscort.afterCommit(pass, of: url, now: now)
        }

        mutating func redirected() {
            pass = SSOEscort.refunding(pass)
        }

        /// The routing decision for a main-frame navigation to `url`.
        mutating func navigate(to url: URL) -> LinkRouter.Destination {
            var escorted = false
            if LinkRouter.needsEscort(for: url, isMainFrameTarget: true) {
                switch SSOEscort.authorize(pass, to: LinkRouter.unwrapRedirect(url), now: now) {
                case .allow(let updated):
                    pass = updated
                    escorted = true
                case .deny:
                    escorted = false
                }
            }
            return LinkRouter.destination(for: url, isMainFrameTarget: true, isSSOEscorted: escorted)
        }
    }

    // MARK: - The exploit

    /// THE regression. No bug in Google is needed: anyone can register an OAuth
    /// client in minutes with any https `redirect_uri`, then mail a link to
    /// Google's own authorization endpoint.
    ///
    /// The user sees a genuine Google consent screen at a genuine Google URL,
    /// presses Continue, and Google `302`s to the attacker. Under the old
    /// sticky flag that redirect landed *inside* the account's data store —
    /// with the injected message-handler surface, and, because MailSpace has no
    /// address bar, indistinguishable from Google. Worse, the attacker's page
    /// then kept the flag set, so it could drive the tab anywhere for ever.
    func testAttackerRedirectUriAfterAGenuineConsentPageIsNotAllowedInApp() {
        var tab = Tab(pass: nil, now: start)

        // 1. The mailed link. A real Google host, so it opens in the tab.
        let authorize = url(
            "https://accounts.google.com/o/oauth2/v2/auth"
                + "?client_id=ATTACKER&redirect_uri=https://evil.example/cb"
                + "&response_type=code&scope=email&prompt=consent"
        )
        XCTAssertEqual(tab.navigate(to: authorize), .allowInApp)

        // 2. Google's real consent page renders. It must not arm a pass: the
        //    whole purpose of this endpoint is to hand the browser to a
        //    redirect_uri a stranger chose.
        tab.commit(authorize)
        XCTAssertNil(tab.pass, "the authorization endpoint must not arm an escort")

        // 3. The user presses Continue and Google redirects to the attacker.
        let callback = url("https://evil.example/cb?code=4/0Ab")
        XCTAssertEqual(
            tab.navigate(to: callback),
            .openExternally(callback),
            "the attacker's redirect_uri must leave for the user's browser"
        )
    }

    /// The same chain with the session already expired, so the user really does
    /// sign in first — which under the old flag was the easier route in.
    func testASignInBeforeTheConsentPageDoesNotCarryAPassPastIt() {
        var tab = Tab(pass: nil, now: start)

        tab.commit(url("https://accounts.google.com/v3/signin/identifier?continue=…"))
        XCTAssertNotNil(tab.pass, "a real sign-in step arms a pass")

        // The consent page is a Google page that is not a sign-in step as far
        // as the escort is concerned, so it ends the chain.
        tab.commit(url("https://accounts.google.com/o/oauth2/v2/auth?client_id=ATTACKER&redirect_uri=https://evil.example/cb"))
        XCTAssertNil(tab.pass)

        let callback = url("https://evil.example/cb?code=4/0Ab")
        XCTAssertEqual(tab.navigate(to: callback), .openExternally(callback))
    }

    /// The aggravating variant needing no OAuth client at all: an expired
    /// session bounces Gmail to `accounts.google.com`, which arms a pass. The
    /// tab must not become "follow anything" for the window in which the user
    /// is most likely to click something.
    func testAnArmedPassStillSendsAnOrdinaryForeignPageToTheBrowserAfterItLands() {
        var tab = Tab(pass: nil, now: start)
        tab.commit(url("https://accounts.google.com/v3/signin/identifier"))

        // One foreign destination is what the pass is for.
        XCTAssertEqual(tab.navigate(to: url("https://idp.company.example/saml/sso")), .allowInApp)
        tab.commit(url("https://idp.company.example/saml/sso"))

        // That page cannot then take the tab anywhere else.
        let elsewhere = url("https://evil.example/landing")
        XCTAssertEqual(tab.navigate(to: elsewhere), .openExternally(elsewhere))
    }

    // MARK: - The case the carve-out exists for

    /// A real Workspace sign-in bouncing through the customer's identity
    /// provider and back to Google. The external browser cannot see this
    /// account's data store, so this has to complete in the tab.
    func testWorkspaceSSOBounceThroughAForeignIdPStillCompletes() {
        var tab = Tab(pass: nil, now: start)

        // Google's sign-in page renders and arms the pass.
        tab.commit(url("https://accounts.google.com/v3/signin/identifier?continue=https://mail.google.com/mail/u/0/"))
        XCTAssertNotNil(tab.pass)

        // The user types a Workspace address; Google redirects to the IdP,
        // through one intermediate hop.
        XCTAssertEqual(tab.navigate(to: url("https://idp.company.example/saml/sso?SAMLRequest=…")), .allowInApp)
        tab.redirected()
        XCTAssertEqual(tab.navigate(to: url("https://idp.company.example/auth/realms/company/login")), .allowInApp)
        tab.commit(url("https://idp.company.example/auth/realms/company/login"))

        // The IdP's own login form posts back to the IdP.
        XCTAssertEqual(tab.navigate(to: url("https://idp.company.example/auth/realms/company/authenticate")), .allowInApp)
        tab.commit(url("https://idp.company.example/auth/realms/company/authenticate"))

        // …which returns the assertion to Google. A Google host never needs a
        // pass, and committing there arms a fresh one for the rest of the chain.
        XCTAssertEqual(tab.navigate(to: url("https://accounts.google.com/a/company.example/acs")), .allowInApp)
        tab.commit(url("https://accounts.google.com/a/company.example/acs"))
        XCTAssertEqual(tab.pass?.spent, 0, "coming back to Google restarts the budget")
        XCTAssertNil(tab.pass?.landedHost, "and drops the host the chain was pinned to")

        // And lands on the inbox.
        XCTAssertEqual(tab.navigate(to: url("https://mail.google.com/mail/u/0/")), .allowInApp)
    }

    /// A second bounce out to the IdP, after Google has taken the assertion and
    /// asked for one more challenge, is a fresh pass and works the same way.
    func testTheChainMayLeaveGoogleAgainAfterComingBack() {
        var tab = Tab(pass: nil, now: start)
        tab.commit(url("https://accounts.google.com/v3/signin/identifier"))
        XCTAssertEqual(tab.navigate(to: url("https://idp.company.example/sso")), .allowInApp)
        tab.commit(url("https://idp.company.example/sso"))
        tab.commit(url("https://accounts.google.com/signin/challenge/totp"))

        XCTAssertEqual(tab.navigate(to: url("https://mfa.company.example/push")), .allowInApp)
    }

    /// Routing now sends Google's other products to the browser, so a page like
    /// a Drive preview is something an escort has a say over. A live pass covers
    /// it: the pass exists to let a sign-in finish, and stranding a chain that
    /// hops through a Google page is the worse failure. It is self-limiting —
    /// committing that page ends the chain, so exactly one such hop is possible
    /// and ordinary routing resumes immediately after.
    func testAGooglePageDuringASignInIsCoveredByThePassAndThenEndsIt() {
        var tab = Tab(pass: nil, now: start)
        tab.commit(url("https://accounts.google.com/v3/signin/identifier"))

        let drive = url("https://drive.google.com/file/d/abc/preview")
        XCTAssertEqual(tab.navigate(to: drive), .allowInApp)
        tab.commit(drive)
        XCTAssertNil(tab.pass, "an ordinary Google page ends the chain")

        XCTAssertEqual(tab.navigate(to: drive), .openExternally(drive), "and the browser owns it from then on")
    }

    /// With no sign-in in flight — the normal state of a signed-in tab — a
    /// Google product link leaves for the browser.
    func testWithoutAPassGoogleProductsGoToTheBrowser() {
        var tab = Tab(pass: nil, now: start)
        tab.commit(url("https://mail.google.com/mail/u/0/"))

        for candidate in [
            "https://meet.google.com/abc-defg-hij",
            "https://docs.google.com/document/d/1a2b/edit",
            "https://www.google.com/maps/place/Kyiv"
        ] {
            XCTAssertEqual(tab.navigate(to: url(candidate)), .openExternally(url(candidate)), "should leave: \(candidate)")
        }
    }

    // MARK: - Arming

    func testOnlyARealSignInStepArmsAPass() {
        for candidate in [
            "https://accounts.google.com/v3/signin/identifier",
            "https://accounts.google.com/signin/challenge/pwd",
            "https://accounts.google.com/o/saml2/idp?idpid=abc",
            "https://accounts.google.co.uk/ServiceLogin",
            "https://gds.google.com/web/challenge",
            "https://consent.google.com/m?continue=https://mail.google.com/"
        ] {
            XCTAssertTrue(SSOEscort.arms(url(candidate)), "should arm: \(candidate)")
        }
    }

    func testDelegatedAuthorizationEndpointsNeverArmAPass() {
        for candidate in [
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=x&redirect_uri=https://evil.example/cb",
            "https://accounts.google.com/o/oauth2/auth",
            "https://accounts.google.com/o/oauth2/postmessageRelay",
            "https://accounts.google.com/signin/oauth/consent?authuser=0",
            "https://accounts.google.com/signin/oauth/oauthchooseaccount",
            "https://signin.google.com/o/oauth2/auth"
        ] {
            XCTAssertTrue(SSOEscort.isDelegatedAuthorization(url(candidate)), "delegated: \(candidate)")
            XCTAssertFalse(SSOEscort.arms(url(candidate)), "must not arm: \(candidate)")
        }
    }

    func testOrdinaryPagesNeverArmAPass() {
        for candidate in [
            "https://mail.google.com/mail/u/0/",
            "https://www.google.com/gmail/about/",
            "https://idp.company.example/saml/sso",
            "https://accounts.google.com/signup/v2/webcreateaccount",
            "about:blank"
        ] {
            XCTAssertFalse(SSOEscort.arms(url(candidate)), "must not arm: \(candidate)")
        }
        XCTAssertFalse(SSOEscort.arms(nil))
    }

    // MARK: - Expiry

    func testAPassExpires() {
        let pass = SSOEscort.Pass(armedAt: start)
        let target = url("https://idp.company.example/sso")

        XCTAssertEqual(
            SSOEscort.authorize(pass, to: target, now: start.addingTimeInterval(SSOEscort.timeToLive - 1)),
            .allow(SSOEscort.Pass(armedAt: start, spent: 1))
        )
        XCTAssertEqual(
            SSOEscort.authorize(pass, to: target, now: start.addingTimeInterval(SSOEscort.timeToLive + 1)),
            .deny
        )
        // A clock that went backwards is not a licence either.
        XCTAssertEqual(SSOEscort.authorize(pass, to: target, now: start.addingTimeInterval(-60)), .deny)
    }

    func testAPassRunsOutOfDestinations() {
        var tab = Tab(pass: nil, now: start)
        tab.commit(url("https://accounts.google.com/v3/signin/identifier"))

        for hop in 1...SSOEscort.hopBudget {
            XCTAssertEqual(
                tab.navigate(to: url("https://idp.company.example/hop/\(hop)")),
                .allowInApp,
                "hop \(hop) is within budget"
            )
        }
        let overrun = url("https://idp.company.example/hop/over")
        XCTAssertEqual(tab.navigate(to: overrun), .openExternally(overrun))
    }

    /// A `302` inside a navigation the pass already paid for is that same
    /// navigation, so a long redirect chain must not exhaust the budget.
    func testServerRedirectsInsideOneNavigationAreRefunded() {
        var pass: SSOEscort.Pass? = SSOEscort.Pass(armedAt: start, spent: 3)
        pass = SSOEscort.refunding(pass)
        XCTAssertEqual(pass?.spent, 2)

        // And a refund never goes below zero, however many redirects arrive.
        pass = SSOEscort.Pass(armedAt: start)
        pass = SSOEscort.refunding(SSOEscort.refunding(pass))
        XCTAssertEqual(pass?.spent, 0)

        XCTAssertNil(SSOEscort.refunding(nil))
    }

    func testNoPassMeansNoEscort() {
        XCTAssertEqual(SSOEscort.authorize(nil, to: url("https://idp.company.example/sso"), now: start), .deny)
    }

    func testAHostlessTargetIsNeverEscorted() {
        XCTAssertEqual(
            SSOEscort.authorize(SSOEscort.Pass(armedAt: start), to: url("https:///relative"), now: start),
            .deny
        )
    }

    // MARK: - Commits

    func testAForeignCommitPinsThePassToThatHost() {
        var pass = SSOEscort.afterCommit(nil, of: url("https://accounts.google.com/v3/signin/identifier"), now: start)
        pass = SSOEscort.afterCommit(pass, of: url("https://idp.company.example/login"), now: start)
        XCTAssertEqual(pass?.landedHost, "idp.company.example")

        XCTAssertEqual(
            SSOEscort.authorize(pass, to: url("https://idp.company.example/authenticate"), now: start),
            .allow(SSOEscort.Pass(armedAt: start, spent: 1, landedHost: "idp.company.example"))
        )
        XCTAssertEqual(SSOEscort.authorize(pass, to: url("https://evil.example/next"), now: start), .deny)
    }

    /// A foreign page that never had a pass does not acquire one by rendering.
    func testAForeignCommitWithoutAPassStaysWithoutOne() {
        XCTAssertNil(SSOEscort.afterCommit(nil, of: url("https://evil.example/landing"), now: start))
    }

    func testAGooglePageThatIsNeitherSignInNorAppEndsTheChain() {
        let armed = SSOEscort.Pass(armedAt: start)
        for candidate in [
            "https://www.google.com/gmail/about/",
            "https://myaccount.google.com/security",
            "https://drive.google.com/file/d/abc/preview",
            "https://accounts.google.com/signup/v2/webcreateaccount",
            "https://ssl.gstatic.com/ui/v1/icons/mail.png"
        ] {
            XCTAssertNil(SSOEscort.afterCommit(armed, of: url(candidate), now: start), "should end: \(candidate)")
        }
    }

    /// An app surface is left alone here — `didFinish` there is what completes
    /// the sign-in, and completing it drops the pass.
    func testAppSurfacesLeaveThePassForDidFinish() {
        let armed = SSOEscort.Pass(armedAt: start)
        XCTAssertEqual(SSOEscort.afterCommit(armed, of: url("https://mail.google.com/mail/u/0/"), now: start), armed)
        XCTAssertEqual(
            SSOEscort.afterCommit(armed, of: url("https://calendar.google.com/calendar/u/0/r"), now: start),
            armed
        )
    }

    func testPageDrivenUrlsSayNothingEitherWay() {
        let armed = SSOEscort.Pass(armedAt: start, spent: 2)
        for candidate in ["about:blank", "blob:https://accounts.google.com/2b4f-1", "data:text/html,<p>hi</p>"] {
            XCTAssertEqual(SSOEscort.afterCommit(armed, of: url(candidate), now: start), armed, "should keep: \(candidate)")
        }
        XCTAssertEqual(SSOEscort.afterCommit(armed, of: nil, now: start), armed)
    }

    func testEachSignInCommitRearmsWithAFullBudget() {
        let spent = SSOEscort.Pass(armedAt: start, spent: 4, landedHost: "idp.company.example")
        let rearmed = SSOEscort.afterCommit(
            spent,
            of: url("https://accounts.google.com/signin/challenge/totp"),
            now: start.addingTimeInterval(300)
        )
        XCTAssertEqual(rearmed, SSOEscort.Pass(armedAt: start.addingTimeInterval(300)))
    }
}

// MARK: - Weak-keyed pass storage

final class WeakObjectMapTests: XCTestCase {
    private final class Probe {}

    func testStoresAndReadsByIdentity() {
        var map = WeakObjectMap<Probe, Int>()
        let first = Probe()
        let second = Probe()

        map[first] = 7
        XCTAssertEqual(map[first], 7)
        XCTAssertNil(map[second])
    }

    func testRemovalReportsWhatItHeld() {
        var map = WeakObjectMap<Probe, Int>()
        let probe = Probe()
        map[probe] = 7

        XCTAssertEqual(map.removeValue(forKey: probe), 7)
        XCTAssertNil(map.removeValue(forKey: probe))
        XCTAssertNil(map[probe])
    }

    func testAssigningNilRemoves() {
        var map = WeakObjectMap<Probe, Int>()
        let probe = Probe()
        map[probe] = 7
        map[probe] = nil
        XCTAssertNil(map[probe])
        XCTAssertEqual(map.count, 0)
    }

    /// A dead webview must not leave a live sign-in pass for whatever the
    /// allocator puts at that address next.
    func testReleasedKeysFallOut() {
        var map = WeakObjectMap<Probe, Int>()
        do {
            let temporary = Probe()
            map[temporary] = 7
            XCTAssertEqual(map.count, 1)
        }
        XCTAssertEqual(map.count, 0)

        let live = Probe()
        map[live] = 1
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map[live], 1)
    }
}
