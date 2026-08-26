import AppKit

/// How wide a tab in `AccountTabBar` is.
///
/// Every tab in the bar is the same width, and that width is the widest tab's
/// natural content width — so the longest account name fits without truncation
/// and the row reads as one control rather than a ragged set of pills. Tabs
/// only stop growing at `maximumWidth`, and only shrink below the widest when
/// the bar itself runs out of room, in which case they shrink *together*: no
/// tab is ever a different width from its siblings.
///
/// The arithmetic lives here, apart from AppKit layout, because it is the part
/// worth testing: `AccountTabBar` just applies the number this returns.
enum TabMetrics {
    /// Space between a tab's edge and its content, on both sides.
    ///
    /// 16pt, matching the title inset of macOS's own push buttons and tab
    /// controls. The 11/12pt this replaced read as cramped next to them.
    static let horizontalPadding: CGFloat = 16
    /// The service icon (envelope or calendar).
    static let iconSize: CGFloat = 14
    /// Between the icon and the label.
    static let iconLabelSpacing: CGFloat = 6
    /// Between the label and an optional trailing accessory.
    static let accessorySpacing: CGFloat = 6

    static let height: CGFloat = 28
    /// Between one tab and the next.
    static let spacing: CGFloat = 6

    /// The narrowest a tab is allowed to get. Below this the label has no room
    /// left to tell one account from another, so the bar scrolls instead of
    /// shrinking further.
    ///
    /// 104pt leaves 104 - 32 (padding) - 14 (icon) - 6 (gap) = 52pt of label:
    /// eight or nine characters plus the ellipsis.
    static let minimumWidth: CGFloat = 104
    /// The widest a tab is allowed to get, however long the account name is.
    /// One very long name must not push its siblings off the bar.
    static let maximumWidth: CGFloat = 260

    /// The selected tab's label is semibold, which is wider than the regular
    /// weight the other tabs use.
    static func labelFont(selected: Bool) -> NSFont {
        .systemFont(ofSize: 12.5, weight: selected ? .semibold : .regular)
    }

    /// Every tab is measured in the *selected* weight, whether it is selected
    /// or not, so that clicking a tab never changes how wide the tabs are.
    static var measurementFont: NSFont { labelFont(selected: true) }

    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// What one tab would like to be: padding, icon, gap, label, and — when the
    /// tab has one — a gap and a trailing accessory.
    ///
    /// `accessoryWidth` is the seam for the per-account unread pill (plan unit
    /// U10). Passing it here rather than letting the pill overlay the label is
    /// the whole point: a tab that gains a pill gets *wider*, and because the
    /// bar sizes every tab by the widest natural width, so do all its siblings.
    /// The label keeps the room it had. `nil` means no accessory at all, and
    /// costs neither the accessory nor the gap before it.
    static func naturalWidth(labelWidth: CGFloat, accessoryWidth: CGFloat? = nil) -> CGFloat {
        var width = horizontalPadding * 2 + iconSize + iconLabelSpacing + labelWidth
        if let accessoryWidth {
            width += accessorySpacing + accessoryWidth
        }
        // Whole points: a fractional measurement that rounds down clips the
        // last glyph of the widest label, which is the one label that must fit.
        return width.rounded(.up)
    }

    /// The single width every tab in the bar takes.
    ///
    /// - `naturalWidths`: what each tab would like to be, from `naturalWidth`.
    /// - `available`: the room the tabs have to share, excluding the space
    ///   between them. `0` means "not laid out yet, no constraint known".
    ///
    /// Widest wins, clamped to `minimumWidth...maximumWidth`. If that many tabs
    /// at that width do not fit, they all shrink equally until they do, and
    /// stop at `minimumWidth` — past that the bar scrolls horizontally, which
    /// it is already built to do, rather than grinding the labels into nothing.
    static func uniformWidth(naturalWidths: [CGFloat], available: CGFloat) -> CGFloat {
        guard let widest = naturalWidths.max() else { return 0 }

        let target = min(max(widest, minimumWidth), maximumWidth)
        guard available > 0 else { return target }

        let count = CGFloat(naturalWidths.count)
        let fitted = ((available - spacing * (count - 1)) / count).rounded(.down)
        return max(minimumWidth, min(target, fitted))
    }
}
