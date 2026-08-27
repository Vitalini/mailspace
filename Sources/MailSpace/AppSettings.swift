import Foundation

/// App-level preferences, over `UserDefaults.standard`.
///
/// The shape `docs/plans/2026-08-26-1224-feat-settings-window-plan.md` calls
/// for (KTD-S1): one object, typed accessors, `registerDefaults` at launch, no
/// framework. Only the update keys live here so far — when the Settings window
/// plan lands, its General and Accounts controls are added to this file rather
/// than to a second store.
///
/// The defaults domain follows the bundle identifier, so the self-test bundle
/// gets its own for free and no probe can write the real app's preferences.
final class AppSettings {
    enum Key {
        static let automaticallyChecksForUpdates = "AutomaticallyCheckForUpdates"
        static let lastUpdateCheck = "LastUpdateCheck"
        static let automaticTabRecycling = "AutomaticTabRecycling"
    }

    static let shared = AppSettings()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            Key.automaticallyChecksForUpdates: true,
            Key.automaticTabRecycling: true
        ])
    }

    /// Whether MailSpace looks for a new release on its own. Off means the
    /// "Check for Updates…" menu item is the only way one is ever found — it
    /// never stops the manual check working.
    var automaticallyChecksForUpdates: Bool {
        get { defaults.bool(forKey: Key.automaticallyChecksForUpdates) }
        set { defaults.set(newValue, forKey: Key.automaticallyChecksForUpdates) }
    }

    /// Whether MailSpace rebuilds a tab that has been open a long time.
    ///
    /// On by default, and the reason the app does not grow to gigabytes over a
    /// day of uptime. Off means a tab is only ever reloaded when the user asks
    /// — ⌘R, or selecting a tab the crash throttle gave up on.
    var automaticTabRecycling: Bool {
        get { defaults.bool(forKey: Key.automaticTabRecycling) }
        set { defaults.set(newValue, forKey: Key.automaticTabRecycling) }
    }

    /// When the last check completed — successfully or not. Also the throttle: a
    /// background check inside the interval does nothing.
    var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }
}
