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

    func testTheRegistryHoldsOneCopyCodeCategory() throws {
        let categories = NotificationCategory.registered
        XCTAssertEqual(categories.count, 1)

        let category = try XCTUnwrap(categories.first)
        XCTAssertEqual(category.identifier, NotificationCategory.oneTimeCode.identifier)
        XCTAssertEqual(category.actions.map(\.title), ["Copy Code"])
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
}
