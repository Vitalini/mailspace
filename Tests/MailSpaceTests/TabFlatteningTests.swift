import XCTest
@testable import MailSpace

/// The tab bar is one tab per enabled service per account, in account order —
/// and that same flattened list is what Cmd+1..9 addresses.
final class TabFlatteningTests: XCTestCase {
    private func account(_ name: String, mail: Bool = true, calendar: Bool = true) -> Account {
        Account(name: name, mailEnabled: mail, calendarEnabled: calendar)
    }

    func testEachAccountContributesOneTabPerEnabledService() {
        let work = account("Work")
        let personal = account("Personal")

        let tabs = TabOrder.tabs(for: [work, personal])

        XCTAssertEqual(tabs.count, 4)
        XCTAssertEqual(tabs.map(\.view), [.mail, .calendar, .mail, .calendar])
        XCTAssertEqual(tabs.map(\.accountId), [work.id, work.id, personal.id, personal.id])
    }

    func testCalendarOnlyAccountContributesASingleTab() {
        let family = account("Family", mail: false, calendar: true)
        let tabs = TabOrder.tabs(for: [family])

        XCTAssertEqual(tabs, [TabRef(accountId: family.id, view: .calendar)])
    }

    func testTabOrderFollowsAccountOrderNotServiceOrder() {
        let mailOnly = account("MailOnly", mail: true, calendar: false)
        let calendarOnly = account("CalendarOnly", mail: false, calendar: true)

        let tabs = TabOrder.tabs(for: [mailOnly, calendarOnly])

        XCTAssertEqual(tabs, [
            TabRef(accountId: mailOnly.id, view: .mail),
            TabRef(accountId: calendarOnly.id, view: .calendar)
        ])
    }

    func testNoAccountsMeansNoTabs() {
        XCTAssertTrue(TabOrder.tabs(for: []).isEmpty)
    }

    // MARK: - Colours

    func testDefaultColoursRotateSoNeighbouringAccountsDiffer() {
        XCTAssertNotEqual(AccountColor.forPosition(0), AccountColor.forPosition(1))
        XCTAssertEqual(AccountColor.forPosition(0), AccountColor.forPosition(AccountColor.allCases.count))
    }

    func testStoreAssignsARotatingColourToEachNewAccount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceColors-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        let first = store.add(name: "Work")
        let second = store.add(name: "Personal")

        XCTAssertNotEqual(first.color, second.color)
        XCTAssertEqual(AccountStore(directory: directory).account(id: second.id)?.color, second.color)
    }

    func testExplicitColourWins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceColors-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = AccountStore(directory: directory)
        XCTAssertEqual(store.add(name: "Work", color: .pink).color, .pink)
    }

    func testLegacyAccountsWithoutColoursAreBackfilledDistinctly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceColors-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let first = UUID()
        let second = UUID()
        try Data("""
        [{"id":"\(first.uuidString)","name":"Legacy One"},
         {"id":"\(second.uuidString)","name":"Legacy Two"}]
        """.utf8).write(to: directory.appendingPathComponent("accounts.json"))

        let store = AccountStore(directory: directory)
        let firstColor = try XCTUnwrap(store.account(id: first)?.color)
        let secondColor = try XCTUnwrap(store.account(id: second)?.color)
        XCTAssertNotEqual(firstColor, secondColor)

        // The backfill is written through, so it survives the next launch.
        XCTAssertEqual(AccountStore(directory: directory).account(id: second)?.color, secondColor)
    }
}

