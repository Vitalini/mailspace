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

    /// Returns `{ ok, feed, status, type, reached, host, path }`.
    ///
    /// `ok: false` means the poll never got an answer — a network error, or the
    /// 20s abort below — and the caller must keep the previous count rather
    /// than read it as zero unread.
    ///
    /// A 4xx used to count as zero. It no longer does: only 401/403, which is
    /// Google saying the session is gone, is a zero, and every other 4xx is an
    /// answer without a count (`UnreadCheck.answer`). "This feed does not
    /// exist" and "nothing unread" were the same number until that split.
    ///
    /// `host`/`path` say where the body actually came from, which only differs
    /// from what was asked for on the followed-redirect branch below. A body
    /// from another feed counts another set and is never attributed to the
    /// inbox.
    ///
    /// `status` and `type` are new and additive, and they exist for one reason:
    /// `redirect: 'manual'`. With the default `follow`, a signed-out feed fetch
    /// redirects cross-origin, fails CORS and throws — indistinguishable from
    /// Wi-Fi being off, which is what made silent sync death undetectable.
    /// With `manual`, the same answer arrives as an inspectable
    /// `type: 'opaqueredirect'` response while a genuine offline failure still
    /// throws. That one flag is the whole technical unlock; see `SessionHealth`.
    ///
    /// Gmail's inbox atom feed, and the only feed MailSpace ever asks for.
    ///
    /// It is the one form Google documents, and it says what it does: it
    /// "outputs your inbox". Its `<fullcount>` is unread mail *in the Inbox* —
    /// archived mail cannot appear in it whatever labels it carries.
    ///
    /// v1.1.0 asked for `/mail/feed/atom/%5Esmartlabel_personal` instead, under
    /// a setting captioned "Matches the number Gmail shows on its own Primary
    /// tab". Anything after `/atom/` is a *label* feed, and a label feed is not
    /// inbox-scoped: it counts unread mail carrying that label anywhere in the
    /// mailbox, archived included. On an account with ~3,500 unread sitting in
    /// archived labels and 2 in the inbox, the tab read `999+`.
    ///
    /// There is no atom-feed URL for "unread in Primary" — the feed offers the
    /// inbox and it offers labels, and Primary is the intersection of the two.
    /// So the scope pop-up is gone rather than pointed at another label, and
    /// this constant is the whole of the URL construction.
    static let feedPath = "/mail/feed/atom"

    /// Whether a body served from `host`/`path` is this account's inbox feed.
    ///
    /// Only ever false in one situation, and it is the situation that matters:
    /// the fetch met a redirect, followed it, and landed somewhere else. A body
    /// from a different feed counts a different set, and attributing it to the
    /// inbox is the same class of mistake as the label feed itself.
    ///
    /// `/mail/u/N/feed/atom` is accepted because that is the same inbox feed
    /// under a multi-login profile — a redirect the app already meets in the
    /// wild.
    static func servesTheInboxFeed(host: String, path: String) -> Bool {
        guard mailHosts.contains(host.lowercased()) else { return false }
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == feedPath { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5 else { return false }
        return parts[0] == "mail"
            && parts[1] == "u"
            && !parts[2].isEmpty
            && parts[2].allSatisfy(\.isNumber)
            && parts[3] == "feed"
            && parts[4] == "atom"
    }

    /// The Dock total: only the accounts that opted in (A4). An account left
    /// out is still polled and still holds its own count — it just does not add
    /// to this number.
    static func dockTotal(_ counts: [UUID: Int], participants: Set<UUID>) -> Int {
        counts.reduce(0) { total, entry in
            participants.contains(entry.key) ? total + entry.value : total
        }
    }

    /// The URL is host-relative so the fetch is same-origin whichever Gmail
    /// host the webview is on.
    private static func feedScript(path: String) -> String {
        """
        if (!/^mail\\.google(mail)?\\.com$/.test(location.hostname)) {
          return { ok: true, feed: '', status: -1, type: 'not-gmail', reached: false, host: '', path: '' };
        }
        const requested = '\(path)';
        // Host and path only, never the query: a redirect can carry a token,
        // and nothing needs it to answer "was this the inbox feed".
        const shape = function (raw) {
          try {
            const parsed = new URL(raw, location.origin);
            return { host: parsed.host, path: parsed.pathname };
          } catch (error) {
            return { host: '', path: '' };
          }
        };
        const controller = new AbortController();
        const deadline = setTimeout(function () { controller.abort(); }, 20000);
        try {
          const response = await fetch(requested, {
            credentials: 'include',
            cache: 'no-store',
            redirect: 'manual',
            signal: controller.signal
          });
          if (response.type === 'opaqueredirect') {
            // A redirect came back, so Google answered — whatever it means, the
            // network is up. Which redirect it is, is the question: a signed-out
            // account goes cross-origin to accounts.google.com, a multi-login
            // profile goes same-origin to /mail/u/N/. Following it separates
            // them, because only the cross-origin one fails CORS and throws.
            try {
              const followed = await fetch(requested, {
                credentials: 'include',
                cache: 'no-store',
                redirect: 'follow',
                signal: controller.signal
              });
              // The one branch where the body can come from somewhere other
              // than the path that was asked for, so it is the one branch whose
              // origin is reported back and checked.
              const served = shape(followed.url);
              if (!followed.ok) {
                return {
                  ok: followed.status < 500, feed: '',
                  status: followed.status, type: 'redirect-followed', reached: true,
                  host: served.host, path: served.path
                };
              }
              return {
                ok: true, feed: await followed.text(),
                status: followed.status, type: 'redirect-followed', reached: true,
                host: served.host, path: served.path
              };
            } catch (followError) {
              return {
                ok: false, feed: '', status: 0, type: 'opaqueredirect', reached: true,
                host: '', path: ''
              };
            }
          }
          // `redirect: 'manual'` and not a redirect, so nothing was followed and
          // the body is from the requested path by construction.
          if (!response.ok) {
            return {
              ok: response.status < 500, feed: '',
              status: response.status, type: response.type, reached: true,
              host: location.host, path: requested
            };
          }
          return {
            ok: true, feed: await response.text(),
            status: response.status, type: response.type, reached: true,
            host: location.host, path: requested
          };
        } catch (error) {
          return { ok: false, feed: '', status: -1, type: 'error', reached: false, host: '', path: '' };
        } finally {
          clearTimeout(deadline);
        }
        """
    }

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

    /// One poll in flight.
    ///
    /// Three things can end it — the page answers, the deadline passes, or the
    /// webview it was asked of is thrown away — and exactly one of them may.
    /// `finish` is both the group's `leave` and the settled flag, so a "Check
    /// Now" cannot be left waiting and cannot be left twice.
    ///
    /// The freeze this exists to stop: the token used to be a bare account id
    /// cleared only by the JavaScript completion handler. When the recycler
    /// replaced a mail webview mid-poll — which it does on its own, twice a day
    /// per account — that handler was never called, the id stayed in the set,
    /// and every later cycle skipped the account on `guard !inFlight.contains`.
    /// Its unread count and its calendar countdown then sat frozen until the
    /// app was relaunched, with nothing on screen to say so.
    private final class PollToken {
        let accountId: UUID
        /// The webview the question was put to, so a discard can find the poll
        /// that died with it. Weak: the token must never keep it alive.
        weak var webView: WKWebView?
        var deadline: DispatchWorkItem?
        private var finish: (() -> Void)?

        init(accountId: UUID, webView: WKWebView, finish: @escaping () -> Void) {
            self.accountId = accountId
            self.webView = webView
            self.finish = finish
        }

        /// True for the one ending that gets to act on this poll.
        func claim() -> Bool {
            guard let finish else { return false }
            self.finish = nil
            deadline?.cancel()
            deadline = nil
            finish()
            return true
        }
    }

    /// How long a poll may go unanswered before the slot is taken back.
    ///
    /// Longer than the script's own 20-second `AbortController`, so a slow but
    /// live page still answers for itself, and well inside the 60-second cycle
    /// so the next tick can ask again.
    static let defaultTimeout: TimeInterval = 30

    private let interval: TimeInterval
    private let pollTimeout: TimeInterval
    private var timer: Timer?
    private var counts: [UUID: Int] = [:]
    /// Accounts with a poll still running. Doubles as the completion's
    /// permission to write: `forget` drops the token, so a poll that outlives
    /// its account cannot put a stale count back.
    private var inFlight: [UUID: PollToken] = [:]
    /// Consecutive cycles an account has failed to answer. Bounds "keep the
    /// previous count" so it cannot become "stale forever".
    private var unansweredCycles: [UUID: Int] = [:]
    /// Accounts already logged as stuck, so the line is written once per
    /// episode rather than every minute.
    private var reportedStale: Set<UUID> = []
    /// Accounts `SessionHealth` currently reports as signed out — the Dock
    /// badge's trailing `!`.
    private var signedOutAccounts: Set<UUID> = []
    /// Accounts whose Mail tab the recycler could not get back onto its page.
    /// Same `!`, same reason: the number below it is not the whole truth.
    private var stalledAccounts: Set<UUID> = []
    /// Cycle counter, so an account Google is rate-limiting can be polled at
    /// half the rate.
    private var cycle = 0
    /// What each account's last check requested and got back — the whole of the
    /// Settings diagnostic. Kept per account because that is the grain the
    /// owner compares against Gmail's own sidebar.
    private var lastChecks: [UUID: UnreadFeedAnswer] = [:]
    /// When the last check of any account completed.
    private(set) var lastCheckedAt: Date?

    /// Supplies the mail webview of every account that currently has Mail on.
    ///
    /// Filtered on `mailEnabled` **alone**, never on `countInBadge`: an account
    /// left out of the Dock total is still polled, because its count belongs to
    /// its own tab as well (KTD-S7).
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

    /// Every answer from Google, reachable or not. This is the only
    /// reachability evidence in the app that is about *Google* rather than
    /// about the local link, which is why the recycler prefers it.
    var onReachability: ((Bool) -> Void)?

    /// The accounts whose counts add up to the Dock badge (A4). Applied at the
    /// summing step, so ticking the box re-totals immediately instead of after
    /// a poll cycle.
    var badgeParticipants: () -> Set<UUID> = { [] }

    /// The counts settled. Fired from `updateBadge()` — the one place they ever
    /// do — so the Dock total and the per-tab pills are drawn from the same
    /// number on the same pass and can never disagree (KTD-S7).
    var onCountsChanged: (() -> Void)?

    /// This account's own unread count, for its own tab (U10).
    ///
    /// A missing key is `nil` — never polled, nothing known — which the tab
    /// renders identically to a definite zero.
    func count(for accountId: UUID) -> Int? {
        counts[accountId]
    }

    /// This account's last check, for the Settings status line. `nil` until it
    /// has been checked once.
    func lastCheck(for accountId: UUID) -> UnreadFeedAnswer? {
        lastChecks[accountId]
    }

    /// How the feed script is put to a webview.
    ///
    /// The same seam as `Log.sink` and `TabRecycler.now`, and for the same
    /// reason: the two endings that exist precisely because an answer may never
    /// arrive cannot be driven through a real page — a test would have to make
    /// a callback go missing on purpose. Nothing in the app ever replaces this.
    var ask: (WKWebView, @escaping (Result<Any, any Error>) -> Void) -> Void = { webView, answer in
        webView.callAsyncJavaScript(
            UnreadPoller.feedScript(path: UnreadPoller.feedPath),
            arguments: [:],
            in: nil,
            in: .defaultClient,
            completionHandler: answer
        )
    }

    /// No `AppSettings`: there is nothing left for a preference to choose. The
    /// feed is one constant, and the poll interval arrives already read.
    init(interval: TimeInterval = 60, timeout: TimeInterval = UnreadPoller.defaultTimeout) {
        self.interval = interval
        self.pollTimeout = timeout
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
    ///
    /// `completion` runs once every fetch this call started has answered — what
    /// the Settings "Check Now" button waits on, the same contract
    /// `NextEventPoller.refresh` already offers.
    func refresh(accountId: UUID? = nil, completion: (() -> Void)? = nil) {
        let mailAccounts = mailWebViews()
        let active = Set(mailAccounts.map(\.accountId))
        let targets = mailAccounts.filter { accountId == nil || $0.accountId == accountId }
        if accountId == nil { cycle &+= 1 }
        guard !targets.isEmpty else {
            pruneCounts(keeping: active)
            updateBadge()
            completion?()
            return
        }

        let group = DispatchGroup()

        for target in targets {
            // A poll that has not come back yet must not be stacked on by the
            // next 60s tick. Bounded by the token's own deadline, so silence
            // here can never become permanent.
            guard inFlight[target.accountId] == nil else { continue }
            // Google is answering 429/5xx: halve the rate for this account
            // rather than keep hammering a surface that is already pushing back.
            if accountId == nil, isBackingOff?(target.accountId) == true, cycle % 2 == 0 { continue }

            let busy = isBusy?(target.accountId) == true

            switch Self.reading(for: target.webView.url) {
            case .definiteZero:
                // Google has the tab on its own login page. The only real zero
                // there is, and it renders as nothing rather than as a `0`.
                record(Self.signedOutOnThePage, for: target.accountId)
                counts[target.accountId] = 0
                clearUnanswered(target.accountId)
                observe(target.accountId, busy ? .busy : .authFailedStrong)
            case .noAnswer:
                record(Self.notOnMail, for: target.accountId)
                noteUnanswered(target.accountId)
                observe(target.accountId, busy ? .busy : .unreachable)
            case .poll:
                group.enter()
                poll(accountId: target.accountId, webView: target.webView, busy: busy) {
                    group.leave()
                }
            }
        }

        pruneCounts(keeping: active)
        updateBadge()
        if let completion {
            group.notify(queue: .main, execute: completion)
        }
    }

    /// The two answers the poller settles without asking Gmail anything, so the
    /// Settings line covers them too rather than reading "not checked yet" for
    /// an account that is plainly signed out.
    static let signedOutOnThePage = UnreadFeedAnswer(
        outcome: .signedOut, count: 0, status: -1, type: "sign-in"
    )
    static let notOnMail = UnreadFeedAnswer(
        outcome: .notMail, count: nil, status: -1, type: "not-gmail"
    )
    /// A poll that was asked and never came back at all. Reported in the
    /// Settings line as its own thing rather than left reading as the last
    /// successful check, which is what "frozen" looked like from there.
    static let notAnswering = UnreadFeedAnswer(
        outcome: .noAnswer, count: nil, status: -1, type: "timeout"
    )

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
        if let token = inFlight[accountId] { release(token) }
        unansweredCycles[accountId] = nil
        lastChecks[accountId] = nil
        reportedStale.remove(accountId)
        signedOutAccounts.remove(accountId)
        stalledAccounts.remove(accountId)
        updateBadge()
    }

    /// Told by the health monitor which accounts are signed out, so the Dock
    /// badge stops lying by omission.
    func setSignedOut(_ accounts: Set<UUID>) {
        guard accounts != signedOutAccounts else { return }
        signedOutAccounts = accounts
        updateBadge()
    }

    /// Told by the recycler which accounts have a Mail tab that failed to load
    /// and has not come back. Carried in the same `!` as signed-out: both mean
    /// "this number is not the whole truth".
    func setStalled(_ accounts: Set<UUID>) {
        guard accounts != stalledAccounts else { return }
        stalledAccounts = accounts
        updateBadge()
    }

    /// Re-totals the badge without going near Gmail — what a change to A4 needs.
    func refreshBadge() {
        updateBadge()
    }

    private func poll(
        accountId: UUID,
        webView: WKWebView,
        busy: Bool,
        completion: @escaping () -> Void
    ) {
        let token = PollToken(accountId: accountId, webView: webView, finish: completion)
        inFlight[accountId] = token

        let deadline = DispatchWorkItem { [weak self] in self?.pollTimedOut(token) }
        token.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + pollTimeout, execute: deadline)

        ask(webView) { [weak self] result in
            guard let self else {
                _ = token.claim()
                return
            }
            // `forget`, the deadline and a discarded webview all clear the
            // token, so a poll that outlives its webview or its account never
            // gets a stale count written back.
            guard self.release(token) else { return }

            let payload = (try? result.get()) as? [String: Any]
            let probe = Self.probe(from: payload)
            // Reported before the busy filter, and whatever the verdict: a
            // probe that got *any* answer out of Google proves the path to
            // Google is open, which is the only reachability question the
            // recycler actually cares about.
            if probe.reached { self.onReachability?(true) }
            self.observe(accountId, busy ? .busy : SessionHealth.observation(for: probe))

            // One decision, in one place: an answer either carries a count this
            // app can stand behind or it does not, and everything that does not
            // is handled exactly as a failed fetch already was — keep the last
            // count, bounded at ten cycles. Nothing here can produce a zero.
            let answer = UnreadCheck.answer(from: payload, requestedPath: Self.feedPath)
            self.record(answer, for: accountId)
            if let count = answer.count {
                self.clearUnanswered(accountId)
                self.counts[accountId] = count
            } else {
                self.noteUnanswered(accountId)
            }
            self.updateBadge()
        }
    }

    /// Hands this poll to the caller, if it is still the live one for its
    /// account and nothing else has claimed it.
    @discardableResult
    private func release(_ token: PollToken) -> Bool {
        guard token.claim() else { return false }
        if inFlight[token.accountId] === token { inFlight[token.accountId] = nil }
        return true
    }

    /// The page never answered. Handled exactly as the `noAnswer` reading is —
    /// keep the previous count, bounded at ten cycles — and, above all, hand the
    /// slot back so the next cycle asks again.
    private func pollTimedOut(_ token: PollToken) {
        guard release(token) else { return }
        record(Self.notAnswering, for: token.accountId)
        noteUnanswered(token.accountId)
        observe(token.accountId, isBusy?(token.accountId) == true ? .busy : .unreachable)
        updateBadge()
    }

    /// The webview a poll was asked of has been thrown away — the recycler
    /// rebuilding a tab, an account's service being switched off — so its
    /// callback is never coming.
    ///
    /// Without this the account's badge froze until the app was relaunched. The
    /// deadline alone would eventually free it; this frees it at once, on the
    /// event that already knows.
    func webViewWasDiscarded(_ webView: WKWebView) {
        guard let token = inFlight.values.first(where: { $0.webView === webView }) else { return }
        release(token)
    }

    private func record(_ answer: UnreadFeedAnswer, for accountId: UUID) {
        lastChecks[accountId] = answer
        lastCheckedAt = Date()
    }

    /// The script's answer as `SessionHealth` reads it. A payload that never
    /// arrived at all is a thrown fetch by another name.
    static func probe(from payload: [String: Any]?) -> SessionHealth.Probe {
        guard let payload else {
            return SessionHealth.Probe(ok: false, parsed: false, status: -1, type: "error", reached: false)
        }
        let feed = (payload["feed"] as? String) ?? ""
        return SessionHealth.Probe(
            ok: (payload["ok"] as? Bool) ?? false,
            parsed: AtomFeedParser.unreadCount(from: feed) != nil,
            status: (payload["status"] as? Int) ?? -1,
            type: (payload["type"] as? String) ?? "error",
            reached: (payload["reached"] as? Bool) ?? false
        )
    }

    private func observe(_ accountId: UUID, _ observation: SessionHealth.Observation) {
        onObservation?(accountId, observation)
    }

    private func noteUnanswered(_ accountId: UUID) {
        let cycles = (unansweredCycles[accountId] ?? 0) + 1
        unansweredCycles[accountId] = cycles
        guard cycles >= Self.unansweredLimit else { return }
        counts[accountId] = Self.contribution(previous: counts[accountId], unansweredCycles: cycles)
        if reportedStale.insert(accountId).inserted {
            Log.info(
                "unread feed unanswered for \(cycles) cycles on account "
                + "\(accountId.uuidString.prefix(8)); its badge contribution is now 0"
            )
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
        for id in lastChecks.keys where !active.contains(id) {
            lastChecks[id] = nil
        }
        // Released rather than dropped: the token owns a "Check Now" caller's
        // completion, and forgetting it silently would leave that button
        // spinning for the rest of the session.
        for (id, token) in inFlight where !active.contains(id) {
            release(token)
        }
        reportedStale.formIntersection(active)
        signedOutAccounts.formIntersection(active)
        stalledAccounts.formIntersection(active)
    }

    /// The Dock badge stops lying by omission: an account that is signed out —
    /// or whose tab failed to load and has not come back — is dropped from the
    /// sum, so the badge silently shrank and still read as a confident number.
    /// One `!` however many accounts are affected, for either reason.
    static func badgeLabel(total: Int, anySignedOut: Bool) -> String? {
        if anySignedOut { return total > 0 ? "\(total)!" : "!" }
        return total > 0 ? String(total) : nil
    }

    func updateBadge() {
        let total = Self.dockTotal(counts, participants: badgeParticipants())
        NSApp.dockTile.badgeLabel = Self.badgeLabel(
            total: total,
            anySignedOut: !signedOutAccounts.isEmpty || !stalledAccounts.isEmpty
        )
        onCountsChanged?()
    }
}
