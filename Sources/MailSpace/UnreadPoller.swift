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

    private static let feedScript = """
    try {
      const response = await fetch('https://mail.google.com/mail/feed/atom', {
        credentials: 'include',
        cache: 'no-store'
      });
      if (!response.ok) { return ''; }
      return await response.text();
    } catch (error) {
      return '';
    }
    """

    private let interval: TimeInterval
    private var timer: Timer?
    private var counts: [UUID: Int] = [:]

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
        updateBadge()
    }

    private func poll(accountId: UUID, webView: WKWebView) {
        webView.callAsyncJavaScript(
            Self.feedScript,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            guard let self else { return }
            // A signed-out account, an expired session or a retired feed all
            // land here as zero rather than as an error the user has to see.
            let feed = (try? result.get()) as? String ?? ""
            self.counts[accountId] = AtomFeedParser.unreadCount(from: feed) ?? 0
            self.updateBadge()
        }
    }

    private func pruneCounts(keeping active: Set<UUID>) {
        for id in counts.keys where !active.contains(id) {
            counts[id] = nil
        }
    }

    private func updateBadge() {
        let total = counts.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : nil
    }
}
