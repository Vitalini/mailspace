import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, AccountHosting, SessionLocating {
    let accountStore = AccountStore()

    private let navigationPolicy = NavigationPolicy()
    private let loginAutofill = LoginAutofill()
    private var sessions: [UUID: AccountSession] = [:]
    private var windowController: MainWindowController?
    private var loginProbe: LoginProbe?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        loginAutofill.locator = self

        if SelfTest.mode == .login {
            loginProbe = LoginProbe()
            loginProbe?.run()
            return
        }

        for account in accountStore.accounts {
            makeSession(for: account)
        }

        let controller = MainWindowController(host: self)
        windowController = controller
        controller.restoreSelection()
        controller.showWindow()

        if SelfTest.mode == .state {
            SelfTest.schedule { [weak self] in
                (self?.windowController?.stateDescription ?? "unavailable")
                    + " sessions=\(self?.sessions.count ?? -1)"
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow() }
        return true
    }

    // MARK: - AccountHosting

    func session(for accountId: UUID) -> AccountSession? {
        sessions[accountId]
    }

    func requestAddAccount() {
        addAccount(nil)
    }

    func requestEditAccount(id: UUID) {
        guard let account = accountStore.account(id: id), let edit = AccountEditor.run(editing: account) else { return }

        let previousEmail = account.email
        guard let updated = accountStore.update(
            id: id,
            name: edit.name,
            email: edit.email,
            mailEnabled: edit.mailEnabled,
            calendarEnabled: edit.calendarEnabled
        ) else { return }

        // A renamed address leaves its Keychain item behind; move it with the
        // account rather than orphaning it.
        if previousEmail != updated.email, !previousEmail.isEmpty {
            if edit.password == nil, let carried = KeychainStore.password(for: previousEmail) {
                KeychainStore.setPassword(carried, for: updated.email)
            }
            KeychainStore.deletePassword(for: previousEmail)
        }
        applyPasswordEdit(edit, for: updated)

        sessions[id]?.syncEnabledViews(with: updated)
        sessions[id]?.loadIfNeeded()
        windowController?.refresh()
    }

    func requestRemoveAccount(id: UUID) {
        guard let account = accountStore.account(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(account.name)”?"
        alert.informativeText = "MailSpace will sign this account out and delete its stored Google session from this Mac. Your mail itself is not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Account")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Ordering matters: WebKit refuses to delete a data store that is still
        // in use, so tear the webviews down before removing the store.
        let session = sessions.removeValue(forKey: id)
        session?.detach()
        accountStore.remove(id: id)
        KeychainStore.deletePassword(for: account.email)
        windowController?.refresh()
        WebViewFactory.destroyDataStore(for: id)
    }

    // MARK: - SessionLocating

    func session(hosting webView: WKWebView) -> AccountSession? {
        sessions.values.first { $0.hosts(webView) }
    }

    func account(for accountId: UUID) -> Account? {
        accountStore.account(id: accountId)
    }

    // MARK: - Menu actions

    @objc func addAccount(_ sender: Any?) {
        guard let edit = AccountEditor.run() else { return }
        let account = accountStore.add(
            name: edit.name,
            email: edit.email,
            mailEnabled: edit.mailEnabled,
            calendarEnabled: edit.calendarEnabled
        )
        applyPasswordEdit(edit, for: account)
        makeSession(for: account)
        if let view = account.effectiveView {
            windowController?.select(accountId: account.id, view: view)
        }
    }

    @objc func showMailView(_ sender: Any?) {
        windowController?.selectView(.mail)
    }

    @objc func showCalendarView(_ sender: Any?) {
        windowController?.selectView(.calendar)
    }

    // MARK: - Sessions

    @discardableResult
    private func makeSession(for account: Account) -> AccountSession {
        let session = AccountSession(
            account: account,
            userScripts: [LoginAutofill.userScript],
            replyHandlers: [LoginAutofill.handlerName: loginAutofill]
        )
        session.setDelegates(navigationPolicy)
        session.loadIfNeeded()
        sessions[account.id] = session
        return session
    }

    /// Writes the dialog's password decision through to the Keychain. The
    /// password never reaches `accounts.json` or any log.
    private func applyPasswordEdit(_ edit: AccountEditor.Result, for account: Account) {
        guard !account.email.isEmpty else { return }
        if edit.clearPassword {
            KeychainStore.deletePassword(for: account.email)
        }
        if let password = edit.password {
            KeychainStore.setPassword(password, for: account.email)
        }
    }
}

// MARK: - Main menu

enum MainMenu {
    static let accountsMenuTitle = "Accounts"
    static let viewMenuTitle = "View"

    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(accountsMenuItem())
        mainMenu.addItem(windowMenuItem())
        return mainMenu
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        // The top-level item needs its own title too — `item(withTitle:)`
        // looks it up there, not on the submenu.
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func appMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "MailSpace")
        menu.addItem(withTitle: "About MailSpace", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide MailSpace", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit MailSpace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return submenuItem(menu)
    }

    private static func fileMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "File")
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return submenuItem(menu)
    }

    /// Standard Edit menu — required so copy/paste/select-all reach the webviews.
    private static func editMenuItem() -> NSMenuItem {
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
        return submenuItem(menu)
    }

    /// R15: ⇧⌘M / ⇧⌘K are free in both Gmail and Google Calendar, whose own
    /// shortcuts are single letters and plain ⌘-letter combinations.
    private static func viewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: viewMenuTitle)
        let mail = menu.addItem(withTitle: "Mail", action: #selector(AppDelegate.showMailView(_:)), keyEquivalent: "m")
        mail.keyEquivalentModifierMask = [.command, .shift]
        let calendar = menu.addItem(withTitle: "Calendar", action: #selector(AppDelegate.showCalendarView(_:)), keyEquivalent: "k")
        calendar.keyEquivalentModifierMask = [.command, .shift]
        return submenuItem(menu)
    }

    /// Populated for real by `MainWindowController.refresh()`; this is the
    /// placeholder shown before the window controller exists.
    private static func accountsMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: accountsMenuTitle)
        menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "")
        return submenuItem(menu)
    }

    private static func windowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let item = submenuItem(menu)
        NSApp.windowsMenu = menu
        return item
    }
}
