import Foundation

/// What a Mail tab draws for its own account's unread count (U10).
///
/// Pure, so the two rules that matter — never a literal `0`, and never a number
/// so long it eats the account name — are decided in one place and tested
/// without a window. The number itself is `UnreadPoller`'s; nothing here fetches
/// anything.
enum UnreadCounts {
    /// Above this the pill caps and the exact figure moves to the tooltip.
    ///
    /// A busy inbox runs past 4000, and four digits plus a separator eats the
    /// tab width the account name needs. Gmail's own surfaces cap too.
    ///
    /// Worth remembering what the cap cost once: it is what turned a count of
    /// ~3,480 from the wrong feed into an unreadable `999+`, so the three
    /// digits that would have identified it never reached the screen. The cap
    /// is right; the defence against a wrong number belongs upstream of it, in
    /// `UnreadCheck.answer`.
    static let cap = 999

    /// The pill text, or `nil` when the tab shows nothing at all.
    ///
    /// `nil` (never polled) and `0` (polled, nothing unread) render identically
    /// — as nothing — so no caller downstream needs to tell them apart. A
    /// literal `0` on a tab is noise at best and, next to a session that has
    /// quietly expired, a lie.
    static func tabLabel(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count > cap ? "\(cap)+" : "\(count)"
    }

    /// The exact figure, grouped — `"4,231 unread"`. This is where the truth
    /// lives once the pill caps, and it is `nil` wherever the pill is hidden.
    static func tabTooltip(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let grouped = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(grouped) unread"
    }
}
