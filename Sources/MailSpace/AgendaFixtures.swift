import Foundation

/// Hand-written agenda documents, in the shape Google Calendar's `htmlembed`
/// AGENDA renderer produces.
///
/// **Every one of these was written by hand. None was captured from a real
/// calendar**, and every title in them is a placeholder (S22, and a Definition
/// of Done item rather than a note).
///
/// They live in `Sources` rather than in `Tests/…/Fixtures` for one reason:
/// `swift test` runs `AgendaParser` over them and `MAILSPACE_SELFTEST=agenda`
/// runs the *shipped* JavaScript over them inside a webview, and the whole point
/// of that probe is that both halves see the identical bytes. A copy in each
/// place is a copy that drifts.
///
/// All of them are dated `Wed Aug 26, 2026`, so a test picks a `now` on that
/// day and reads the answers off the clock.
enum AgendaFixtures {
    /// The day every dated fixture below is written for.
    static let day = (year: 2026, month: 8, day: 26)
    static let header = "Wed Aug 26, 2026"

    /// Every fixture, by name, for the probe to walk.
    static let all: [(name: String, html: String)] = [
        ("marketing-200", marketing200),
        ("empty-day", emptyDay),
        ("two-sections", twoSections),
        ("yesterday", yesterday),
        ("tomorrow", tomorrow),
        ("all-day-only", allDayOnly),
        ("one-timed", oneTimed),
        ("four-timed", fourTimed),
        ("bare-hour", bareHour),
        ("meridiem-edges", meridiemEdges),
        ("mixed-all-day-and-timed", mixedAllDayAndTimed),
        ("extra-row-class", extraRowClass),
        ("unreadable-time", unreadableTime),
        ("malformed", malformed)
    ]

    /// The trap KTD-S13 exists for: status 200, and not an agenda at all. The
    /// endpoint answers a request it does not like with a marketing page, so a
    /// 200 on its own never means "agenda".
    static let marketing200 = """
    <html><head><title>Google Calendar</title></head>
    <body><div class="promo-hero"><h1>Get Google Calendar</h1>
    <p>Keep track of your schedule.</p></div></body></html>
    """

    /// A day with nothing on it renders no `.date-section` at all. That is an
    /// answer, not a failure.
    static let emptyDay = """
    <html><body><div class="view-container"><div class="agenda"></div></div></body></html>
    """

    /// More than one day back from a one-day window means the window we asked
    /// for is not the window we got.
    static let twoSections = """
    <html><body><div class="view-container">
    \(section(header: "Wed Aug 26, 2026", rows: [row(time: "9:00am", title: "Placeholder A")]))
    \(section(header: "Thu Aug 27, 2026", rows: [row(time: "9:00am", title: "Placeholder B")]))
    </div></body></html>
    """

    static let yesterday = """
    <html><body><div class="view-container">
    \(section(header: "Tue Aug 25, 2026", rows: [row(time: "9:00am", title: "Placeholder A")]))
    </div></body></html>
    """

    static let tomorrow = """
    <html><body><div class="view-container">
    \(section(header: "Thu Aug 27, 2026", rows: [row(time: "9:00am", title: "Placeholder A")]))
    </div></body></html>
    """

    /// An all-day event has an empty time cell. There is no start to count down
    /// to, so it is skipped and the tab shows nothing.
    static let allDayOnly = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [row(time: "", title: "Placeholder All Day")]))
    </div></body></html>
    """

    /// One timed event, at 15:30 local.
    static let oneTimed = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [row(time: "3:30pm", title: "Placeholder A")]))
    </div></body></html>
    """

    /// Four timed events: 08:00, 09:15, 13:00, 16:45.
    static let fourTimed = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [
        row(time: "8:00am", title: "Placeholder A"),
        row(time: "9:15am", title: "Placeholder B"),
        row(time: "1:00pm", title: "Placeholder C"),
        row(time: "4:45pm", title: "Placeholder D")
    ]))
    </div></body></html>
    """

    /// The bare-hour form the prototype's fixtures assume alongside `h:mm`
    /// (gate G-C2). 17:00 local.
    static let bareHour = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [row(time: "5pm", title: "Placeholder A")]))
    </div></body></html>
    """

    /// The two times a twelve-hour clock gets wrong: `12:00am` is midnight and
    /// `12:00pm` is noon, not 12:00 and 24:00.
    static let meridiemEdges = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [
        row(time: "12:05am", title: "Placeholder A"),
        row(time: "12:05pm", title: "Placeholder B")
    ]))
    </div></body></html>
    """

    /// An all-day event above a timed one. The all-day row must be skipped
    /// rather than failing the document, or a mixed day shows nothing.
    static let mixedAllDayAndTimed = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [
        row(time: "", title: "Placeholder All Day"),
        row(time: "2:00pm", title: "Placeholder A")
    ]))
    </div></body></html>
    """

    /// A row carrying a class MailSpace does not know — the shape a *declined*
    /// event might arrive in (gate G-C4, unanswered). It is deliberately treated
    /// as an ordinary event: the countdown is to the next event on the calendar,
    /// and inventing a heuristic for "declined" would be guessing.
    static let extraRowClass = """
    <html><body><div class="view-container">
    <div class="date-section date-section-today"><div class="date">\(header)</div>
    <table class="events">
    <tr class="event event-declined"><td class="event-time">10:00am</td>
    <td class="event-summary">Placeholder A</td></tr>
    </table></div>
    </div></body></html>
    """

    /// A time in a shape the parser does not know fails the *whole* document.
    /// Skipping the row would count down to the meeting after it.
    static let unreadableTime = """
    <html><body><div class="view-container">
    \(section(header: header, rows: [
        row(time: "half past three", title: "Placeholder A"),
        row(time: "4:45pm", title: "Placeholder B")
    ]))
    </div></body></html>
    """

    /// A section with no day header at all.
    static let malformed = """
    <html><body><div class="view-container">
    <div class="date-section"><table class="events">
    <tr class="event"><td class="event-time">9:00am</td></tr>
    </table></div>
    </div></body></html>
    """

    // MARK: - Building blocks

    static func section(header: String, rows: [String]) -> String {
        """
        <div class="date-section date-section-today"><div class="date">\(header)</div>
        <table class="events">
        \(rows.joined(separator: "\n"))
        </table></div>
        """
    }

    static func row(time: String, title: String) -> String {
        "<tr class=\"event\"><td class=\"event-time\">\(time)</td>"
            + "<td class=\"event-summary\">\(title)</td></tr>"
    }
}
