import Foundation

/// Hand-written Calendar page fragments for the meeting-link lookup.
///
/// **Every one of these was written by hand. None was captured from a real
/// calendar**: every title and link is a placeholder (S22). The event element
/// is a `div` carrying `data-eventid`, the attribute the plan names for today's
/// Calendar DOM; that shape has not been checked against a live page yet.
///
/// They live in `Sources` rather than in `Tests/…/Fixtures` for the reason
/// `AgendaFixtures` does: `swift test` runs `MeetingLink` over them and
/// `MAILSPACE_SELFTEST=meetinglink` runs the shipped page script over them, and
/// both halves must see the identical bytes.
enum MeetingLinkFixtures {
    struct Fixture {
        let name: String
        let title: String
        let html: String
        let expected: MeetingLink.Match
    }

    static let meet = "https://meet.google.com/abc-defg-hij"
    static let otherMeet = "https://meet.google.com/xyz-wxyz-xyz"
    static let zoom = "https://us02web.zoom.us/j/123456789?pwd=placeholder"

    static func page(_ body: String) -> String {
        "<!DOCTYPE html><html><head><title>Calendar</title></head><body>\(body)</body></html>"
    }

    static func event(_ id: String, _ inner: String) -> String {
        "<div role=\"button\" data-eventid=\"\(id)\"><div class=\"chip\">\(inner)</div></div>"
    }

    static func found(_ url: String, links: Int = 1, fallback: Bool = false) -> MeetingLink.Match {
        MeetingLink.Match(url: url, links: links, fallback: fallback)
    }

    static let all: [Fixture] = [
        Fixture(
            name: "anchor-in-event",
            title: "Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><a href=\"\(meet)\">Join with Google Meet</a>")),
            expected: found(meet)
        ),
        Fixture(
            name: "text-link-in-event",
            title: "Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><span>Video call: \(meet).</span>")),
            expected: found(meet)
        ),
        Fixture(
            name: "title-whitespace-normalised",
            title: "Weekly sync",
            html: page(event("e1", "<span>  Weekly&nbsp;\n sync </span><a href=\"\(zoom)\">Zoom</a>")),
            expected: found(zoom)
        ),
        Fixture(
            name: "two-events-same-title",
            title: "Standup",
            html: page(
                event("e1", "<span>Standup</span><a href=\"\(meet)\">Join</a>")
                + event("e2", "<span>Standup</span><a href=\"\(otherMeet)\">Join</a>")
            ),
            expected: MeetingLink.Match(url: nil, links: 2, fallback: false)
        ),
        Fixture(
            name: "same-link-twice",
            title: "Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><a href=\"\(meet)\">\(meet)</a>")),
            expected: found(meet)
        ),
        Fixture(
            name: "event-without-link",
            title: "Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><span>Room 4</span>")),
            expected: .nothing
        ),
        Fixture(
            name: "only-a-foreign-link",
            title: "Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><a href=\"https://example.com/agenda\">Agenda</a>")),
            expected: .nothing
        ),
        Fixture(
            name: "link-in-another-event",
            title: "Weekly sync",
            html: page(
                event("e1", "<span>Weekly sync</span>")
                + event("e2", "<span>Planning</span><a href=\"\(meet)\">Join</a>")
            ),
            expected: .nothing
        ),
        Fixture(
            name: "reply-prefix-is-not-a-match",
            title: "Weekly sync",
            html: page(
                event("e1", "<span>Weekly sync</span>")
                + event("e2", "<span>Re: Weekly sync</span><a href=\"\(zoom)\">Zoom</a>")
            ),
            expected: .nothing
        ),
        Fixture(
            name: "title-only-in-description",
            title: "Weekly sync",
            html: page(event("e1", "<span>Planning</span><span>Follow-up to Weekly sync</span><a href=\"\(meet)\">Join</a>")),
            expected: .nothing
        ),
        Fixture(
            name: "reminder-prefix-fails-safe",
            title: "Starting now: Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><a href=\"\(meet)\">Join</a>")),
            expected: .nothing
        ),
        Fixture(
            name: "title-and-link-loose-in-body",
            title: "Weekly sync",
            html: page(
                event("e1", "<span>Planning</span>")
                + "<p>Weekly sync</p><p><a href=\"\(meet)\">Join</a></p>"
            ),
            expected: .nothing
        ),
        Fixture(
            name: "suffix-trick-host",
            title: "Weekly sync",
            html: page(event("e1", "<span>Weekly sync</span><a href=\"https://meet.google.com.evil.example/x\">Join</a>")),
            expected: .nothing
        ),
        Fixture(
            name: "link-redirect",
            title: "Weekly sync",
            html: page(event(
                "e1",
                "<span>Weekly sync</span><a href=\"https://meet.google.com/linkredirect?dest=https://evil.example\">Join</a>"
            )),
            expected: .nothing
        ),
        Fixture(
            name: "ambiguity-in-events-is-final",
            title: "Weekly sync",
            html: page(
                event("e1", "<span>Weekly sync</span><a href=\"\(meet)\">Join</a><a href=\"\(zoom)\">Zoom</a>")
                + "<div role=\"dialog\"><div><span>Weekly sync</span></div><div><a href=\"\(otherMeet)\">Join</a></div></div>"
            ),
            expected: MeetingLink.Match(url: nil, links: 2, fallback: false)
        ),
        Fixture(
            name: "fallback-open-event-dialog",
            title: "Weekly sync",
            html: page(
                "<div role=\"main\"><div role=\"dialog\"><div><span role=\"heading\">Weekly sync</span></div>"
                + "<div><a href=\"\(meet)\">Join with Google Meet</a></div></div></div>"
            ),
            expected: found(meet, fallback: true)
        ),
        Fixture(
            name: "fallback-aria-label",
            title: "Weekly sync",
            html: page("<div><div aria-label=\"Weekly sync\"><a href=\"\(zoom)\">Join</a></div></div>"),
            expected: found(zoom, fallback: true)
        ),
        Fixture(
            name: "fallback-hidden-is-ignored",
            title: "Weekly sync",
            html: page(
                "<div aria-hidden=\"true\"><div><span>Weekly sync</span></div>"
                + "<div><a href=\"\(meet)\">Join</a></div></div>"
            ),
            expected: .nothing
        ),
        Fixture(
            name: "fallback-never-borrows-from-an-event",
            title: "Weekly sync",
            html: page(
                "<div><div><span>Weekly sync</span></div>"
                + event("e2", "<span>Planning</span><a href=\"\(meet)\">Join</a>")
                + "</div>"
            ),
            expected: .nothing
        ),
        Fixture(
            name: "fallback-too-far-away",
            title: "Weekly sync",
            html: page(
                "<section><div><div><div><div><span>Weekly sync</span></div></div></div></div>"
                + "<a href=\"\(meet)\">Join</a></section>"
            ),
            expected: .nothing
        ),
        Fixture(
            name: "empty-title",
            title: "",
            html: page(event("e1", "<span></span><a href=\"\(meet)\">Join</a>")),
            expected: .nothing
        )
    ]
}
