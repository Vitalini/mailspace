import XCTest
@testable import MailSpace

/// The Join allow-list (R28) and the Swift reference of the meeting-link
/// lookup (R27, KTD17). Every document is a hand-written placeholder.
final class MeetingLinkTests: XCTestCase {
    // MARK: - Allow-list

    /// One table for the Swift gate, the page script's gate (smoke) and this.
    func testTheAllowListAcceptsEveryAllowedURL() {
        for url in MeetingLinkFixtures.allowedURLs {
            XCTAssertTrue(MeetingLink.isAllowed(url), url)
        }
    }

    func testTheAllowListRefusesEveryRefusedURL() {
        for url in MeetingLinkFixtures.refusedURLs {
            XCTAssertFalse(MeetingLink.isAllowed(url), url)
        }
    }

    /// The gate admits a subset of what opens as-is: every allowed URL parses,
    /// stays on its host, and has no dot segment for the browser to resolve.
    func testEveryAllowedURLOpensExactlyAsWritten() throws {
        let hosts = ["meet.google.com", "zoom.us", "us02web.zoom.us", "teams.microsoft.com"]
        for raw in MeetingLinkFixtures.allowedURLs {
            let url = try XCTUnwrap(URL(string: raw), raw)
            XCTAssertTrue(hosts.contains(url.host ?? ""), raw)
            XCTAssertEqual(url.standardized.absoluteString, raw, raw)
        }
    }

    /// Review #1: nothing may climb out of `/l/meetup-join/`.
    func testTeamsRefusesDotSegmentsEncodedDotsAndBackslashes() {
        let base = "https://teams.microsoft.com/l/meetup-join/"
        for tail in ["../x", "x/../y", "./x", "x/./y", "%2e%2e/x", "%2E./x", "x/.%2e/y", "x\\..\\y", "x\\y"] {
            XCTAssertFalse(MeetingLink.isAllowed(base + tail), tail)
        }
        XCTAssertTrue(MeetingLink.isAllowed(base + "19%3ameeting_placeholder%40thread.v2/0"))
    }

    // MARK: - Fixtures

    /// Every fixture's expected answer is the reference's answer; the page
    /// script is held to the same table by `MAILSPACE_SELFTEST=meetinglink`.
    func testEveryFixtureMatchesItsExpectedResult() {
        for fixture in MeetingLinkFixtures.all {
            XCTAssertEqual(answer(fixture), fixture.expected, fixture.name)
        }
    }

    func testThereAreAtLeastTwentyUniquelyNamedFixtures() {
        let names = MeetingLinkFixtures.all.map(\.name)
        XCTAssertGreaterThanOrEqual(names.count, 20)
        XCTAssertEqual(Set(names).count, names.count)
    }

    private func answer(_ fixture: MeetingLinkFixtures.Fixture) -> MeetingLink.Match {
        MeetingLink.find(html: fixture.html, title: fixture.title) { _ in fixture.fetched }
    }

    private func answer(_ name: String) -> MeetingLink.Match? {
        MeetingLinkFixtures.all.first { $0.name == name }.map(answer)
    }

    /// The ids the fetch was asked for, per fixture.
    private func fetches(_ name: String) -> [String] {
        guard let fixture = MeetingLinkFixtures.all.first(where: { $0.name == name }) else { return [] }
        var asked: [String] = []
        _ = MeetingLink.find(html: fixture.html, title: fixture.title) { id in
            asked.append(id)
            return fixture.fetched
        }
        return asked
    }

    /// AE9.
    func testTheRecordOfTheOneMatchingEventGivesItsMeeting() {
        XCTAssertEqual(answer("meet-in-record")?.url, MeetingLinkFixtures.meet)
        XCTAssertEqual(answer("zoom-only-in-location")?.url, MeetingLinkFixtures.zoom)
        XCTAssertEqual(answer("teams-in-record")?.url, MeetingLinkFixtures.teams)
        XCTAssertEqual(answer("record-as-object")?.url, MeetingLinkFixtures.meet)
    }

    /// AE10 and review #4: two events with the same title give a URL only
    /// when both records agree on one link; a decoy with another link or no
    /// link gives none, and is never fetched.
    func testTwoEventsWithTheSameTitleMustAgree() {
        XCTAssertEqual(answer("decoy-same-title-two-events"), MeetingLink.Match(url: nil, links: 2, fetched: false))
        XCTAssertEqual(answer("decoy-same-title-one-without-link"), MeetingLink.Match(url: nil, links: 1, fetched: false))
        XCTAssertTrue(fetches("decoy-same-title-one-without-link").isEmpty)
    }

