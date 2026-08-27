import AppKit

/// Settings ▸ General — G1…G5 plus the update preferences.
///
/// Every control here writes its preference and is read back at the point of
/// use, so nothing in this pane needs a relaunch (S3). None of them owns
/// behaviour: the compose rule lives in `ComposeRouting`, the link and download
/// behaviour in `NavigationPolicy`, the handler check in `DefaultMailApp`.
final class SettingsGeneralPane: NSViewController {
    private let updates: UpdateController
    private let settings: AppSettings
    private unowned let host: AccountHosting

    // G1
    private let composePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    // G2
    private let backgroundLinksBox = NSButton(
        checkboxWithTitle: "Open links without bringing the browser forward",
        target: nil,
        action: nil
    )
    // G3
    private let downloadPathLabel = NSTextField(labelWithString: "")
    private let downloadWarning = NSTextField(labelWithString: "")
    // G4
    private let downloadActionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    // G6
    private let countdownBox = NSButton(
        checkboxWithTitle: "Show time until the next event on Calendar tabs",
        target: nil,
        action: nil
    )
    private let countdownStatus = NSTextField(labelWithString: "")
    private let countdownCheckButton = NSButton(title: "Check Now", target: nil, action: nil)
    // G5
    private let defaultMailStatus = NSTextField(labelWithString: "")
    private let makeDefaultButton = NSButton(title: "Make MailSpace the Default", target: nil, action: nil)
    private let defaultMailWarning = NSTextField(labelWithString: "")
    // Software update
    private let automaticBox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let checkNowButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    /// How G6 reaches the countdown poller. Defaults to an inert set, so a
    /// window built without one — the settings self-test — still works.
    private let calendar: CalendarCountdownControls

    init(
        updates: UpdateController,
        settings: AppSettings = .shared,
        accounts host: AccountHosting,
        calendar: CalendarCountdownControls = CalendarCountdownControls()
    ) {
        self.updates = updates
        self.settings = settings
        self.host = host
        self.calendar = calendar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MailSpace builds its UI in code")
    }

