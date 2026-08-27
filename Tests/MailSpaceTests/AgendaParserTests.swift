import XCTest
@testable import MailSpace

/// The Swift reference parser over the hand-written fixtures.
///
/// The parser that ships runs inside the page, so this is its executable spec
/// rather than the code path; `MAILSPACE_SELFTEST=agenda` is what proves the two
/// agree. Every fixture here was written by hand and carries placeholder titles
/// — none was captured from a real calendar.
final class AgendaParserTests: XCTestCase {
    private let kyiv = TimeZone(identifier: "Europe/Kyiv")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    /// A moment on the day every dated fixture is written for.
    private func today(_ hour: Int, _ minute: Int, _ second: Int = 0, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: AgendaFixtures.day.year,
            month: AgendaFixtures.day.month,
            day: AgendaFixtures.day.day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    private func parse(_ html: String, at now: Date, in timeZone: TimeZone? = nil) -> AgendaParser.Result? {
        AgendaParser.parse(html: html, now: now, timeZone: timeZone ?? kyiv)
    }

    // MARK: - Did not understand

    /// KTD-S13: the endpoint answers a request it does not like with a
    /// marketing page, status 200. A 200 alone is never an agenda.
    func testAMarketingPageWithStatus200IsNotAnAgenda() {
        XCTAssertNil(parse(AgendaFixtures.marketing200, at: today(9, 0, in: kyiv)))
    }

    func testTwoDaySectionsAreNotTheWindowWeAskedFor() {
        XCTAssertNil(parse(AgendaFixtures.twoSections, at: today(7, 0, in: kyiv)))
    }

    func testADayHeaderThatIsNotTodayIsRefused() {
        XCTAssertNil(parse(AgendaFixtures.yesterday, at: today(9, 0, in: kyiv)))
        XCTAssertNil(parse(AgendaFixtures.tomorrow, at: today(9, 0, in: kyiv)))
    }

    func testASectionWithNoDayHeaderIsRefused() {
        XCTAssertNil(parse(AgendaFixtures.malformed, at: today(7, 0, in: kyiv)))
    }

    /// One unreadable time fails the whole document. Skipping the row would
    /// count down to the meeting after it, which is the one outcome worse than
    /// showing nothing.
    func testAnUnreadableTimeFailsTheWholeDocument() {
        XCTAssertNil(parse(AgendaFixtures.unreadableTime, at: today(7, 0, in: kyiv)))
    }

    // MARK: - Understood, with nothing to show

    func testAnEmptyDayIsAnAnswerNotAFailure() {
        XCTAssertEqual(
            parse(AgendaFixtures.emptyDay, at: today(9, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: nil, remainingCount: 0)
        )
    }

    func testAnAllDayEventIsNotSomethingToCountDownTo() {
        XCTAssertEqual(
            parse(AgendaFixtures.allDayOnly, at: today(9, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: nil, remainingCount: 0)
        )
    }

    func testNothingLeftTodayShowsNothing() {
        XCTAssertEqual(
            parse(AgendaFixtures.fourTimed, at: today(17, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: nil, remainingCount: 0)
        )
    }

    /// AGENDA mode prints start times only, so an event that has already begun
    /// is simply not a candidate — the answer moves to the next start or goes
    /// blank. An in-progress event cannot be detected, by construction.
    func testAnEventThatHasAlreadyStartedIsNotACandidate() {
        XCTAssertEqual(
            parse(AgendaFixtures.oneTimed, at: today(15, 31, in: kyiv)),
            AgendaParser.Result(startsInSeconds: nil, remainingCount: 0)
        )
        // Exactly at the start counts as begun: strictly after `now`, never at.
        XCTAssertEqual(
            parse(AgendaFixtures.oneTimed, at: today(15, 30, in: kyiv)),
            AgendaParser.Result(startsInSeconds: nil, remainingCount: 0)
        )
    }

    // MARK: - Understood, with a countdown

    func testOneTimedEventAtEveryThresholdTheOwnerAskedFor() {
        // 45 seconds
        XCTAssertEqual(parse(AgendaFixtures.oneTimed, at: today(15, 29, 15, in: kyiv))?.startsInSeconds, 45)
        // 5 minutes
        XCTAssertEqual(parse(AgendaFixtures.oneTimed, at: today(15, 25, in: kyiv))?.startsInSeconds, 300)
        // 90 minutes
        XCTAssertEqual(parse(AgendaFixtures.oneTimed, at: today(14, 0, in: kyiv))?.startsInSeconds, 5400)
        // 5 hours
        XCTAssertEqual(parse(AgendaFixtures.oneTimed, at: today(10, 30, in: kyiv))?.startsInSeconds, 18000)
    }

    func testTheLabelForEachOfThoseThresholds() {
        func label(at hour: Int, _ minute: Int, _ second: Int = 0) -> String? {
            guard let seconds = parse(AgendaFixtures.oneTimed, at: today(hour, minute, second, in: kyiv))?
                .startsInSeconds else { return nil }
            return CalendarCountdown.format(secondsUntilStart: seconds)
        }
        XCTAssertEqual(label(at: 15, 29, 15), "now")
        XCTAssertEqual(label(at: 15, 25), "5m")
        XCTAssertEqual(label(at: 14, 0), "1h")
        XCTAssertEqual(label(at: 10, 30), "5h")
    }

    func testOneTimedEventCountsItself() {
        XCTAssertEqual(
            parse(AgendaFixtures.oneTimed, at: today(15, 25, in: kyiv)),
            AgendaParser.Result(startsInSeconds: 300, remainingCount: 1)
        )
    }

    /// Four timed events with the first already past: the earliest *future*
    /// one, and three still to start.
    func testSeveralEventsWithOnePastGiveTheEarliestFutureOne() {
        let result = parse(AgendaFixtures.fourTimed, at: today(8, 15, in: kyiv))
        XCTAssertEqual(result?.remainingCount, 3)
        // 08:15 → 09:15 is an hour.
        XCTAssertEqual(result?.startsInSeconds, 3600)
    }

    func testTheAnswerMovesOnAsTheDayGoesBy() {
        XCTAssertEqual(parse(AgendaFixtures.fourTimed, at: today(7, 0, in: kyiv))?.remainingCount, 4)
        XCTAssertEqual(parse(AgendaFixtures.fourTimed, at: today(13, 30, in: kyiv))?.remainingCount, 1)
        XCTAssertEqual(parse(AgendaFixtures.fourTimed, at: today(13, 30, in: kyiv))?.startsInSeconds, 11700)
    }

    func testAnAllDayRowAboveATimedOneIsSkippedNotFatal() {
        XCTAssertEqual(
            parse(AgendaFixtures.mixedAllDayAndTimed, at: today(13, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: 3600, remainingCount: 1)
        )
    }

    /// The bare-hour form, which gate G-C2 has not seen on a real timed event
    /// yet. If the shape he reports differs, this is the test that moves.
    func testTheBareHourForm() {
        XCTAssertEqual(
            parse(AgendaFixtures.bareHour, at: today(16, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: 3600, remainingCount: 1)
        )
    }

    func testMidnightAndNoonAreNotTheSameHour() {
        // 00:05 has passed by 06:00; 12:05 has not.
        XCTAssertEqual(
            parse(AgendaFixtures.meridiemEdges, at: today(6, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: 21900, remainingCount: 1)
        )
        // Before both.
        XCTAssertEqual(parse(AgendaFixtures.meridiemEdges, at: today(0, 0, in: kyiv))?.remainingCount, 2)
        XCTAssertEqual(parse(AgendaFixtures.meridiemEdges, at: today(0, 0, in: kyiv))?.startsInSeconds, 300)
    }

    /// Gate G-C4 is unanswered: if declined events appear and carry a marker,
    /// nobody has seen it. A row with an unfamiliar extra class is treated as an
    /// ordinary event rather than guessed at — the countdown is to the next
    /// event *on the calendar*.
    func testAnUnfamiliarRowClassIsStillAnEvent() {
        XCTAssertEqual(
            parse(AgendaFixtures.extraRowClass, at: today(9, 0, in: kyiv)),
            AgendaParser.Result(startsInSeconds: 3600, remainingCount: 1)
        )
    }

    // MARK: - Time zones

    /// `ctz` makes Google render the times in one zone; the parser reads them in
    /// that same zone. The identical document at the identical instant answers
    /// differently when the zone differs, which is exactly why the zone is
    /// passed rather than assumed.
    func testTheSameDocumentReadInTwoZones() {
        // 14:00 UTC is 10:00 in New York and 17:00 in Kyiv, both on 26 August.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let instant = utc.date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 14))!

        // In New York the 15:30 event is still five and a half hours away.
        XCTAssertEqual(
            parse(AgendaFixtures.oneTimed, at: instant, in: newYork),
            AgendaParser.Result(startsInSeconds: 19800, remainingCount: 1)
        )
        // In Kyiv the same instant is 17:00 and the event has been and gone.
        XCTAssertEqual(
            parse(AgendaFixtures.oneTimed, at: instant, in: kyiv),
            AgendaParser.Result(startsInSeconds: nil, remainingCount: 0)
        )
    }

    // MARK: - The pieces

    func testClockParsing() {
        XCTAssertEqual(AgendaParser.parseClock("3:30pm")?.hour, 15)
        XCTAssertEqual(AgendaParser.parseClock("3:30pm")?.minute, 30)
        XCTAssertEqual(AgendaParser.parseClock("3pm")?.hour, 15)
        XCTAssertEqual(AgendaParser.parseClock("3 PM")?.hour, 15)
        XCTAssertEqual(AgendaParser.parseClock("3 p.m.")?.hour, 15)
        XCTAssertEqual(AgendaParser.parseClock("12:00am")?.hour, 0)
        XCTAssertEqual(AgendaParser.parseClock("12:00pm")?.hour, 12)
        XCTAssertEqual(AgendaParser.parseClock("11:59pm")?.hour, 23)
        XCTAssertNil(AgendaParser.parseClock(""))
        XCTAssertNil(AgendaParser.parseClock("15:30"))
        XCTAssertNil(AgendaParser.parseClock("0:30am"))
        XCTAssertNil(AgendaParser.parseClock("13:00pm"))
        XCTAssertNil(AgendaParser.parseClock("3:60pm"))
        XCTAssertNil(AgendaParser.parseClock("half past three"))
        XCTAssertNil(AgendaParser.parseClock("3:30pm – 4:00pm"), "AGENDA prints start times, never ranges")
    }

    func testHeaderDateParsing() {
        XCTAssertEqual(AgendaParser.parseHeaderDate("Wed Aug 26, 2026")?.month, 8)
        XCTAssertEqual(AgendaParser.parseHeaderDate("Wed Aug 26, 2026")?.day, 26)
        XCTAssertEqual(AgendaParser.parseHeaderDate("Wed Aug 26, 2026")?.year, 2026)
        XCTAssertEqual(AgendaParser.parseHeaderDate("Aug 26, 2026")?.month, 8)
        XCTAssertEqual(AgendaParser.parseHeaderDate("Wednesday August 26, 2026")?.month, 8)
        XCTAssertNil(AgendaParser.parseHeaderDate("26/08/2026"))
        XCTAssertNil(AgendaParser.parseHeaderDate("Wed Xxx 26, 2026"))
        XCTAssertNil(AgendaParser.parseHeaderDate(""))
    }

    func testTextExtraction() {
        XCTAssertEqual(AgendaParser.text(of: "<td class=\"event-time\">3:30pm</td>"), "3:30pm")
        XCTAssertEqual(AgendaParser.text(of: "  3:30&nbsp;pm  "), "3:30 pm")
        XCTAssertEqual(AgendaParser.text(of: "<span>a</span><span>b</span>"), "a b")
        XCTAssertEqual(AgendaParser.text(of: ""), "")
    }

    /// The fixtures are the probe's inputs too, so a missing one is a silently
    /// weaker self-test.
    func testEveryFixtureIsListed() {
        XCTAssertEqual(AgendaFixtures.all.count, 14)
        XCTAssertTrue(AgendaFixtures.all.allSatisfy { !$0.html.isEmpty })
        XCTAssertEqual(Set(AgendaFixtures.all.map(\.name)).count, AgendaFixtures.all.count)
    }
}
