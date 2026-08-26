import AppKit

/// Settings ▸ General.
///
/// Carries the update preferences only. The settings-window plan's G1–G5 belong
/// in this file when they land; the section below is written as a section so
/// adding them means adding stacks, not rearranging this one.
final class SettingsGeneralPane: NSViewController {
    private let updates: UpdateController
    private let settings: AppSettings

    private let automaticBox = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)
    private let checkNowButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    init(updates: UpdateController, settings: AppSettings = .shared) {
        self.updates = updates
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MailSpace builds its UI in code")
    }

    override func loadView() {
        let sectionTitle = NSTextField(labelWithString: "Software Update")
        sectionTitle.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        automaticBox.target = self
        automaticBox.action = #selector(toggleAutomatic(_:))
        automaticBox.state = settings.automaticallyChecksForUpdates ? .on : .off

        let caption = NSTextField(labelWithString:
            "MailSpace looks for a new release once a day and shows you what changed. "
            + "Nothing is ever installed until you click Update.")
        caption.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byWordWrapping
        caption.maximumNumberOfLines = 3
        caption.preferredMaxLayoutWidth = 420

        checkNowButton.target = self
        checkNowButton.action = #selector(checkNow(_:))
        checkNowButton.bezelStyle = .rounded

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        let checkRow = NSStackView(views: [checkNowButton, statusLabel])
        checkRow.orientation = .horizontal
        checkRow.spacing = 10
        checkRow.alignment = .centerY

        let versionLabel = NSTextField(labelWithString: updates.versionDescription)
        versionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [sectionTitle, automaticBox, caption, checkRow, versionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: automaticBox)
        stack.setCustomSpacing(14, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 220))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
        ])
        view = content
        refreshStatus()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        automaticBox.state = settings.automaticallyChecksForUpdates ? .on : .off
        refreshStatus()
    }

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
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        statusLabel.stringValue = updates.lastCheckDescription
    }
}
