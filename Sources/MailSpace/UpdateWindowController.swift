import AppKit

/// The window he sees when a release is waiting: which version, what changed,
/// Update or Later.
///
/// Nothing here installs anything on its own. The Update button is the only
/// path, and it stays a button until it is clicked — the check, the download
/// and the install are three separate decisions and only the first two are
/// automatic.
final class UpdateWindowController: NSObject, NSWindowDelegate {
    typealias Install = (
        _ progress: @escaping (UpdateInstaller.Stage) -> Void,
        _ completion: @escaping (Result<URL, Error>) -> Void
    ) -> Void

    private var window: NSWindow?
    private let headline = NSTextField(labelWithString: "")
    private let subhead = NSTextField(labelWithString: "")
    private let notesView = NSTextView()
    private let status = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let laterButton = NSButton(title: "Later", target: nil, action: nil)
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)

    private var install: Install?
    private var installing = false

    var isPresenting: Bool { window?.isVisible == true }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func present(
        release: UpdateRelease,
        currentVersion: SemanticVersion,
        buildDescription: String?,
        refusal: String?,
        install: @escaping Install
    ) {
        self.install = install
        buildWindowIfNeeded()

        headline.stringValue = "MailSpace \(release.version) is available"
        var have = "You have \(currentVersion)."
        if let buildDescription { have += " This build is \(buildDescription)." }
        if release.assetSize > 0 {
            have += " Download is \(ByteCountFormatter.string(fromByteCount: Int64(release.assetSize), countStyle: .file))."
        }
        subhead.stringValue = have

        notesView.textStorage?.setAttributedString(ReleaseNotes.attributed(release.notes))
        notesView.scroll(.zero)

        if let refusal {
            updateButton.isEnabled = false
            laterButton.title = "Close"
            setStatus(refusal, isError: true)
        } else {
            updateButton.isEnabled = true
            laterButton.title = "Later"
            setStatus("", isError: false)
        }

        progressBar.isHidden = true
        installing = false
        bringToFront()
    }

    // MARK: - Actions

    @objc private func updateClicked(_ sender: Any?) {
        guard let install, !installing else { return }
        installing = true
        updateButton.isEnabled = false
        laterButton.isEnabled = false
        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        setStatus(UpdateInstaller.Stage.downloading(fraction: nil).label, isError: false)

        install({ [weak self] stage in
            self?.show(stage)
        }, { [weak self] result in
            self?.finished(result)
        })
    }

    @objc private func laterClicked(_ sender: Any?) {
        window?.close()
    }

    private func show(_ stage: UpdateInstaller.Stage) {
        switch stage {
        case .downloading(let fraction):
            if let fraction {
                if progressBar.isIndeterminate {
                    progressBar.isIndeterminate = false
                    progressBar.minValue = 0
                    progressBar.maxValue = 1
                }
                progressBar.doubleValue = fraction
            }
        case .verifying, .installing:
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        }
        setStatus(stage.label, isError: false)
    }

    private func finished(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            progressBar.isIndeterminate = true
            setStatus("Installed. Relaunching MailSpace…", isError: false)
        case .failure(let error):
            installing = false
            progressBar.stopAnimation(nil)
            progressBar.isHidden = true
            updateButton.isEnabled = true
            laterButton.isEnabled = true
            let message = UpdateInstaller.describe(error)
            setStatus(message, isError: true)

            // The window keeps the reason on screen, and the alert makes sure a
            // refused install is not something he has to notice.
            let alert = NSAlert()
            alert.messageText = "The update was not installed."
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
        }
    }

    private func setStatus(_ text: String, isError: Bool) {
        status.stringValue = text
        status.textColor = isError ? .systemRed : .secondaryLabelColor
        status.isHidden = text.isEmpty
    }

    // MARK: - Layout

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Software Update"
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 460, height: 340)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        headline.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        subhead.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        subhead.textColor = .secondaryLabelColor
        subhead.lineBreakMode = .byWordWrapping
        subhead.maximumNumberOfLines = 3

        notesView.isEditable = false
        notesView.isSelectable = true
        notesView.drawsBackground = false
        notesView.textContainerInset = NSSize(width: 8, height: 8)
        notesView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.documentView = notesView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.controlSize = .small

        status.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 4
        status.isHidden = true

        updateButton.target = self
        updateButton.action = #selector(updateClicked(_:))
        updateButton.keyEquivalent = "\r"
        updateButton.bezelStyle = .rounded

        laterButton.target = self
        laterButton.action = #selector(laterClicked(_:))
        laterButton.keyEquivalent = "\u{1b}"
        laterButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [laterButton, updateButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let buttonRow = NSStackView(views: [NSView(), buttons])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        let stack = NSStackView(views: [headline, subhead, scroll, progressBar, status, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(4, after: headline)
        stack.setCustomSpacing(12, after: subhead)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            progressBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            status.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            subhead.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])

        self.window = window
    }

    /// An install in flight is not something a window close may abandon —
    /// the swap is already staged and the app is about to be replaced.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !installing
    }
}
