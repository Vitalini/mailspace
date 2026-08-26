import AppKit
import WebKit

/// Keeps the Dock badge showing the total unread count across accounts.
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

    /// Returns `{ ok, feed }`. `ok: false` means the poll never got an answer —
    /// a network error, or the 20s abort below — and the caller must keep the
    /// previous count rather than read it as zero unread. A 4xx *is* an answer
    /// (signed out, feed retired), so it counts as zero.
    private static let feedScript = """
    const controller = new AbortController();
    const deadline = setTimeout(function () { controller.abort(); }, 20000);
    try {
      const response = await fetch('https://mail.google.com/mail/feed/atom', {
        credentials: 'include',
        cache: 'no-store',
        signal: controller.signal
      });
      if (!response.ok) { return { ok: response.status < 500, feed: '' }; }
      return { ok: true, feed: await response.text() };
    } catch (error) {
      return { ok: false, feed: '' };
    } finally {
      clearTimeout(deadline);
    }
    """

    private let interval: TimeInterval
    private var timer: Timer?
    private var counts: [UUID: Int] = [:]
    /// Accounts with a poll still running. Doubles as the completion's
    /// permission to write: `forget` drops the id, so a poll that outlives its
    /// account cannot put a stale count back.
    private var inFlight: Set<UUID> = []

    /// Supplies the mail webview of every account that currently has Mail on.
    var mailWebViews: MailWebViewProvider = { [] }

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
    /// right after a new-mail notification so the badge keeps up).
    func refresh(accountId: UUID? = nil) {
        let mailAccounts = mailWebViews()
        let active = Set(mailAccounts.map(\.accountId))
        let targets = mailAccounts.filter { accountId == nil || $0.accountId == accountId }
        guard !targets.isEmpty else {
            pruneCounts(keeping: active)
            updateBadge()
            return
        }

        for target in targets {
            // A poll that has not come back yet must not be stacked on by the
            // next 60s tick.
            guard !inFlight.contains(target.accountId) else { continue }
            // A webview that has not loaded anything yet has no origin to
            // fetch from.
            guard target.webView.url != nil else {
                counts[target.accountId] = 0
                continue
            }
            poll(accountId: target.accountId, webView: target.webView)
        }

        pruneCounts(keeping: active)
        updateBadge()
    }

    /// Drops an account's contribution — after removal, or after Mail is
    /// switched off for it.
    func forget(accountId: UUID) {
        counts[accountId] = nil
        inFlight.remove(accountId)
        updateBadge()
    }

    private func poll(accountId: UUID, webView: WKWebView) {
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
            // A failed or aborted fetch is not "zero unread" — keep the last
            // known count so a network blip does not clear the Dock badge.
            guard let payload, (payload["ok"] as? Bool) == true else { return }

            let feed = (payload["feed"] as? String) ?? ""
            self.counts[accountId] = AtomFeedParser.unreadCount(from: feed) ?? 0
            self.updateBadge()
        }
    }

    private func pruneCounts(keeping active: Set<UUID>) {
        for id in counts.keys where !active.contains(id) {
            counts[id] = nil
        }
        inFlight.formIntersection(active)
    }

    private func updateBadge() {
        let total = counts.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }
}
