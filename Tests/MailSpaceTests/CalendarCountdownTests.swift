import XCTest
@testable import MailSpace

/// The pure half of the Calendar tab countdown: the day window, the label at
/// every threshold, and the rules that retire an answer instead of letting it
/// age on screen.
final class CalendarCountdownTests: XCTestCase {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let kyiv = TimeZone(identifier: "Europe/Kyiv")!

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
        in timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    // MARK: - todayWindow

    func testTodayWindowIsTodayAndTomorrow() {
        let window = CalendarCountdown.todayWindow(
            now: date(2026, 8, 26, 13, 47, in: kyiv),
            timeZone: kyiv
        )
        XCTAssertEqual(window.start, "20260826")
        XCTAssertEqual(window.end, "20260827")
    }

    func testTodayWindowAtOneSecondBeforeMidnightIsStillToday() {
        let window = CalendarCountdown.todayWindow(
            now: date(2026, 8, 26, 23, 59, 59, in: kyiv),
            timeZone: kyiv
        )
        XCTAssertEqual(window.start, "20260826")
        XCTAssertEqual(window.end, "20260827")
    }

    func testTodayWindowRollsOverAtLocalMidnight() {
        let window = CalendarCountdown.todayWindow(
            now: date(2026, 8, 27, 0, 0, 0, in: kyiv),
            timeZone: kyiv
        )
        XCTAssertEqual(window.start, "20260827")
        XCTAssertEqual(window.end, "20260828")
    }

    /// The `+ 86400` bug, caught. 1 November 2026 is 25 hours long in New York,
    /// so midnight plus 86 400 seconds is 23:00 the *same* day — the window
    /// would ask for today twice and the tab would show nothing all day.
    func testTodayWindowOnTheTwentyFiveHourDay() {
        let start = date(2026, 11, 1, 0, 0, 0, in: newYork)
        XCTAssertEqual(
            CalendarCountdown.stamp(start.addingTimeInterval(86_400), timeZone: newYork),
            "20261101",
            "precondition: naive arithmetic lands on the same day"
        )

        let window = CalendarCountdown.todayWindow(now: date(2026, 11, 1, 9, 0, in: newYork), timeZone: newYork)
        XCTAssertEqual(window.start, "20261101")
        XCTAssertEqual(window.end, "20261102")
    }

    /// And the 23-hour day at the other end of the year.
    func testTodayWindowOnTheTwentyThreeHourDay() {
        let window = CalendarCountdown.todayWindow(now: date(2026, 3, 8, 9, 0, in: newYork), timeZone: newYork)
        XCTAssertEqual(window.start, "20260308")
        XCTAssertEqual(window.end, "20260309")
    }

    func testWindowIsReadInTheGivenZoneNotTheSystemOne() {
        // 2026-08-26 22:30 in New York is already the 27th in Kyiv.
        let instant = date(2026, 8, 26, 22, 30, in: newYork)
        XCTAssertEqual(CalendarCountdown.todayWindow(now: instant, timeZone: newYork).start, "20260826")
        XCTAssertEqual(CalendarCountdown.todayWindow(now: instant, timeZone: kyiv).start, "20260827")
    }

    // MARK: - format

