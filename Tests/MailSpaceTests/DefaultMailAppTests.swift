import XCTest
@testable import MailSpace

/// Who owns `mailto:` (G5, B3).
///
/// The comparison is by path, and this is why: three bundles with the
/// identifier `com.vitalii.MailSpace` are registered with LaunchServices on
/// this Mac, so an identifier check reports a cheerful "you are the default"
/// for a build inside a worktree that is about to be deleted.
final class DefaultMailAppTests: XCTestCase {
    private let me = URL(fileURLWithPath: "/Applications/MailSpace.app", isDirectory: true)
    private let identifier = "com.vitalii.MailSpace"

    func testTheSameBundleIsMe() {
        XCTAssertEqual(
            DefaultMailApp.state(handler: me, me: me, handlerIdentifier: identifier, myIdentifier: identifier),
            .isMe
        )
    }

    func testATrailingSlashIsTheSameBundle() {
        let handler = URL(fileURLWithPath: "/Applications/MailSpace.app/", isDirectory: true)
        XCTAssertEqual(
            DefaultMailApp.state(handler: handler, me: me, handlerIdentifier: identifier, myIdentifier: identifier),
            .isMe
        )
    }

    /// The case the whole helper exists for.
    func testAnotherCopyOfMailSpaceIsNotMe() {
        let stale = URL(fileURLWithPath: "/Users/v/proj/.claude/worktrees/x/build/MailSpace.app", isDirectory: true)
        XCTAssertEqual(
            DefaultMailApp.state(handler: stale, me: me, handlerIdentifier: identifier, myIdentifier: identifier),
            .otherCopy(stale)
        )
    }

    func testADifferentAppIsAnotherApp() {
        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app", isDirectory: true)
        XCTAssertEqual(
            DefaultMailApp.state(handler: mail, me: me, handlerIdentifier: "com.apple.mail", myIdentifier: identifier),
            .otherApp(mail)
        )
    }

    func testNoHandlerIsUnknown() {
        XCTAssertEqual(
            DefaultMailApp.state(handler: nil, me: me, handlerIdentifier: nil, myIdentifier: identifier),
            .unknown
        )
    }

    /// An unreadable bundle identifier must not be mistaken for a match.
    func testAnUnreadableHandlerIdentifierIsAnotherApp() {
        let other = URL(fileURLWithPath: "/Applications/Something.app", isDirectory: true)
        XCTAssertEqual(
            DefaultMailApp.state(handler: other, me: me, handlerIdentifier: nil, myIdentifier: identifier),
            .otherApp(other)
        )
    }

    // MARK: - What the user is shown

    func testOnlyTheCorrectStateLeavesNothingToClick() {
        XCTAssertFalse(DefaultMailApp.canBecomeDefault(.isMe))
        XCTAssertTrue(DefaultMailApp.canBecomeDefault(.otherCopy(me)))
        XCTAssertTrue(DefaultMailApp.canBecomeDefault(.otherApp(me)))
        XCTAssertTrue(DefaultMailApp.canBecomeDefault(.unknown))
    }

    func testTheStatusLineAndTheMenuItemAgree() {
        let stale = URL(fileURLWithPath: "/tmp/build/MailSpace.app", isDirectory: true)
        XCTAssertTrue(DefaultMailApp.statusText(.otherCopy(stale)).contains(stale.path))
        XCTAssertTrue(DefaultMailApp.statusText(.otherCopy(stale)).contains("Another copy"))
        XCTAssertTrue(DefaultMailApp.menuTitle(.otherCopy(stale)).contains("Another Copy"))

        XCTAssertTrue(DefaultMailApp.statusText(.isMe).contains("MailSpace is your default"))
        XCTAssertEqual(DefaultMailApp.menuTitle(.otherApp(stale)), "Make MailSpace the Default Mail App")

        let mail = URL(fileURLWithPath: "/System/Applications/Mail.app", isDirectory: true)
        XCTAssertTrue(DefaultMailApp.statusText(.otherApp(mail)).hasPrefix("Mail is"))
    }
}
