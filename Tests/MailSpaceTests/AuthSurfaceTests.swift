import XCTest
@testable import MailSpace

final class AuthSurfaceTests: XCTestCase {
    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "https://example.com")!
        }
        return url
    }

    // MARK: - Sign-in steps

    func testSignInChainIsRecognised() {
        for candidate in [
            "https://accounts.google.com/v3/signin/identifier?continue=https://mail.google.com/mail/u/0/",
            "https://accounts.google.com/signin/challenge/pwd",
            "https://accounts.google.com/signin/challenge/totp",
            "https://accounts.google.com/signin/oauth/consent",
            "https://accounts.google.com/AccountChooser",
            "https://accounts.google.com/CheckCookie",
            "https://accounts.google.co.uk/ServiceLogin",
            "https://accounts.youtube.com/accounts/SetSID",
            "https://gds.google.com/web/challenge",
            "https://signin.google.com/o/oauth2/auth"
        ] {
            XCTAssertEqual(AuthSurface.classify(url(candidate)), .signIn, "expected a sign-in step: \(candidate)")
        }
    }

    /// A look-alike host must never be read as Google's sign-in.
    func testLookalikeHostsAreNotSignIn() {
        for candidate in [
            "https://accounts.google.com.evil.example/signin",
            "https://accounts.notgoogle.com/signin",
            "https://myaccounts.google.example/"
        ] {
            XCTAssertNotEqual(AuthSurface.classify(url(candidate)), .signIn, "must not be a sign-in step: \(candidate)")
        }
    }

    // MARK: - App surfaces

    func testSignedInSurfacesMapToTheirView() {
        XCTAssertEqual(AuthSurface.classify(url("https://mail.google.com/mail/u/0/")), .app(.mail))
        XCTAssertEqual(AuthSurface.classify(url("https://mail.google.com/mail/u/0/#inbox")), .app(.mail))
        XCTAssertEqual(AuthSurface.classify(url("https://mail.google.com/mail")), .app(.mail))
        XCTAssertEqual(AuthSurface.classify(url("https://mail.googlemail.com/mail/u/0/")), .app(.mail))
        XCTAssertEqual(AuthSurface.classify(url("https://calendar.google.com/calendar/u/0/r")), .app(.calendar))
        XCTAssertEqual(AuthSurface.classify(url("https://calendar.google.com/calendar/r/week")), .app(.calendar))
    }

    /// Query strings never change what a page is — which is also why Gmail's
    /// print and compose popups need the provenance gate, not a URL rule.
    func testQueryStringsDoNotChangeTheClassification() {
        XCTAssertEqual(AuthSurface.classify(url("https://mail.google.com/mail/u/0/?view=cm&fs=1&tf=1")), .app(.mail))
        XCTAssertEqual(AuthSurface.classify(url("https://mail.google.com/mail/u/0/?ui=2&ik=abc&view=pt")), .app(.mail))
        XCTAssertEqual(AuthSurface.classify(url("https://mail.google.com/mail/u/0/?pli=1&authuser=0")), .app(.mail))
    }

    func testMarketingAndHelpPagesAreNotAppSurfaces() {
        for candidate in [
            "https://www.google.com/gmail/about/",
            "https://workspace.google.com/intl/en/gmail/",
            "https://mail.google.com/mail/about/",
            "https://mail.google.com/mail/help/intro.html",
            "https://calendar.google.com/calendar/about/",
            "https://mail.google.com/",
            "https://drive.google.com/drive/u/0/my-drive",
            "https://myaccount.google.com/security"
        ] {
            XCTAssertEqual(AuthSurface.classify(url(candidate)), .other, "expected other: \(candidate)")
        }
    }

    func testNonWebUrlsAreOther() {
        XCTAssertEqual(AuthSurface.classify(nil), .other)
        XCTAssertEqual(AuthSurface.classify(url("about:blank")), .other)
        XCTAssertEqual(AuthSurface.classify(url("blob:https://accounts.google.com/2b4f-1")), .other)
        XCTAssertEqual(AuthSurface.classify(url("data:text/html,<p>hi</p>")), .other)
        XCTAssertEqual(AuthSurface.classify(url("mailto:a@b.com")), .other)
    }

    func testIsSignedInIsPerView() {
        XCTAssertTrue(AuthSurface.isSignedIn(url("https://mail.google.com/mail/u/0/"), for: .mail))
        XCTAssertFalse(AuthSurface.isSignedIn(url("https://mail.google.com/mail/u/0/"), for: .calendar))
        XCTAssertFalse(AuthSurface.isSignedIn(url("https://www.google.com/gmail/about/"), for: .mail))
        XCTAssertFalse(AuthSurface.isSignedIn(nil, for: .mail))
    }

    // MARK: - New-window routing

    /// The reported bug: "Sign in" on the signed-out Gmail page must take over
    /// the tab instead of opening a window the tab never hears from again.
    func testClickedSignInFromASignedOutPageTakesOverTheOpener() {
        XCTAssertTrue(AuthSurface.shouldLoadInOpener(
            requested: url("https://accounts.google.com/ServiceLogin?service=mail"),
            openerURL: url("https://www.google.com/gmail/about/"),
            isLinkActivated: true
        ))
    }

    func testClickedSignInWorksFromAnUnloadedTabToo() {
        XCTAssertTrue(AuthSurface.shouldLoadInOpener(
            requested: url("https://accounts.google.com/ServiceLogin"),
            openerURL: nil,
            isLinkActivated: true
        ))
    }

    /// A scripted window.open keeps its window: its return value and the
    /// window.opener channel are part of the flow the page is running.
    func testScriptedWindowOpenStillGetsAPopup() {
        XCTAssertFalse(AuthSurface.shouldLoadInOpener(
            requested: url("https://accounts.google.com/signin/challenge/pwd"),
            openerURL: url("https://www.google.com/gmail/about/"),
            isLinkActivated: false
        ))
    }

    /// Anything opened from a signed-in surface is left alone — that page can
    /// hold an unsent draft.
    func testSignedInSurfacesAreNeverNavigatedAway() {
        XCTAssertFalse(AuthSurface.shouldLoadInOpener(
            requested: url("https://accounts.google.com/AddSession"),
            openerURL: url("https://mail.google.com/mail/u/0/#inbox"),
            isLinkActivated: true
        ))
        XCTAssertFalse(AuthSurface.shouldLoadInOpener(
            requested: url("https://accounts.google.com/SignOutOptions"),
            openerURL: url("https://calendar.google.com/calendar/u/0/r"),
            isLinkActivated: true
        ))
    }

    /// Gmail's own popups — print, compose, open-in-new-window, Drive previews
    /// — are not sign-in steps and must keep their windows.
    func testNonAuthPopupsAreUntouched() {
        for candidate in [
            "https://mail.google.com/mail/u/0/?view=cm&fs=1",
            "https://mail.google.com/mail/u/0/?ui=2&view=pt",
            "https://drive.google.com/file/d/abc/preview",
            "about:blank"
        ] {
            XCTAssertFalse(
                AuthSurface.shouldLoadInOpener(
                    requested: url(candidate),
                    openerURL: url("https://mail.google.com/mail/u/0/"),
                    isLinkActivated: true
                ),
                "must stay a popup: \(candidate)"
            )
        }
    }
}

