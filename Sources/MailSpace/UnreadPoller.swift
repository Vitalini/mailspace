import AppKit
import WebKit

/// Keeps the Dock badge showing the total unread count across accounts, and
/// feeds one health observation per account per cycle to `SessionHealth`.
///
/// The count comes from Gmail's own atom feed, fetched *inside* each account's
/// mail webview: same origin, so the account's session cookies apply and no
/// cookie copying is needed. `callAsyncJavaScript` is what makes this work —
/// plain `evaluateJavaScript` would hand back a pending Promise.
///
/// Only accounts with Mail enabled are polled; a calendar-only account never
/// touches the Gmail feed.
final class UnreadPoller {
    typealias MailWebViewProvider = () -> [(accountId: UUID, webView: WKWebView)]

    /// Gmail hosts the feed fetch is same-origin from. A signed-out account's
    /// mail webview sits on `accounts.google.com` instead, where the fetch is
    /// cross-origin, gets no CORS headers and rejects.
    static let mailHosts: Set<String> = ["mail.google.com", "mail.googlemail.com"]

    /// Returns `{ ok, feed, status, type }`.
    ///
    /// `ok`/`feed` mean exactly what they always did, byte for byte, because
    /// the Dock badge is load-bearing and has already had a stale-badge bug.
    /// `ok: false` means the poll never got an answer — a network error, or the
    /// 20s abort below — and the caller must keep the previous count rather
    /// than read it as zero unread. A 4xx *is* an answer (signed out, feed
    /// retired), so it counts as zero. So is "this page is not Gmail".
    ///
    /// `status` and `type` are new and additive, and they exist for one reason:
    /// `redirect: 'manual'`. With the default `follow`, a signed-out feed fetch
    /// redirects cross-origin, fails CORS and throws — indistinguishable from
    /// Wi-Fi being off, which is what made silent sync death undetectable.
    /// With `manual`, the same answer arrives as an inspectable
    /// `type: 'opaqueredirect'` response while a genuine offline failure still
    /// throws. That one flag is the whole technical unlock; see `SessionHealth`.
    ///
    /// The URL is host-relative so the fetch is same-origin whichever Gmail
    /// host the webview is on.
    private static let feedScript = """
    if (!/^mail\\.google(mail)?\\.com$/.test(location.hostname)) {
      return { ok: true, feed: '', status: -1, type: 'not-gmail' };
    }
    const controller = new AbortController();
    const deadline = setTimeout(function () { controller.abort(); }, 20000);
    try {
      const response = await fetch('/mail/feed/atom', {
        credentials: 'include',
        cache: 'no-store',
        redirect: 'manual',
        signal: controller.signal
      });
      if (response.type === 'opaqueredirect') {
        return { ok: false, feed: '', status: 0, type: 'opaqueredirect' };
      }
      if (!response.ok) {
        return { ok: response.status < 500, feed: '', status: response.status, type: response.type };
      }
      return { ok: true, feed: await response.text(), status: response.status, type: response.type };
    } catch (error) {
      return { ok: false, feed: '', status: -1, type: 'error' };
    } finally {
      clearTimeout(deadline);
    }
    """

    /// What this account's mail webview can be asked for right now.
    ///
    /// The boolean this replaces read *any* non-Gmail URL as a definite zero,
    /// so an account zeroed its badge for the moment it was mid-reload — and
    /// automatic recycling makes that happen twice a day per account. The
    /// distinction that actually matters is "signed out" versus "not answering
    /// right now", and only the first is a real zero.
    enum Reading: Equatable {
        /// On Gmail: run the feed fetch.
        case poll
        /// On the sign-in chain: a definite zero. This is the only case the
        /// original comment was ever about.
        case definiteZero
        /// A `nil` URL, `about:blank`, a mid-load state, any other Google page,
        /// a foreign host. Write nothing and keep the previous count — the
        /// identical handling a failed fetch already gets.
        case noAnswer
    }

    /// How many consecutive no-answer cycles an account may contribute its old
    /// count for. Ten minutes: orders of magnitude longer than a recycle, far
    /// shorter than forever.
    static let unansweredLimit = 10

