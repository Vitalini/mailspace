import AppKit
import XCTest
@testable import MailSpace

/// The three cheap wins from `docs/next-steps.md` §1, each of which is a rule
/// small enough to pin down here rather than notice going wrong later.
final class ContentPinningTests: XCTestCase {
    /// `refresh()` used to remove every subview and re-pin on every call —
    /// including a re-click of the tab already showing and every drag drop —
    /// which makes WebKit drop and rebuild that page's compositing backing
    /// store for nothing.
    func testAViewThatIsAlreadyPinnedIsNotRepinned() {
        let webView = NSView()
        let other = NSView()

        XCTAssertFalse(MainWindowController.needsRepin(currentSubviews: [webView], desired: webView))
        XCTAssertTrue(MainWindowController.needsRepin(currentSubviews: [other], desired: webView))
        XCTAssertTrue(MainWindowController.needsRepin(currentSubviews: [], desired: webView))
        // Anything left over from an earlier layout means the container is not
        // in the state the skip assumes.
        XCTAssertTrue(MainWindowController.needsRepin(currentSubviews: [webView, other], desired: webView))
    }

    /// The evidence for "signed out" is the account's mail webview — the feed
    /// probe and the classified URL both live there — so the warning goes on
    /// the Mail tab, which is also the tab whose selection puts the sign-in
    /// form in front of the user.
    func testTheSignedOutPillLandsOnTheAccountsMailTab() {
        let out = UUID()
        let fine = UUID()
        XCTAssertTrue(AccountTabBar.showsSignedOut(tab: TabRef(accountId: out, view: .mail), signedOut: [out]))
        XCTAssertFalse(AccountTabBar.showsSignedOut(tab: TabRef(accountId: out, view: .calendar), signedOut: [out]))
        XCTAssertFalse(AccountTabBar.showsSignedOut(tab: TabRef(accountId: fine, view: .mail), signedOut: [out]))
        XCTAssertFalse(AccountTabBar.showsSignedOut(tab: TabRef(accountId: out, view: .mail), signedOut: []))
    }

    /// `NotificationOrigin.isTrusted` opens by rejecting every subframe, so a
    /// shim running in an iframe could never produce a notification that was
    /// accepted. Injecting it there only cost a script evaluation per frame and
    /// left the message handler reachable from third-party content.
    func testTheNotificationShimIsMainFrameOnly() {
        XCTAssertTrue(NotificationShim.userScript.isForMainFrameOnly)
        XCTAssertTrue(LoginAutofill.userScript.isForMainFrameOnly)
    }

    /// Recycling is on unless the user turns it off — the whole point is that
    /// nothing has to be remembered.
    func testAutomaticRecyclingIsOnByDefault() {
        let suite = "MailSpaceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("could not make a throwaway defaults domain")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        AppSettings.registerDefaults(in: defaults)
        XCTAssertTrue(AppSettings(defaults: defaults).automaticTabRecycling)
    }
}
