import AppKit

/// The panel's body: a scrolling list of headed shortcut rows above a footer
/// that never scrolls away (KTD9, KTD11).
///
/// It owns no window and reads no menu — it is handed groups and renders them —
/// so `ShortcutsPanelContentTests` can build and populate it without an
/// application and without anything reaching a display.
final class ShortcutsContentView: NSView {
    /// R20. The panel documents MailSpace's shortcuts; Gmail's and Calendar's
    /// belong to the pages, and this is where the reader is sent for them.
    static let footerText = "Gmail and Calendar have their own shortcuts. Press ? inside the page to see them."

    /// The scroll view's document view: one header label per group, one
    /// horizontal row per shortcut, in the order they were given. Internal so
    /// the content tests can read what was built.
    let list = NSStackView()

    private let scroll = NSScrollView()
    private let footer = ShortcutsContentView.footnote(footerText)

    /// The width of `⌥⇧⌘V` — Paste and Match Style, the widest key string the
    /// app produces — plus a little slack. A floor, not a fixed width: a wider
    /// shortcut takes the space from the title column rather than being
    /// truncated, because half a shortcut is worse than a short title.
    private static let keyColumnWidth: CGFloat = 76
    private static let inset: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// R16. Called on every open, so the list is whatever the menus say now.
    /// The previous rows go first — repeated opens must not stack subviews.
    func populate(with groups: [MenuShortcutGroup]) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for group in groups {
            list.addArrangedSubview(Self.header(group.title))
            for shortcut in group.rows {
                let row = self.row(shortcut)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(
                    equalTo: list.widthAnchor,
                    constant: -2 * Self.inset
                ).isActive = true
            }
        }
    }

    // MARK: - Construction

    private func build() {
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 16, left: Self.inset, bottom: 16, right: Self.inset)
        list.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = list
        scroll.hasVerticalScroller = true
        // R19 is vertical only: the list is pinned to the clip view's width, so
        // there is no horizontal scrolling to do.
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.lineBreakMode = .byWordWrapping
        footer.maximumNumberOfLines = 2

        addSubview(scroll)
        addSubview(footer)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            list.topAnchor.constraint(equalTo: clip.topAnchor),
            list.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            // Not the bottom: the list grows past the clip view, which is what
            // gives it something to scroll.
            list.widthAnchor.constraint(equalTo: clip.widthAnchor)
        ])
    }

    /// Title leading and free to grow, key string trailing and right-aligned in
    /// its own column, so the glyphs line up down the sheet.
    private func row(_ shortcut: MenuShortcut) -> NSStackView {
        let title = NSTextField(labelWithString: shortcut.title)
        title.lineBreakMode = .byTruncatingTail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let keys = NSTextField(labelWithString: shortcut.keys)
        keys.alignment = .right
        keys.lineBreakMode = .byClipping
        keys.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        keys.setContentCompressionResistancePriority(.required, for: .horizontal)
        keys.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.keyColumnWidth).isActive = true

        let row = NSStackView(views: [title, keys]).horizontal()
        row.distribution = .fill
        return row
    }

    // MARK: - Labels
    //
    // The same fonts and colours `SettingsGeneralPane` uses, so the two windows
    // read as one surface (KTD8). Its helpers are private to that pane and a
    // shared UI-helpers file does not exist; three four-line functions are not
    // reason enough to invent one and edit a settled pane.

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private static func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        return label
    }
}

/// R18. Esc closes the panel. Nothing in the view chain interprets key events —
/// the list is labels — so the window takes `cancelOperation(_:)` itself, which
/// is where AppKit's responder chain ends up. The Update window's precedent, a
/// button with `keyEquivalent = "\u{1b}"`, does not transfer: the panel has no
/// dismiss button, and a hidden one never fires its key equivalent.
final class ShortcutsPanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// ⌘/ — the keyboard cheat sheet.
///
/// One window for the process lifetime, built once and repopulated on every
/// open from the live menu bar (KTD6). Nothing here caches the catalogue: the
/// Accounts menu is rebuilt eagerly by `MainWindowController.refresh()`, so
/// walking the bar as it stands is already current, and no `update()` pass is
/// run — it would fire `validateMenuItem` and its Launch Services query for an
/// enabled state the panel ignores anyway (R5).
final class ShortcutsWindowController {
    /// Distinct from the Settings window's, so the two remember their own
    /// places (R22).
    static let frameAutosaveName = "MailSpaceShortcutsWindow"

    private var window: NSWindow?
    private var content: ShortcutsContentView?

    /// R15. Opening the panel while it is open re-fronts and regenerates it; it
    /// is never a toggle.
    func show() {
        buildIfNeeded()
        guard let window, let content else { return }
        // The one place the live menu bar is read.
        let groups = MenuShortcuts.groups(of: NSApp.mainMenu ?? NSMenu())
        content.populate(with: MenuShortcuts.orderedForDisplay(groups))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Builds the content view and fills it, with no window anywhere. The
    /// window-free seam the content tests use.
    static func contentView(for groups: [MenuShortcutGroup]) -> ShortcutsContentView {
        let view = ShortcutsContentView(frame: NSRect(x: 0, y: 0, width: 460, height: 560))
        view.populate(with: groups)
        return view
    }

    /// Construction only, once per process. Population lives in `show()`:
    /// `SettingsWindowController.buildIfNeeded()`'s shape would populate the
    /// list exactly once and then never again.
    private func buildIfNeeded() {
        guard window == nil else { return }

        let window = ShortcutsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = MainMenu.shortcutsItemTitle
        // R17. Pinned to Aqua like Settings and the main window.
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        // R21. ⌘/ from a full-screen main window puts the panel on that Space
        // instead of switching the user away from it.
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)

        // `setFrameUsingName` restores a saved frame and reports whether there
        // was one, so only a genuinely first run centres; the autosave name is
        // attached afterwards, where it cannot overwrite the frame just
        // restored. `MainWindowController.showWindow()`'s recipe, not
        // `SettingsWindowController`'s, which has these two the other way round
        // and re-centres every launch. Never in `show()`: that would drag an
        // open panel back to its saved frame on every reopen.
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        let content = ShortcutsContentView(frame: window.contentLayoutRect)
        window.contentView = content

        self.window = window
        self.content = content
    }
}
