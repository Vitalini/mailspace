import AppKit
import XCTest
@testable import MailSpace

/// One tab, one trailing slot, three things that want it. These are the rules
/// that decide which one gets it and what that costs the row's geometry — all
/// of it pure, because the AppKit layout that applies it is not the part that
/// gets an answer wrong.
final class TabIndicatorTests: XCTestCase {
    // MARK: - Hide at zero

    func testAZeroCountIsNothingAtAll() {
        // A literal `0` on a tab is noise on a good day, and beside a session
        // that has quietly expired it is a lie. Unknown and zero render the
        // same, so nothing downstream has to tell them apart.
        XCTAssertNil(UnreadCounts.tabLabel(nil))
        XCTAssertNil(UnreadCounts.tabLabel(0))
        XCTAssertNil(UnreadCounts.tabTooltip(nil))
        XCTAssertNil(UnreadCounts.tabTooltip(0))
        XCTAssertEqual(
            TabIndicator.resolve(view: .mail, warning: nil, unread: 0, countdownSeconds: nil),
            .none
        )
        XCTAssertEqual(
            TabIndicator.resolve(view: .mail, warning: nil, unread: nil, countdownSeconds: nil),
            .none
        )
    }

    func testAnyCountAboveZeroShows() {
        XCTAssertEqual(UnreadCounts.tabLabel(1), "1")
        XCTAssertEqual(UnreadCounts.tabLabel(12), "12")
        XCTAssertEqual(UnreadCounts.tabLabel(999), "999")
    }

    // MARK: - The cap

    func testCountsCapAtNineNinetyNinePlusAndTheTruthMovesToTheTooltip() {
        // His *Everything*-scope inboxes run past 4000, and four digits plus a
        // separator eats the width the account name needs.
        XCTAssertEqual(UnreadCounts.tabLabel(1000), "999+")
        XCTAssertEqual(UnreadCounts.tabLabel(4231), "999+")
        XCTAssertEqual(UnreadCounts.tabTooltip(4231), "4,231 unread")
        XCTAssertEqual(UnreadCounts.tabTooltip(12), "12 unread")
    }

    // MARK: - Precedence

    /// The rule this whole type exists for. A signed-out account's unread count
    /// stopped being true the moment the session died; showing it beside the
    /// warning is the stale number the health monitor exists to end.
    func testAWarningBeatsACountOnAMailTab() {
        XCTAssertEqual(
            TabIndicator.resolve(
                view: .mail, warning: .signedOut, unread: 42, countdownSeconds: nil
            ),
            .warning(.signedOut)
        )
        XCTAssertEqual(
            TabIndicator.resolve(
                view: .mail, warning: .notLoading, unread: 4231, countdownSeconds: nil
            ),
            .warning(.notLoading)
        )
    }

    /// Same rule on the other kind of tab: a countdown computed from an agenda
    /// the tab can no longer refresh is exactly as stale as the count.
    func testAWarningBeatsACountdownOnACalendarTab() {
        XCTAssertEqual(
            TabIndicator.resolve(
                view: .calendar, warning: .notLoading, unread: nil, countdownSeconds: 300
            ),
            .warning(.notLoading)
        )
    }

    func testWithNoWarningEachTabShowsItsOwnKind() {
        XCTAssertEqual(
            TabIndicator.resolve(view: .mail, warning: nil, unread: 7, countdownSeconds: 300),
            .count("7")
        )
        XCTAssertEqual(
            TabIndicator.resolve(view: .calendar, warning: nil, unread: 7, countdownSeconds: 300),
            .countdown("(5m)")
        )
    }

    func testTheCountdownIsParenthesisedAndShort() {
        let cases: [(Int, TabIndicator)] = [
            (0, .countdown("(now)")),
            (59, .countdown("(now)")),
            (300, .countdown("(5m)")),
            (2700, .countdown("(45m)")),
            (5400, .countdown("(1h)")),
            (18000, .countdown("(5h)"))
        ]
        for (seconds, expected) in cases {
            XCTAssertEqual(
                TabIndicator.resolve(
                    view: .calendar, warning: nil, unread: nil, countdownSeconds: seconds
                ),
                expected,
                "at \(seconds)s"
            )
        }
    }

    /// Every honest silence renders the same: nothing. G6 off, nothing later
    /// today, signed out, not fetched yet and not understood all arrive here as
    /// `nil`, and none of them may leave a number behind.
    func testACalendarTabWithNothingToSaySaysNothing() {
        XCTAssertEqual(
            TabIndicator.resolve(
                view: .calendar, warning: nil, unread: nil, countdownSeconds: nil
            ),
            .none
        )
        // A day or more, and a start already behind us: both are wrong answers
        // rather than small ones, so `CalendarCountdown` refuses them and the
        // tab stays blank.
        XCTAssertEqual(
            TabIndicator.resolve(
                view: .calendar, warning: nil, unread: nil, countdownSeconds: -1
            ),
            .none
        )
        XCTAssertEqual(
            TabIndicator.resolve(
                view: .calendar, warning: nil, unread: nil, countdownSeconds: 90_000
            ),
            .none
        )
    }