    /// Unrelated same-title events that all hold the same one link.
    func testSameTitleEventsThatAgreeGetJoin() {
        XCTAssertEqual(answer("same-title-events-daily-same-link"), MeetingLinkFixtures.found(MeetingLinkFixtures.meet))
        XCTAssertEqual(answer("same-title-events-at-the-cap")?.url, MeetingLinkFixtures.meet)
    }

    func testSameTitleEventsThatDisagreeGetNothing() {
        XCTAssertNil(answer("same-title-events-one-instance-different-link")?.url)
        XCTAssertNil(answer("same-title-events-one-instance-without-link")?.url)
        XCTAssertNil(answer("same-title-events-instance-with-two-links")?.url)
        XCTAssertEqual(answer("same-title-events-over-the-cap"), .nothing)
    }

    /// No fetch fan-out: a missing record among several series is no link.
    func testAMissingRecordAmongSeveralSeriesIsNeverFetched() {
        XCTAssertNil(answer("same-title-events-one-record-missing-is-not-fetched")?.url)
        XCTAssertTrue(fetches("same-title-events-one-record-missing-is-not-fetched").isEmpty)
    }

    // MARK: - Series

    private typealias Identity = MeetingLink.EventIdentity

    func testInstancesOfOneSeriesShareTheMastersSeries() {
        let master = MeetingLink.identity(of: MeetingLinkFixtures.calendarId("series1"))
        let monday = MeetingLink.identity(of: MeetingLinkFixtures.calendarId("series1_20261013T090000Z"))
        let allDay = MeetingLink.identity(of: MeetingLinkFixtures.calendarId("series1_20261014"))

        XCTAssertEqual(master, Identity(series: "series1 placeholder@example.com", timestamp: ""))
        XCTAssertEqual(monday, Identity(series: "series1 placeholder@example.com", timestamp: "20261013T090000Z"))
        XCTAssertEqual(allDay.series, master.series)
        XCTAssertEqual(allDay.timestamp, "20261014")
    }

    func testAnotherCalendarOrBaseIsAnotherSeries() {
        let mine = MeetingLink.identity(of: MeetingLinkFixtures.calendarId("series1_20261013T090000Z"))
        let theirs = MeetingLink.identity(of: MeetingLinkFixtures.calendarId("series1_20261013T090000Z", "other@example.com"))
        let other = MeetingLink.identity(of: MeetingLinkFixtures.calendarId("series2_20261013T090000Z"))

        XCTAssertNotEqual(mine.series, theirs.series)
        XCTAssertNotEqual(mine.series, other.series)
    }

    /// Only a timestamp-shaped suffix makes an instance; padding is ignored.
    func testOnlyATimestampSuffixMakesAnInstance() {
        XCTAssertEqual(MeetingLink.identity(of: MeetingLinkFixtures.calendarId("under_score_id")).timestamp, "")
        XCTAssertEqual(
            MeetingLink.identity(of: MeetingLinkFixtures.calendarId("under_score_id")).series,
            "under_score_id placeholder@example.com"
        )
        XCTAssertEqual(MeetingLink.identity(of: MeetingLinkFixtures.calendarId("_20261015T090000Z")).timestamp, "")
        let id = MeetingLinkFixtures.calendarId("series1_20261015T090000Z")
        XCTAssertEqual(MeetingLink.identity(of: id + "=="), MeetingLink.identity(of: id))
    }

    /// Anything that does not decode to `<id> <email>` is a series of its own.
    func testAMalformedIdIsItsOwnSeries() {
        for id in ["ev1", "ZXYx", "not base64!", "abcde", "", "bm9zcGFjZQ",
                   MeetingLinkFixtures.calendarId("two spaces here")] {
            XCTAssertEqual(MeetingLink.identity(of: id), Identity(series: "#" + MeetingLink.normalizeEventId(id), timestamp: ""), id)
        }
    }

    func testOneSeriesUsesItsMasterOrInstanceRecords() {
        XCTAssertEqual(answer("series-master-record-only"), MeetingLinkFixtures.found(MeetingLinkFixtures.meet))
        XCTAssertEqual(answer("series-instance-records-agree")?.url, MeetingLinkFixtures.meet)
        XCTAssertEqual(answer("series-other-series-record-ignored")?.url, MeetingLinkFixtures.meet)
        XCTAssertEqual(answer("series-instance-record-wins-over-master")?.url, MeetingLinkFixtures.meet)
        XCTAssertTrue(fetches("series-master-record-only").isEmpty)
    }

