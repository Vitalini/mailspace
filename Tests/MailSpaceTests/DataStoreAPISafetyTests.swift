import WebKit
import XCTest
@testable import MailSpace

/// The launch sweep's two WebKit calls, made the way launch makes them: in a
/// process where no webview exists yet.
///
/// `WKWebsiteDataStore`'s class-level calls hand their result back through
/// WebKit's main run loop, and that run loop is not there until something in
/// the process has instantiated a WebKit object. Called before that, both of
/// these took the process down — EXC_BAD_ACCESS at 0x40 on
/// `com.apple.WebKit.WebsiteDataStoreIO`, nowhere near the caller. Which is
/// every launch with no account to build a webview from: a first run, and the
/// run after the last account was removed — the one that has orphans to sweep.
///
/// This is as much of a test as the failure allows: a segfault is not an error
/// anything can catch, so what is asserted is that a completion arrives at all.
/// A regression takes the whole test run down with it, which is the point.
///
/// It has to be the first thing in this process to touch WebKit, or an earlier
/// instantiation somewhere else in the suite would prime the run loop and make
/// it pass for the wrong reason. Nothing else in the suite imports WebKit —
/// keep it that way.
final class DataStoreAPISafetyTests: XCTestCase {
    /// A store that has never existed. Under the test process's own identity,
    /// so nothing the app owns is in reach either way.
    private static let neverCreated = UUID(uuidString: "5EE0E5EE-0000-4000-8000-00000000FEED")!

    func testTheSweepsWebKitCallsSurviveAProcessWithNoWebView() {
        let listed = expectation(description: "the store listing came back")
        WebViewFactory.dataStoreIdentifiers { _ in listed.fulfill() }
        wait(for: [listed], timeout: 30)

        // And the removal the sweep makes off the back of that listing.
        //
        // It also pins down what was measured alongside the crash: an
        // identifier with nothing behind it is not a crash once the run loop
        // exists, it is a plain success. So the sweep cannot be made safe by
        // filtering which identifiers reach the removal — only by the
        // initialisation both calls now go through.
        let removed = expectation(description: "the removal came back")
        WebViewFactory.destroyDataStore(for: Self.neverCreated) { error in
            XCTAssertNil(error, "removing a store that was never created is not an error")
            removed.fulfill()
        }
        wait(for: [removed], timeout: 30)
    }
}
