import WebKit
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

    // MARK: - Where "Reload Tab" sends the rebuilt webview

    private let calendar = AccountView.calendar.url
    private let thread = URL(string: "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWDsKmGpLnBvTcRhNwZfPqSx")!

    /// A previous load failed: its aim is where the user was trying to go.
    func testAnOutstandingTargetWinsOverTheCurrentPage() {
        let failed = URL(string: "https://mail.google.com/mail/u/0/#label/Work")!
        XCTAssertEqual(TabRecycler.rebuildURL(view: .mail, outstanding: failed, current: thread), failed)
    }

    /// The open thread survives the rebuild.
    func testTheTabsOwnPageIsKept() {
        XCTAssertEqual(TabRecycler.rebuildURL(view: .mail, outstanding: nil, current: thread), thread)
    }

    /// A process that died before committing anything has no page.
    func testNoPageFallsBackToTheEntryPoint() {
        XCTAssertEqual(TabRecycler.rebuildURL(view: .mail, outstanding: nil, current: nil), mail)
        XCTAssertEqual(TabRecycler.rebuildURL(view: .calendar, outstanding: nil, current: nil), calendar)
    }

    func testABlankPageFallsBackToTheEntryPoint() {
        XCTAssertEqual(
            TabRecycler.rebuildURL(view: .mail, outstanding: nil, current: URL(string: "about:blank")),
            mail
        )
    }

    /// A fresh webview has no SSO escort: a sign-in or customer SSO page would
    /// be sent to the browser and leave the tab blank.
    func testSignInAndForeignPagesFallBackToTheEntryPoint() {
        let signIn = URL(string: "https://accounts.google.com/v3/signin/identifier?continue=x")!
        let sso = URL(string: "https://sso.example.com/saml2/idp/login")!
        XCTAssertEqual(TabRecycler.rebuildURL(view: .mail, outstanding: nil, current: signIn), mail)
        XCTAssertEqual(TabRecycler.rebuildURL(view: .mail, outstanding: nil, current: sso), mail)
    }

    /// The other view's page is not this tab's page.
    func testTheSiblingViewsPageFallsBackToTheEntryPoint() {
        XCTAssertEqual(TabRecycler.rebuildURL(view: .calendar, outstanding: nil, current: thread), calendar)
    }

    // MARK: - The rebuild itself

    /// R16, R18: the webview is replaced even when the automatic recycler's
    /// guards would refuse (selected tab, fresh document), and a failed load of
    /// the fresh webview enters the retry ladder.
    func testTheSignInFlagCanBeCarriedToAFreshWebView() {
        let policy = NavigationPolicy()
        let old = WKWebView()
        let fresh = WKWebView()
        policy.markAuthenticating(old)
        XCTAssertTrue(policy.isAuthenticating(old))

        let wasAuthenticating = policy.isAuthenticating(old)
        policy.webViewWasDiscarded(old)
        XCTAssertFalse(policy.isAuthenticating(old))
        if wasAuthenticating { policy.markAuthenticating(fresh) }

        XCTAssertTrue(policy.isAuthenticating(fresh))
    }

    func testARebuildReplacesTheWebViewAndAFailedLoadIsRetried() {
        let host = FakeRecyclerHost()
        var scheduled: [TimeInterval] = []
        let recycler = TabRecycler(settings: AppSettings(defaults: isolatedDefaults()))
        recycler.host = host
        recycler.schedule = { delay, _ in scheduled.append(delay) }
        recycler.load = { _, _ in }

        let old = WKWebView()
        let target = TabRecycler.Target(
            accountId: UUID(), accountName: "work", view: .mail, slot: 0, webView: old
        )
        host.targets = [target]

        XCTAssertTrue(recycler.rebuild(target, to: thread))
        guard let fresh = host.replacements.first else { return XCTFail("no rebuild happened") }
        XCTAssertFalse(fresh === old)
        XCTAssertEqual(recycler.outstandingTarget(for: fresh), thread)
        XCTAssertTrue(recycler.isRecycling(fresh))
        XCTAssertNil(recycler.outstandingTarget(for: old))

        scheduled.removeAll()
        recycler.webViewDidFail(fresh)
        XCTAssertEqual(scheduled, [30], "the first rung of the ladder")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "tab-reload-\(UUID().uuidString)")!
        AppSettings.registerDefaults(in: suite)
        return suite
    }
}
