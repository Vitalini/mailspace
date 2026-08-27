import AppKit
import WebKit

/// Keeps one number per account: how long until that account's next event
/// later today (plan unit U11).
///
/// The calendar twin of `UnreadPoller`, and deliberately written to look like
/// it. The source is Google Calendar's own no-JavaScript agenda renderer,
/// fetched *inside* each account's calendar webview: same origin, so the
/// account's session cookies apply, no new authentication exists and the
/// countdown on the Talkable tab is by construction the Talkable calendar's
/// (KTD-S11).
///
/// Two things this poller does that `UnreadPoller` does not:
///
/// - **It names the day in the URL.** `dates=<today>/<tomorrow>` is why scroll
///   position, the chosen view and a tab left open past midnight are all
///   irrelevant — the answer is about today because we asked about today, not
///   because the page happened to be showing it.
/// - **It parses in the page.** The response holds meeting titles; the bridge
///   carries `{ ok, status, startsInSeconds, remainingCount }` and nothing else
///   (KTD-S14, S22).
///
/// The failure policy, in one place: nothing understood shows nothing; a failed
/// fetch keeps the last value until it retires; a 4xx clears it at once.
final class NextEventPoller {
    typealias CalendarWebViewProvider = () -> [(accountId: UUID, calendarId: String, webView: WKWebView)]

    /// The one host the fetch is same-origin from.
    static let calendarHosts: Set<String> = ["calendar.google.com"]

    /// The exact request, built in Swift so it is testable and so nothing is
    /// interpolated into a JavaScript source string.
    ///
    /// `GET /calendar/u/0/htmlembed?src=<calendar id>&mode=AGENDA&hl=en
    /// &ctz=<IANA zone>&dates=<YYYYMMDD>/<YYYYMMDD>` — host-relative, so it is
    /// same-origin from whichever Calendar URL the tab is on. `hl=en` makes the
    /// day header and the time cells deterministic; `ctz` makes Google do the
    /// time-zone conversion; `dates` is half-open, so today is one request.
    static func agendaPath(
        calendarId: String,
        timeZone: TimeZone,
        window: (start: String, end: String)
    ) -> String {
        // The stamps are built by `CalendarCountdown.stamp` and are always
        // digits, so the separator can stay a literal slash.
        "/calendar/u/0/htmlembed"
            + "?src=\(escaped(calendarId))"
            + "&mode=AGENDA"
            + "&hl=en"
            + "&ctz=\(escaped(timeZone.identifier))"
            + "&dates=\(window.start)/\(window.end)"
    }

    /// Whether the agenda can be read from the page this webview is on.
    ///
    /// A signed-out account sits on `accounts.google.com`, where the fetch
    /// would be cross-origin. That is a definite "nothing to show" rather than
    /// a failed check, and it is why signing out inside a tab makes the
    /// countdown disappear instead of freezing.
    static func canPoll(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return calendarHosts.contains(host)
    }

    private let settings: AppSettings
    private let fetchInterval: TimeInterval
    private let renderInterval: TimeInterval
    /// At most one fetch per account per this long, for the tab-became-visible
    /// poke: `tabBecameVisible` fires on every `refresh()`, not only on a user
    /// tab switch, so ⌘1/⌘2 flipping would otherwise be a burst.
    private let pokeThrottle: TimeInterval

    private var fetchTimer: Timer?
    private var renderTimer: Timer?
    private var midnightTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    private var entries: [UUID: CalendarCountdown.Entry] = [:]
    /// What each account's last check came back as. Feeds the Settings status
    /// line, which is how the owner finds out whether this works at all without
    /// anyone reading his session.
    private var outcomes: [UUID: AgendaOutcome] = [:]
    /// Accounts with a fetch still running. Doubles as the completion's
    /// permission to write: `forget` drops the id, so a fetch that outlives its
    /// account cannot put a stale entry back.
    private var inFlight: Set<UUID> = []
    private var lastFetchStarted: [UUID: Date] = [:]
    /// The labels last handed out, so the change callback fires when the tab
    /// bar would actually look different rather than every 30 seconds.
    private var lastLabels: [UUID: String] = [:]
    private var running = false

    /// Supplies the calendar webview of every account that can have a
    /// countdown: Calendar switched on, and an address to ask about (G-C3 —
    /// `src=default` and `src=primary` both 404, so a concrete id is required).
    var calendarWebViews: CalendarWebViewProvider = { [] }

    /// Something a Calendar tab would draw has changed. Fired where entries
    /// settle — the single place, mirroring `UnreadPoller.updateBadge()`.
    var onCountdownsChanged: (() -> Void)?

