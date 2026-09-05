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
/// (KTD2, `docs/next-steps.md` §4).
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
        let promoted = promotedGroupTitles.compactMap { title in
            groups.first { $0.title == title }
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
    /// form of their own.
    private static let namedKeys: [Unicode.Scalar: String] = {
        var keys: [Unicode.Scalar: String] = [
            "\u{000D}": "↩",   // Return
            "\u{0003}": "⌅",   // Enter, keypad
            "\u{0009}": "⇥",   // Tab
            "\u{0019}": "⇤",   // Backtab
            "\u{0008}": "⌫",   // Backspace
            "\u{007F}": "⌫",   // Delete
            "\u{F728}": "⌦",   // Forward delete
            "\u{001B}": "⎋",   // Escape
            "\u{0020}": "␣",   // Space
            "\u{F700}": "↑",
            "\u{F701}": "↓",
            "\u{F702}": "←",
            "\u{F703}": "→",
            "\u{F72C}": "⇞",   // Page up
            "\u{F72D}": "⇟",   // Page down
            "\u{F729}": "↖",   // Home
            "\u{F72B}": "↘"    // End
        ]
        // F1…F20 are contiguous from NSF1FunctionKey.
        for index in 0..<20 {
            guard let scalar = Unicode.Scalar(0xF704 + index) else { continue }
            keys[scalar] = "F\(index + 1)"
        }
        return keys
    }()
}
