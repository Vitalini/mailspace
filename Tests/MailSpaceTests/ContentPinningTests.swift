import AppKit
import XCTest
@testable import MailSpace

/// Three cheap wins, each of which is a rule small enough to pin down here
/// rather than notice going wrong later.
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
        XCTAssertEqual(
            AccountTabBar.warning(tab: TabRef(accountId: out, view: .mail), signedOut: [out]),
            .signedOut
        )
        XCTAssertNil(AccountTabBar.warning(tab: TabRef(accountId: out, view: .calendar), signedOut: [out]))
        XCTAssertNil(AccountTabBar.warning(tab: TabRef(accountId: fine, view: .mail), signedOut: [out]))
        XCTAssertNil(AccountTabBar.warning(tab: TabRef(accountId: out, view: .mail), signedOut: []))
    }

    /// A tab whose recycle load failed for good wears the same pill in the same
    /// slot, with its own words. It used to wear nothing at all: the state was
    /// invisible to the tab bar, to the Dock badge and to the health monitor at
    /// once, which is what made ten minutes of bad Wi-Fi look like "no new mail"
    /// rather than like four dead tabs.
    func testADeadTabWearsTheSamePillWithItsOwnWords() {
        let dead = UUID()
        XCTAssertEqual(
            AccountTabBar.warning(tab: TabRef(accountId: dead, view: .mail), signedOut: [], stalled: [dead]),
            .notLoading
        )
        XCTAssertNil(
            AccountTabBar.warning(tab: TabRef(accountId: dead, view: .calendar), signedOut: [], stalled: [dead])
        )
        XCTAssertNotEqual(TabWarning.notLoading.tooltip, TabWarning.signedOut.tooltip)
    }

    /// Both at once is the sign-in's problem to fix, so signed-out wins.
    func testSignedOutOutranksNotLoading() {
        let both = UUID()
        XCTAssertEqual(
            AccountTabBar.warning(tab: TabRef(accountId: both, view: .mail), signedOut: [both], stalled: [both]),
            .signedOut
        )
    }

    /// The benchmark's pass mark used to be decorative for the one regression
    /// it exists to catch. `sustained` is the footprint of the *new* WebContent
    /// process only — `resolvePid` takes the set difference at recycle time —
    /// so a change that retained the old webview would leave it alive at 700-odd
    /// MB beside a fresh 11 MB one and score PASS on the 11. `oldPidExited` was
    /// printed and had no vote; now it has one.
    func testTheBenchmarkFailsWhenTheOldProcessSurvives() {
        // The shipped result: small new process, old one gone.
        XCTAssertEqual(
            BenchProbe.verdict(arm: "b", freshMB: 28, sustainedMB: 11, sampleCount: 28, oldPidExited: true),
            "PASS"
        )
        // The regression the benchmark exists to catch, and used to miss.
        XCTAssertEqual(
            BenchProbe.verdict(arm: "b", freshMB: 28, sustainedMB: 11, sampleCount: 28, oldPidExited: false),
            "FAIL"
        )
        // A run that could not tell is not a pass either.
        XCTAssertEqual(
            BenchProbe.verdict(arm: "b", freshMB: 28, sustainedMB: 11, sampleCount: 28, oldPidExited: nil),
            "INCONCLUSIVE"
        )
        // The measured `reload()` arm: nothing is reclaimed, and no process
        // accounting is expected of it.
        XCTAssertEqual(
            BenchProbe.verdict(arm: "a", freshMB: 28, sustainedMB: 426, sampleCount: 28, oldPidExited: nil),
            "FAIL"
        )
        XCTAssertEqual(
            BenchProbe.verdict(arm: "a", freshMB: 28, sustainedMB: 11, sampleCount: 28, oldPidExited: nil),
            "PASS"
        )
        XCTAssertEqual(
            BenchProbe.verdict(arm: "b", freshMB: 28, sustainedMB: 11, sampleCount: 0, oldPidExited: true),
            "INCONCLUSIVE"
        )
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
