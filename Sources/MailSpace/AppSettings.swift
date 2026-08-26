import Foundation

/// Which account composes a `mailto:` link (G1).
///
/// Stored as one string so the whole setting is a single key: `"ask"`,
/// `"current"`, or the UUID of a specific account.
enum ComposeFrom: Equatable {
    case ask
    case current
    case fixed(UUID)

    var rawValue: String {
        switch self {
        case .ask: return "ask"
        case .current: return "current"
        case .fixed(let id): return id.uuidString
        }
    }

    /// Anything unrecognised — a hand-edited value, an account UUID that is no
    /// longer valid text — reads as the default rather than trapping.
    init(rawValue: String) {
        switch rawValue {
        case "current": self = .current
        case "ask": self = .ask
        default:
            if let id = UUID(uuidString: rawValue) {
                self = .fixed(id)
            } else {
                self = .ask
            }
        }
    }
}

/// What happens the moment a download lands (G4).
enum DownloadFinishedAction: String, CaseIterable {
    case notify
    case reveal
    case open
    case nothing

    var displayName: String {
        switch self {
        case .notify: return "Notify me"
        case .reveal: return "Reveal in Finder"
        case .open: return "Open it"
        case .nothing: return "Do nothing"
        }
    }
}

/// What the Dock badge — and every unread number that comes from the same poll
/// — is counting (A5).
enum BadgeScope: String, CaseIterable {
    case primary
    case everything

    var displayName: String {
        switch self {
        case .primary: return "Primary inbox only"
        case .everything: return "Everything in the inbox (includes Promotions and Social)"
        }
    }
}

/// App-level preferences, over `UserDefaults.standard`.
///
/// The shape `docs/plans/2026-08-26-1224-feat-settings-window-plan.md` calls
/// for (KTD-S1): one object, typed accessors, `registerDefaults` at launch, no
/// framework. Per-account preferences are deliberately *not* here — they live
/// on `Account` in `accounts.json` (KTD-S2).
///
/// The defaults domain follows the bundle identifier, so the self-test bundle
/// gets its own for free and no probe can write the real app's preferences.
final class AppSettings {
    enum Key {
        static let automaticallyChecksForUpdates = "AutomaticallyCheckForUpdates"
        static let lastUpdateCheck = "LastUpdateCheck"
        static let composeFrom = "ComposeFrom"
        static let openLinksInBackground = "OpenLinksInBackground"
        static let downloadDirectoryPath = "DownloadDirectoryPath"
        static let downloadFinishedAction = "DownloadFinishedAction"
        static let badgeScope = "BadgeScope"
        // Valves: read at the point of use, no row in the window (KTD-S6).
        static let unreadPollSeconds = "UnreadPollSeconds"
        static let unreadUsePlainFeed = "UnreadUsePlainFeed"
        static let disableSignInAutofill = "DisableSignInAutofill"
    }

    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.automaticallyChecksForUpdates: true,
            Key.composeFrom: ComposeFrom.ask.rawValue,
            Key.openLinksInBackground: true,
            Key.downloadDirectoryPath: "",
            Key.downloadFinishedAction: DownloadFinishedAction.notify.rawValue,
            Key.badgeScope: BadgeScope.primary.rawValue,
            Key.unreadPollSeconds: 60.0,
            Key.unreadUsePlainFeed: false,
            Key.disableSignInAutofill: false
        ])
    }

    /// Whether MailSpace looks for a new release on its own. Off means the
    /// "Check for Updates…" menu item is the only way one is ever found — it
    /// never stops the manual check working.
    var automaticallyChecksForUpdates: Bool {
        get { defaults.bool(forKey: Key.automaticallyChecksForUpdates) }
        set { defaults.set(newValue, forKey: Key.automaticallyChecksForUpdates) }
    }

    /// When the last check completed — successfully or not. Also the throttle: a
    /// background check inside the interval does nothing.
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    // MARK: - General pane

    /// G1. Which account a `mailto:` composes from.
    var composeFrom: ComposeFrom {
        get { ComposeFrom(rawValue: defaults.string(forKey: Key.composeFrom) ?? "") }
        set { defaults.set(newValue.rawValue, forKey: Key.composeFrom) }
    }

    /// G2. Hand an external link to the browser without letting it take the
    /// screen. Only holds when the browser is already running — a cold launch
    /// activates itself and no flag stops it.
    var openLinksInBackground: Bool {
        get { defaults.bool(forKey: Key.openLinksInBackground) }
        set { defaults.set(newValue, forKey: Key.openLinksInBackground) }
    }

    /// G3. Where downloads land. Empty means "wherever macOS puts Downloads",
    /// which is also what a deleted key reads as.
    var downloadDirectory: URL {
        get {
            let path = defaults.string(forKey: Key.downloadDirectoryPath) ?? ""
            guard !path.isEmpty else { return Self.systemDownloadDirectory }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Key.downloadDirectoryPath) }
    }

    /// True while the folder is the system one, so the pane can say "Downloads"
    /// instead of spelling out a path the user never chose.
    var usesSystemDownloadDirectory: Bool {
        (defaults.string(forKey: Key.downloadDirectoryPath) ?? "").isEmpty
    }

    /// Puts G3 back to the system Downloads folder.
    func useSystemDownloadDirectory() {
        defaults.set("", forKey: Key.downloadDirectoryPath)
    }

    static var systemDownloadDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// G4. What happens when a download finishes.
    var downloadFinishedAction: DownloadFinishedAction {
        get { DownloadFinishedAction(rawValue: defaults.string(forKey: Key.downloadFinishedAction) ?? "") ?? .notify }
        set { defaults.set(newValue.rawValue, forKey: Key.downloadFinishedAction) }
    }

    // MARK: - Accounts pane

    /// A5. What "unread" means, for the Dock badge and for every surface fed by
    /// the same poll.
    var badgeScope: BadgeScope {
        get { BadgeScope(rawValue: defaults.string(forKey: Key.badgeScope) ?? "") ?? .primary }
        set { defaults.set(newValue.rawValue, forKey: Key.badgeScope) }
    }

    // MARK: - Valves (no UI, `defaults write` only — KTD-S6)

    /// How often the unread count is fetched. Any value a person would type
    /// here is a debugging value, so it gets a key and not a row.
    var unreadPollSeconds: TimeInterval {
        let stored = defaults.double(forKey: Key.unreadPollSeconds)
        return stored > 0 ? stored : 60
    }

    /// Forces the whole-inbox atom feed regardless of `badgeScope` — the way
    /// out for the day Gmail retires the Primary smart label.
    var unreadUsePlainFeed: Bool {
        defaults.bool(forKey: Key.unreadUsePlainFeed)
    }

    /// Stops the native side answering the sign-in autofill request at all. The
    /// guard belongs here, next to the reply handler — never in the injected
    /// page script, which protects nothing.
    var disableSignInAutofill: Bool {
        defaults.bool(forKey: Key.disableSignInAutofill)
    }
}
