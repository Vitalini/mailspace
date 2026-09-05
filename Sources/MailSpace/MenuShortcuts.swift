import AppKit

/// One row of the cheat sheet: a menu item that carries a key equivalent.
struct MenuShortcut: Equatable {
    /// The menu item's title, verbatim.
    let title: String
    /// The key equivalent already rendered as macOS glyphs, e.g. `⇧⌘M`.
    let keys: String
}

/// The rows of one top-level menu, in menu order.
struct MenuShortcutGroup: Equatable {
    /// The title of the top-level menu these rows came from.
    let title: String
    let rows: [MenuShortcut]
}

/// The cheat sheet is a projection of the live menu bar, never a table kept
/// beside it — a second list of shortcuts is a second thing to forget to update
/// (KTD2).
///
/// Everything here is pure: it takes the `NSMenu` it is given, reads no
/// `NSApp`, and calls no `update()`. That is what lets `MenuShortcutsTests`
/// walk synthetic menus without an application.
enum MenuShortcuts {
    /// The one place the sheet departs from menu-bar order (KTD2). Menu order
    /// puts a dozen Cut/Copy/Paste rows ahead of ⇧⌘M and ⇧⌘K, which pushes the
    /// two shortcuts the sheet exists to teach — and the ⌘1…9 tab rows under
    /// them — off the first screen. A fixed two-name list, not a heuristic.
    static let promotedGroupTitles = [MainMenu.viewMenuTitle, MainMenu.accountsMenuTitle]

    // MARK: - Walking

    /// Every item of `menuBar` that carries a key equivalent, grouped under the
    /// title of the top-level menu it lives in, groups and rows in menu order.
    ///
    /// Enabled state is ignored (R5): Cut and Paste are listed whether or not
    /// the current first responder takes them. Separators, hidden items and
    /// items with no key equivalent are dropped, and a group left with nothing
    /// disappears with its header (R6).
    ///
    /// That empty-key-equivalent rule is also what keeps the Window menu clean:
    /// the per-window entries AppKit appends itself through `addWindowsItem`
    /// carry no key equivalent, so they never reach a row and no explicit
    /// exclusion is needed for them.
    static func groups(of menuBar: NSMenu) -> [MenuShortcutGroup] {
        menuBar.items.compactMap { root in
            // The menu bar has no bare items; if one appears it has no group to
            // head and nothing to contribute.
            guard let submenu = root.submenu else { return nil }
            let rows = shortcuts(in: submenu)
            guard !rows.isEmpty else { return nil }
            return MenuShortcutGroup(title: root.title, rows: rows)
        }
    }

    /// Groups in reading order: the app's own menus first, then everything else
    /// as it arrived (KTD2). A promoted name that has no group — Accounts with
    /// no accounts (R11) — is skipped, never inserted empty.
    static func orderedForDisplay(_ groups: [MenuShortcutGroup]) -> [MenuShortcutGroup] {
        // `flatMap`, not `first`: the tail filter drops *every* group with a
        // promoted title, so promoting only the first would lose a second
        // group named "View". Identical output when the titles are unique.
        let promoted = promotedGroupTitles.flatMap { title in
            groups.filter { $0.title == title }
        }
        return promoted + groups.filter { !promotedGroupTitles.contains($0.title) }
    }

    /// Descends every submenu level: a shortcut three menus deep still belongs
    /// to its top-level ancestor's group (R9). Alternates are listed like any
    /// other row (R7) — they are real shortcuts, and invisible until the
    /// modifier is held, which is exactly what a cheat sheet is for.
    private static func shortcuts(in menu: NSMenu) -> [MenuShortcut] {
        var rows: [MenuShortcut] = []
        for item in menu.items where !item.isSeparatorItem && !item.isHidden {
            if !item.keyEquivalent.isEmpty {
                rows.append(
                    MenuShortcut(
                        title: item.title,
                        keys: keyString(item.keyEquivalent, item.keyEquivalentModifierMask)
                    )
                )
            }
            if let submenu = item.submenu {
                rows.append(contentsOf: shortcuts(in: submenu))
            }
        }
        return rows
    }

    // MARK: - Rendering

    /// A key equivalent and its modifier mask as the string a Mac user reads on
    /// a menu: modifiers in the fixed order ⌃⌥⇧⌘ regardless of how the mask was
    /// written, then the key (R8).
    ///
    /// An uppercase letter carries ⇧ whether or not the mask says so — that is
    /// how AppKit matches it. Nothing in the app writes a key equivalent that
    /// way today, so the rule is defensive.
    static func keyString(_ keyEquivalent: String, _ mask: NSEvent.ModifierFlags) -> String {
        guard let scalar = keyEquivalent.unicodeScalars.first else { return "" }

        var shift = mask.contains(.shift)
        let key: String
        if let named = namedKeys[scalar] {
            key = named
        } else {
            let character = String(scalar)
            let upper = character.uppercased()
            if upper != character.lowercased(), character == upper {
                shift = true
            }
            key = upper
        }

        var glyphs = ""
        if mask.contains(.control) { glyphs += "⌃" }
        if mask.contains(.option) { glyphs += "⌥" }
        if shift { glyphs += "⇧" }
        if mask.contains(.command) { glyphs += "⌘" }
        // Everything else in the mask — .function, .numericPad, .capsLock,
        // .help — has no glyph on a menu and is dropped.
        return glyphs + key
    }

    /// Keys that arrive in `keyEquivalent` as one character with no printable
    /// form of their own. Named through `NSEvent.SpecialKey` rather than written
    /// as raw code points: AppKit owns these values, and the case name says
    /// which key each row is for.
    private static let namedKeys: [Unicode.Scalar: String] = {
        var keys: [Unicode.Scalar: String] = [
            NSEvent.SpecialKey.carriageReturn.unicodeScalar: "↩",
            NSEvent.SpecialKey.enter.unicodeScalar: "⌅",
            NSEvent.SpecialKey.tab.unicodeScalar: "⇥",
            NSEvent.SpecialKey.backTab.unicodeScalar: "⇤",
            NSEvent.SpecialKey.backspace.unicodeScalar: "⌫",
            NSEvent.SpecialKey.delete.unicodeScalar: "⌫",
            NSEvent.SpecialKey.deleteForward.unicodeScalar: "⌦",
            NSEvent.SpecialKey.upArrow.unicodeScalar: "↑",
            NSEvent.SpecialKey.downArrow.unicodeScalar: "↓",
            NSEvent.SpecialKey.leftArrow.unicodeScalar: "←",
            NSEvent.SpecialKey.rightArrow.unicodeScalar: "→",
            NSEvent.SpecialKey.pageUp.unicodeScalar: "⇞",
            NSEvent.SpecialKey.pageDown.unicodeScalar: "⇟",
            NSEvent.SpecialKey.home.unicodeScalar: "↖",
            NSEvent.SpecialKey.end.unicodeScalar: "↘",
            // Escape and Space are ordinary ASCII and have no `SpecialKey` case
            // — OpenStep's reserved range does not cover them.
            "\u{001B}": "⎋",
            "\u{0020}": "␣"
        ]
        // F1…F20 are contiguous from `.f1`.
        let firstFunctionKey = NSEvent.SpecialKey.f1.unicodeScalar.value
        for index in 0..<20 {
            guard let scalar = Unicode.Scalar(firstFunctionKey + UInt32(index)) else { continue }
            keys[scalar] = "F\(index + 1)"
        }
        return keys
    }()
}