    func testFormatAtEveryThreshold() {
        XCTAssertNil(CalendarCountdown.format(secondsUntilStart: -1))
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 0), "now")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 45), "now")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 59), "now")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 60), "1m")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 299), "4m")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 300), "5m")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 3599), "59m")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 3600), "1h")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 18000), "5h")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 82800), "23h")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 86399), "23h")
    }

    /// Floored, never rounded: 90 minutes reads `1h`, not `2h`. Understating the
    /// time you have is the safe direction.
    func testFormatFloorsRatherThanRounds() {
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 5400), "1h")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 119), "1m")
        XCTAssertEqual(CalendarCountdown.format(secondsUntilStart: 7199), "1h")
    }

    /// A day or more is not something a today-only window can produce, and it
    /// would be a wrong answer rather than a big one.
    func testFormatRefusesADayOrMore() {
        XCTAssertNil(CalendarCountdown.format(secondsUntilStart: 86400))
        XCTAssertNil(CalendarCountdown.format(secondsUntilStart: 200_000))
    }

    func testBareAndParenthesisedComeFromTheSameArithmetic() {
        XCTAssertEqual(CalendarCountdown.label(secondsUntilStart: 300), "5m")
        XCTAssertEqual(CalendarCountdown.label(secondsUntilStart: 300, style: .bare), "5m")
        XCTAssertEqual(CalendarCountdown.label(secondsUntilStart: 300, style: .parenthesised), "(5m)")
        XCTAssertEqual(CalendarCountdown.label(secondsUntilStart: 45, style: .parenthesised), "(now)")
        XCTAssertNil(CalendarCountdown.label(secondsUntilStart: -1, style: .parenthesised))
        XCTAssertEqual(CalendarCountdown.parenthesised("5h"), "(5h)")
    }

    func testLongFormIsGeneratedFromTheNumber() {
        XCTAssertEqual(CalendarCountdown.longForm(secondsUntilStart: 30), "Next event starts in less than a minute")
        XCTAssertEqual(CalendarCountdown.longForm(secondsUntilStart: 60), "Next event in 1 minute")
        XCTAssertEqual(CalendarCountdown.longForm(secondsUntilStart: 2700), "Next event in 45 minutes")
        XCTAssertEqual(CalendarCountdown.longForm(secondsUntilStart: 3600), "Next event in 1 hour")
        XCTAssertEqual(CalendarCountdown.longForm(secondsUntilStart: 18000), "Next event in 5 hours")
        XCTAssertNil(CalendarCountdown.longForm(secondsUntilStart: -5))
    }

    // MARK: - Retirement

    private func entry(startsAt start: Date, fetchedAt: Date, remaining: Int = 1) -> CalendarCountdown.Entry {
        CalendarCountdown.Entry(start: start, fetchedAt: fetchedAt, remainingCount: remaining)
    }

    func testAFreshEntryIsNotRetired() {
        let now = date(2026, 8, 26, 14, 0, in: kyiv)
        let entry = entry(startsAt: now.addingTimeInterval(1800), fetchedAt: now.addingTimeInterval(-60))
        XCTAssertFalse(CalendarCountdown.isRetired(entry: entry, now: now, timeZone: kyiv))
        XCTAssertEqual(CalendarCountdown.secondsUntilStart(entry: entry, now: now), 1800)
    }

    func testAnEntryRetiresWhenItsEventStarts() {
        let now = date(2026, 8, 26, 14, 0, in: kyiv)
        let started = entry(startsAt: now, fetchedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(CalendarCountdown.isRetired(entry: started, now: now, timeZone: kyiv))

        let past = entry(startsAt: now.addingTimeInterval(-1), fetchedAt: now.addingTimeInterval(-60))
        XCTAssertTrue(CalendarCountdown.isRetired(entry: past, now: now, timeZone: kyiv))
        XCTAssertNil(CalendarCountdown.secondsUntilStart(entry: past, now: now))
    }

    func testAnEntryRetiresAfterFifteenMinutes() {
        let now = date(2026, 8, 26, 14, 0, in: kyiv)
        let start = now.addingTimeInterval(3600)
        XCTAssertFalse(CalendarCountdown.isRetired(
            entry: entry(startsAt: start, fetchedAt: now.addingTimeInterval(-900)),
            now: now,
            timeZone: kyiv
        ))
        XCTAssertTrue(CalendarCountdown.isRetired(
            entry: entry(startsAt: start, fetchedAt: now.addingTimeInterval(-901)),
            now: now,
            timeZone: kyiv
        ))
        XCTAssertTrue(CalendarCountdown.isRetired(
            entry: entry(startsAt: start, fetchedAt: now.addingTimeInterval(-16 * 60)),
            now: now,
            timeZone: kyiv
        ))
    }

    /// A tab left open past midnight. The answer was about yesterday, and the
    /// age rule alone would not catch a fetch made at 23:58 read at 00:01.
    func testAnEntryRetiresWhenLocalMidnightHasPassed() {
        let fetchedAt = date(2026, 8, 26, 23, 58, in: kyiv)
        let now = date(2026, 8, 27, 0, 1, in: kyiv)
        let stale = entry(startsAt: now.addingTimeInterval(3600), fetchedAt: fetchedAt)
        XCTAssertLessThan(now.timeIntervalSince(fetchedAt), CalendarCountdown.maximumAge)
        XCTAssertTrue(CalendarCountdown.isRetired(entry: stale, now: now, timeZone: kyiv))
    }

    /// The same two instants, read in a zone where midnight has not happened
    /// yet, are not stale — "today" is a local question.
    func testMidnightRetirementIsLocal() {
        let fetchedAt = date(2026, 8, 26, 23, 58, in: kyiv)
        let now = date(2026, 8, 27, 0, 1, in: kyiv)
        let stale = entry(startsAt: now.addingTimeInterval(3600), fetchedAt: fetchedAt)
        XCTAssertFalse(CalendarCountdown.isRetired(entry: stale, now: now, timeZone: newYork))
    }

    // MARK: - Status

    private func status(
        enabled: Bool = true,
        accounts: Int = 2,
        _ outcomes: [AgendaOutcome],
        showing: Int = 0
    ) -> CalendarCountdownStatus.Kind {
        CalendarCountdown.status(
            enabled: enabled,
            calendarAccounts: accounts,
            outcomes: outcomes,
            showing: showing
        ).kind
    }

    func testStatusReportsTheWorstAnswerFirst() {
        XCTAssertEqual(status(enabled: false, [.ok]), .disabled)
        XCTAssertEqual(status(accounts: 0, []), .noCalendarAccounts)
        XCTAssertEqual(status([]), .notCheckedYet)
        XCTAssertEqual(status([.notCalendar, .notCalendar]), .waitingForCalendar)
        XCTAssertEqual(status([.ok, .ok], showing: 1), .working)
        XCTAssertEqual(status([.ok, .notCalendar]), .working)
        XCTAssertEqual(status([.ok, .noAnswer]), .noAnswer)
        XCTAssertEqual(status([.ok, .notUnderstood]), .notUnderstood)
        // The gate-G-C1 answer wins over everything: if any calendar is refused,
        // that is what the owner needs to see.
        XCTAssertEqual(status([.ok, .noAnswer, .notUnderstood, .refused]), .refused)
    }

    func testStatusTextNamesShapesAndCountsOnly() {
        let working = CalendarCountdown.status(enabled: true, calendarAccounts: 2, outcomes: [.ok, .ok], showing: 1)
        XCTAssertEqual(working.text, "Working — 2 Calendar tabs checked, 1 showing a countdown.")
        let one = CalendarCountdown.status(enabled: true, calendarAccounts: 1, outcomes: [.ok], showing: 0)
        XCTAssertEqual(one.text, "Working — 1 Calendar tab checked, 0 showing a countdown.")
        XCTAssertEqual(
            CalendarCountdown.status(enabled: true, calendarAccounts: 1, outcomes: [.refused], showing: 0).text,
            "Google refused the request — a calendar could not be read this way."
        )
        XCTAssertEqual(
            CalendarCountdown.status(enabled: false, calendarAccounts: 1, outcomes: [.ok], showing: 1).text,
            "Turned off."
        )
    }

    // MARK: - The request

    func testAgendaPathIsTheRequestTheSpecNames() {
        let path = NextEventPoller.agendaPath(
            calendarId: "someone@example.com",
            timeZone: kyiv,
            window: ("20260826", "20260827")
        )
        XCTAssertEqual(
            path,
            "/calendar/u/0/htmlembed?src=someone@example.com&mode=AGENDA&hl=en"
                + "&ctz=Europe%2FKyiv&dates=20260826/20260827"
        )
    }

    /// A `+` in an address is a tag, not a space. Left unencoded the server
    /// would ask about a different calendar.
    func testAgendaPathEncodesAPlusInTheAddress() {
        let path = NextEventPoller.agendaPath(
            calendarId: "someone+work@example.com",
            timeZone: TimeZone(identifier: "UTC")!,
            window: ("20260826", "20260827")
        )
        XCTAssertTrue(path.contains("src=someone%2Bwork@example.com"), path)
        XCTAssertFalse(path.contains("+"), path)
    }

    func testCanPollOnlyOnCalendarOverHTTPS() {
        XCTAssertTrue(NextEventPoller.canPoll(URL(string: "https://calendar.google.com/calendar/u/0/r")))
        XCTAssertTrue(NextEventPoller.canPoll(URL(string: "https://CALENDAR.google.com/calendar/u/0/r/month")))
        // Signed out: a definite nothing, not a failed check.
        XCTAssertFalse(NextEventPoller.canPoll(URL(string: "https://accounts.google.com/ServiceLogin")))
        XCTAssertFalse(NextEventPoller.canPoll(URL(string: "http://calendar.google.com/")))
        XCTAssertFalse(NextEventPoller.canPoll(URL(string: "https://calendar.google.com.evil.test/")))
        XCTAssertFalse(NextEventPoller.canPoll(URL(string: "about:blank")))
        XCTAssertFalse(NextEventPoller.canPoll(nil))
    }
}
