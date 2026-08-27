import AppKit
import Network
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, AccountHosting, SessionLocating, NotificationRouting, TabRecyclerHost {
    let accountStore = AccountStore()

    private let settings = AppSettings.shared
    private let navigationPolicy = NavigationPolicy()
    private let loginAutofill = LoginAutofill()
    private let notificationBridge = NotificationBridge()
    private lazy var unreadPoller = UnreadPoller(interval: settings.unreadPollSeconds)
    private let tabRecycler = TabRecycler()
    private let health = SessionHealthTracker()
    private var sessions: [UUID: AccountSession] = [:]
    private var windowController: MainWindowController?
    private let updateController = UpdateController()
    /// `lazy` is what makes `self` available as the account host here.
    private lazy var settingsWindowController = SettingsWindowController(
        updates: updateController,
        settings: settings,
        accounts: self
    )
    private var loginProbe: LoginProbe?
    private var shimProbe: ShimProbe?
    private var autofillProbe: AutofillProbe?
    private var storeProbe: StoreRemovalProbe?
    private var updateProbe: UpdateProbe?
    private var benchProbe: BenchProbe?
    private var assumptionProbe: AssumptionProbe?
    private var recoveryProbe: RecoveryProbe?
    private var settingsProbe: SettingsProbe?
    /// A mailto: URL that arrived before the window was ready (cold launch).
    private var pendingMailto: URL?

    /// Accounts whose Dock contribution has already been seeded from a real
    /// page. The first poll runs at t=0, when every mail webview is still
    /// blank, so without this the badge stayed empty for up to a minute after
    /// every launch.
    private var badgeSeeded: Set<UUID> = []
    private let launchedAt = Date()
    /// When the Mac last woke. Read by the health monitor, and by the recycler
    /// as G16 — waking is when every tab comes due at once and the network is
    /// least ready.
    private(set) var lastWakeAt: Date?
    /// Whether the Mac currently has a usable network path. A cycle without one
    /// tells the health monitor nothing.
    private var networkIsUp = true
    /// When the feed probe last got *any* answer out of Google. The link being
    /// up says a request can leave this Mac; only this says one arrives.
    private var lastReachedGoogleAt: Date?
    private let pathMonitor = NWPathMonitor()
    /// Accounts the recycler reports as having a dead Mail tab, and the ones
    /// already notified about, so the banner is one per episode.
    private var notifiedStalls: Set<UUID> = []

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
        notificationBridge.currentSelection = { [weak self] in
            guard let selection = self?.windowController?.selection else { return nil }
            return TabRef(accountId: selection.accountId, view: selection.view)
        }
        navigationPolicy.notifyDownloadFinished = { [weak self] url in
            self?.notificationBridge.postDownloadFinished(at: url)
        }
        unreadPoller.mailWebViews = { [weak self] in
            guard let self else { return [] }
            return self.accountStore.accounts.compactMap { account in
                guard account.mailEnabled, let webView = self.sessions[account.id]?.webView(for: .mail) else { return nil }
                return (accountId: account.id, webView: webView)
            }
        }
        // A4 is applied here, at the summing step — not by filtering the
        // provider above, which would leave an opted-out account unpolled
        // (KTD-S7).
        unreadPoller.badgeParticipants = { [weak self] in
            guard let self else { return [] }
            return Set(self.accountStore.accounts.filter { $0.mailEnabled && $0.countInBadge }.map(\.id))
        }
        unreadPoller.onObservation = { [weak self] accountId, observation in
            self?.health.record(observation, for: accountId)
        }
        unreadPoller.isBusy = { [weak self] accountId in self?.isBusy(accountId) ?? true }
        unreadPoller.isBackingOff = { [weak self] accountId in self?.health.isBackingOff(accountId) ?? false }
        unreadPoller.onReachability = { [weak self] reached in self?.googleAnswered(reached) }
        health.onChange = { [weak self] accountId, change in self?.healthChanged(accountId, change) }

        tabRecycler.host = self
        navigationPolicy.onDidCommit = { [weak self] webView in self?.webViewDidCommit(webView) }
        navigationPolicy.onDidFinish = { [weak self] webView in self?.webViewDidFinish(webView) }
        navigationPolicy.onNavigationFailed = { [weak self] webView, _ in
            self?.tabRecycler.webViewDidFail(webView)
        }
        navigationPolicy.onWebViewDiscarded = { [weak self] webView in
            self?.tabRecycler.webViewWasDiscarded(webView)
        }
        observeSleepAndNetwork()

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
        if SelfTest.mode == .update {
            updateProbe = UpdateProbe()
            updateProbe?.run()
            return
        }
        if SelfTest.mode == .bench {
            benchProbe = BenchProbe()
            benchProbe?.run()
            return
        }
        if SelfTest.mode == .assume {
            assumptionProbe = AssumptionProbe()
            assumptionProbe?.run()
            return
        }
        if SelfTest.mode == .recovery {
            recoveryProbe = RecoveryProbe()
            recoveryProbe?.run()
            return
        }
        if SelfTest.mode == .settings {
            settingsProbe = SettingsProbe()
            settingsProbe?.run()
            return
        }
        if SelfTest.mode == .tabshot {
            TabShotProbe().run()
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
        // Started only once every account has a session, so the very first tick
        // sees the real tab list.
        tabRecycler.start()
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
        accountsChanged()
        unreadPoller.refresh(accountId: id)
    }

    /// The account list changed. Nothing in MailSpace posts to
    /// `NotificationCenter` and this plan does not invent it (KTD-S10): the
    /// window and the Settings pane are told by hand, in one place, so no
    /// account path can update one and forget the other.
    private func accountsChanged() {
        windowController?.refresh()
        settingsWindowController.reloadAccounts()
    }

    func badgeInputsChanged(repoll: Bool) {
        if repoll {
            // The scope changed what the number means, so the number has to be
            // fetched again — not a stop()/start() cycle, which only the
            // interval needs.
            unreadPoller.refresh()
        } else {
            unreadPoller.refreshBadge()
        }
    }

    /// The user has just brought this tab up. A webview the crash throttle
    /// stopped reloading gets another go now that someone is looking at it —
    /// the throttle exists to stop a reload loop, not to retire the tab for the
    /// rest of the session.
    ///
    /// It is also where a signed-out account is put back in front of him. The
    /// stale-inbox variant is still sitting on a rendered `mail.google.com`
    /// page, so clicking the warning would otherwise show him the same dead
    /// inbox; re-navigating to the view's own entry point makes Gmail redirect
    /// straight to the sign-in form, and `shouldLoadInOpener` then keeps the
    /// whole chain in the tab.
    func tabBecameVisible(accountId: UUID, view: AccountView, isSelectionChange: Bool) {
        guard let webView = sessions[accountId]?.webView(for: view) else { return }
        // A recycle that gave up aimed at a specific page — the label and
        // thread he was on — so that, not the view's generic entry point, is
        // where a rescue goes. The entry point is the fallback for a webview
        // that crashed before committing anything and has no URL to reload.
        let recovered = navigationPolicy.recoverIfStalled(
            webView,
            baseURL: tabRecycler.outstandingTarget(for: webView) ?? view.url
        )
        if recovered, tabRecycler.hasFailedLoad(webView) {
            Log.info("selected a tab whose recycle had given up; loading it again")
            tabRecycler.userIsRetrying(webView)
        }

        // Gated on a *real* selection change: `refresh()` calls this
        // unconditionally, and a rebuild of the tab bar is not the user asking
        // for anything.
        guard isSelectionChange, view == .mail else { return }
        // Asked of the page, not of the URL: an inline reply is invisible to
        // `hasOpenCompose`, and this navigation would throw it away.
        editorState(in: webView) { [weak self] state in
            guard let self else { return }
            guard self.health.shouldRenavigate(
                accountId: accountId,
                url: webView.url,
                hasLiveEditor: RecycleDecision.hasLiveEditor(state)
            ) else { return }
            Log.info("signed-out account selected; re-navigating its mail tab to the sign-in page")
            webView.load(URLRequest(url: view.url))
        }
    }

    /// G11: this tab has just stopped being the visible one.
    func tabWasDeselected(accountId: UUID, view: AccountView) {
        guard let webView = sessions[accountId]?.webView(for: view) else { return }
        tabRecycler.webViewWasDeselected(webView)
    }

    func signedOutAccounts() -> Set<UUID> {
        health.signedOutAccounts
    }

    func stalledAccounts() -> Set<UUID> {
        tabRecycler.stalledAccounts
    }

    // MARK: - TabRecyclerHost

    var mainWindowIsVisible: Bool {
        windowController?.isOnScreen ?? false
    }

    /// G15. Two sources, and the second one is the one that decides — see
    /// `RecycleDecision.Reachability`.
    var reachability: RecycleDecision.Reachability {
        RecycleDecision.reachability(
            pathIsSatisfied: networkIsUp,
            lastReachedGoogleAt: lastReachedGoogleAt,
            probesAreRunning: accountStore.accounts.contains { $0.mailEnabled },
            now: Date()
        )
    }

    /// The feed probe got an answer out of Google — or did not.
    ///
    /// A single success re-proves the path for `reachProofWindow`, and it is
    /// also the moment every tab that gave up gets another go. That is what
    /// makes an outage self-healing: nothing is asked of the user.
    private func googleAnswered(_ reached: Bool) {
        guard reached else { return }
        let wasReachable = reachability == .up
        lastReachedGoogleAt = Date()
        guard !wasReachable else { return }
        tabRecycler.networkBecameReachable()
    }

    /// G18. One structural question, asked in the page's main frame.
    ///
    /// No text crosses the bridge: the script returns whether the focused
    /// element is typable and how many editable boxes are non-empty. It reads
    /// no word of anybody's mail, and it cannot break because Gmail renamed a
    /// CSS class — `contenteditable`, `role="textbox"` and `<textarea>` are the
    /// platform's own vocabulary.
    func editorState(
        in webView: WKWebView,
        completion: @escaping (RecycleDecision.EditorState?) -> Void
    ) {
        var answered = false
        let answer: (RecycleDecision.EditorState?) -> Void = { state in
            guard !answered else { return }
            answered = true
            completion(state)
        }

        // A page that cannot answer in five seconds is wedged, and a wedged
        // page is the one most in need of rebuilding — so silence is "no
        // editor", not "leave it alone forever".
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { answer(nil) }

        webView.callAsyncJavaScript(
            Self.editorProbeScript,
            arguments: [:],
            in: nil,
            in: .defaultClient
        ) { result in
            guard let payload = (try? result.get()) as? [String: Any] else {
                answer(nil)
                return
            }
            answer(
                RecycleDecision.EditorState(
                    focused: (payload["focused"] as? Bool) ?? false,
                    dirty: (payload["dirty"] as? Int) ?? 0
                )
            )
        }
    }

    private static let editorProbeScript = """
    const active = document.activeElement;
    const focused = !!(active && (
      active.isContentEditable ||
      active.tagName === 'TEXTAREA' ||
      (active.tagName === 'INPUT' && /^(text|search|email|url|tel)$/i.test(active.type || 'text'))
    ));
    let dirty = 0;
    const boxes = document.querySelectorAll(
      '[contenteditable="true"], [g_editable="true"], [role="textbox"], textarea'
    );
    for (const box of boxes) {
      // A length, never the text. Nothing here can carry a word of anyone's
      // mail back across the bridge.
      const value = box.value !== undefined ? box.value : box.textContent;
      if ((value || '').trim().length > 0) { dirty += 1; }
    }
    return { focused: focused, dirty: dirty };
    """

    func markRecycleStalled(_ webView: WKWebView, target url: URL) {
        navigationPolicy.markStalled(webView)
    }

    func recycleStallsChanged() {
        let stalled = tabRecycler.stalledAccounts
        unreadPoller.setStalled(stalled)
        windowController?.refresh()

        notifiedStalls.formIntersection(stalled)
        for accountId in stalled where !notifiedStalls.contains(accountId) {
            notifiedStalls.insert(accountId)
            guard let account = accountStore.account(id: accountId) else { continue }
            Log.error("account \(accountId.uuidString.prefix(8)) has a mail tab that will not load")
            notificationBridge.post(
                title: "\(account.name) — Mail is not loading",
                body: "MailSpace could not reload this tab. Click to try again.",
                tag: "mailspace-tab-stalled",
                account: account,
                view: .mail
            )
        }
    }

    func recycleTargets() -> [TabRecycler.Target] {
        TabOrder.tabs(for: accountStore.accounts).enumerated().compactMap { index, tab in
            guard
                let account = accountStore.account(id: tab.accountId),
                let webView = sessions[tab.accountId]?.webView(for: tab.view)
            else { return nil }
            return TabRecycler.Target(
                accountId: tab.accountId,
                accountName: account.name,
                view: tab.view,
                slot: index,
                webView: webView
            )
        }
    }

    func recycleCandidate(for target: TabRecycler.Target) -> RecycleDecision.Candidate? {
        guard let session = sessions[target.accountId] else { return nil }
        // G4(c): a sign-in in flight on *any* of the account's webviews blocks
        // all of them, because `signInCompleted` is about to call
        // `reloadSignedOutViews` across the whole session and the two must not
        // race.
        let authenticating = session.webViews.contains { navigationPolicy.isAuthenticating($0) }
        return RecycleDecision.Candidate(
            url: target.webView.url,
            view: target.view,
            slot: target.slot,
            committedAt: nil,
            isSelected: windowController?.selection
                == MainWindowController.Selection(accountId: target.accountId, view: target.view),
            isLoading: target.webView.isLoading,
            isStalled: navigationPolicy.isStalled(target.webView),
            isAuthenticating: authenticating,
            accountHasPopup: navigationPolicy.hasPopup(for: target.accountId),
            accountHasDownload: navigationPolicy.hasActiveDownload(for: target.accountId),
            accountIsSignedOut: health.isSignedOut(target.accountId),
            lastOpenPanelAt: navigationPolicy.lastOpenPanel(for: target.webView),
            lastDeselectedAt: nil
        )
    }

    func performRecycle(_ target: TabRecycler.Target, to url: URL) -> WKWebView? {
        guard let fresh = sessions[target.accountId]?.recycle(target.view) else { return nil }
        fresh.load(URLRequest(url: url))
        // Nothing else needs re-wiring: `UnreadPoller.mailWebViews` re-reads the
        // session on every call, and `NotificationBridge` resolves through
        // `session(hosting:)`.
        if windowController?.selection
            == MainWindowController.Selection(accountId: target.accountId, view: target.view) {
            windowController?.replacedSelectedWebView()
        }
        return fresh
    }

    // MARK: - Session health

    private func webViewDidCommit(_ webView: WKWebView) {
        tabRecycler.webViewDidCommit(webView)
        tabRecycler.webViewDidSettle(webView)
        guard let session = session(hosting: webView), session.view(for: webView) == .mail else { return }
        health.didCommit(for: session.accountId)
    }

    private func webViewDidFinish(_ webView: WKWebView) {
        guard let session = session(hosting: webView), session.view(for: webView) == .mail else { return }
        guard badgeSeeded.insert(session.accountId).inserted else { return }
        unreadPoller.refresh(accountId: session.accountId)
    }

    /// Whether nothing can be concluded about this account's session right now.
    private func isBusy(_ accountId: UUID) -> Bool {
        guard let webView = sessions[accountId]?.webView(for: .mail) else { return true }
        if webView.isLoading { return true }
        if tabRecycler.isRecycling(webView) { return true }
        if let age = tabRecycler.age(of: webView), age < 90 { return true }
        if !networkIsUp { return true }
        // Losing the network is not being signed out. The link can be up while
        // nothing reaches Google — a portal, a router with no upstream — and
        // every observation taken in that window is about the network, not
        // about the session.
        if reachability != .up { return true }
        // A sign-in that is actually happening. Google `pushState`s through its
        // steps rather than committing a document per step, so the `didCommit`
        // streak reset does not cover a slow one; three minutes of 2FA on a
        // phone used to confirm a signed-out verdict on a session being signed
        // *in*. Quiescence is the discriminator the file already relies on, and
        // a person mid-sign-in is not quiet.
        if tabRecycler.sawLocalInput(within: 180), AuthSurface.classify(webView.url) == .signIn {
            return true
        }
        let now = Date()
        if now.timeIntervalSince(launchedAt) < 120 { return true }
        if let wake = lastWakeAt, now.timeIntervalSince(wake) < 120 { return true }
        return false
    }

    private func healthChanged(_ accountId: UUID, _ change: SessionHealth.Change) {
        unreadPoller.setSignedOut(health.signedOutAccounts)
        windowController?.refresh()

        guard case .signedOut(let shouldNotify) = change else {
            Log.info("account \(accountId.uuidString.prefix(8)) is signed in again")
            return
        }
        Log.info("account \(accountId.uuidString.prefix(8)) reported signed out (notify=\(shouldNotify))")
        guard shouldNotify, let account = accountStore.account(id: accountId) else { return }

        // He is already looking at the page; a banner about it is noise.
        let selection = windowController?.selection
        if NSApp.isActive,
           mainWindowIsVisible,
           selection?.accountId == accountId,
           selection?.view == .mail {
            return
        }

        notificationBridge.post(
            title: "\(account.name) — Mail is signed out",
            body: "MailSpace stopped receiving mail for this account. Click to sign in.",
            tag: "mailspace-session-health",
            account: account,
            view: .mail
        )
    }

    private func observeSleepAndNetwork() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastWakeAt = Date()
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let up = path.status == .satisfied
                guard up != self.networkIsUp else { return }
                self.networkIsUp = up
                guard up else { return }
                // The interface is back. Nothing has yet proved Google is
                // reachable, so this does not release the recycler's G15 — but
                // it does make the next feed probe worth waiting for, and that
                // probe is what triggers the rescue.
                Log.info("network path is back")
                self.unreadPoller.refresh()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.vitalii.MailSpace.path"))
    }

    /// Confirms, then tears the account down. The confirmation belongs to the
    /// window the user clicked in — a sheet on the Settings window when that is
    /// where the − button was, and today's app-modal dialog when no window is
    /// passed (a self-test, or a caller with nothing to attach to).
    func requestRemoveAccount(id: UUID, presentedOn presentingWindow: NSWindow?) {
        guard let account = accountStore.account(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(account.name)”?"
        alert.informativeText = "MailSpace will sign this account out and delete its stored Google session from this Mac. Your mail itself is not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Account")
        alert.addButton(withTitle: "Cancel")

        guard let presentingWindow else {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performRemoval(id: id)
            return
        }
        alert.beginSheetModal(for: presentingWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.performRemoval(id: id)
        }
    }

    /// The teardown, moved here verbatim from inside `requestRemoveAccount`.
    /// Nothing in the ordering below is edited: every step of it is a bug
    /// somebody already paid for, and `MAILSPACE_SELFTEST=store` is what proves
    /// the move was mechanical.
    private func performRemoval(id: UUID) {
        // A sheet blocks only its own window, so the main window's tab context
        // menu can remove the same account while the Settings sheet is up.
        // Without this line the second removal runs against a released session
        // and a Keychain item that is already gone.
        guard let account = accountStore.account(id: id) else { return }

        // Ordering matters twice over. `forget` goes first so a poll still in
        // flight cannot write a stale count back after the account is gone. And
        // WebKit refuses to delete a data store anything still references, so
        // every webview on it — the account's popup windows included — and
        // every download running on it has to be gone before `destroyDataStore`.
        unreadPoller.forget(accountId: id)
        health.forget(id)
        badgeSeeded.remove(id)
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
        accountsChanged()

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
        // `select` refreshes the main window and moves its first responder, but
        // never activates it — so an account added from Settings lands behind
        // the still-key Settings window.
        if let view = account.effectiveView {
            windowController?.select(accountId: account.id, view: view)
        }
        settingsWindowController.reloadAccounts()
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

    /// B6. The way back when the window's saved frame points at a display that
    /// is no longer there.
    @objc func resetWindowPosition(_ sender: Any?) {
        windowController?.resetWindowPosition()
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

    /// ⌥⌘R — a diagnostic, not the feature. Automatic recycling is what keeps
    /// memory and sync healthy; this exists so a recycle can be provoked on
    /// demand while verifying that it does. Deliberately not on plain ⌘R, which
    /// is load-bearing for crash-throttle recovery. One line in the View menu
    /// and this method are the whole of it.
    @objc func reloadAllTabs(_ sender: Any?) {
        for session in sessions.values {
            for webView in session.webViews {
                navigationPolicy.reload(webView, baseURL: nil)
            }
        }
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

    /// B4: a declined LaunchServices consent dialog has to be visible. From the
    /// menu that means an alert; the Settings row says it inline instead.
    @objc func makeDefaultMailApp(_ sender: Any?) {
        DefaultMailApp.makeDefault { error in
            guard let error else { return }
            Log.error("could not become the default mail app: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "MailSpace is not the default mail app"
            alert.informativeText = "macOS declined the change: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// B3: the File-menu item reads the same live, prompt-free state the
    /// Settings row does, so it can never claim MailSpace owns `mailto:` while
    /// a stale copy in a deleted worktree actually holds it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(makeDefaultMailApp(_:)) else { return true }
        let state = DefaultMailApp.current()
        menuItem.title = DefaultMailApp.menuTitle(state)
        return DefaultMailApp.canBecomeDefault(state)
    }

    /// The Mail-capable accounts in the order the tab bar shows them — the
    /// order the compose picker offers, and the order "the first Mail account"
    /// means.
    private func mailAccountsInTabOrder() -> [Account] {
        TabOrder.tabs(for: accountStore.accounts)
            .filter { $0.view == .mail }
            .compactMap { accountStore.account(id: $0.accountId) }
    }

    private func openMailto(_ url: URL) {
        guard let controller = windowController else { return }

        let accounts = mailAccountsInTabOrder()
        let resolution = ComposeRouting.resolve(
            setting: settings.composeFrom,
            selected: controller.selection?.accountId,
            accounts: accounts
        )

        switch resolution {
        case .account(let accountId):
            compose(url, in: accountId, controller: controller)
        case .ask(let candidates):
            // The picker runs before the compose loads, so cancelling means
            // nothing was sent anywhere.
            guard let chosen = Self.askWhichAccount(
                among: candidates.compactMap { accountStore.account(id: $0) },
                preferring: controller.selection?.accountId,
                recipients: Self.recipients(of: url)
            ) else { return }
            compose(url, in: chosen, controller: controller)
        case .none:
            // Nowhere to compose — show the first-run prompt instead of failing
            // silently.
            NSApp.activate(ignoringOtherApps: true)
            controller.showWindow()
        }
    }

    private func compose(_ url: URL, in accountId: UUID, controller: MainWindowController) {
        guard
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

    /// The `Ask me each time` picker: one button per account, the tab on screen
    /// first so Return picks it, Esc cancels the compose outright. Buttons
    /// rather than a pop-up so the whole thing is keyboard-only without anyone
    /// having to tab into a control first.
    private static func askWhichAccount(
        among accounts: [Account],
        preferring selected: UUID?,
        recipients: String
    ) -> UUID? {
        guard !accounts.isEmpty else { return nil }
        var ordered = accounts
        if let selected, let index = ordered.firstIndex(where: { $0.id == selected }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Compose from which account?"
        alert.informativeText = recipients.isEmpty ? "" : "To: \(recipients)"
        alert.alertStyle = .informational
        for account in ordered {
            let button = alert.addButton(withTitle: account.name)
            button.image = account.color.dotImage()
            button.imagePosition = .imageLeading
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard ordered.indices.contains(index) else { return nil }
        return ordered[index].id
    }

    /// Who the message is addressed to, for the picker's subtitle. Read from
    /// the URL only — nothing is logged and nothing is stored.
    private static func recipients(of mailto: URL) -> String {
        // `mailto:` is opaque, so the addresses sit between the scheme and the
        // first `?` rather than in `path`.
        let body = mailto.absoluteString.dropFirst("mailto:".count)
        let addresses = body.components(separatedBy: "?").first ?? ""
        return addresses.removingPercentEncoding ?? addresses
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
        // Diagnostic only. Tabs are rebuilt automatically once they have been
        // open half a day; this is the lever for provoking one on demand.
        let reloadAll = menu.addItem(withTitle: "Reload All Tabs", action: #selector(AppDelegate.reloadAllTabs(_:)), keyEquivalent: "r")
        reloadAll.keyEquivalentModifierMask = [.command, .option]
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
        // The only recovery for a frame stranded on a display that has been
        // unplugged. A rescue belongs in a menu, not in Settings (B6).
        menu.addItem(withTitle: "Reset Window Position", action: #selector(AppDelegate.resetWindowPosition(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let item = submenuItem(menu)
        NSApp.windowsMenu = menu
        return item
    }
}
