import AppKit

/// What a tab's one trailing accessory slot is showing (U10, U11).
///
/// There is exactly one slot per tab and three things that want it: the health
/// warning, the account's unread count, and the Calendar countdown. This type is
/// the whole of that decision, and it is pure so the precedence rule is a test
/// rather than a comment.
enum TabIndicator: Equatable {
    /// Nothing at all — the tab is icon and label, exactly as wide as it was
    /// before any of this existed.
    case none
    /// The orange pill. This account's session is gone, or this tab will not
    /// load.
    case warning(TabWarning)
    /// The account's own unread count, already capped — `"12"`, `"999+"`.
    case count(String)
    /// Time until the account's next event later today — `"(5m)"`, `"(1h)"`.
    case countdown(String)

    /// Whether the slot is drawn at all. The only thing that changes a tab's
    /// width, and therefore the only thing the bar has to re-lay-out for.
    var isPresent: Bool { self != .none }

    // MARK: - Precedence

    /// What this tab shows, given everything that wants the slot.
    ///
    /// **The warning wins, always.** An account that is signed out has an unread
    /// count that stopped being true the moment the session died, and a Calendar
    /// tab that will not load has a countdown computed from an agenda it can no
    /// longer refresh. Showing either one beside a broken session is precisely
    /// the stale-number lie the health monitor exists to end, so the slot goes
    /// to the thing that is still true and still actionable: clicking the tab
    /// fixes it.
    ///
    /// Below the warning the two are never in competition — a Mail tab has no
    /// countdown and a Calendar tab has no unread count — so the rest is a
    /// straight read of whichever one belongs to this kind of tab.
    static func resolve(
        view: AccountView,
        warning: TabWarning?,
        unread: Int?,
        countdownSeconds: Int?
    ) -> TabIndicator {
        if let warning { return .warning(warning) }
        switch view {
        case .mail:
            return UnreadCounts.tabLabel(unread).map(TabIndicator.count) ?? .none
        case .calendar:
            // Parenthesised, the way the owner described it in words. `nil`
            // covers every honest silence at once: G6 off, nothing later today,
            // signed out, not fetched yet, not understood.
            guard
                let seconds = countdownSeconds,
                let label = CalendarCountdown.label(secondsUntilStart: seconds, style: .parenthesised)
            else { return .none }
            return .countdown(label)
        }
    }

    /// Whether moving from one indicator to another changes the tab's geometry.
    ///
    /// Only appearing and disappearing does. A countdown ticking from `(5m)` to
    /// `(45m)`, or a count going from `9` to `10`, must not resize anything —
    /// with equal-width tabs that would breathe the *entire row* once a minute.
    /// The slot is a fixed width for exactly this reason, so the strings can
    /// change inside it for free.
    static func needsRelayout(from old: TabIndicator, to new: TabIndicator) -> Bool {
        old.isPresent != new.isPresent
    }

    // MARK: - The slot

    /// The pill's own type. Monospaced digits so the number does not jitter as
    /// it changes between polls.
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    /// Room inside the capsule, each side.
    static let horizontalPadding: CGFloat = 6
    /// The capsule never goes narrower than this, so a single digit still reads
    /// as a pill rather than a dot.
    static let minimumWidth: CGFloat = 20

    /// Every string the slot can ever be asked to hold.
    ///
    /// Not a sample — the reachable set really is this small. Counts cap at
    /// `999+`; countdowns are `now`, one or two minute digits, one or two hour
    /// digits, and nothing else (`CalendarCountdown.format`).
    static let widestStrings = ["\(UnreadCounts.cap)+", "(now)", "(59m)", "(23h)"]

    /// One width for every indicator, everywhere in the bar.
    ///
    /// Sized for the widest string any of them can hold, so the slot a tab
    /// reserves does not depend on what it happens to be showing. That buys two
    /// things at the cost of a few points of white space: a countdown can tick
    /// and a count can climb without moving anything, and a warning can replace
    /// either one without the row resizing around it.
    static let slotWidth: CGFloat = {
        let widest = widestStrings
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return max(
            SignedOutPill.size.width,
            max(minimumWidth, (widest + horizontalPadding * 2).rounded(.up))
        )
    }()

    /// The width this indicator contributes to its tab's natural width: the
    /// fixed slot, or nothing at all when there is no indicator.
    var accessoryWidth: CGFloat? { isPresent ? Self.slotWidth : nil }

    // MARK: - Words

    /// Everything one tab needs to draw its slot: what to show, and the words
    /// that go with it. Assembled once per pass so `rebuild` and
    /// `updateIndicators` cannot disagree about either half.
    struct State: Equatable {
        var indicator: TabIndicator = .none
        /// Appended to the tab's own tooltip and `accessibilityLabel`. `nil`
        /// where the indicator has nothing to add.
        var detail: String?

        static let none = State()
    }

    /// What the tooltip says about this indicator, appended to the tab's own
    /// description. `nil` where the indicator carries no extra information —
    /// a warning replaces the tooltip outright rather than extending it.
    static func tooltipSuffix(
        _ indicator: TabIndicator,
        unread: Int?,
        countdownDescription: String?
    ) -> String? {
        switch indicator {
        case .none, .warning:
            return nil
        case .count:
            // The exact figure, so a capped `999+` is one hover from the truth.
            return UnreadCounts.tabTooltip(unread)
        case .countdown:
            // Generated from the integer upstream; it names no event (S22).
            return countdownDescription
        }
    }
}
