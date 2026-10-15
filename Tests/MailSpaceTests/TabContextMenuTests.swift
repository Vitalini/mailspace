import AppKit
import XCTest
@testable import MailSpace

/// The tab's right-click menu.
///
/// Built by `AccountTabView.contextMenu(for:…)`, which touches no `NSApp`, so
/// `swift test` can read the menu and fire its items without an application.
final class TabContextMenuTests: XCTestCase {
    private let clicked = TabRef(accountId: UUID(), view: .calendar)

    private var reloaded: [TabRef] = []
    private var reloadedAll = 0
    private var edited: [UUID] = []
    private var removed: [UUID] = []

    private func menu() -> NSMenu {
        AccountTabView.contextMenu(
            for: clicked,
            reload: { [unowned self] tab in self.reloaded.append(tab) },
            reloadAll: { [unowned self] in self.reloadedAll += 1 },
            edit: { [unowned self] id in self.edited.append(id) },
            remove: { [unowned self] id in self.removed.append(id) }
        )
    }

    private func fire(_ title: String, in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            return XCTFail("no item titled \(title)")
        }
        guard let action = item.action, let target = item.target as? NSObject else {
            return XCTFail("\(title) has no target and action")
        }
        target.perform(action, with: item)
    }

    /// R14.
    func testTheItemsAreInOrder() {
        let items = menu().items
        XCTAssertEqual(
            items.map { $0.isSeparatorItem ? "-" : $0.title },
            ["Reload Tab", "Reload All Tabs", "-", "Account Settings…", "Remove Account…"]
        )
    }

    /// R15: the tab that was right-clicked, not whichever one is selected.
    func testReloadTabReloadsTheClickedTabOnce() {
        let menu = menu()
        fire("Reload Tab", in: menu)
        XCTAssertEqual(reloaded, [clicked])
        XCTAssertEqual(reloadedAll, 0)
    }

    /// R19.
    func testReloadAllTabsReloadsAllOnce() {
        let menu = menu()
        fire("Reload All Tabs", in: menu)
        XCTAssertEqual(reloadedAll, 1)
        XCTAssertEqual(reloaded, [])
    }

    func testSettingsAndRemoveStillReachTheirAccount() {
        let menu = menu()
        fire("Account Settings…", in: menu)
        fire("Remove Account…", in: menu)
        XCTAssertEqual(edited, [clicked.accountId])
        XCTAssertEqual(removed, [clicked.accountId])
        XCTAssertEqual(reloaded, [])
    }

    /// ⌘R and ⌥⌘R stay on the main menu only.
    func testNoItemHasAKeyEquivalent() {
        for item in menu().items {
            XCTAssertEqual(item.keyEquivalent, "", item.title)
        }
    }
}