    private let interval: TimeInterval
    private var timer: Timer?
    private var counts: [UUID: Int] = [:]
    /// Accounts with a poll still running. Doubles as the completion's
    /// permission to write: `forget` drops the id, so a poll that outlives its
    /// account cannot put a stale count back.
    private var inFlight: Set<UUID> = []
    /// Consecutive cycles an account has failed to answer. Bounds "keep the
    /// previous count" so it cannot become "stale forever".
    private var unansweredCycles: [UUID: Int] = [:]
    /// Accounts already logged as stuck, so the line is written once per
    /// episode rather than every minute.
    private var reportedStale: Set<UUID> = []
    /// Accounts `SessionHealth` currently reports as signed out — the Dock
    /// badge's trailing `!`.
    private var signedOutAccounts: Set<UUID> = []
    /// Cycle counter, so an account Google is rate-limiting can be polled at
    /// half the rate.
    private var cycle = 0

    /// Supplies the mail webview of every account that currently has Mail on.
    var mailWebViews: MailWebViewProvider = { [] }

    /// One health observation per account per cycle. The detector reads the
    /// classified URL and the probe verdict, never the count, so the badge and
    /// the indicator cannot drag each other around.
    var onObservation: ((UUID, SessionHealth.Observation) -> Void)?

    /// Whether this account's mail webview is in a state where nothing can be
    /// concluded: loading, freshly committed, mid-recycle, offline, just woken,
    /// just launched.
    var isBusy: ((UUID) -> Bool)?