    override func loadView() {
        let composeRow = labeledRow("Compose mailto: links from:", composePopup)
        let linksCaption = Self.caption("Works when your browser is already running.")
        let downloadActionRow = labeledRow("When a download finishes:", downloadActionPopup)
        let countdownCaption = Self.caption("Only events later today, from the account you are signed in to.")
        let countdownStatusRow = NSStackView(views: [countdownCheckButton, countdownStatus]).horizontal()
        let stack = NSStackView(views: [
            Self.sectionTitle("Composing"),
            composeRow,

            Self.sectionTitle("Links"),
            backgroundLinksBox,
            linksCaption,

            Self.sectionTitle("Downloads"),
            labeledRow("Save downloads to:", downloadRow()),
            downloadWarning,
            downloadActionRow,

            Self.sectionTitle("Calendar"),
            countdownBox,
            countdownCaption,
            countdownStatusRow,

            Self.sectionTitle("Default Mail App"),
            defaultMailStatus,
            makeDefaultButton,
            defaultMailWarning,

            Self.sectionTitle("Software Update"),
            automaticBox,
            Self.caption(
                "MailSpace looks for a new release once a day and shows you what changed. "
                + "Nothing is ever installed until you click Update."
            ),
            NSStackView(views: [checkNowButton, statusLabel]).horizontal(),
            Self.footnote(updates.versionDescription)
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // A section title belongs to what comes after it, so the gap goes above.
        // `makeDefaultButton` carries the gap as well as the warning under it: a
        // hidden view contributes no spacing of its own, and that warning is
        // hidden whenever macOS has not just refused.
        for view in [
            composeRow, linksCaption, downloadActionRow, countdownStatusRow, makeDefaultButton, defaultMailWarning
        ] {
            stack.setCustomSpacing(18, after: view)
        }
        stack.setCustomSpacing(4, after: backgroundLinksBox)
        stack.setCustomSpacing(4, after: countdownBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        configureControls()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 590))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
        view = content
        reload()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    /// Re-reads everything the window can be out of step with: the account list
    /// behind G1, the download folder's writability, and who owns `mailto:`.
    func reload() {
        guard isViewLoaded else { return }
        rebuildComposePopup()
        backgroundLinksBox.state = settings.openLinksInBackground ? .on : .off
        refreshDownloadFolder()
        downloadActionPopup.selectItem(withTag: Self.tag(for: settings.downloadFinishedAction))
        countdownBox.state = settings.showsCalendarCountdown ? .on : .off
        refreshCountdownStatus()
        refreshDefaultMailApp()
        automaticBox.state = settings.automaticallyChecksForUpdates ? .on : .off
        statusLabel.stringValue = updates.lastCheckDescription
    }

    // MARK: - Wiring

    private func configureControls() {
        composePopup.target = self
        composePopup.action = #selector(composeFromChanged(_:))

        backgroundLinksBox.target = self
        backgroundLinksBox.action = #selector(toggleBackgroundLinks(_:))

        downloadActionPopup.target = self
        downloadActionPopup.action = #selector(downloadActionChanged(_:))
        downloadActionPopup.removeAllItems()
        for action in DownloadFinishedAction.allCases {
            downloadActionPopup.addItem(withTitle: action.displayName)
            downloadActionPopup.lastItem?.tag = Self.tag(for: action)
        }

        downloadPathLabel.lineBreakMode = .byTruncatingMiddle
        downloadPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        Self.style(downloadWarning, as: .warning)
        Self.style(defaultMailWarning, as: .warning)
        defaultMailStatus.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        countdownBox.target = self
        countdownBox.action = #selector(toggleCalendarCountdown(_:))
        countdownCheckButton.target = self
        countdownCheckButton.action = #selector(recheckCalendar(_:))
        countdownCheckButton.bezelStyle = .rounded
        // The pane carries two buttons titled "Check Now" — this one and the
        // update check. They are unambiguous under their own section headings on
        // screen, and this is what tells them apart to anything reading the view.
        countdownCheckButton.setAccessibilityLabel("Check the calendar countdown now")
        Self.style(countdownStatus, as: .secondary)

        makeDefaultButton.target = self
        makeDefaultButton.action = #selector(makeDefault(_:))
        makeDefaultButton.bezelStyle = .rounded

        automaticBox.target = self
        automaticBox.action = #selector(toggleAutomatic(_:))

        checkNowButton.target = self
        checkNowButton.action = #selector(checkNow(_:))
        checkNowButton.bezelStyle = .rounded
        Self.style(statusLabel, as: .secondary)
    }

    // MARK: - G1

    private func rebuildComposePopup() {
        let accounts = mailAccounts()
        composePopup.removeAllItems()
        composePopup.addItem(withTitle: "Ask me each time")
        composePopup.lastItem?.representedObject = ComposeFrom.ask.rawValue
        composePopup.addItem(withTitle: "The account I'm looking at")
        composePopup.lastItem?.representedObject = ComposeFrom.current.rawValue
        if !accounts.isEmpty {
            composePopup.menu?.addItem(.separator())
            for account in accounts {
                composePopup.addItem(withTitle: account.name)
                composePopup.lastItem?.representedObject = account.id.uuidString
                composePopup.lastItem?.image = account.color.dotImage()
            }
        }

        let stored = settings.composeFrom.rawValue
        let match = composePopup.itemArray.first { ($0.representedObject as? String) == stored }
        // A fixed account that has been removed, or has lost Mail, shows as the
        // rule it actually degrades to rather than as a blank row.
        composePopup.select(match ?? composePopup.itemArray.first)
        if match == nil, settings.composeFrom != .ask { settings.composeFrom = .ask }
    }

    private func mailAccounts() -> [Account] {
        TabOrder.tabs(for: host.accountStore.accounts)
            .filter { $0.view == .mail }
            .compactMap { tab in host.accountStore.account(id: tab.accountId) }
    }

    @objc private func composeFromChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        settings.composeFrom = ComposeFrom(rawValue: raw)
    }

    // MARK: - G2

    @objc private func toggleBackgroundLinks(_ sender: NSButton) {
        settings.openLinksInBackground = sender.state == .on
    }

    // MARK: - G3

    private func downloadRow() -> NSView {
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseDownloadFolder(_:)))
        choose.bezelStyle = .rounded
        let useDefault = NSButton(title: "Use Default", target: self, action: #selector(useDefaultDownloadFolder(_:)))
        useDefault.bezelStyle = .rounded
        let row = NSStackView(views: [downloadPathLabel, choose, useDefault]).horizontal()
        row.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        return row
    }

