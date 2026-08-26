import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let accountStore = AccountStore()
    private(set) var sessions: [UUID: AccountSession] = [:]

    private var window: NSWindow?
    private var contentContainer: NSView?
    private var activeAccountId: UUID?
    private var loginProbe: LoginProbe?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()

        for account in accountStore.accounts {
            makeSession(for: account)
        }
        activeAccountId = accountStore.accounts.first?.id

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MailSpace"
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameAutosaveName("MailSpaceMainWindow")
        window.center()

        let container = NSView()
        window.contentView = container
        contentContainer = container

        window.makeKeyAndOrderFront(nil)
        self.window = window
        showActiveView()

        switch SelfTest.mode {
        case .state:
            SelfTest.schedule { [weak self] in
                "accounts=\(self?.accountStore.accounts.count ?? -1) sessions=\(self?.sessions.count ?? -1)"
            }
            return
        case .login:
            loginProbe = LoginProbe()
            loginProbe?.run()
            return
        case nil:
            break
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Accounts

    @discardableResult
    private func makeSession(for account: Account) -> AccountSession {
        let session = AccountSession(account: account)
        session.loadIfNeeded()
        sessions[account.id] = session
        return session
    }

    @objc func addAccount(_ sender: Any?) {
        guard let name = AccountNamePrompt.run(window: window) else { return }
        let account = accountStore.add(name: name)
        makeSession(for: account)
        activeAccountId = account.id
        showActiveView()
    }

    private func showActiveView() {
        guard let container = contentContainer else { return }
        container.subviews.forEach { $0.removeFromSuperview() }

        guard
            let id = activeAccountId,
            let account = accountStore.account(id: id),
            let session = sessions[id]
        else { return }

        let webView = session.webView(for: account.lastView)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        window?.title = "MailSpace — \(account.name)"
    }
}

// MARK: - Add-account prompt

enum AccountNamePrompt {
    /// Modal name prompt for a new account. Returns nil when cancelled.
    static func run(window: NSWindow?) -> String? {
        let alert = NSAlert()
        alert.messageText = "Add Account"
        alert.informativeText = "Name this account (for example \"Work\" or \"Personal\"). You will sign in to Google in the next step."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Work"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Main menu

enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(accountsMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    /// The Accounts menu is rebuilt by `MainWindowController` whenever the
    /// account list changes; this builds the static part.
    static let accountsMenuTitle = "Accounts"

    private static func accountsMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: accountsMenuTitle)
        menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "MailSpace")
        menu.addItem(withTitle: "About MailSpace", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide MailSpace", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MailSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = menu
        return item
    }

    private static func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.submenu = menu
        return item
    }

    /// Standard Edit menu — required so copy/paste/select-all reach the webviews.
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let pasteMatch = menu.addItem(withTitle: "Paste and Match Style", action: NSSelectorFromString("pasteAsPlainText:"), keyEquivalent: "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
