import AppKit
import UserNotifications
import XCTest
@testable import MailSpace

/// The category registry and the Copy Code handler. Every test writes a
/// uniquely named pasteboard, never the user's clipboard.
final class NotificationActionsTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var logged: [String] = []
    private var previousSink: ((String) -> Void)!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MailSpaceTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)
        logged = []
        previousSink = Log.sink
        Log.sink = { [weak self] in self?.logged.append($0) }
    }

    override func tearDown() {
        Log.sink = previousSink
        pasteboard.releaseGlobally()
        super.tearDown()
    }

    private let withCode: [AnyHashable: Any] = [NotificationCategory.InfoKey.code: "482913"]

    // MARK: - Registry

    func testTheRegistryHoldsCopyCodeAndJoin() throws {
        let categories = NotificationCategory.registered
        XCTAssertEqual(categories.count, 2)

        let copy = try XCTUnwrap(categories.first { $0.identifier == NotificationCategory.oneTimeCode.identifier })
        XCTAssertEqual(copy.actions.map(\.title), ["Copy Code"])
        let join = try XCTUnwrap(categories.first { $0.identifier == NotificationCategory.meetingJoin.identifier })
        XCTAssertEqual(join.actions.map(\.title), ["Join"])
    }

    /// Join is delivered without activating MailSpace; the browser comes
    /// forward on its own.
    func testJoinDoesNotBringTheAppForward() throws {
        let action = try XCTUnwrap(NotificationCategory.meetingJoin.category.actions.first)
        XCTAssertFalse(action.options.contains(.foreground))
    }

    /// Without `.foreground`, macOS delivers the press without activating
    /// MailSpace (R7).
    func testCopyCodeDoesNotBringTheAppForward() throws {
        let action = try XCTUnwrap(NotificationCategory.oneTimeCode.category.actions.first)
        XCTAssertFalse(action.options.contains(.foreground))
    }

    func testIdentifiersAreUniqueAndNamespaced() {
        let categories = NotificationCategory.registered
        let identifiers = categories.map(\.identifier) + categories.flatMap { $0.actions.map(\.identifier) }

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        for identifier in identifiers {
            XCTAssertTrue(identifier.hasPrefix("com.vitalii.MailSpace."), identifier)
        }
    }

    // MARK: - Copy handler

    func testCopyCodeReplacesThePasteboardWithTheCode() {
        let handled = NotificationCategory.handle(
            actionIdentifier: NotificationCategory.ActionId.copyCode,
            userInfo: withCode,
            pasteboard: pasteboard
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(pasteboard.string(forType: .string), "482913")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    }

    /// A click on the body keeps today's routing and leaves the clipboard alone (AE4).
    func testTheDefaultActionIsNotHandled() {
        let handled = NotificationCategory.handle(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: withCode,
            pasteboard: pasteboard
        )

        XCTAssertFalse(handled)
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
    }

    func testDismissIsNotHandled() {
        let handled = NotificationCategory.handle(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: withCode,
            pasteboard: pasteboard
        )

        XCTAssertFalse(handled)
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
    }

    /// Handled even with nothing to copy, so the press never turns into a tab
    /// switch; one fixed line says so.
    func testCopyCodeWithoutACodeLeavesThePasteboardAlone() {
        let handled = NotificationCategory.handle(
            actionIdentifier: NotificationCategory.ActionId.copyCode,
            userInfo: [:],
            pasteboard: pasteboard
        )

        XCTAssertTrue(handled)
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
        XCTAssertEqual(logged.count, 1)
    }

    /// R9: the code never reaches the log.
    func testTheCodeIsNeverLogged() {
        _ = NotificationCategory.handle(
            actionIdentifier: NotificationCategory.ActionId.copyCode,
            userInfo: withCode,
            pasteboard: pasteboard
        )

        XCTAssertFalse(logged.contains { $0.contains("482913") })
    }

    // MARK: - Join handler

    private let meet = "https://meet.google.com/abc-defg-hij"

    private func join(_ info: [AnyHashable: Any], action: String = NotificationCategory.ActionId.join) -> (NotificationCategory.JoinResult, [URL]) {
        var opened: [URL] = []
        let result = NotificationCategory.handleJoin(actionIdentifier: action, userInfo: info) { opened.append($0) }
        return (result, opened)
    }

    /// AE9.
    func testJoinOpensTheMeeting() {
        let (result, opened) = join([NotificationCategory.InfoKey.meetingURL: meet])

        XCTAssertEqual(result, .opened)
        XCTAssertEqual(opened, [URL(string: meet)!])
    }

    /// AE11: a stored link that fails the allow-list opens nothing.
    func testJoinWithAForeignLinkFocusesCalendarInstead() {
        let (result, opened) = join([NotificationCategory.InfoKey.meetingURL: "https://meet.google.com.evil.example/x"])

        XCTAssertEqual(result, .focusCalendar)
        XCTAssertTrue(opened.isEmpty)
    }

    func testJoinWithoutALinkFocusesCalendar() {
        let (result, opened) = join([:])

        XCTAssertEqual(result, .focusCalendar)
        XCTAssertTrue(opened.isEmpty)
    }

    func testCopyAndJoinIgnoreEachOther() {
        let (result, opened) = join([NotificationCategory.InfoKey.meetingURL: meet], action: NotificationCategory.ActionId.copyCode)
        XCTAssertEqual(result, .notHandled)
        XCTAssertTrue(opened.isEmpty)

        let copied = NotificationCategory.handle(
            actionIdentifier: NotificationCategory.ActionId.join,
            userInfo: withCode,
            pasteboard: pasteboard
        )
        XCTAssertFalse(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "old")
    }

    func testABodyClickIsNotAJoin() {
        XCTAssertEqual(join([NotificationCategory.InfoKey.meetingURL: meet], action: UNNotificationDefaultActionIdentifier).0, .notHandled)
    }

    /// R31: the meeting URL never reaches the log, on success or failure.
    func testTheMeetingURLIsNeverLogged() {
        _ = join([NotificationCategory.InfoKey.meetingURL: meet])
        _ = join([NotificationCategory.InfoKey.meetingURL: "https://meet.google.com.evil.example/x"])

        XCTAssertFalse(logged.contains { $0.contains("meet.google.com") })
    }
}
