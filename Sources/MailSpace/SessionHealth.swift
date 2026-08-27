import Foundation

/// Whether an account's Google session is still alive, decided from one
/// observation per 60 s poll cycle.
///
/// Two different failures wear the same face, and they need two different
/// proofs:
///
/// * **The common expiry.** Google re-navigates the tab to its login page.
///   `AuthSurface.classify` already names that state exactly; nothing is
///   inferred and nothing new is needed but a consumer.
/// * **Silent sync death.** The page stays on `mail.google.com`, keeps showing
///   the last inbox it rendered, and its requests quietly fail. The URL says
///   healthy. Only the feed probe can see this — and until now it could not,
///   because a signed-out feed fetch redirected cross-origin, failed CORS,
///   threw, and arrived as `ok:false`, indistinguishable from Wi-Fi being off.
///   `redirect: 'manual'` is the whole technical unlock: it turns "the server
///   answered, and its answer was go and sign in" from an exception into an
///   inspectable `opaqueredirect` response, and leaves a genuine offline
///   failure as an exception.
///
/// Pure logic with an injected clock, the same shape as `CrashThrottle` and
/// `SSOEscort`, so the rule is testable without WebKit, a network, or a real
/// expired Google session.
enum SessionHealth {
    /// What one poll cycle saw.
    enum Observation: Equatable {
        /// Suppresses everything; the streak is frozen, never advanced and
        /// never reset. A recycle, a load, a wake, a launch, no network.
        case busy
        case healthy
        /// Google itself says so: the tab is on the login page, or the feed
        /// answered 401/403 from its own origin.
        case authFailedStrong
        /// An opaque redirect. The server answered "go and sign in", but a
        /// captive portal or an enterprise proxy can produce the same shape,
        /// so this is worth six cycles and never a notification.
        case authFailedWeak
        /// 429 or 5xx. Google is pushing back; that is not evidence of
        /// anything about the session.
        case throttled
        /// A thrown fetch, an abort, an unparseable 200, or any page that is
        /// neither the sign-in chain nor Gmail. Never evidence of anything.
        case unreachable
    }

    enum State: Equatable {
        case healthy
        case signedOut
    }

    /// What the extended feed probe hands back. Additive to the script's
    /// existing `ok`/`feed` contract, which the Dock badge depends on.
    struct Probe: Equatable {
        var ok: Bool
        /// Whether `AtomFeedParser` could read a `<fullcount>` out of the body.
        var parsed: Bool
        /// HTTP status, or 0 for an opaque redirect and -1 for a thrown fetch.
        var status: Int
        /// The `Response.type` — `basic`, `opaqueredirect`, `error`.
        var type: String

        init(ok: Bool, parsed: Bool, status: Int, type: String) {
            self.ok = ok
            self.parsed = parsed
            self.status = status
            self.type = type
        }
    }

    /// Streak arithmetic. `authFailedStrong` needs three, `authFailedWeak` six.
    static let strongConfirmations = 3
    static let weakConfirmations = 6

    /// …and in both cases at least this much wall clock since the streak began,
    /// so a coalesced burst of timer fires cannot confirm anything. Detection
    /// latency is therefore three to four minutes, which is right for a failure
    /// measured in hours.
    static let minimumStreakDuration: TimeInterval = 180

    /// Two counted observations must be at least this far apart.
    static let minimumSpacing: TimeInterval = 45

    /// While the state persists, the notification is re-fired at most this
    /// often.
    static let reminderInterval: TimeInterval = 12 * 3600

    /// Consecutive `throttled` observations after which the account's effective
    /// probe interval doubles, until the next `healthy`.
    static let throttleBackoffThreshold = 2

    /// Turns a URL classification plus a probe result into the single
    /// observation for this cycle.
    ///
    /// The URL comes first because it is the strongest and cheapest signal
    /// there is: if Google has already moved the tab onto its login page,
    /// nothing needs to be inferred from a fetch.
    static func observation(url: URL?, probe: Probe?) -> Observation {
        switch AuthSurface.classify(url) {
        case .signIn:
            return .authFailedStrong
        case .app(.mail):
            guard let probe else { return .unreachable }
            return observation(for: probe)
        case .app, .other:
            // A Google page that is neither the chain nor the inbox, or a
            // foreign host. Never evidence of anything.
            return .unreachable
        }
    }

    /// The probe verdict, for a tab whose URL still looks perfectly healthy.
    static func observation(for probe: Probe) -> Observation {
        if probe.type == "opaqueredirect" || probe.status == 0 { return .authFailedWeak }
        if probe.status == 401 || probe.status == 403 { return .authFailedStrong }
        if probe.status == 429 || probe.status >= 500 { return .throttled }
        if probe.ok, (200..<300).contains(probe.status), probe.parsed { return .healthy }
        // A thrown fetch, an abort, or a 2xx body with no `<fullcount>` in it.
        return .unreachable
    }

    /// What changed for the user as a result of this cycle.
    enum Change: Equatable {
        case unchanged
        /// The account is now reported as signed out. `shouldNotify` is false
        /// for weak evidence and for a reminder that is not due yet.
        case signedOut(shouldNotify: Bool)
        /// Back to healthy — clear the pill, the Dock `!` and the notified flag.
        case recovered
    }

    /// One account's running state.
    struct Monitor: Equatable {
        private(set) var state: State = .healthy
        private(set) var streak = 0
        /// Whether the streak so far is made of strong evidence only. A single
        /// weak observation downgrades the whole streak, which is what keeps a
        /// captive portal from ever raising a notification.
        private(set) var streakIsStrong = true
        private(set) var streakStartedAt: Date?
        private(set) var lastCountedAt: Date?
        private(set) var lastNotifiedAt: Date?
        private(set) var throttledStreak = 0