    /// A Mail tab can never carry a countdown and a Calendar tab can never
    /// carry a count, so the two never compete for the slot and no extra colour
    /// is needed to tell them apart.
    func testTheTwoKindsNeverCrossTabs() {
        XCTAssertEqual(
            TabIndicator.resolve(view: .mail, warning: nil, unread: nil, countdownSeconds: 300),
            .none
        )
        XCTAssertEqual(
            TabIndicator.resolve(view: .calendar, warning: nil, unread: 12, countdownSeconds: nil),
            .none
        )
    }

    // MARK: - Width stability

    /// The countdown ticks every 30 seconds. With equal-width tabs, a slot that
    /// sized itself to its string would push all four tabs wider as `5m` became
    /// `45m` and back again a minute later.
    func testTheSlotIsTheSameWidthWhateverItHolds() {
        let widths = [
            TabIndicator.count("1"),
            TabIndicator.count("999+"),
            TabIndicator.countdown("(now)"),
            TabIndicator.countdown("(5m)"),
            TabIndicator.countdown("(45m)"),
            TabIndicator.countdown("(23h)"),
            TabIndicator.warning(.signedOut)
        ].map(\.accessoryWidth)

        XCTAssertEqual(Set(widths.map { $0 ?? -1 }).count, 1)
        XCTAssertEqual(widths.first ?? nil, TabIndicator.slotWidth)
    }

    /// And the fixed width has to actually fit the widest thing it can be asked
    /// to hold, or the cap and the countdown clip instead of the label.
    func testTheSlotFitsEveryStringItCanHold() {
        for text in TabIndicator.widestStrings {
            let measured = (text as NSString)
                .size(withAttributes: [.font: TabIndicator.font]).width
            XCTAssertLessThanOrEqual(
                measured + TabIndicator.horizontalPadding * 2,
                TabIndicator.slotWidth + 1,
                "\(text) does not fit the slot"
            )
        }
    }

    func testNothingCostsNoWidthAtAll() {
        XCTAssertNil(TabIndicator.none.accessoryWidth)
        XCTAssertFalse(TabIndicator.none.isPresent)
    }

    // MARK: - The relayout trigger

    /// Appearing and disappearing is the only thing the bar re-lays out for.
    func testOnlyAppearingAndDisappearingRelayoutsTheRow() {
        XCTAssertTrue(TabIndicator.needsRelayout(from: .none, to: .count("3")))
        XCTAssertTrue(TabIndicator.needsRelayout(from: .count("3"), to: .none))
        XCTAssertTrue(TabIndicator.needsRelayout(from: .countdown("(5m)"), to: .none))
        XCTAssertTrue(TabIndicator.needsRelayout(from: .none, to: .warning(.signedOut)))
    }

    func testATickingCountdownDoesNotRelayoutTheRow() {
        XCTAssertFalse(TabIndicator.needsRelayout(from: .countdown("(5m)"), to: .countdown("(45m)")))
        XCTAssertFalse(TabIndicator.needsRelayout(from: .countdown("(45m)"), to: .countdown("(1h)")))
        XCTAssertFalse(TabIndicator.needsRelayout(from: .count("9"), to: .count("999+")))
        // A count replaced by the warning that outranks it: same slot, same
        // width, so the row does not move while the news gets worse.
        XCTAssertFalse(TabIndicator.needsRelayout(from: .count("9"), to: .warning(.signedOut)))
    }

    // MARK: - What the words say

    func testTheTooltipCarriesTheExactFigureAndTheSpokenCountdown() {
        XCTAssertEqual(
            TabIndicator.tooltipSuffix(
                .count("999+"), unread: 4231, countdownDescription: nil
            ),
            "4,231 unread"
        )
        XCTAssertEqual(
            TabIndicator.tooltipSuffix(
                .countdown("(45m)"), unread: nil, countdownDescription: "Next event in 45 minutes"
            ),
            "Next event in 45 minutes"
        )
        // A warning replaces the tab's description outright rather than
        // extending it, so it contributes no suffix.
        XCTAssertNil(
            TabIndicator.tooltipSuffix(
                .warning(.signedOut), unread: 4231, countdownDescription: "Next event in 45 minutes"
            )
        )
        XCTAssertNil(TabIndicator.tooltipSuffix(.none, unread: nil, countdownDescription: nil))
    }

    // MARK: - The tab that draws it

    private func tabView(
        view: AccountView,
        state: TabIndicator.State,
        selected: Bool = false
    ) -> AccountTabView {
        AccountTabView(
            account: Account(name: "Personal", email: "person@example.com", color: .purple),
            view: view,
            isSelected: selected,
            state: state
        )
    }

