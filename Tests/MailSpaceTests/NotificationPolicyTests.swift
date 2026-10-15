import XCTest
@testable import MailSpace

/// Whether a web notification becomes a native one (A2, A3) and how it arrives
/// (B1).
///
/// The rule sits next to `NotificationOrigin.isTrusted`, never inside it: one
/// is a preference, the other is the boundary that stops a third-party frame
/// putting the user's account name on a macOS banner.
final class NotificationPolicyTests: XCTestCase {
    private func account(mail: Bool = true, calendar: Bool = true, notifyMail: Bool = true, notifyCalendar: Bool = true) -> Account {
        Account(
            name: "Work",
            mailEnabled: mail,
            calendarEnabled: calendar,
            notifyMail: notifyMail,
            notifyCalendar: notifyCalendar
        )
    }

    func testBothOnPostsBoth() {
        let account = account()
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    func testMutingMailLeavesCalendarAlone() {
        let account = account(notifyMail: false)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    func testMutingCalendarLeavesMailAlone() {
        let account = account(notifyCalendar: false)
        XCTAssertTrue(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    func testBothMutedPostsNothing() {
        let account = account(notifyMail: false, notifyCalendar: false)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .mail))
        XCTAssertFalse(NotificationPolicy.shouldPost(account: account, view: .calendar))
    }

    /// A service the account does not offer has nothing to alert about,
    /// whatever the flag says.
    func testADisabledServiceNeverPosts() {
        let mailOnly = account(mail: true, calendar: false, notifyCalendar: true)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: mailOnly, view: .calendar))

        let calendarOnly = account(mail: false, calendar: true, notifyMail: true)
        XCTAssertFalse(NotificationPolicy.shouldPost(account: calendarOnly, view: .mail))
    }

    // MARK: - B2

    func testGmailsSilentFlagSilencesTheNotification() {
        XCTAssertNil(NotificationPolicy.sound(silent: true))
        XCTAssertNotNil(NotificationPolicy.sound(silent: false))
    }

    /// The shim has to send the flag at all — it used to read `options.silent`
    /// onto its own object and then post without it.
    func testTheShimForwardsTheSilentFlag() {
        XCTAssertTrue(NotificationShim.userScript.source.contains("silent: !!options.silent"))
    }

    /// The shim forwards no page `actions` and routes no click back, so the
    /// page must not be invited to attach buttons; Copy Code is native.
    func testTheShimStillOffersNoPageActions() {
        XCTAssertTrue(NotificationShim.userScript.source.contains("MailSpaceNotification.maxActions = 0;"))
    }

    // MARK: - R32: Calendar key names

    func testTheShimForwardsKeyNamesACountAndOneLink() {
        let source = NotificationShim.userScript.source
        XCTAssertTrue(source.contains("optionKeys: keysOf(options)"))
        XCTAssertTrue(source.contains("dataKeys: keysOf(data)"))
        XCTAssertTrue(source.contains("actionCount: countActions(options)"))
        XCTAssertTrue(source.contains("dataLink: meetingLinkIn(data)"))
    }

    /// Calendar's `data` is page content; only its key names and one
    /// candidate link may cross (KTD18).
    func testTheShimNeverForwardsTheDataObject() {
        let source = NotificationShim.userScript.source
        XCTAssertFalse(source.contains("data: options.data"))
        XCTAssertFalse(source.contains("data: data"))
    }

    /// Two different meeting strings are no link at all.
    func testTheShimOffersADataLinkOnlyWhenThereIsExactlyOne() {
        let source = NotificationShim.userScript.source
        XCTAssertTrue(source.contains("} else if (found !== value) {"))
    }

    func testTheCalendarLineCarriesNamesAndCountsOnly() {
        let title = "Weekly sync"
        let body = "Tomorrow at 10:00"
        let link = "https://meet.google.com/abc-defg-hij"

        let line = CalendarNotificationLine.make(
            optionKeys: ["body", "tag", "data"],
            dataKeys: ["eventId"],
            actionCount: 2,
            join: .data,
            links: 0
        )

        XCTAssertEqual(line, "calendar notification keys=body,tag,data data=eventId actions=2 join=data links=0")
        XCTAssertFalse(line.contains(title))
        XCTAssertFalse(line.contains(body))
        XCTAssertFalse(line.contains(link))
        XCTAssertFalse(line.contains("meet.google.com"))
    }

    /// A key name that is not an identifier could be content; it is masked.
    func testTheCalendarLineMasksKeysThatAreNotIdentifiers() {
        let line = CalendarNotificationLine.make(
            optionKeys: [], dataKeys: ["eventId", "Weekly sync with Bob"], actionCount: 0, join: .fetch, links: 1
        )

        XCTAssertEqual(line, "calendar notification keys=- data=eventId,? actions=0 join=fetch links=1")
    }

    /// R32's source vocabulary, exactly.
    func testTheJoinSourcesAreTheR32Vocabulary() {
        let sources: [JoinSource] = [.data, .page, .fetch, .none, .error, .timeout, .noWebView]
        XCTAssertEqual(sources.map(\.rawValue), ["data", "page", "fetch", "none", "error", "timeout", "no-webview"])
    }

    // MARK: - B1

    func testTheTabOnScreenGetsNoBanner() {
        let tab = TabRef(accountId: UUID(), view: .mail)
        XCTAssertTrue(NotificationPolicy.suppressBanner(appIsActive: true, notification: tab, selection: tab))
    }

    func testAnotherTabStillBanners() {
        let accountId = UUID()
        let mail = TabRef(accountId: accountId, view: .mail)
        let calendar = TabRef(accountId: accountId, view: .calendar)
        let other = TabRef(accountId: UUID(), view: .mail)

        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: mail, selection: calendar))
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: other, selection: mail))
    }

    /// The point of a banner is to reach someone who is looking elsewhere.
    func testABackgroundedAppAlwaysBanners() {
        let tab = TabRef(accountId: UUID(), view: .mail)
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: false, notification: tab, selection: tab))
    }

    func testAnUnattributableNotificationAlwaysBanners() {
        let tab = TabRef(accountId: UUID(), view: .mail)
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: nil, selection: tab))
        XCTAssertFalse(NotificationPolicy.suppressBanner(appIsActive: true, notification: tab, selection: nil))
    }
}
