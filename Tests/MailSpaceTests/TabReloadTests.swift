import XCTest
@testable import MailSpace

/// Reviving a webview: what "reload" actually means, and which webview ⌘R
/// means it for.
final class TabReloadTests: XCTestCase {
    private let mail = AccountView.mail.url

    // MARK: - What recovery does

    func testAWebViewWithAPageIsReloaded() {
        XCTAssertEqual(
            NavigationPolicy.recovery(currentURL: URL(string: "https://mail.google.com/mail/u/0/"), baseURL: mail),
            .reload
        )
    }

    /// The regression: `reload()` on a webview whose `url` is `nil` does
    /// nothing at all — and the tab that reaches the crash throttle before
    /// committing anything is exactly the tab whose `url` is `nil`. It came up
    /// blank, the one recovery it gets was consumed, and it stayed blank for
    /// the rest of the session.
    func testAWebViewThatNeverLoadedIsRenavigatedToItsOwnEntryPoint() {
        XCTAssertEqual(NavigationPolicy.recovery(currentURL: nil, baseURL: mail), .load(mail))
        XCTAssertEqual(
            NavigationPolicy.recovery(currentURL: nil, baseURL: AccountView.calendar.url),
            .load(AccountView.calendar.url)
        )
    }

    /// No page and nowhere to go. The caller must be able to tell, because the
    /// stall token is the tab's one way back and spending it here would throw
    /// that away.
    func testNoPageAndNoEntryPointIsImpossibleRatherThanANoOp() {
        XCTAssertEqual(NavigationPolicy.recovery(currentURL: nil, baseURL: nil), .impossible)
    }

    // MARK: - Which webview ⌘R acts on

    private final class Pane {}

    /// The reported bug: ⌘R with a Docs or print popup focused reloaded the
    /// main window instead, and the popup could not be reloaded at all.
    func testTheKeyWindowsOwnWebViewWins() {
        let popup = Pane()
        let tab = Pane()

        let target = NavigationPolicy.reloadTarget(keyWindowWebView: popup, selectedTab: (tab, mail))
        XCTAssertTrue(target?.webView === popup)
        // A popup has no entry point of its own to fall back to.
        XCTAssertNil(target?.baseURL)
    }

    func testTheMainWindowFallsBackToTheSelectedTab() {
        let tab = Pane()
        let target = NavigationPolicy.reloadTarget(keyWindowWebView: nil, selectedTab: (tab, mail))
        XCTAssertTrue(target?.webView === tab)
        XCTAssertEqual(target?.baseURL, mail)
    }

    func testNothingFocusedAndNothingSelectedIsANoOp() {
        XCTAssertNil(NavigationPolicy.reloadTarget(keyWindowWebView: Pane?.none, selectedTab: nil))
    }
}
