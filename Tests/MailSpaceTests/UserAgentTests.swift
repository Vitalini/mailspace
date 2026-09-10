import AppKit
import XCTest
@testable import MailSpace

/// What MailSpace tells the web it is.
///
/// AppKit, never WebKit: the resolver's only framework dependency is
/// `NSWorkspace`, and this file proves it can be exercised in a process where
/// no WebKit object exists. `DataStoreAPISafetyTests` has to be the first thing
/// in the suite to touch WebKit, so nothing here may import it.
final class UserAgentTests: XCTestCase {
    /// WebKit's own prefix, spelled out rather than read off `UserAgent`, so a
    /// change to either one fails here.
    private let frozenPrefix =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    // MARK: - Shape

    func testTheUserAgentIsTheFrozenPrefixThenOneSpaceThenTheApplicationName() {
        XCTAssertEqual(UserAgent.userAgent, "\(frozenPrefix) \(UserAgent.applicationName)")
        XCTAssertTrue(UserAgent.userAgent.hasPrefix(frozenPrefix))
        XCTAssertTrue(UserAgent.userAgent.hasSuffix(UserAgent.applicationName))
    }

    func testTheApplicationNameIsSafarisVersionTokenAndBuildNumber() {
        XCTAssertEqual(
            UserAgent.applicationName,
            "Version/\(UserAgent.safariVersion) Safari/605.1.15"
        )
        // `resolve` returns its input unchanged only for a version it accepts,
        // so this asserts the advertised version is a well-formed one without
        // restating the validation rule.
        XCTAssertEqual(UserAgent.resolve(installed: UserAgent.safariVersion), UserAgent.safariVersion)
    }

    // MARK: - Freshness
    //
    // Two separate claims. (a) is about the value that ships on this Mac; (b)
    // is about the constant that ships when the lookup fails. Collapsing them
    // into one bound loses both signals.

    /// (a) The advertised version is the installed Safari's own string,
    /// character for character. A Mac that has Safari and still advertises the
    /// fallback constant fails here.
    func testTheAdvertisedVersionIsTheInstalledSafarisOwn() throws {
        guard
            let installed = UserAgent.installedSafariVersion(),
            UserAgent.resolve(installed: installed) == installed
        else {
            throw XCTSkip("No Safari on this Mac with a readable, well-formed short version.")
        }
        XCTAssertEqual(UserAgent.safariVersion, installed)
    }

    /// (b) The fallback constant is at most one Safari major behind the
    /// installed Safari — Google supports the current and previous major only.
    ///
    /// The bound is a heuristic, and it fires early when Apple skips majors the
    /// way 18 was followed by 26. A failure here is triaged against Google's
    /// published supported-browser list and answered by moving the constant,
    /// never by widening the bound.
    func testTheFallbackConstantHasNotGoneStale() throws {
        guard
            let installed = UserAgent.installedSafariVersion(),
            let installedVersion = SemanticVersion(installed),
            let fallback = SemanticVersion(UserAgent.fallbackVersion)
        else {
            throw XCTSkip("No Safari on this Mac with a version this test can parse.")
        }
        XCTAssertGreaterThanOrEqual(
            fallback.major,
            installedVersion.major - 1,
            """
            The fallback \(UserAgent.fallbackVersion) is more than one major behind \
            the installed Safari \(installed). Check Google's supported-browser list \
            and move the constant — do not widen this bound.
            """
        )
    }

    // MARK: - Validation and fallback

    func testAWellFormedVersionIsCarriedVerbatim() {
        XCTAssertEqual(UserAgent.resolve(installed: "26.6.2"), "26.6.2")
        XCTAssertEqual(UserAgent.resolve(installed: "26.6"), "26.6")
        XCTAssertEqual(UserAgent.resolve(installed: "18.0"), "18.0")
    }

    func testAnythingElseFallsBackToTheConstant() {
        XCTAssertEqual(UserAgent.resolve(installed: nil), UserAgent.fallbackVersion)
        let refused = [
            "26",           // a bare major: SemanticVersion refuses it, so the resolver must too
            "",
            "26.6-beta",
            "26.6.2.1",
            "v26.6",
            "Safari",
            "26.",
            ".6",
            "26.6 ",
            " 26.6",
            "26.6.2\n26.6"  // `^…$` must not be satisfied by one line of a multi-line value
        ]
        for value in refused {
            XCTAssertEqual(
                UserAgent.resolve(installed: value),
                UserAgent.fallbackVersion,
                "\(String(reflecting: value)) must not reach the user agent"
            )
        }
    }

    func testTheFallbackConstantIsItselfSomethingTheResolverAccepts() {
        XCTAssertEqual(UserAgent.resolve(installed: UserAgent.fallbackVersion), UserAgent.fallbackVersion)
        XCTAssertNotNil(SemanticVersion(UserAgent.fallbackVersion))
    }

    // MARK: - What the rest of the app reads
    //
    // `NavigationPolicy` and `SelfTest` read the two names off
    // `WebViewFactory`, so those are the strings that actually reach a page.
    // Reading a `static let String` off it instantiates no WebKit object, and
    // this file still imports no WebKit.

    func testWebViewFactoryForwardsTheUserAgent() {
        XCTAssertEqual(WebViewFactory.userAgent, UserAgent.userAgent)
    }

    func testWebViewFactoryForwardsTheApplicationName() {
        XCTAssertEqual(WebViewFactory.applicationName, UserAgent.applicationName)
    }
}
