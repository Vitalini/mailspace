import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, AccountHosting, SessionLocating, NotificationRouting {
    let accountStore = AccountStore()

    private let navigationPolicy = NavigationPolicy()
    private let loginAutofill = LoginAutofill()
    private let notificationBridge = NotificationBridge()
    private let unreadPoller = UnreadPoller()
    private var sessions: [UUID: AccountSession] = [:]
    private var windowController: MainWindowController?
    private let updateController = UpdateController()
    private lazy var settingsWindowController = SettingsWindowController(updates: updateController)
    private var loginProbe: LoginProbe?
    private var shimProbe: ShimProbe?
    private var autofillProbe: AutofillProbe?
    private var storeProbe: StoreRemovalProbe?
    /// A mailto: URL that arrived before the window was ready (cold launch).
    private var pendingMailto: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A self-test never runs as the app the user relies on. Its probes talk
        // to UNUserNotificationCenter, and an unattended run has nobody to
        // answer a permission prompt — macOS treats that silence as a denial.
        // `make smoke` assembles the same binary under the throwaway identity;
        // anything else is refused here, before a single probe starts.
        if SelfTest.isEnabled, !SelfTest.isSelfTestBundle {
            SelfTest.refuse(
                "\(SelfTest.mode?.rawValue ?? "unknown") result=REFUSED "
                + "reason=self-test-must-run-under-the-throwaway-bundle "
                + "bundle=\(Bundle.main.bundleIdentifier ?? "none") expected=\(SelfTest.bundleIdentifier) "
                + "hint=run-make-smoke-which-builds-build/MailSpace-SelfTest.app"
            )
        }

        // Before anything reads a preference, so every consumer sees a
        // populated domain rather than a false-shaped zero value.
        AppSettings.registerDefaults()

        NSApp.mainMenu = MainMenu.build()
        loginAutofill.locator = self
        navigationPolicy.mailtoHandler = { [weak self] url in self?.openMailto(url) }
        navigationPolicy.onSignInCompleted = { [weak self] accountId in self?.signInCompleted(accountId) }
        notificationBridge.locator = self
        notificationBridge.router = self
        notificationBridge.onMailNotification = { [weak self] accountId in
            self?.unreadPoller.refresh(accountId: accountId)
        }
        unreadPoller.mailWebViews = { [weak self] in
            guard let self else { return [] }
            return self.accountStore.accounts.compactMap { account in
                guard account.mailEnabled, let webView = self.sessions[account.id]?.webView(for: .mail) else { return nil }
                return (accountId: account.id, webView: webView)
            }
        }

        if SelfTest.mode == .login {
            loginProbe = LoginProbe()
            loginProbe?.run()
            return
        }
        if SelfTest.mode == .shim {
            shimProbe = ShimProbe()
            shimProbe?.run()
            return
        }
        if SelfTest.mode == .autofill {
            autofillProbe = AutofillProbe()
            autofillProbe?.run()
            return
        }
        if SelfTest.mode == .store {
            storeProbe = StoreRemovalProbe()
            storeProbe?.run()
            return
        }

        for account in accountStore.accounts {
            makeSession(for: account)
        }

        let controller = MainWindowController(host: self)
        windowController = controller
        controller.restoreSelection()
        controller.showWindow()

        notificationBridge.start()
        unreadPoller.start()
        updateController.start()
        sweepOrphanedDataStores()
        if let pending = pendingMailto {
            pendingMailto = nil
            openMailto(pending)
        }

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
            calendarEnabled: edit.calendarEnabled,
            color: edit.color
        ) else { return }

        // A renamed address leaves its Keychain item behind; move it with the
        // account rather than orphaning it.
        if previousEmail != updated.email, !previousEmail.isEmpty {
            if edit.password == nil, let carried = KeychainStore.shared.password(for: previousEmail) {
                KeychainStore.shared.setPassword(carried, for: updated.email)
            }
            KeychainStore.shared.deletePassword(for: previousEmail)
        }
        applyPasswordEdit(edit, for: updated)

        sessions[id]?.syncEnabledViews(with: updated)
        sessions[id]?.loadIfNeeded()
        if !updated.mailEnabled { unreadPoller.forget(accountId: id) }
        windowController?.refresh()
        unreadPoller.refresh(accountId: id)
    }

    /// The user has just brought this tab up. A webview the crash throttle
    /// stopped reloading gets another go now that someone is looking at it —
    /// the throttle exists to stop a reload loop, not to retire the tab for the
    /// rest of the session.
    func tabBecameVisible(accountId: UUID, view: AccountView) {
        guard let webView = sessions[accountId]?.webView(for: view) else { return }
        // The view's own entry point comes along because a webview that crashed
        // before committing anything has no URL to reload.
        navigationPolicy.recoverIfStalled(webView, baseURL: view.url)
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

        // Ordering matters twice over. `forget` goes first so a poll still in
        // flight cannot write a stale count back after the account is gone. And
        // WebKit refuses to delete a data store anything still references, so
        // every webview on it — the account's popup windows included — and
        // every download running on it has to be gone before `destroyDataStore`.
        unreadPoller.forget(accountId: id)
        navigationPolicy.closePopups(for: id)
        navigationPolicy.cancelDownloads(for: id)
        // Scoped on purpose: detaching is not enough, the session object itself
        // has to die, because its configuration holds the data store for its
        // whole lifetime. Measured — with the session still in scope every
        // removal attempt failed with "Data store is in use", however long it
        // waited, and the dialog above had already promised the opposite.
        if let session = sessions.removeValue(forKey: id) {
            session.detach()
        }
        accountStore.remove(id: id)
        KeychainStore.shared.deletePassword(for: account.email)
        windowController?.refresh()

        let name = account.name
        WebViewFactory.destroyDataStore(for: id) { error in
            guard let error else { return }
            Self.reportDataStoreRemovalFailure(name: name, error: error)
        }
    }

    /// Stored sessions no account claims any more.
    ///
    /// Account removal can fail — a download still running, a popup that would
    /// not go — and nothing ever came back for what it left behind. The whole
    /// Google session for a deleted account then sits on disk indefinitely,
    /// which is the one thing the removal dialog promises will not happen.
    ///
    /// Pure so the "delete exactly what no account claims" rule is a test
    /// rather than a filesystem experiment.
    static func orphanedStores(onDisk: [UUID], claimedBy accounts: [Account]) -> [UUID] {
        let claimed = Set(accounts.map(\.id))
        return onDisk.filter { !claimed.contains($0) }
    }

    /// Deletes those at launch.
    ///
    /// Asking WebKit which stores exist, rather than deriving the list from
    /// `~/Library/WebKit`, keeps "a store" defined by the framework that owns
    /// the layout — and means the sweep only ever hands `destroyDataStore` an
    /// identifier WebKit itself just reported.
    ///
    /// Both calls go through `WebViewFactory`, which is where the reason lives:
    /// on this path there is usually no webview yet, and WebKit's class-level
    /// data-store APIs crash in a process that has not instantiated one.
    ///
    /// It is skipped whenever `accounts.json` did not read cleanly. A file that
    /// failed to parse leaves an empty account list, and sweeping against that
    /// would delete every session on the Mac — the exact opposite of a repair.
    private func sweepOrphanedDataStores() {
        guard accountStore.didLoadCleanly else {
            Log.error("skipping the orphaned-session sweep: accounts.json did not read cleanly")
            return
        }

        let accounts = accountStore.accounts
        WebViewFactory.dataStoreIdentifiers { identifiers in
            for orphan in Self.orphanedStores(onDisk: identifiers, claimedBy: accounts) {
                WebViewFactory.destroyDataStore(for: orphan) { error in
                    guard let error else { return }
                    Log.error("orphaned session \(orphan) could not be removed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The removal dialog promises the Google session is deleted from this Mac.
    /// When it is not, the user has to hear about it — a stderr line is not an
    /// answer to a promise made in a modal.
    private static func reportDataStoreRemovalFailure(name: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = "“\(name)” was removed, but its Google session is still on this Mac"
        alert.informativeText =
            "macOS would not delete the stored session: \(error.localizedDescription). "
            + "Quitting MailSpace releases it; nothing in the app can reach that account any more."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
            calendarEnabled: edit.calendarEnabled,
            color: edit.color
        )
        applyPasswordEdit(edit, for: account)
        makeSession(for: account)
        if let view = account.effectiveView {
            windowController?.select(accountId: account.id, view: view)
        }
        unreadPoller.refresh(accountId: account.id)
    }

    /// ⌘, — the Settings window.
    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.show()
    }

    /// A check he asked for: it always answers, including when the answer is
    /// "you are up to date" or "GitHub could not be reached".
    @objc func checkForUpdates(_ sender: Any?) {
        updateController.checkForUpdates(sender)
    }

    @objc func showMailView(_ sender: Any?) {
        windowController?.selectView(.mail)
    }

    @objc func showCalendarView(_ sender: Any?) {
        windowController?.selectView(.calendar)
    }

    /// ⌘R. Acts on the window the user is actually looking at — a Docs or print
    /// popup could not be reloaded at all before, and pressing ⌘R over one
    /// reloaded the main window instead. Also the way out of a tab the crash
    /// throttle has given up on, which is why it clears the crash record rather
    /// than only reloading.
    @objc func reloadCurrentTab(_ sender: Any?) {
        guard let target = NavigationPolicy.reloadTarget(
            keyWindowWebView: navigationPolicy.popupWebView(in: NSApp.keyWindow),
            selectedTab: selectedTab()
        ) else { return }

        navigationPolicy.reload(target.webView, baseURL: target.baseURL)
    }

    /// The selected tab's web view together with the entry point to fall back
    /// to when it never loaded a page.
    private func selectedTab() -> (webView: WKWebView, baseURL: URL)? {
        guard
            let selection = windowController?.selection,
            let webView = sessions[selection.accountId]?.webView(for: selection.view)
        else { return nil }
        return (webView, selection.view.url)
    }

    // MARK: - NotificationRouting

    func focusAccount(_ accountId: UUID, view: AccountView) {
        windowController?.focus(accountId: accountId, view: view)
    }

    // MARK: - mailto:

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let mailto = urls.first(where: { $0.scheme?.lowercased() == "mailto" }) else { return }
        // On a cold launch the URL arrives before the window exists; hold it
        // until the mail webview is there to receive it.
        if windowController == nil {
            pendingMailto = mailto
            return
        }
        openMailto(mailto)
    }

    @objc func makeDefaultMailApp(_ sender: Any?) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { error in
            guard let error else { return }
            Log.error("could not become the default mail app: \(error.localizedDescription)")
        }
    }

    /// Which account composes a `mailto:` — the selected one while it has Mail
    /// switched on, otherwise the first account that does.
    ///
    /// `selected ?? firstMailEnabled` does not work: `??` short-circuits on any
    /// non-nil selection, and `reconciledSelection` installs one whenever there
    /// is an account at all. So the fallback was dead code, and a `mailto:`
    /// arriving while a Calendar-only account was selected was dropped on the
    /// floor — the app just came to the front.
    static func mailtoAccount(selected: UUID?, accounts: [Account]) -> UUID? {
        if
            let selected,
            let account = accounts.first(where: { $0.id == selected }),
            account.mailEnabled
        {
            return selected
        }
        return accounts.first(where: { $0.mailEnabled })?.id
    }

    private func openMailto(_ url: URL) {
        guard let controller = windowController else { return }

        // With no Mail-enabled account there is nowhere to compose — show the
        // first-run prompt instead of failing silently.
        guard
            let accountId = Self.mailtoAccount(
                selected: controller.selection?.accountId,
                accounts: accountStore.accounts
            ),
            let webView = sessions[accountId]?.webView(for: .mail),
            let compose = Self.composeURL(for: url)
        else {
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow()
            return
        }

        webView.load(URLRequest(url: compose))
        controller.focus(accountId: accountId, view: .mail)
    }

    /// Hands the whole mailto payload to Gmail, which parses the recipients,
    /// subject and body itself.
    static func composeURL(for mailto: URL) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = mailto.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://mail.google.com/mail/u/0/?extsrc=mailto&url=\(encoded)")
    }

    // MARK: - Sessions

    /// One account has just signed in. Its tabs share the data store, so they
    /// only need re-navigating — the ones still sitting on a signed-out page.
    private func signInCompleted(_ accountId: UUID) {
        guard let session = sessions[accountId] else { return }
        session.reloadSignedOutViews()
        // The badge poll fetches from inside the mail webview, so it has to
        // wait for the signed-in page to be the one it runs in; a poll fired
        // now would still be in the signed-out origin and come back empty.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.unreadPoller.refresh(accountId: accountId)
        }
    }

    @discardableResult
    private func makeSession(for account: Account) -> AccountSession {
        let session = AccountSession(
            account: account,
            userScripts: [NotificationShim.userScript, LoginAutofill.userScript],
            messageHandlers: [NotificationShim.handlerName: notificationBridge],
            replyHandlers: [loginAutofill.registration]
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
            KeychainStore.shared.deletePassword(for: account.email)
        }
        if let password = edit.password {
            KeychainStore.shared.setPassword(password, for: account.email)
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
        menu.addItem(withTitle: "Check for Updates…", action: #selector(AppDelegate.checkForUpdates(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // ⌘, is the system-wide Settings shortcut; `Accounts ▸ Account
        // Settings…` gives it up for this (settings plan, KTD-S5).
        menu.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Make MailSpace the Default Mail App", action: #selector(AppDelegate.makeDefaultMailApp(_:)), keyEquivalent: "")
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
        menu.addItem(.separator())
        // The visible way back from a tab the crash throttle gave up on, and
        // the only one when that tab is the only tab there is to select.
        menu.addItem(withTitle: "Reload Tab", action: #selector(AppDelegate.reloadCurrentTab(_:)), keyEquivalent: "r")
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
