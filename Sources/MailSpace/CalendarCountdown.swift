import Foundation

/// What one account's last agenda check came back as.
///
/// Integers, because this is exactly what crosses the JS bridge (KTD-S14): the
/// injected script returns a status code and two numbers, never a string, so no
/// event title can reach Swift even by accident.
enum AgendaOutcome: Int, Equatable, CaseIterable {
    /// The agenda was fetched and understood. It may still hold nothing.
    case ok = 0
    /// The webview is not on `calendar.google.com` — signed out, or mid
    /// navigation. A definite "nothing to show", not a failed check.
    case notCalendar = 1
    /// Google answered 4xx. A definite answer: this calendar cannot be read
    /// this way, so the cached value is dropped at once rather than held.
    case refused = 2
    /// No answer at all — network error, the 20s abort, or a 5xx. The cached
    /// value is kept until it retires.
    case noAnswer = 3
    /// Something came back, but not an agenda MailSpace recognises: no
    /// `view-container` (KTD-S13), the wrong number of day sections, a header
    /// that is not today, or a time cell in an unknown shape.
    case notUnderstood = 4
}

/// What the Settings status line says about the countdown, as a value rather
/// than a string built at the call site.
///
/// It reports *shapes* only — how many Calendar tabs were checked and what the
/// last answer was. It can never carry an event title, a time or a count of
/// anything read out of the page (S22).
struct CalendarCountdownStatus: Equatable {
    enum Kind: Equatable {
        case disabled
        case noCalendarAccounts
        case notCheckedYet
        case waitingForCalendar
        case refused
        case notUnderstood
        case noAnswer
        case working
    }

    let kind: Kind
    /// How many Calendar tabs the last pass considered.
    let checked: Int
    /// How many of them currently have a countdown to show.
    let showing: Int

    var text: String {
        switch kind {
        case .disabled:
            return "Turned off."
        case .noCalendarAccounts:
            return "No account has Calendar switched on."
        case .notCheckedYet:
            return "Not checked yet."
        case .waitingForCalendar:
            return "Waiting for a signed-in Calendar tab."
        case .refused:
            return "Google refused the request — a calendar could not be read this way."
        case .notUnderstood:
            return "Google answered, but not with an agenda MailSpace understands."
        case .noAnswer:
            return "The last check got no answer."
        case .working:
            return "Working — \(checked) Calendar \(checked == 1 ? "tab" : "tabs") checked, "
                + "\(showing) showing a countdown."
        }
    }
}

/// The pure half of the Calendar tab countdown (plan unit U11): which day to
/// ask Google for, how to say how long is left, and when a cached answer stops
/// being worth showing.
///
/// Nothing here touches AppKit, WebKit or the network, so every rule below is a
/// unit test rather than something to watch for on screen.
enum CalendarCountdown {
    /// One account's cached answer.
    struct Entry: Equatable {
        /// When the next event starts, as an absolute instant.
        ///
        /// Absolute rather than "seconds left" is what lets the label tick down
        /// for five minutes without another fetch.
        let start: Date
        let fetchedAt: Date
        /// How many events are still to start today. A number, never a list.
        let remainingCount: Int
    }

    /// How the label is rendered. The arithmetic is identical either way, so
    /// the eventual tab-bar pass picks a form without reformatting anything.
    enum LabelStyle {
        /// `5m` — the pill form.
        case bare
        /// `(5m)` — the parenthesised form the owner asked for in words.
        case parenthesised
    }

    /// A cached answer older than this is retired rather than shown. Fifteen
    /// minutes is three missed five-minute fetches: long enough that a blip
    /// does not blank the tab, short enough that a countdown cannot drift into
    /// being wrong.
    static let maximumAge: TimeInterval = 15 * 60

    // MARK: - The date window

    /// The half-open `dates=` window for *today* in `timeZone`, as the two
    /// `YYYYMMDD` stamps Google's agenda renderer takes.
    ///
    /// Built with `startOfDay` and `byAdding: .day`, never `+ 86400`: a DST day
    /// is 23 or 25 hours long, and the arithmetic version silently asks for the
    /// wrong day twice a year — on a 25-hour day it asks for today twice and
    /// the tab shows nothing all day.
    static func todayWindow(now: Date, timeZone: TimeZone) -> (start: String, end: String) {
        let calendar = gregorian(timeZone)
        let startOfToday = calendar.startOfDay(for: now)
        // A nil here is impossible for the Gregorian calendar. If it ever
        // happened the window would collapse to nothing, which shows nothing —
        // the safe direction.
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday
        return (stamp(startOfToday, timeZone: timeZone), stamp(startOfTomorrow, timeZone: timeZone))
    }