    /// Whether Google is currently pushing this account back, in which case it
    /// is polled every other cycle.
    var isBackingOff: ((UUID) -> Bool)?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Polls every mail account, or just one when `accountId` is given (used
    /// right after a new-mail notification, and on a mail webview's first
    /// `didFinish` so the badge does not sit blank for a minute after launch).
    func refresh(accountId: UUID? = nil) {
        let mailAccounts = mailWebViews()
        let active = Set(mailAccounts.map(\.accountId))
        let targets = mailAccounts.filter { accountId == nil || $0.accountId == accountId }
        if accountId == nil { cycle &+= 1 }
        guard !targets.isEmpty else {
            pruneCounts(keeping: active)
            updateBadge()
            return
        }

        for target in targets {
            // A poll that has not come back yet must not be stacked on by the
            // next 60s tick.
            guard !inFlight.contains(target.accountId) else { continue }
            // Google is answering 429/5xx: halve the rate for this account
            // rather than keep hammering a surface that is already pushing back.
            if accountId == nil, isBackingOff?(target.accountId) == true, cycle % 2 == 0 { continue }

            let busy = isBusy?(target.accountId) == true

            switch Self.reading(for: target.webView.url) {
            case .definiteZero:
                counts[target.accountId] = 0
                clearUnanswered(target.accountId)
                observe(target.accountId, busy ? .busy : .authFailedStrong)
            case .noAnswer:
                noteUnanswered(target.accountId)
                observe(target.accountId, busy ? .busy : .unreachable)
            case .poll:
                poll(accountId: target.accountId, webView: target.webView, busy: busy)
            }
        }

        pruneCounts(keeping: active)
        updateBadge()
    }

    /// Where the feed can actually be read from, and what silence there means.
    static func reading(for url: URL?) -> Reading {
        switch AuthSurface.classify(url) {
        case .signIn:
            return .definiteZero
        case .app(.mail):
            // `canPoll` stays the same-origin fetch precondition; it just
            // stopped being the zero/keep decision.
            return canPoll(url) ? .poll : .noAnswer
        case .app, .other:
            return .noAnswer
        }
    }

    /// Whether the feed can be read from the page this webview is on: only a
    /// Gmail origin, where the fetch is same-origin and the account's cookies
    /// apply.
    static func canPoll(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return mailHosts.contains(host)
    }

    /// What an account contributes to the badge after `cycles` consecutive
    /// unanswered polls: its previous count, until the bound is reached, then
    /// zero.
    static func contribution(previous: Int?, unansweredCycles cycles: Int) -> Int? {
        cycles >= unansweredLimit ? 0 : previous
    }

    /// Drops an account's contribution — after removal, or after Mail is
    /// switched off for it.
    func forget(accountId: UUID) {
        counts[accountId] = nil
        inFlight.remove(accountId)
        unansweredCycles[accountId] = nil
        reportedStale.remove(accountId)
        signedOutAccounts.remove(accountId)
        updateBadge()
    }

    /// Told by the health monitor which accounts are signed out, so the Dock
    /// badge stops lying by omission.
    func setSignedOut(_ accounts: Set<UUID>) {
        guard accounts != signedOutAccounts else { return }
        signedOutAccounts = accounts
        updateBadge()
    }

    private func poll(accountId: UUID, webView: WKWebView, busy: Bool) {
        inFlight.insert(accountId)
        webView.callAsyncJavaScript(
            Self.feedScript,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self else { return }
            // `forget` clears the token, so an account removed mid-poll never
            // gets a stale count written back.
            guard self.inFlight.remove(accountId) != nil else { return }

            let payload = (try? result.get()) as? [String: Any]
            let probe = Self.probe(from: payload)
            self.observe(accountId, busy ? .busy : SessionHealth.observation(for: probe))

            // A failed or aborted fetch is not "zero unread" — keep the last
            // known count so a network blip does not clear the Dock badge.
            guard let payload, (payload["ok"] as? Bool) == true else {
                self.noteUnanswered(accountId)
                self.updateBadge()
                return
            }

            let feed = (payload["feed"] as? String) ?? ""
            self.clearUnanswered(accountId)
            self.counts[accountId] = AtomFeedParser.unreadCount(from: feed) ?? 0
            self.updateBadge()
        }
    }

    /// The script's answer as `SessionHealth` reads it. A payload that never
    /// arrived at all is a thrown fetch by another name.
    static func probe(from payload: [String: Any]?) -> SessionHealth.Probe {
        guard let payload else {
            return SessionHealth.Probe(ok: false, parsed: false, status: -1, type: "error")
        }
        let feed = (payload["feed"] as? String) ?? ""
        return SessionHealth.Probe(
            ok: (payload["ok"] as? Bool) ?? false,
            parsed: AtomFeedParser.unreadCount(from: feed) != nil,
            status: (payload["status"] as? Int) ?? -1,
            type: (payload["type"] as? String) ?? "error"
        )
    }

    private func observe(_ accountId: UUID, _ observation: SessionHealth.Observation) {
        onObservation?(accountId, observation)
    }

    private func noteUnanswered(_ accountId: UUID) {
        let cycles = (unansweredCycles[accountId] ?? 0) + 1
        unansweredCycles[accountId] = cycles
        if let forced = Self.contribution(previous: counts[accountId], unansweredCycles: cycles), forced == 0 {
            counts[accountId] = 0
            if reportedStale.insert(accountId).inserted {
                Log.info("unread feed unanswered for \(cycles) cycles on one account; its badge contribution is now 0")
            }
        }
    }

    private func clearUnanswered(_ accountId: UUID) {
        unansweredCycles[accountId] = 0
        reportedStale.remove(accountId)
    }

    private func pruneCounts(keeping active: Set<UUID>) {
        for id in counts.keys where !active.contains(id) {
            counts[id] = nil
        }
        for id in unansweredCycles.keys where !active.contains(id) {
            unansweredCycles[id] = nil
        }
        inFlight.formIntersection(active)
        reportedStale.formIntersection(active)
        signedOutAccounts.formIntersection(active)
    }

    /// The Dock badge stops lying by omission: a signed-out account is dropped
    /// from the sum, so the badge silently shrank and still read as a confident
    /// number. One `!` however many accounts are out.
    static func badgeLabel(total: Int, anySignedOut: Bool) -> String? {
        if anySignedOut { return total > 0 ? "\(total)!" : "!" }
        return total > 0 ? String(total) : nil
    }

    func updateBadge() {
        let total = counts.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = Self.badgeLabel(total: total, anySignedOut: !signedOutAccounts.isEmpty)
    }
}
