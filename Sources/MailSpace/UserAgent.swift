import AppKit

/// The user agent MailSpace presents to the web: the Safari installed on this
/// Mac, read once at launch.
///
/// The engine here genuinely *is* WebKit, so advertising Safari is accurate
/// rather than a spoof — but a hardcoded number goes stale on Apple's release
/// schedule, not MailSpace's, and Gmail then reports the browser as no longer
/// supported. Reading the installed Safari's own version keeps the claim true
/// after every macOS update, with no MailSpace release.
///
/// Two things depend on the string, in different ways: Google refuses
/// `accounts.google.com` sign-in to a user agent with no `Version/… Safari/…`
/// tail at all (`disallowed_useragent`), and Gmail reads the number to decide
/// whether the browser is current.
///
/// AppKit only — the resolver stays testable in a process that has never
/// instantiated a WebKit object.
enum UserAgent {
    /// WebKit's own prefix. Frozen: this is what Safari itself sends, down to
    /// the `10_15_7` that stopped tracking the real macOS version years ago.
    private static let webKitPrefix =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)"

    /// WebKit's build number, which is not the Safari version and does not
    /// move with it.
    private static let webKitBuild = "605.1.15"

    /// Advertised when Safari cannot be found or its version cannot be read.
    ///
    /// One Safari major behind is still inside Google's current-and-previous
    /// window; two is not. `UserAgentTests` bounds this against the installed
    /// Safari so it cannot go quietly stale.
    static let fallbackVersion = "26.6"

    /// Two or three ASCII-digit parts, whole-string. ASCII rather than `\d` so
    /// everything accepted here is also something `SemanticVersion` can parse;
    /// two parts minimum for the same reason — `SemanticVersion` refuses a bare
    /// major.
    private static let versionPattern = "^[0-9]+\\.[0-9]+(\\.[0-9]+)?$"

    /// Read once per process: `static let` initialisation is lazy, thread-safe
    /// and happens exactly once, so the LaunchServices lookup and the plist
    /// read cost one call however many webviews and popups ask for the string.
    ///
    /// The consequence is that a Safari update installed while MailSpace is
    /// running is picked up at the next launch, not immediately. Safari ships
    /// with macOS updates, which restart the Mac anyway.
    static let safariVersion = resolve(installed: installedSafariVersion())

    /// The suffix WebKit also exposes through `applicationNameForUserAgent`,
    /// for pages that sniff it separately from `navigator.userAgent`.
    static let applicationName = "Version/\(safariVersion) Safari/\(webKitBuild)"

    static let userAgent = "\(webKitPrefix) \(applicationName)"

    /// Turns the raw short version the caller read — `nil` when there is no
    /// Safari or no key — into the version to advertise.
    ///
    /// Pure, so the fallback path is a test rather than a machine's opinion.
    /// An accepted version is carried verbatim: Safari states its own version
    /// and MailSpace repeats it, never a normalised rewrite of it.
    static func resolve(installed: String?) -> String {
        guard let installed, isWellFormed(installed) else { return fallbackVersion }
        return installed
    }

    /// The installed Safari's `CFBundleShortVersionString`, or `nil` at the
    /// first step that fails. Opening the bundle reads its `Info.plist`; it
    /// does not launch Safari.
    static func installedSafariVersion() -> String? {
        guard
            let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari"),
            let info = Bundle(url: safari)?.infoDictionary
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// Matched against the whole string, so a well-formed first line of a
    /// multi-line value cannot pass for the value.
    private static func isWellFormed(_ version: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: versionPattern) else { return false }
        let whole = NSRange(version.startIndex..<version.endIndex, in: version)
        guard let match = regex.firstMatch(in: version, range: whole) else { return false }
        return match.range == whole
    }
}