// MARK: - Weak provenance set

final class WeakObjectSetTests: XCTestCase {
    private final class Probe {}

    func testHoldsMembershipByIdentity() {
        var set = WeakObjectSet<Probe>()
        let first = Probe()
        let second = Probe()

        set.insert(first)
        XCTAssertTrue(set.contains(first))
        XCTAssertFalse(set.contains(second))
    }

    /// The one-shot guard sign-in completion relies on: the first removal
    /// reports the object was there, the second does not.
    func testRemoveReportsMembershipOnlyOnce() {
        var set = WeakObjectSet<Probe>()
        let probe = Probe()
        set.insert(probe)

        XCTAssertTrue(set.remove(probe))
        XCTAssertFalse(set.remove(probe))
        XCTAssertFalse(set.contains(probe))
    }

    /// A released object must not leave provenance behind for whatever the
    /// allocator puts at that address next.
    func testReleasedObjectsFallOutOfTheSet() {
        var set = WeakObjectSet<Probe>()
        do {
            let temporary = Probe()
            set.insert(temporary)
            XCTAssertEqual(set.count, 1)
        }
        XCTAssertEqual(set.count, 0)

        // Inserting again prunes the dead entry rather than accumulating it.
        let live = Probe()
        set.insert(live)
        XCTAssertTrue(set.contains(live))
        XCTAssertEqual(set.count, 1)
    }
}
