import AppKit
import XCTest
@testable import MailSpace

/// The cheat sheet is whatever the menu bar says, so the walker is the whole
/// feature: everything the panel shows comes out of these two functions, and
/// both take their menus as arguments and can be run without an application.
final class MenuShortcutsTests: XCTestCase {
    // MARK: - Builders

    /// A top-level menu item in the shape `MainMenu.submenuItem(_:)` produces:
    /// the title lives on the item as well as the submenu.
    private func topLevel(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let menu = NSMenu(title: title)
        build(menu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func bar(_ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu()
        items.forEach { menu.addItem($0) }
        return menu
    }

    private func group(_ title: String, _ rows: [(String, String)]) -> MenuShortcutGroup {
        MenuShortcutGroup(title: title, rows: rows.map { MenuShortcut(title: $0.0, keys: $0.1) })
    }

    // MARK: - Walking

    func testEachSubmenuBecomesAGroupInBarOrder() {
        let menuBar = bar([
            topLevel("File") { $0.addItem(withTitle: "Close Window", action: nil, keyEquivalent: "w") },
            topLevel("Edit") { $0.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c") }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [
            group("File", [("Close Window", "⌘W")]),
            group("Edit", [("Copy", "⌘C")])
        ])
    }

    /// R5. Cut and Paste are grey whenever the first responder does not take
    /// them, which is most of the time — and they are still the shortcuts.
    func testADisabledItemIsListed() {
        let menuBar = bar([
            topLevel("Edit") {
                let item = $0.addItem(withTitle: "Paste", action: nil, keyEquivalent: "v")
                item.isEnabled = false
            }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [group("Edit", [("Paste", "⌘V")])])
    }

    /// R6. Separators, hidden items and items with no key equivalent are not
    /// shortcuts, and a menu made only of those leaves no header behind.
    func testSeparatorsHiddenItemsAndKeylessItemsVanishWithTheirGroup() {
        let menuBar = bar([
            topLevel("File") {
                $0.addItem(.separator())
                let hidden = $0.addItem(withTitle: "Secret", action: nil, keyEquivalent: "s")
                hidden.isHidden = true
                $0.addItem(withTitle: "Make MailSpace the Default Mail App", action: nil, keyEquivalent: "")
            },
            topLevel("Edit") { $0.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c") }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [group("Edit", [("Copy", "⌘C")])])
    }

    /// R7. An alternate is invisible until the modifier is held — precisely the
    /// shortcut a cheat sheet exists to reveal.
    func testAnAlternateItemIsListed() {
        let menuBar = bar([
            topLevel("View") {
                $0.addItem(withTitle: "Reload Tab", action: nil, keyEquivalent: "r")
                let alternate = $0.addItem(withTitle: "Reload All Tabs", action: nil, keyEquivalent: "r")
                alternate.keyEquivalentModifierMask = [.command, .option]
                alternate.isAlternate = true
            }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [
            group("View", [("Reload Tab", "⌘R"), ("Reload All Tabs", "⌥⌘R")])
        ])
    }

    /// R9. Depth is a menu-design detail; the reader looks under the top-level
    /// name they can see in the bar.
    func testAnItemThreeLevelsDeepLandsUnderItsTopLevelTitle() {
        let menuBar = bar([
            topLevel("File") { file in
                let second = NSMenu(title: "Share")
                let third = NSMenu(title: "More")
                third.addItem(withTitle: "Buried", action: nil, keyEquivalent: "b")
                let secondItem = second.addItem(withTitle: "More", action: nil, keyEquivalent: "")
                secondItem.submenu = third
                let firstItem = file.addItem(withTitle: "Share", action: nil, keyEquivalent: "")
                firstItem.submenu = second
            }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [group("File", [("Buried", "⌘B")])])
    }

    /// R4. Menu order, not alphabetical order — the sheet reads like the menu.
    func testRowsKeepMenuOrder() {
        let menuBar = bar([
            topLevel("View") {
                $0.addItem(withTitle: "Zebra", action: nil, keyEquivalent: "z")
                $0.addItem(withTitle: "Apple", action: nil, keyEquivalent: "a")
            }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar).first?.rows.map(\.title), ["Zebra", "Apple"])
    }

    /// KTD3. The real bar has no bare top-level item, but a group needs a
    /// submenu to be a group.
    func testARootItemWithNoSubmenuIsSkipped() {
        let menuBar = bar([
            NSMenuItem(title: "Loose", action: nil, keyEquivalent: "l"),
            topLevel("Edit") { $0.addItem(withTitle: "Copy", action: nil, keyEquivalent: "c") }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [group("Edit", [("Copy", "⌘C")])])
    }

    // MARK: - The Accounts menu

    /// R10, R12. The tab shortcuts are the live Accounts rows, built by
    /// `MainWindowController.rebuildAccountsMenu()`; the tenth tab onward has no
    /// key equivalent and therefore nothing to document.
    func testOnlyTheFirstNineTabsAreListed() {
        let menuBar = bar([
            topLevel(MainMenu.accountsMenuTitle) { menu in
                menu.addItem(withTitle: "Add Account…", action: nil, keyEquivalent: "")
                menu.addItem(.separator())
                for index in 0..<10 {
                    menu.addItem(
                        withTitle: "Account \(index) · Mail",
                        action: nil,
                        keyEquivalent: index < 9 ? String(index + 1) : ""
                    )
                }
            }
        ])

        let rows = MenuShortcuts.groups(of: menuBar).first?.rows ?? []
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows.first, MenuShortcut(title: "Account 0 · Mail", keys: "⌘1"))
        XCTAssertEqual(rows.last, MenuShortcut(title: "Account 8 · Mail", keys: "⌘9"))
        XCTAssertFalse(rows.contains { $0.title == "Account 9 · Mail" })
    }

    /// R11. No accounts means no tab shortcuts, and a header over nothing is
    /// worse than no header.
    func testAnAccountsMenuWithNoAccountsProducesNoGroup() {
        let menuBar = bar([
            topLevel(MainMenu.accountsMenuTitle) {
                $0.addItem(withTitle: "Add Account…", action: nil, keyEquivalent: "")
            }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [])
    }

    /// R13. ⌘M minimises and ⇧⌘M shows Mail. Both are real; collapsing them by
    /// key character would hide one of them.
    func testShortcutsSharingAKeyCharacterAreBothListed() {
        let menuBar = bar([
            topLevel("View") {
                let mail = $0.addItem(withTitle: "Mail", action: nil, keyEquivalent: "m")
                mail.keyEquivalentModifierMask = [.command, .shift]
            },
            topLevel("Window") { $0.addItem(withTitle: "Minimize", action: nil, keyEquivalent: "m") }
        ])

        XCTAssertEqual(MenuShortcuts.groups(of: menuBar), [
            group("View", [("Mail", "⇧⌘M")]),
            group("Window", [("Minimize", "⌘M")])
        ])
    }

    // MARK: - Display order

    /// KTD2. MailSpace's own shortcuts sit above the fold; the OS-standard
    /// menus keep their relative order below them.
    func testViewAndAccountsAreMovedToTheFront() {
        let groups = ["MailSpace", "File", "Edit", "View", MainMenu.accountsMenuTitle, "Window"]
            .map { group($0, [("Item", "⌘X")]) }

        XCTAssertEqual(
            MenuShortcuts.orderedForDisplay(groups).map(\.title),
            ["View", MainMenu.accountsMenuTitle, "MailSpace", "File", "Edit", "Window"]
        )
    }

    /// R11 again, one layer up: a promoted name with no group must not conjure
    /// an empty header.
    func testAMissingAccountsGroupIsNotInserted() {
        let groups = ["MailSpace", "View", "Window"].map { group($0, [("Item", "⌘X")]) }

        XCTAssertEqual(
            MenuShortcuts.orderedForDisplay(groups).map(\.title),
            ["View", "MailSpace", "Window"]
        )
    }

    // MARK: - Glyph rendering

    /// R8. The glyph order is the one macOS prints, whatever order the mask was
    /// written in.
    func testModifiersRenderInTheFixedOrder() {
        XCTAssertEqual(MenuShortcuts.keyString("z", [.command, .shift]), "⇧⌘Z")
        XCTAssertEqual(MenuShortcuts.keyString("v", [.command, .option, .shift]), "⌥⇧⌘V")
        XCTAssertEqual(MenuShortcuts.keyString("h", [.option, .command]), "⌥⌘H")
        XCTAssertEqual(MenuShortcuts.keyString("a", [.control, .option, .shift, .command]), "⌃⌥⇧⌘A")
    }

    /// R8. AppKit matches an uppercase key equivalent with Shift held, so the
    /// sheet must say so even when the mask does not.
    func testAnUppercaseLetterImpliesShift() {
        XCTAssertEqual(MenuShortcuts.keyString("Z", [.command]), "⇧⌘Z")
    }

    func testModifiersWithNoGlyphAreDropped() {
        XCTAssertEqual(MenuShortcuts.keyString("\u{F700}", [.command, .function]), "⌘↑")
        XCTAssertEqual(MenuShortcuts.keyString("1", [.command, .numericPad]), "⌘1")
    }

    func testSpecialKeysRenderAsTheirGlyphs() {
        XCTAssertEqual(MenuShortcuts.keyString("\r", [.command]), "⌘↩")
        XCTAssertEqual(MenuShortcuts.keyString("\u{1B}", []), "⎋")
        XCTAssertEqual(MenuShortcuts.keyString("\t", [.control]), "⌃⇥")
        XCTAssertEqual(MenuShortcuts.keyString(" ", [.command]), "⌘␣")
        XCTAssertEqual(MenuShortcuts.keyString("\u{7F}", [.command]), "⌘⌫")
        XCTAssertEqual(MenuShortcuts.keyString("\u{F704}", []), "F1")
        XCTAssertEqual(MenuShortcuts.keyString("\u{F717}", []), "F20")
    }

    func testNonLettersRenderVerbatim() {
        XCTAssertEqual(MenuShortcuts.keyString(",", [.command]), "⌘,")
        XCTAssertEqual(MenuShortcuts.keyString("/", [.command]), "⌘/")
    }
}