        init() {}

        /// True while Google is pushing back and the poller should halve its
        /// rate for this account.
        var isBackingOff: Bool { throttledStreak >= throttleBackoffThreshold }

        /// Every `didCommit` in this account's mail webview resets the streak.
        ///
        /// This one line is what makes a live sign-in chain incapable of
        /// raising the indicator: Google commits a page at every step —
        /// identifier, password, TOTP, consent — while an expired session
        /// commits once and then sits still for hours. The confirmation count
        /// only absorbs a single anomalous cycle; quiescence is the real
        /// discriminator.
        mutating func didCommit() {
            streak = 0
            streakIsStrong = true
            streakStartedAt = nil
            lastCountedAt = nil
        }

        @discardableResult
        mutating func record(_ observation: Observation, now: Date) -> Change {
            switch observation {
            case .busy, .unreachable:
                // Frozen, not reset, on purpose: a session that expired before
                // the network dropped is still reported once it comes back.
                return .unchanged

            case .throttled:
                throttledStreak += 1
                return .unchanged

            case .healthy:
                throttledStreak = 0
                let wasSignedOut = state == .signedOut
                state = .healthy
                streak = 0
                streakIsStrong = true
                streakStartedAt = nil
                lastCountedAt = nil
                lastNotifiedAt = nil
                return wasSignedOut ? .recovered : .unchanged

            case .authFailedStrong, .authFailedWeak:
                throttledStreak = 0
                // A coalesced timer burst — several fires arriving at once
                // after a wake — must not advance a streak.
                if let last = lastCountedAt, now.timeIntervalSince(last) < minimumSpacing {
                    return .unchanged
                }
                if streak == 0 { streakStartedAt = now; streakIsStrong = true }
                if observation == .authFailedWeak { streakIsStrong = false }
                streak += 1
                lastCountedAt = now
                return confirm(now: now)
            }
        }

        private mutating func confirm(now: Date) -> Change {
            let needed = streakIsStrong ? strongConfirmations : weakConfirmations
            guard streak >= needed else { return .unchanged }
            guard let started = streakStartedAt,
                  now.timeIntervalSince(started) >= minimumStreakDuration else { return .unchanged }

            let wasHealthy = state == .healthy
            state = .signedOut

            // Never on weak evidence, and at most once per `reminderInterval`
            // while the state persists.
            guard streakIsStrong else { return .signedOut(shouldNotify: false) }
            if wasHealthy || lastNotifiedAt == nil {
                lastNotifiedAt = now
                return .signedOut(shouldNotify: true)
            }
            if let last = lastNotifiedAt, now.timeIntervalSince(last) >= reminderInterval {
                lastNotifiedAt = now
                return .signedOut(shouldNotify: true)
            }
            return .signedOut(shouldNotify: false)
        }
    }
}

/// Holds one `SessionHealth.Monitor` per account and reports what changed.
///
/// Deliberately thin: it never reloads anything and never runs a timer. Only a
/// user selection re-navigates a signed-out tab, which keeps "how often we
/// retry" bounded by the person looking at it — the same rule
/// `recoverIfStalled` already establishes.
final class SessionHealthTracker {
    private var monitors: [UUID: SessionHealth.Monitor] = [:]
    /// Accounts whose signed-out tab has already been re-navigated once during
    /// the current episode, so selecting the tab repeatedly does not reload the
    /// login page every time.
    private var recoveredThisEpisode: Set<UUID> = []

    /// Fired when an account changes state, on the main thread.
    var onChange: ((UUID, SessionHealth.Change) -> Void)?

    var signedOutAccounts: Set<UUID> {
        Set(monitors.filter { $0.value.state == .signedOut }.keys)
    }

    func isSignedOut(_ accountId: UUID) -> Bool {
        monitors[accountId]?.state == .signedOut
    }

    func isBackingOff(_ accountId: UUID) -> Bool {
        monitors[accountId]?.isBackingOff ?? false
    }

    func record(_ observation: SessionHealth.Observation, for accountId: UUID, now: Date = Date()) {
        var monitor = monitors[accountId] ?? SessionHealth.Monitor()
        let change = monitor.record(observation, now: now)
        monitors[accountId] = monitor
        if case .recovered = change { recoveredThisEpisode.remove(accountId) }
        guard change != .unchanged else { return }
        onChange?(accountId, change)
    }

    /// Every commit in an account's mail webview resets its streak.
    func didCommit(for accountId: UUID) {
        guard var monitor = monitors[accountId] else { return }
        monitor.didCommit()
        monitors[accountId] = monitor
    }

    func forget(_ accountId: UUID) {
        monitors[accountId] = nil
        recoveredThisEpisode.remove(accountId)
    }

    /// Whether selecting this account's tab should re-navigate it onto the
    /// sign-in page. True at most once per episode, and never when the tab is
    /// holding an unsent draft.
    ///
    /// Losing a draft to a helpful re-navigation is worse than a stale tab, so
    /// the compose test is the same URL-only one the recycler uses and errs the
    /// same way.
    func shouldRenavigate(accountId: UUID, url: URL?) -> Bool {
        guard isSignedOut(accountId) else { return false }
        guard !recoveredThisEpisode.contains(accountId) else { return false }
        if let url, RecycleDecision.hasOpenCompose(url) { return false }
        recoveredThisEpisode.insert(accountId)
        return true
    }
}
