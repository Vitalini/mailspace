import XCTest
@testable import MailSpace

/// Which frames may reach MailSpace's native script handlers.
///
/// Both handlers used to answer whichever frame asked, and the "only Google"
/// restriction lived in the injected JavaScript — which runs in the page and so
/// protects nothing. The autofill one handed back the account's plaintext
/// Google password.
final class LoginAutofillOriginTests: XCTestCase {
    private func trusted(
        scheme: String = "https",
        host: String = "accounts.google.com",
        port: Int = 0,
        isMainFrame: Bool = true
    ) -> Bool {
        LoginAutofill.isTrustedOrigin(scheme: scheme, host: host, port: port, isMainFrame: isMainFrame)
    }

    func testGoogleSignInTopFrameIsTrusted() {
        XCTAssertTrue(trusted())
        // WebKit reports 0 for a scheme's own default port; 443 spelled out is
        // the same origin.
        XCTAssertTrue(trusted(port: 443))
    }

    /// The attack: `lh3.googleusercontent.com` is allow-listed for in-app
    /// navigation, so "some Google-ish host" would be no bar at all.
    func testOtherGoogleHostsAreNotTrusted() {
        for host in [
            "lh3.googleusercontent.com",
            "mail.google.com",
            "calendar.google.com",
            "drive.google.com",
            "www.google.com",
            "accounts.google.co.uk",
            "myaccount.google.com"
        ] {
            XCTAssertFalse(trusted(host: host), "must not get the password: \(host)")
        }
    }

    func testLookalikeHostsAreNotTrusted() {
        for host in [
            "accounts.google.com.evil.example",
            "accounts.notgoogle.com",
            "accounts-google.com",
            "evil.accounts.google.com.example"
        ] {
            XCTAssertFalse(trusted(host: host), "must not get the password: \(host)")
        }
    }

    func testSubframesAreNeverTrusted() {
        XCTAssertFalse(trusted(isMainFrame: false))
    }

    func testNonHttpsAndOddPortsAreNotTrusted() {
        XCTAssertFalse(trusted(scheme: "http"))
        XCTAssertFalse(trusted(scheme: "data"))
        XCTAssertFalse(trusted(port: 8443))
    }

    func testHostAndSchemeComparisonsAreCaseInsensitive() {
        XCTAssertTrue(trusted(scheme: "HTTPS", host: "Accounts.Google.COM"))
    }
}

/// The notification shim's handler has to live in the page's own world — it
/// replaces `window.Notification`, which only works there — so the origin check
/// is the only thing between a third-party frame and native macOS banners
/// carrying the user's account name.
final class NotificationOriginTests: XCTestCase {
    private func trusted(
        scheme: String = "https",
        host: String,
        port: Int = 0,
        isMainFrame: Bool = true,
        view: AccountView
    ) -> Bool {
        NotificationOrigin.isTrusted(
            scheme: scheme, host: host, port: port, isMainFrame: isMainFrame, view: view
        )
    }

    func testGmailsOwnFrameMayNotifyTheMailView() {
        XCTAssertTrue(trusted(host: "mail.google.com", view: .mail))
        XCTAssertTrue(trusted(host: "mail.googlemail.com", view: .mail))
        XCTAssertTrue(trusted(host: "mail.google.com", port: 443, view: .mail))
    }

    func testCalendarsOwnFrameMayNotifyTheCalendarView() {
        XCTAssertTrue(trusted(host: "calendar.google.com", view: .calendar))
    }

    /// A view only accepts its own product's notifications, so a compromised
    /// Calendar page cannot post as Mail.
    func testViewsDoNotAcceptEachOthersOrigins() {
        XCTAssertFalse(trusted(host: "calendar.google.com", view: .mail))
        XCTAssertFalse(trusted(host: "mail.google.com", view: .calendar))
    }

    func testThirdPartyAndOtherGoogleFramesCannotNotify() {
        for host in [
            "doubleclick.net",
            "attacker.example",
            "lh3.googleusercontent.com",
            "drive.google.com",
            "www.google.com",
            "mail.google.com.evil.example"
        ] {
            XCTAssertFalse(trusted(host: host, view: .mail), "must not raise a banner: \(host)")
        }
    }

    func testSubframesAndNonHttpsCannotNotify() {
        XCTAssertFalse(trusted(host: "mail.google.com", isMainFrame: false, view: .mail))
        XCTAssertFalse(trusted(scheme: "http", host: "mail.google.com", view: .mail))
        XCTAssertFalse(trusted(host: "mail.google.com", port: 8080, view: .mail))
    }
}