    func testOneSeriesWhoseRecordsDisagreeGetsNothing() {
        XCTAssertEqual(answer("series-instance-records-differ"), MeetingLink.Match(url: nil, links: 2, fetched: false))
        XCTAssertNil(answer("series-instance-record-without-link")?.url)
    }

    /// One request, for the earliest instance, whatever the chip order.
    func testOneSeriesWithoutARecordFetchesItsEarliestInstanceOnce() {
        XCTAssertEqual(answer("series-no-record-fetch-earliest"), MeetingLinkFixtures.found(MeetingLinkFixtures.meet, fetched: true))
        XCTAssertEqual(fetches("series-no-record-fetch-earliest"), [MeetingLinkFixtures.instances("series1")[0]])
    }

    func testTwoSeriesWithOneTitleKeepTheStrictRule() {
        XCTAssertEqual(answer("two-series-same-title-differ"), MeetingLink.Match(url: nil, links: 2, fetched: false))
        XCTAssertNil(answer("two-series-same-title-one-missing")?.url)
        XCTAssertTrue(fetches("two-series-same-title-one-missing").isEmpty)
        XCTAssertEqual(answer("two-series-same-title-agree")?.url, MeetingLinkFixtures.meet)
    }

    func testPaddingAndEncodingDoNotSplitOneEvent() {
        XCTAssertEqual(answer("one-event-two-chips-padding-ignored")?.url, MeetingLinkFixtures.meet)
        XCTAssertEqual(answer("record-url-encoded-with-params")?.url, MeetingLinkFixtures.meet)
    }

    func testTwoDifferentLinksInTheRecordGiveNothing() {
        XCTAssertEqual(answer("two-links-differ"), MeetingLink.Match(url: nil, links: 2, fetched: false))
    }

    /// AE11.
    func testHostTricksGiveNothing() {
        XCTAssertNil(answer("suffix-trick-host")?.url)
        XCTAssertNil(answer("link-redirect")?.url)
        XCTAssertNil(answer("teams-dot-segments")?.url)
    }

    /// AE12.
    func testARecordWithoutALinkGivesNothingAndIsNotFetched() {
        XCTAssertEqual(answer("record-without-link"), .nothing)
        XCTAssertTrue(fetches("record-without-link").isEmpty)
    }

    func testAnExactTitleInsideAChipIsRequired() {
        XCTAssertEqual(answer("reply-prefix-is-not-a-match"), .nothing)
        XCTAssertEqual(answer("reminder-prefix-fails-safe"), .nothing)
        XCTAssertEqual(answer("title-outside-every-chip"), .nothing)
    }

    func testAnotherEventsRecordIsNeverBorrowed() {
        XCTAssertEqual(answer("link-in-another-events-record"), .nothing)
        XCTAssertEqual(answer("id-prefix-is-not-a-match"), MeetingLinkFixtures.fetchedNothing)
    }

    // MARK: - Fetch fallback

    func testAMissingRecordIsFetchedOnceForThatEvent() {
        XCTAssertEqual(answer("record-missing-fetch-finds-it"), MeetingLinkFixtures.found(MeetingLinkFixtures.meet, fetched: true))
        XCTAssertEqual(fetches("record-missing-fetch-finds-it"), ["ev1"])
        XCTAssertEqual(answer("marker-in-a-non-json-script")?.url, MeetingLinkFixtures.zoom)
    }

    func testASignedOutOrEmptyFetchGivesNothing() {
        XCTAssertEqual(answer("record-missing-signed-out"), MeetingLinkFixtures.fetchedNothing)
        XCTAssertEqual(answer("record-missing-from-fetched-page"), MeetingLinkFixtures.fetchedNothing)
        XCTAssertEqual(answer("fetched-record-two-links"), MeetingLink.Match(url: nil, links: 2, fetched: true))
    }

    func testAnIdUnfitForAURLIsNeverFetched() {
        XCTAssertEqual(answer("id-unfit-for-a-url-is-not-fetched"), .nothing)
        XCTAssertTrue(fetches("id-unfit-for-a-url-is-not-fetched").isEmpty)
    }

    func testAnEmptyTitleGivesNothing() {
        XCTAssertEqual(MeetingLink.find(html: MeetingLinkFixtures.page(""), title: "  ") { _ in nil }, .nothing)
        XCTAssertEqual(answer("empty-title"), .nothing)
    }
}