    @objc private func chooseDownloadFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = settings.downloadDirectory
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        settings.downloadDirectory = chosen
        refreshDownloadFolder()
    }

    @objc private func useDefaultDownloadFolder(_ sender: Any?) {
        settings.useSystemDownloadDirectory()
        refreshDownloadFolder()
    }

    private func refreshDownloadFolder() {
        let directory = settings.downloadDirectory
        downloadPathLabel.stringValue = settings.usesSystemDownloadDirectory
            ? "Downloads"
            : (directory.path as NSString).abbreviatingWithTildeInPath

        // The setting is never silently reverted — he chose it, so he sees why
        // it is failing.
        let writable = FileManager.default.isWritableFile(atPath: directory.path)
        let exists = FileManager.default.fileExists(atPath: directory.path)
        downloadPathLabel.textColor = writable ? .labelColor : .systemRed
        downloadWarning.stringValue = writable
            ? ""
            : (exists ? "MailSpace cannot write here." : "This folder no longer exists.")
        downloadWarning.isHidden = writable
    }

    // MARK: - G4

    @objc private func downloadActionChanged(_ sender: NSPopUpButton) {
        guard let action = DownloadFinishedAction.allCases.first(where: { Self.tag(for: $0) == sender.selectedTag() })
        else { return }
        settings.downloadFinishedAction = action
    }

    private static func tag(for action: DownloadFinishedAction) -> Int {
        (DownloadFinishedAction.allCases.firstIndex(of: action) ?? 0) + 1
    }

    // MARK: - G6

    @objc private func toggleCalendarCountdown(_ sender: NSButton) {
        let enabled = sender.state == .on
        settings.showsCalendarCountdown = enabled
        calendar.setEnabled(enabled)
        refreshCountdownStatus()
    }

    /// Asks for a fresh check and reports what came back.
    ///
    /// This is the cheap way to find out whether the countdown can read a
    /// calendar at all, on the owner's own signed-in session, without anyone
    /// else going near it. The line says what happened — worked, refused, not
    /// understood, no answer — and never what it read.
    @objc private func recheckCalendar(_ sender: Any?) {
        countdownCheckButton.isEnabled = false
        countdownStatus.stringValue = "Checking…"
        calendar.recheck { [weak self] in
            self?.countdownCheckButton.isEnabled = true
            self?.refreshCountdownStatus()
        }
    }

    private func refreshCountdownStatus() {
        let status = calendar.status()
        countdownStatus.stringValue = status.text
        // Red only for the two answers that mean the feature cannot work here.
        // "Not checked yet" and "waiting for a Calendar tab" are ordinary.
        let broken = status.kind == .refused || status.kind == .notUnderstood
        countdownStatus.textColor = broken ? .systemRed : .secondaryLabelColor
        countdownCheckButton.isEnabled = settings.showsCalendarCountdown
    }

    // MARK: - G5

    private func refreshDefaultMailApp() {
        let state = DefaultMailApp.current()
        defaultMailStatus.stringValue = DefaultMailApp.statusText(state)
        makeDefaultButton.isEnabled = DefaultMailApp.canBecomeDefault(state)
        defaultMailWarning.isHidden = defaultMailWarning.stringValue.isEmpty
    }

    @objc private func makeDefault(_ sender: Any?) {
        defaultMailWarning.stringValue = ""
        defaultMailWarning.isHidden = true
        DefaultMailApp.makeDefault { [weak self] error in
            guard let self else { return }
            if let error {
                // B4: a declined consent dialog says so, right here, instead of
                // going to stderr while the status line pretends nothing was
                // asked.
                self.defaultMailWarning.stringValue = "macOS declined the change: \(error.localizedDescription)"
                self.defaultMailWarning.isHidden = false
            }
            self.refreshDefaultMailApp()
        }
    }

    // MARK: - Software update

    @objc private func toggleAutomatic(_ sender: NSButton) {
        settings.automaticallyChecksForUpdates = sender.state == .on
    }

    @objc private func checkNow(_ sender: Any?) {
        checkNowButton.isEnabled = false
        statusLabel.stringValue = "Checking…"
        // Explicitly user-initiated, so this button reports "up to date" and
        // reports failures — the same contract as the menu item.
        updates.check(userInitiated: true) { [weak self] in
            self?.checkNowButton.isEnabled = true
            self?.statusLabel.stringValue = self?.updates.lastCheckDescription ?? ""
        }
    }

    // MARK: - Layout helpers

    private func labeledRow(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let row = NSStackView(views: [label, control]).horizontal()
        row.alignment = .firstBaseline
        return row
    }

    private static func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return label
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        style(label, as: .secondary)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 460
        return label
    }

    private static func footnote(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private enum LabelStyle { case secondary, warning }

    private static func style(_ label: NSTextField, as style: LabelStyle) {
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = style == .warning ? .systemRed : .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 460
    }
}

extension NSStackView {
    /// The horizontal row this window is built out of.
    func horizontal(spacing: CGFloat = 8) -> NSStackView {
        orientation = .horizontal
        alignment = .centerY
        self.spacing = spacing
        return self
    }
}
