import AppKit
import XCTest
@testable import MailSpace

/// The Help menu and the key that opens the cheat sheet.
///
/// That this suite can call `MainMenu.helpMenuItem()` at all is the assertion
/// that matters most: under `swift test` there is no `NSApp`, so a builder that
/// registered `NSApp.helpMenu` itself — the way `windowMenuItem()` registers
/// `NSApp.windowsMenu` — would crash the suite rather than fail it. The
/// registration lives in `MainMenu.build()` instead, and nothing here calls it.
final class MainMenuHelpTests: XCTestCase {
    func testHelpHoldsTheCheatSheetAtCommandSlash() {
        let help = MainMenu.helpMenuItem()

        XCTAssertEqual(help.title, "Help")
        XCTAssertEqual(help.submenu?.title, "Help")
        XCTAssertEqual(help.submenu?.items.count, 1)

        let item = help.submenu?.items.first
        XCTAssertEqual(item?.title, "Keyboard Shortcuts…")
        XCTAssertEqual(item?.keyEquivalent, "/")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(item?.action, #selector(AppDelegate.showKeyboardShortcuts(_:)))
    }

    /// R14. The sheet documents the shortcut that opens it — the one row a
    /// hand-written table would always be the last to gain.
    func testTheCheatSheetListsItsOwnShortcut() {
        let bar = NSMenu()
        bar.addItem(MainMenu.helpMenuItem())

        XCTAssertEqual(MenuShortcuts.groups(of: bar), [
            MenuShortcutGroup(
                title: "Help",
                rows: [MenuShortcut(title: "Keyboard Shortcuts…", keys: "⌘/")]
            )
        ])
    }
}
