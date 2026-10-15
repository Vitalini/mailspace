import Foundation

/// Hand-written Calendar page fragments for the meeting-link lookup, and the
/// one table of allowed and refused meeting URLs.
///
/// **Every one of these was written by hand. None was captured from a real
/// calendar**: every title, id and link is a placeholder (S22). The shape
/// follows what the live page was observed to hold, without its contents: an
/// event chip is an element carrying `data-eventid` with the title in a text
/// node, and an inline `<script>` holds a JSON event list in which one record
/// per event carries the event's `/calendar/event?eid=` URL, its title, and
/// its conference link or location among other strings. Field positions here
/// differ from record to record on purpose: the lookup must not rely on them.
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
        /// What fetching the event's page returns; `nil` is a failed or
        /// signed-out fetch.
        let fetched: String?
        let expected: MeetingLink.Match

        init(name: String, title: String, html: String, fetched: String? = nil, expected: MeetingLink.Match) {
            self.name = name
            self.title = title
            self.html = html
            self.fetched = fetched
            self.expected = expected
        }
    }

    // MARK: - The allow-list table

    /// Every URL here must pass `MeetingLink.isAllowed` and the page script's
    /// `msMeetingAllowed`, and must parse as a URL that has nothing to
    /// normalise away.
    static let allowedURLs = [
        "https://meet.google.com/abc-defg-hij",
        "https://meet.google.com/abc-defg-hij?authuser=0",
        "https://us02web.zoom.us/j/123456789?pwd=x",
        "https://zoom.us/j/123456789",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_placeholder%40thread.v2/0?context=%7b%7d",
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_placeholder%40thread.v2/0"
    ]

    /// Every URL here must fail both.
    static let refusedURLs = [
        "https://meet.google.com/linkredirect?dest=https://evil.example",
        "https://meet.google.com/abc-defg-hij/extra",
        "http://meet.google.com/abc-defg-hij",
        "https://meet.google.com.evil.example/x",
        "https://evilzoom.us/j/1",
        "https://zoom.us/webinar/1",
        "https://zoom.us@evil.example/j/1",
        "https://teams.microsoft.com/settings",
        "https://teams.microsoft.com/l/meetup-join/",
        "https://teams.microsoft.com/l/meetup-join/../../settings",
        "https://teams.microsoft.com/l/meetup-join/x/../../../evil",
        "https://teams.microsoft.com/l/meetup-join/./x",
        "https://teams.microsoft.com/l/meetup-join/%2e%2e/%2e%2e/settings",
        "https://teams.microsoft.com/l/meetup-join/%2E%2E/x",
        "https://teams.microsoft.com/l/meetup-join/x/.%2e/y",
        "https://teams.microsoft.com/l/meetup-join/x/%2e./y",
        "https://teams.microsoft.com/l/meetup-join/x\\..\\..\\settings",
        "https://teams.microsoft.com/l/meetup-join/x\\y",
        "https://teams.microsoft.com/l/meetup-join/x?y=\\z",
        "https://meet.google.com/abc-defg-hij\n",
        "javascript:alert(1)",
        "/abc-defg-hij",
        ""
    ]

    // MARK: - Building blocks

    static let meet = "https://meet.google.com/abc-defg-hij"
    static let otherMeet = "https://meet.google.com/xyz-wxyz-xyz"
    static let zoom = "https://us02web.zoom.us/j/123456789?pwd=placeholder"
    static let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_placeholder%40thread.v2/0?context=%7b%7d"

    static func page(_ body: String) -> String {
        "<!DOCTYPE html><html><head><title>Calendar</title></head><body>\(body)</body></html>"
    }

    /// A week-view chip: the id, the title and a time, and no link.
    static func chip(_ id: String, _ title: String) -> String {
        "<div role=\"button\" data-eventid=\"\(id)\"><div class=\"chip\"><span>\(title)</span><span>10:00</span></div></div>"
    }

    static func eventURL(_ id: String) -> String {
        "https://www.google.com/calendar/event?eid=\(id)"
    }

    /// One record: placeholders around the event URL and the title, then the
    /// event's other strings.
    static func record(_ id: String, _ title: String, _ strings: [Any] = []) -> [Any] {
        ["placeholder-record", NSNull(), eventURL(id), 0, title, ["placeholder", NSNull()], false] + strings
    }

    /// The page's inline event list, nested as a real one is.
    static func eventList(_ records: [Any]) -> String {
        script(json(["placeholder-list", [["week", records]], NSNull()]))
    }

    static func script(_ body: String) -> String {
        "<script nonce=\"placeholder\">\(body)</script>"
    }

    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func found(_ url: String, links: Int = 1, fetched: Bool = false) -> MeetingLink.Match {
        MeetingLink.Match(url: url, links: links, fetched: fetched)
    }

    static let fetchedNothing = MeetingLink.Match(url: nil, links: 0, fetched: true)

    // MARK: - Fixtures

    static let all: [Fixture] = [
        Fixture(
            name: "meet-in-record",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", [NSNull(), [meet, "meet"]])])),
            expected: found(meet)
        ),
        Fixture(
            name: "zoom-only-in-location",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", ["Room 4 or \(zoom)", 1])])),
            expected: found(zoom)
        ),
        Fixture(
            name: "teams-in-record",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", [teams])])),
            expected: found(teams)
        ),
        Fixture(
            name: "same-link-twice",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", [meet, "Join: \(meet)."])])),
            expected: found(meet)
        ),
        Fixture(
            name: "link-in-html-description",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([
                record("ev1", "Weekly sync", ["<p>Agenda</p><a href=\"\(meet)\">Join</a>"])
            ])),
            expected: found(meet)
        ),
        Fixture(
            name: "two-links-differ",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", [meet, "Backup: \(zoom)"])])),
            expected: MeetingLink.Match(url: nil, links: 2, fetched: false)
        ),
        Fixture(
            name: "record-without-link",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", ["Room 4"])])),
            expected: .nothing
        ),
        Fixture(
            name: "only-a-foreign-link",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([
                record("ev1", "Weekly sync", ["https://example.com/agenda"])
            ])),
            expected: .nothing
        ),
        Fixture(
            name: "decoy-same-title-two-events",
            title: "Standup",
            html: page(
                chip("ev1", "Standup") + chip("ev2", "Standup")
                + eventList([record("ev1", "Standup", [meet]), record("ev2", "Standup", [otherMeet])])
            ),
            expected: .nothing
        ),
        Fixture(
            name: "decoy-same-title-one-without-link",
            title: "Weekly sync",
            html: page(
                chip("ev1", "Weekly sync") + chip("ev2", "Weekly sync")
                + eventList([record("ev1", "Weekly sync"), record("ev2", "Weekly sync", [meet])])
            ),
            expected: .nothing
        ),
        Fixture(
            name: "one-event-two-chips-padding-ignored",
            title: "Weekly sync",
            html: page(
                chip("ZXYx", "Weekly sync") + chip("ZXYx==", "Weekly sync")
                + eventList([record("ZXYx", "Weekly sync", [meet])])
            ),
            expected: found(meet)
        ),
        Fixture(
            name: "record-url-encoded-with-params",
            title: "Weekly sync",
            html: page(chip("ZXYx=", "Weekly sync") + eventList([record("ZXYx%3D&ctz=UTC", "Weekly sync", [meet])])),
            expected: found(meet)
        ),
        Fixture(
            name: "list-escapes-equals-sign",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + script(
                json(["placeholder-list", [record("ev1", "Weekly sync", [meet])]])
                    .replacingOccurrences(of: "eid=", with: "eid\\u003d")
            )),
            expected: found(meet)
        ),
        Fixture(
            name: "record-as-object",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + script(json([
                "items": [["url": eventURL("ev1"), "summary": "Weekly sync", "conference": ["uri": meet]]]
            ]))),
            expected: found(meet)
        ),
        Fixture(
            name: "link-in-another-events-record",
            title: "Weekly sync",
            html: page(
                chip("ev1", "Weekly sync") + chip("ev2", "Planning")
                + eventList([record("ev1", "Weekly sync"), record("ev2", "Planning", [meet])])
            ),
            expected: .nothing
        ),
        Fixture(
            name: "id-prefix-is-not-a-match",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev10", "Weekly sync", [meet])])),
            expected: fetchedNothing
        ),
        Fixture(
            name: "reply-prefix-is-not-a-match",
            title: "Weekly sync",
            html: page(
                chip("ev1", "Weekly sync") + chip("ev2", "Re: Weekly sync")
                + eventList([record("ev1", "Weekly sync"), record("ev2", "Re: Weekly sync", [zoom])])
            ),
            expected: .nothing
        ),
        Fixture(
            name: "reminder-prefix-fails-safe",
            title: "Starting now: Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev1", "Weekly sync", [meet])])),
            expected: .nothing
        ),
        Fixture(
            name: "title-whitespace-normalised",
            title: "Weekly sync",
            html: page(chip("ev1", "  Weekly&nbsp;\n sync ") + eventList([record("ev1", "Weekly sync", [meet])])),
            expected: found(meet)
        ),
        Fixture(
            name: "title-outside-every-chip",
            title: "Weekly sync",
            html: page(
                chip("ev1", "Planning") + "<p>Weekly sync</p>"
                + eventList([record("ev1", "Planning", [meet])])
            ),
            expected: .nothing
        ),
        Fixture(
            name: "suffix-trick-host",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([
                record("ev1", "Weekly sync", ["https://meet.google.com.evil.example/x"])
            ])),
            expected: .nothing
        ),
        Fixture(
            name: "link-redirect",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([
                record("ev1", "Weekly sync", ["https://meet.google.com/linkredirect?dest=https://evil.example"])
            ])),
            expected: .nothing
        ),
        Fixture(
            name: "teams-dot-segments",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([
                record("ev1", "Weekly sync", [
                    "https://teams.microsoft.com/l/meetup-join/../../settings",
                    "https://teams.microsoft.com/l/meetup-join/%2e%2e/x"
                ])
            ])),
            expected: .nothing
        ),
        Fixture(
            name: "record-missing-fetch-finds-it",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + eventList([record("ev2", "Planning")])),
            fetched: page(eventList([record("ev2", "Planning"), record("ev1", "Weekly sync", [meet])])),
            expected: found(meet, fetched: true)
        ),
        Fixture(
            name: "record-missing-signed-out",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync")),
            fetched: nil,
            expected: fetchedNothing
        ),
        Fixture(
            name: "record-missing-from-fetched-page",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync")),
            fetched: page(eventList([record("ev2", "Planning", [meet])])),
            expected: fetchedNothing
        ),
        Fixture(
            name: "fetched-record-two-links",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync")),
            fetched: page(eventList([record("ev1", "Weekly sync", [meet, otherMeet])])),
            expected: MeetingLink.Match(url: nil, links: 2, fetched: true)
        ),
        Fixture(
            name: "marker-in-a-non-json-script",
            title: "Weekly sync",
            html: page(chip("ev1", "Weekly sync") + script("window.placeholder({u: \"\(eventURL("ev1"))\", m: \"\(meet)\"});")),
            fetched: page(eventList([record("ev1", "Weekly sync", [zoom])])),
            expected: found(zoom, fetched: true)
        ),
        Fixture(
            name: "id-unfit-for-a-url-is-not-fetched",
            title: "Weekly sync",
            html: page(chip("ev1/../x", "Weekly sync")),
            fetched: page(eventList([record("ev1/../x", "Weekly sync", [meet])])),
            expected: .nothing
        ),
        Fixture(
            name: "empty-title",
            title: "",
            html: page(chip("ev1", "") + eventList([record("ev1", "", [meet])])),
            expected: .nothing
        )
    ]
}