    init(
        settings: AppSettings = .shared,
        fetchInterval: TimeInterval = 300,
        renderInterval: TimeInterval = 30,
        pokeThrottle: TimeInterval = 60
    ) {
        self.settings = settings
        self.fetchInterval = fetchInterval
        self.renderInterval = renderInterval
        self.pokeThrottle = pokeThrottle
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Reading the answer

    /// Seconds until this account's next event today, or `nil` when there is
    /// nothing to say — never checked, not understood, today finished, signed
    /// out, retired, or G6 off.
    func secondsUntilNextEvent(for accountId: UUID, now: Date = Date()) -> Int? {
        guard settings.showsCalendarCountdown, let entry = entries[accountId] else { return nil }
        guard !CalendarCountdown.isRetired(entry: entry, now: now, timeZone: .current) else { return nil }
        return CalendarCountdown.secondsUntilStart(entry: entry, now: now)
    }

    /// The label a Calendar tab would draw: `5m`, or `(5m)`, or nothing.
    func countdown(
        for accountId: UUID,
        style: CalendarCountdown.LabelStyle = .bare,
        now: Date = Date()
    ) -> String? {
        guard let seconds = secondsUntilNextEvent(for: accountId, now: now) else { return nil }
        return CalendarCountdown.label(secondsUntilStart: seconds, style: style)
    }

    /// The spoken form, for a tooltip or `accessibilityLabel`.
    func longFormCountdown(for accountId: UUID, now: Date = Date()) -> String? {
        guard let seconds = secondsUntilNextEvent(for: accountId, now: now) else { return nil }
        return CalendarCountdown.longForm(secondsUntilStart: seconds)
    }

    /// How many events are still to start today for this account. A number the
    /// tab does not draw today; it is here because it is already in the payload
    /// and throwing it away would mean a second fetch to get it back.
    func remainingEventCount(for accountId: UUID, now: Date = Date()) -> Int? {
        guard settings.showsCalendarCountdown, let entry = entries[accountId] else { return nil }
        guard !CalendarCountdown.isRetired(entry: entry, now: now, timeZone: .current) else { return nil }
        return entry.remainingCount
    }

    /// What the Settings line says. Shapes and counts only — never anything
    /// read out of the page.
    var status: CalendarCountdownStatus {
        let accounts = calendarWebViews()
        let now = Date()
        let showing = accounts.reduce(0) { total, account in
            total + (secondsUntilNextEvent(for: account.accountId, now: now) != nil ? 1 : 0)
        }
        return CalendarCountdown.status(
            enabled: settings.showsCalendarCountdown,
            calendarAccounts: accounts.count,
            outcomes: accounts.compactMap { outcomes[$0.accountId] },
            showing: showing
        )
    }

    // MARK: - Lifecycle

    /// Starts both clocks. Called when G6 is on; calling it twice is a restart,
    /// not a second set of timers.
    func start() {
        stop()
        running = true

        let fetch = Timer.scheduledTimer(withTimeInterval: fetchInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(fetch, forMode: .common)
        fetchTimer = fetch

        // A second, much cheaper clock: the label is arithmetic over two dates,
        // no I/O. 30 seconds rather than 60 because at 60 a displayed minute can
        // be a full minute stale. The tolerance lets AppKit coalesce the wake.
        let render = Timer.scheduledTimer(withTimeInterval: renderInterval, repeats: true) { [weak self] _ in
            self?.rerender()
        }
        render.tolerance = 5
        RunLoop.main.add(render, forMode: .common)
        renderTimer = render

        scheduleMidnight()
        observe()
        refresh()
    }

    /// Stops both clocks and drops the cache.
    ///
    /// Switching G6 off has to be the precise inverse of switching it on, so
    /// nothing survives to reappear: no timers, no entries, no outcomes.
    func stop() {
        running = false
        fetchTimer?.invalidate()
        fetchTimer = nil
        renderTimer?.invalidate()
        renderTimer = nil
        midnightTimer?.invalidate()
        midnightTimer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        entries = [:]
        outcomes = [:]
        inFlight = []
        lastFetchStarted = [:]
        notifyIfChanged()
    }

    /// Drops an account's answer — after removal, or after Calendar is switched
    /// off for it.
    func forget(accountId: UUID) {
        entries[accountId] = nil
        outcomes[accountId] = nil
        inFlight.remove(accountId)
        lastFetchStarted[accountId] = nil
        notifyIfChanged()
    }

    // MARK: - Fetching

    /// Fetches every calendar account, or just one when `accountId` is given.
    /// `completion` runs once every fetch this call started has answered — what
    /// the Settings "Check Now" button waits on.
    func refresh(accountId: UUID? = nil, completion: (() -> Void)? = nil) {
        guard settings.showsCalendarCountdown else {
            completion?()
            return
        }

        let accounts = calendarWebViews()
        let active = Set(accounts.map(\.accountId))
        prune(keeping: active)

        let targets = accounts.filter { accountId == nil || $0.accountId == accountId }
        let group = DispatchGroup()

        for target in targets {
            guard !inFlight.contains(target.accountId) else { continue }
            // Not on a Calendar page: a definite nothing, not a failed check.
            guard Self.canPoll(target.webView.url) else {
                entries[target.accountId] = nil
                outcomes[target.accountId] = .notCalendar
                continue
            }
            group.enter()
            fetch(accountId: target.accountId, calendarId: target.calendarId, webView: target.webView) {
                group.leave()
            }
        }

        notifyIfChanged()
        if let completion {
            group.notify(queue: .main, execute: completion)
        }
    }

    /// The tab-became-visible poke, so the number is right on return from a tab
    /// rather than up to five minutes later. Throttled, because
    /// `tabBecameVisible` fires on every `refresh()` of the main window.
    func refreshIfStale(accountId: UUID, now: Date = Date()) {
        guard settings.showsCalendarCountdown else { return }
        if let last = lastFetchStarted[accountId], now.timeIntervalSince(last) < pokeThrottle { return }
        refresh(accountId: accountId)
    }

    private func fetch(
        accountId: UUID,
        calendarId: String,
        webView: WKWebView,
        completion: @escaping () -> Void
    ) {
        let requestedAt = Date()
        let timeZone = TimeZone.current
        let path = Self.agendaPath(
            calendarId: calendarId,
            timeZone: timeZone,
            window: CalendarCountdown.todayWindow(now: requestedAt, timeZone: timeZone)
        )

        inFlight.insert(accountId)
        lastFetchStarted[accountId] = requestedAt
        webView.callAsyncJavaScript(
            AgendaScript.fetchScript,
            arguments: [
                "path": path,
                "nowMs": requestedAt.timeIntervalSince1970 * 1000
            ],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            defer { completion() }
            guard let self else { return }
            // `forget` clears the token, so an account removed mid-fetch never
            // gets a stale entry written back.
            guard self.inFlight.remove(accountId) != nil else { return }
            self.apply(result: result, accountId: accountId, requestedAt: requestedAt)
        }
    }

    /// The failure policy, in one switch.
    private func apply(result: Result<Any, any Error>, accountId: UUID, requestedAt: Date) {
        // Only the outcome code is ever read out of the payload, and only
        // numbers are in it. Nothing from the response is logged.
        let payload = (try? result.get()) as? [String: Any]
        guard let payload,
              let raw = payload["status"] as? Int,
              let outcome = AgendaOutcome(rawValue: raw)
        else {
            // The script itself did not come back. Not an answer.
            outcomes[accountId] = .noAnswer
            notifyIfChanged()
            return
        }

        outcomes[accountId] = outcome
        switch outcome {
        case .ok:
            if let seconds = payload["startsInSeconds"] as? Int, seconds >= 0 {
                entries[accountId] = CalendarCountdown.Entry(
                    start: requestedAt.addingTimeInterval(TimeInterval(seconds)),
                    fetchedAt: requestedAt,
                    remainingCount: (payload["remainingCount"] as? Int) ?? 0
                )
            } else {
                // Understood, and today holds nothing more. A definite empty.
                entries[accountId] = nil
            }
        case .refused, .notCalendar:
            // A definite answer that there is nothing to show. Clear now rather
            // than holding a number that is no longer backed by anything.
            entries[accountId] = nil
        case .noAnswer, .notUnderstood:
            // Keep whatever is cached; it retires on its own (15 minutes, the
            // event's start, or local midnight) instead of ageing on screen.
            break
        }
        notifyIfChanged()
    }

    private func prune(keeping active: Set<UUID>) {
        for id in entries.keys where !active.contains(id) { entries[id] = nil }
        for id in outcomes.keys where !active.contains(id) { outcomes[id] = nil }
        inFlight.formIntersection(active)
    }

    // MARK: - The render clock

    private func rerender() {
        notifyIfChanged()
    }

    /// Fires `onCountdownsChanged` only when a label a tab would draw has
    /// actually changed. A tab bar that re-lays out every 30 seconds for no
    /// reason is the countdown's version of driving the poller through
    /// `refresh()` (KTD-S8).
    private func notifyIfChanged() {
        let now = Date()
        var labels: [UUID: String] = [:]
        for id in entries.keys {
            if let label = countdown(for: id, now: now) { labels[id] = label }
        }
        guard labels != lastLabels else { return }
        lastLabels = labels
        onCountdownsChanged?()
    }

    // MARK: - The other wakeups

    private func observe() {
        let center = NotificationCenter.default
        // The string is always stale after sleep, and so is the answer.
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })
        // A different zone means a different "today" and a different window.
        observers.append(center.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.entries = [:]
            self.notifyIfChanged()
            self.scheduleMidnight()
            self.refresh()
        })
    }

    /// One shot at the next local midnight, then again. "Today" changes there,
    /// so every cached answer is about yesterday and the window has to move.
    private func scheduleMidnight() {
        midnightTimer?.invalidate()
        midnightTimer = nil
        guard running else { return }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        guard let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        // A second past, so the new day is unambiguously the current one.
        let timer = Timer(fire: midnight.addingTimeInterval(1), interval: 0, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.entries = [:]
            self.notifyIfChanged()
            self.scheduleMidnight()
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    // MARK: - Helpers

    /// Query-value escaping that also encodes `+` and `/`: an address can carry
    /// a `+` tag, which a server reads as a space, and a zone identifier carries
    /// a slash.
    private static func escaped(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#/;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