/// Tabs are dragged into any order the user likes, and that order survives a
/// relaunch. A service tab moves independently of its account sibling.
final class TabReorderingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MailSpaceReorder-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> (AccountStore, Account, Account) {
        let store = AccountStore(directory: directory)
        return (store, store.add(name: "Work"), store.add(name: "Personal"))
    }

    func testDefaultOrderIsAccountThenService() {
        let (store, work, personal) = makeStore()
        XCTAssertEqual(TabOrder.tabs(for: store.accounts), [
            TabRef(accountId: work.id, view: .mail),
            TabRef(accountId: work.id, view: .calendar),
            TabRef(accountId: personal.id, view: .mail),
            TabRef(accountId: personal.id, view: .calendar)
        ])
    }

    func testAServiceTabMovesIndependentlyOfItsSibling() {
        let (store, work, personal) = makeStore()

        // Drag [Personal · Mail] to the front.
        store.moveTab(TabRef(accountId: personal.id, view: .mail), to: 0)

        XCTAssertEqual(TabOrder.tabs(for: store.accounts), [
            TabRef(accountId: personal.id, view: .mail),
            TabRef(accountId: work.id, view: .mail),
            TabRef(accountId: work.id, view: .calendar),
            TabRef(accountId: personal.id, view: .calendar)
        ])
    }

    func testMovingRightAccountsForTheRemovedSlot() {
        let (store, work, personal) = makeStore()

        // Drag [Work · Mail] (index 0) to the far end.
        store.moveTab(TabRef(accountId: work.id, view: .mail), to: 4)

        XCTAssertEqual(TabOrder.tabs(for: store.accounts).last, TabRef(accountId: work.id, view: .mail))
    }

    func testOrderSurvivesReload() {
        let (store, work, personal) = makeStore()
        store.moveTab(TabRef(accountId: personal.id, view: .calendar), to: 0)

        let expected = TabOrder.tabs(for: store.accounts)
        XCTAssertEqual(expected.first, TabRef(accountId: personal.id, view: .calendar))
        XCTAssertEqual(TabOrder.tabs(for: AccountStore(directory: directory).accounts), expected)
        XCTAssertEqual(TabOrder.tabs(for: store.accounts).count, 4)
        XCTAssertNotNil(work)
    }

    func testANewAccountLandsAtTheEndRatherThanColliding() {
        let (store, _, personal) = makeStore()
        store.moveTab(TabRef(accountId: personal.id, view: .calendar), to: 0)

        let added = store.add(name: "Third")
        let tabs = TabOrder.tabs(for: store.accounts)

        XCTAssertEqual(tabs.suffix(2), [
            TabRef(accountId: added.id, view: .mail),
            TabRef(accountId: added.id, view: .calendar)
        ])
    }

    func testNewlyEnabledServiceLandsAtTheEnd() {
        let store = AccountStore(directory: directory)
        let family = store.add(name: "Family", mailEnabled: false, calendarEnabled: true)
        let work = store.add(name: "Work")

        store.update(id: family.id, name: "Family", email: "", mailEnabled: true, calendarEnabled: true, color: family.color)

        XCTAssertEqual(TabOrder.tabs(for: store.accounts).last, TabRef(accountId: family.id, view: .mail))
        XCTAssertEqual(TabOrder.tabs(for: store.accounts).first, TabRef(accountId: family.id, view: .calendar))
        XCTAssertTrue(TabOrder.tabs(for: store.accounts).contains(TabRef(accountId: work.id, view: .mail)))
    }

    /// The gap `testNewlyEnabledServiceLandsAtTheEnd` missed: it only enables a
    /// service that was never on, so no stale slot exists. A service that is
    /// switched *off* used to keep its index — `applyTabOrder` renumbers only
    /// enabled tabs, so that index went stale, collided with whatever was
    /// renumbered onto it, and the service reappeared wedged mid-bar instead of
    /// at the end.
    func testAReEnabledServiceLandsAtTheEndRatherThanItsOldSlot() {
        let store = AccountStore(directory: directory)
        let a = store.add(name: "A")
        let b = store.add(name: "B")
        XCTAssertEqual(TabOrder.tabs(for: store.accounts), [
            TabRef(accountId: a.id, view: .mail),
            TabRef(accountId: a.id, view: .calendar),
            TabRef(accountId: b.id, view: .mail),
            TabRef(accountId: b.id, view: .calendar)
        ])

        // Switch A's Calendar off — it must give its slot up, not keep it.
        store.update(id: a.id, name: "A", email: "", mailEnabled: true, calendarEnabled: false, color: a.color)
        XCTAssertNil(store.account(id: a.id)?.order(for: .calendar))

        // Renumber the remaining tabs by dragging B's Mail to the front. This
        // is what used to hand A's stale Calendar index to A's Mail tab.
        store.moveTab(TabRef(accountId: b.id, view: .mail), to: 0)

        // Switch A's Calendar back on.
        store.update(id: a.id, name: "A", email: "", mailEnabled: true, calendarEnabled: true, color: a.color)

        XCTAssertEqual(
            TabOrder.tabs(for: store.accounts).last,
            TabRef(accountId: a.id, view: .calendar),
            "a re-enabled service belongs at the end of the tab bar"
        )
        // And no two tabs share a slot any more.
        let orders = store.accounts.flatMap { account in
            account.enabledViews.compactMap { account.order(for: $0) }
        }
        XCTAssertEqual(Set(orders).count, orders.count, "tab slots must be unique: \(orders)")
    }

    /// The disabled service's slot is really gone from disk, not just in memory.
    func testADisabledServiceStoresNoTabSlot() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")

        store.update(id: work.id, name: "Work", email: "", mailEnabled: true, calendarEnabled: false, color: .blue)

        XCTAssertNil(AccountStore(directory: directory).account(id: work.id)?.order(for: .calendar))
    }

    func testMovingAnUnknownTabIsANoOp() {
        let (store, _, _) = makeStore()
        let before = TabOrder.tabs(for: store.accounts)

        store.moveTab(TabRef(accountId: UUID(), view: .mail), to: 0)

        XCTAssertEqual(TabOrder.tabs(for: store.accounts), before)
    }

    func testTabIdentifierRoundTrips() throws {
        let tab = TabRef(accountId: UUID(), view: .calendar)
        XCTAssertEqual(TabRef(identifier: tab.identifier), tab)
        XCTAssertNil(TabRef(identifier: "not-a-tab"))
        XCTAssertNil(TabRef(identifier: "\(UUID().uuidString)|telepathy"))
    }
}

extension TabReorderingTests {
    /// Saving account settings must not shuffle the tab bar.
    func testEditingAnAccountKeepsItsTabPositions() {
        let store = AccountStore(directory: directory)
        let work = store.add(name: "Work")
        let personal = store.add(name: "Personal")
        store.moveTab(TabRef(accountId: personal.id, view: .mail), to: 0)

        let before = TabOrder.tabs(for: store.accounts)
        store.update(id: work.id, name: "Day Job", email: "work@gmail.com", mailEnabled: true, calendarEnabled: true, color: .red)

        XCTAssertEqual(TabOrder.tabs(for: store.accounts), before)
    }
}