    /// The geometric half of the same rule, through the view that actually
    /// reserves the room.
    func testATabIsTheSameWidthThroughoutACountdown() {
        let five = tabView(view: .calendar, state: .init(indicator: .countdown("(5m)")))
        let fortyFive = tabView(view: .calendar, state: .init(indicator: .countdown("(45m)")))
        XCTAssertEqual(five.naturalWidth, fortyFive.naturalWidth)

        // And ticking through the view's own update path changes nothing.
        let before = five.naturalWidth
        five.state = .init(indicator: .countdown("(1h)"))
        XCTAssertEqual(five.naturalWidth, before)
    }

    func testATabWithAnIndicatorIsWiderThanOneWithout() {
        let blank = tabView(view: .mail, state: .none)
        let counted = tabView(view: .mail, state: .init(indicator: .count("12")))
        XCTAssertEqual(
            counted.naturalWidth - blank.naturalWidth,
            TabMetrics.accessorySpacing + TabIndicator.slotWidth
        )
    }

    /// Losing the indicator has to give the width back, or a tab that read its
    /// inbox to empty would stay permanently wide.
    func testATabNarrowsAgainWhenItsIndicatorGoes() {
        let tab = tabView(view: .mail, state: .init(indicator: .count("12")))
        let wide = tab.naturalWidth
        var relayouts = 0
        tab.onNaturalWidthChanged = { relayouts += 1 }

        tab.state = .none
        XCTAssertLessThan(tab.naturalWidth, wide)
        XCTAssertEqual(relayouts, 1)

        // Ticking inside the slot must not ask the bar to re-measure anything.
        tab.state = .init(indicator: .count("3"))
        relayouts = 0
        tab.state = .init(indicator: .count("4"))
        XCTAssertEqual(relayouts, 0)
    }

    // MARK: - The row, through the bar that lays it out

    /// 1280 is the window's own default width. Narrower than about 900 and four
    /// tabs are already squeezed to the width the *bar* allows rather than the
    /// width their content asks for, so a natural width that grows would not
    /// move anything and the assertion would prove nothing.
    private func bar(width: CGFloat = 1280) -> (AccountTabBar, [Account]) {
        let accounts = [
            Account(name: "Personal", email: "person@example.com", color: .purple),
            Account(name: "Work", email: "work@example.com", color: .teal)
        ]
        let bar = AccountTabBar()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: AccountTabBar.height)
        bar.rebuild(accounts: accounts, selection: nil)
        bar.layoutSubtreeIfNeeded()
        return (bar, accounts)
    }

    private func widths(_ bar: AccountTabBar) -> [CGFloat] {
        bar.tabViewsForTesting.map(\.assignedWidth)
    }

    /// Adding an indicator re-lays out the whole row — and the row stays even,
    /// which is the rule the equal-width tabs already shipped.
    func testGainingAnIndicatorRelaysOutTheWholeRowEvenly() {
        let (bar, accounts) = bar()
        let before = widths(bar)
        XCTAssertEqual(Set(before).count, 1)

        // On the tab with the longest label, so the widest natural width — the
        // one the whole row is sized from — is the one that moves.
        bar.updateIndicators { tab in
            tab.accountId == accounts[0].id && tab.view == .calendar
                ? .init(indicator: .countdown("(45m)"))
                : .none
        }
        bar.layoutSubtreeIfNeeded()

        let after = widths(bar)
        XCTAssertEqual(Set(after).count, 1, "the row must stay even")
        XCTAssertEqual(
            after[0] - before[0],
            TabMetrics.accessorySpacing + TabIndicator.slotWidth
        )
    }

    /// And the ticking half: the same indicator with a different string leaves
    /// every tab exactly where it was.
    func testATickingCountdownLeavesTheRowAlone() {
        let (bar, accounts) = bar()
        let calendar = accounts[0].id
        bar.updateIndicators { tab in
            tab.accountId == calendar && tab.view == .calendar
                ? .init(indicator: .countdown("(5m)"))
                : .none
        }
        bar.layoutSubtreeIfNeeded()
        let settled = widths(bar)

        for label in ["(45m)", "(1h)", "(now)", "(23h)"] {
            bar.updateIndicators { tab in
                tab.accountId == calendar && tab.view == .calendar
                    ? .init(indicator: .countdown(label))
                    : .none
            }
            bar.layoutSubtreeIfNeeded()
            XCTAssertEqual(widths(bar), settled, "\(label) moved the row")
        }
    }

    /// A warning on a Calendar tab is now possible — a recycle that gave up on
    /// that tab — and it lands on the tab that is actually dead rather than on
    /// its working Mail sibling.
    func testADeadCalendarTabWarnsOnItself() {
        let account = UUID()
        let calendar = TabRef(accountId: account, view: .calendar)
        XCTAssertEqual(
            AccountTabBar.warning(tab: calendar, signedOut: [], stalledTabs: [calendar]),
            .notLoading
        )
        XCTAssertNil(
            AccountTabBar.warning(
                tab: TabRef(accountId: account, view: .mail), signedOut: [], stalledTabs: [calendar]
            )
        )
        // Signed-out stays Mail-only: its evidence really is the mail feed
        // probe, so there is nothing to say on the Calendar tab.
        XCTAssertNil(AccountTabBar.warning(tab: calendar, signedOut: [account]))
    }
}
