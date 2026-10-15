import XCTest
@testable import MailSpace

/// The Join allow-list (R28) and the Swift reference of the meeting-link
/// lookup (R27, KTD17). Every document is a hand-written placeholder.
final class MeetingLinkTests: XCTestCase {
    // MARK: - Allow-list

    func testTheAllowListAcceptsMeetZoomAndTeams() {
        for url in [
            "https://meet.google.com/abc-defg-hij",
            "https://meet.google.com/abc-defg-hij?authuser=0",
            "https://us02web.zoom.us/j/123456789?pwd=x",
            "https://zoom.us/j/123456789",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_placeholder%40thread.v2/0?context=%7b%7d"
        ] {
            XCTAssertTrue(MeetingLink.isAllowed(url), url)
        }
    }

    func testTheAllowListRejectsEverythingElse() {
        for url in [
            "https://meet.google.com/linkredirect?dest=https://evil.example",
            "https://meet.google.com/abc-defg-hij/extra",
            "http://meet.google.com/abc-defg-hij",
            "https://meet.google.com.evil.example/x",
            "https://evilzoom.us/j/1",
            "https://zoom.us/webinar/1",
            "https://zoom.us@evil.example/j/1",
            "https://teams.microsoft.com/settings",
            "https://meet.google.com/abc-defg-hij\n",
            "javascript:alert(1)",
            "/abc-defg-hij",
            ""
        ] {
            XCTAssertFalse(MeetingLink.isAllowed(url), url)
        }
    }

    // MARK: - Fixtures

    /// Every fixture's expected answer is the reference's answer; the page
    /// script is held to the same table by `MAILSPACE_SELFTEST=meetinglink`.
    func testEveryFixtureMatchesItsExpectedResult() {
        for fixture in MeetingLinkFixtures.all {
            XCTAssertEqual(
                MeetingLink.find(html: fixture.html, title: fixture.title),
                fixture.expected,
                fixture.name
            )
        }
    }

    func testFixtureNamesAreUnique() {
        let names = MeetingLinkFixtures.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    private func answer(_ name: String) -> MeetingLink.Match? {
        MeetingLinkFixtures.all.first { $0.name == name }.map { MeetingLink.find(html: $0.html, title: $0.title) }
    }

    /// AE9.
    func testOneEventWithAMeetAnchorGivesThatMeeting() {
        XCTAssertEqual(answer("anchor-in-event")?.url, MeetingLinkFixtures.meet)
        XCTAssertEqual(answer("text-link-in-event")?.url, MeetingLinkFixtures.meet)
    }

    /// AE10: two events with the same name are no button.
    func testTwoEventsWithTheSameTitleGiveNothing() {
        XCTAssertNil(answer("two-events-same-title")?.url)
        XCTAssertEqual(answer("two-events-same-title")?.links, 2)
    }

    /// AE11.
    func testASuffixTrickHostGivesNothing() {
        XCTAssertNil(answer("suffix-trick-host")?.url)
    }

    /// AE12.
    func testAnEventWithoutALinkGivesNothing() {
        XCTAssertEqual(answer("event-without-link"), .nothing)
    }

    func testAnExactTitleIsRequired() {
        XCTAssertNil(answer("reply-prefix-is-not-a-match")?.url)
        XCTAssertNil(answer("title-only-in-description")?.url)
        XCTAssertNil(answer("reminder-prefix-fails-safe")?.url)
    }

    func testNothingOutsideAnEventIsBorrowed() {
        XCTAssertNil(answer("link-in-another-event")?.url)
        XCTAssertNil(answer("title-and-link-loose-in-body")?.url)
        XCTAssertNil(answer("fallback-never-borrows-from-an-event")?.url)
    }

    /// The fallback runs only when event containers gave no link at all; an
    /// ambiguous container answer is final.
    func testTheFallbackNeverOverridesAnAmbiguousEvent() {
        XCTAssertEqual(answer("ambiguity-in-events-is-final"), MeetingLink.Match(url: nil, links: 2, fallback: false))
    }

    func testTheFallbackFindsAnOpenEventOutsideTheGrid() {
        XCTAssertEqual(answer("fallback-open-event-dialog")?.url, MeetingLinkFixtures.meet)
        XCTAssertEqual(answer("fallback-open-event-dialog")?.fallback, true)
        XCTAssertEqual(answer("fallback-aria-label")?.url, MeetingLinkFixtures.zoom)
        XCTAssertNil(answer("fallback-hidden-is-ignored")?.url)
        XCTAssertNil(answer("fallback-too-far-away")?.url)
    }

    func testAnEmptyTitleGivesNothing() {
        XCTAssertEqual(MeetingLink.find(html: MeetingLinkFixtures.page(""), title: "  "), .nothing)
        XCTAssertEqual(answer("empty-title"), .nothing)
    }
}