    /// `YYYYMMDD` for a date read in `timeZone`.
    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let parts = gregorian(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - The label

    /// The countdown text, or `nil` when there is nothing honest to say.
    ///
    /// Floored, never rounded, so the number always reads as *at least this
    /// long*: understating the time you have is the safe error direction for a
    /// countdown.
    ///
    /// - `nil` below zero and at a day or more — neither can happen for a
    ///   today-only window, and both would be a wrong answer rather than a
    ///   small one.
    /// - `now` under a minute.
    /// - `1m`…`59m`, then `1h`…`23h`.
    static func format(secondsUntilStart seconds: Int) -> String? {
        guard seconds >= 0 else { return nil }
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600
        guard hours < 24 else { return nil }
        return "\(hours)h"
    }

    /// The same answer, in the form the caller wants to draw.
    static func label(secondsUntilStart seconds: Int, style: LabelStyle = .bare) -> String? {
        guard let text = format(secondsUntilStart: seconds) else { return nil }
        switch style {
        case .bare: return text
        case .parenthesised: return "(\(text))"
        }
    }

    /// Wraps an already-formatted label, for a caller that has one in hand.
    static func parenthesised(_ label: String) -> String {
        "(\(label))"
    }

    /// The spoken form, for the tooltip and `accessibilityLabel`.
    ///
    /// Generated from the integer. It is not read from the page, and it names
    /// no event (S22).
    static func longForm(secondsUntilStart seconds: Int) -> String? {
        guard format(secondsUntilStart: seconds) != nil else { return nil }
        if seconds < 60 { return "Next event starts in less than a minute" }
        if seconds < 3600 {
            let minutes = seconds / 60
            return "Next event in \(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = seconds / 3600
        return "Next event in \(hours) hour\(hours == 1 ? "" : "s")"
    }

    // MARK: - Retirement

    /// Seconds from `now` until the entry's event starts, or `nil` once it has.
    static func secondsUntilStart(entry: Entry, now: Date) -> Int? {
        let seconds = entry.start.timeIntervalSince(now)
        guard seconds >= 0 else { return nil }
        return Int(seconds.rounded(.down))
    }

    /// Whether a cached answer has stopped being worth showing.
    ///
    /// A value that cannot be refreshed retires rather than ageing on screen —
    /// the whole failure policy in one function. Three independent rules:
    ///
    /// 1. the event has started (AGENDA mode prints start times only, so an
    ///    in-progress event is not something this feature can know about);
    /// 2. the answer is older than `maximumAge`;
    /// 3. local midnight has passed since it was fetched, so "today" now means
    ///    a different day.
    ///
    /// The fourth rule — the toggle going off — is not here because it drops
    /// the whole cache rather than expiring one entry.
    static func isRetired(entry: Entry, now: Date, timeZone: TimeZone) -> Bool {
        if now >= entry.start { return true }
        if now.timeIntervalSince(entry.fetchedAt) > maximumAge { return true }
        let calendar = gregorian(timeZone)
        if calendar.startOfDay(for: now) != calendar.startOfDay(for: entry.fetchedAt) { return true }
        return false
    }

    // MARK: - Status

    /// What the Settings line says, from the last pass's outcomes.
    ///
    /// Worst answer first, so a problem is visible rather than averaged away by
    /// an account that happens to work. This is what tells the owner whether
    /// `htmlembed` serves his private calendar at all (gate G-C1) without
    /// anyone reading his session.
    static func status(
        enabled: Bool,
        calendarAccounts: Int,
        outcomes: [AgendaOutcome],
        showing: Int
    ) -> CalendarCountdownStatus {
        func result(_ kind: CalendarCountdownStatus.Kind) -> CalendarCountdownStatus {
            CalendarCountdownStatus(kind: kind, checked: calendarAccounts, showing: showing)
        }

        guard enabled else { return CalendarCountdownStatus(kind: .disabled, checked: 0, showing: 0) }
        guard calendarAccounts > 0 else { return result(.noCalendarAccounts) }
        guard !outcomes.isEmpty else { return result(.notCheckedYet) }
        if outcomes.contains(.refused) { return result(.refused) }
        if outcomes.contains(.notUnderstood) { return result(.notUnderstood) }
        if outcomes.contains(.noAnswer) { return result(.noAnswer) }
        if outcomes.allSatisfy({ $0 == .notCalendar }) { return result(.waitingForCalendar) }
        return result(.working)
    }

    // MARK: - Helpers

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

/// The seam the Settings General pane uses to reach the countdown, so the pane
/// never holds the poller and never reaches for `NSApp.delegate`.
///
/// The defaults make the whole thing inert, which is what lets the settings
/// self-test build the window with no poller behind it.
struct CalendarCountdownControls {
    var status: () -> CalendarCountdownStatus = {
        CalendarCountdownStatus(kind: .notCheckedYet, checked: 0, showing: 0)
    }
    /// G6 was switched. Starts or stops the poller; never anything else.
    var setEnabled: (Bool) -> Void = { _ in }
    /// Check again now, and call back once every account has answered.
    var recheck: (@escaping () -> Void) -> Void = { done in done() }
}
