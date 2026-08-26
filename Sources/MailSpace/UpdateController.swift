import AppKit
import Foundation

/// Owns the update story: when a check happens, what a check is allowed to say,
/// and who is told about it.
///
/// The one rule that shapes everything here: a check the user asked for always
/// produces an answer — a new version, "you are up to date", or the reason it
/// could not find out. A background check is silent unless it found something.
/// A menu item that appears to do nothing is indistinguishable from a broken
/// one, and a background failure he never asked about is noise.
final class UpdateController: NSObject {
    /// How long a background check waits after one completes.
    static let backgroundInterval: TimeInterval = 24 * 60 * 60
    /// How long after launch the first background check fires. Late enough that
    /// it never competes with loading the accounts.
    private static let launchDelay: TimeInterval = 20

    private let settings: AppSettings
    private let feedURL: URL?
    private let publicKey: String
    let currentVersion: SemanticVersion
    /// `git describe` of the commit this build came from, when it is not a clean
    /// release build. Shown so a working build is never mistaken for the
    /// shipped one — both report the same `CFBundleShortVersionString`.
    let buildDescription: String?
    private let installedBundle: URL

    private var checker: UpdateChecker?
    private var window: UpdateWindowController?
    private var timer: Timer?
    private var checkInFlight = false

    init(settings: AppSettings = .shared, bundle: Bundle = .main) {
        self.settings = settings
        let info = bundle.infoDictionary ?? [:]
        feedURL = (info["MSUpdateFeedURL"] as? String).flatMap(URL.init(string:))
        publicKey = (info["MSUpdatePublicKey"] as? String) ?? ""
        currentVersion = SemanticVersion((info["CFBundleShortVersionString"] as? String) ?? "") ?? SemanticVersion(0, 0, 0)
        let describe = (info["MSGitDescribe"] as? String) ?? ""
        // A describe that is exactly the release tag says nothing worth showing.
        buildDescription = (describe.isEmpty || describe == "v\(currentVersion)") ? nil : describe
        installedBundle = bundle.bundleURL
        super.init()
        if let feedURL { checker = UpdateChecker(feedURL: feedURL) }
    }

    // MARK: - Scheduling

    /// Whether a background check is due. Pure so the throttle is a test rather
    /// than a thing observed over a day.
    static func shouldCheckInBackground(
        enabled: Bool,
        lastCheck: Date?,
        now: Date,
        interval: TimeInterval = UpdateController.backgroundInterval
    ) -> Bool {
        guard enabled else { return false }
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    func start() {
        // Self-tests never reach the network for this and never open a window.
        guard !SelfTest.isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            self?.checkInBackgroundIfDue()
        }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            self?.checkInBackgroundIfDue()
        }
        // The check must still fire while a menu is open or a window is being
        // dragged, so it goes on the common run-loop modes.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkInBackgroundIfDue() {
        guard Self.shouldCheckInBackground(
            enabled: settings.automaticallyChecksForUpdates,
            lastCheck: settings.lastUpdateCheck,
            now: Date()
        ) else { return }
        check(userInitiated: false)
    }

    // MARK: - Checking

    @objc func checkForUpdates(_ sender: Any?) {
        check(userInitiated: true)
    }

    func check(userInitiated: Bool, completion: (() -> Void)? = nil) {
        // A window already on screen is the answer to this question.
        if let window, window.isPresenting {
            if userInitiated { window.bringToFront() }
            completion?()
            return
        }
        guard !checkInFlight else {
            completion?()
            return
        }
        guard let checker else {
            if userInitiated {
                Self.showFailure(UpdateCheckFailure(
                    summary: "This build has no update feed.",
                    detail: "MSUpdateFeedURL is missing from Info.plist, so MailSpace does not know where to look."
                ))
            }
            completion?()
            return
        }

        checkInFlight = true
        checker.check(currentVersion: currentVersion) { [weak self] result in
            guard let self else { return }
            self.checkInFlight = false
            self.settings.lastUpdateCheck = Date()
            defer { completion?() }

            switch result {
            case .available(let release):
                self.present(release)
            case .upToDate(let current, _):
                guard userInitiated else { return }
                let alert = NSAlert()
                alert.messageText = "MailSpace \(current) is the latest version."
                alert.informativeText = self.buildDescription.map {
                    "This build is \($0)."
                } ?? "You are up to date."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .failed(let failure):
                guard userInitiated else {
                    Log.error("background update check failed: \(failure.detail)")
                    return
                }
                Self.showFailure(failure)
            }
        }
    }

    private static func showFailure(_ failure: UpdateCheckFailure) {
        Log.error("update check failed: \(failure.detail)")
        let alert = NSAlert()
        alert.messageText = failure.summary
        alert.informativeText = failure.detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Presenting

    private func present(_ release: UpdateRelease) {
        let controller = window ?? UpdateWindowController()
        window = controller
        controller.present(
            release: release,
            currentVersion: currentVersion,
            buildDescription: buildDescription,
            refusal: refusalToInstall(),
            install: { [weak self] progress, completion in
                self?.install(release, progress: progress, completion: completion)
            }
        )
    }

    /// Why this copy may not replace itself, if it may not.
    ///
    /// Both cases are real on this Mac: `make run` launches the bundle inside
    /// the repository, and a build made before `make update-key` carries no key
    /// to check a download against.
    private func refusalToInstall() -> String? {
        guard InstallLocation.isSelfUpdatable(bundle: installedBundle) else {
            return "This copy of MailSpace is running from \(installedBundle.deletingLastPathComponent().path), "
                + "so it will not replace itself. Install the update into /Applications by hand, "
                + "or move MailSpace there and check again."
        }
        guard !publicKey.isEmpty else {
            return UpdateSecurityError.noPublicKey.description
        }
        return nil
    }

    private func install(
        _ release: UpdateRelease,
        progress: @escaping (UpdateInstaller.Stage) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        // A fresh installer per attempt: it owns one URLSession and one progress
        // observation, and nothing about a failed attempt should survive into
        // the next one.
        let installer = UpdateInstaller(publicKey: publicKey)
        installer.install(release, replacing: installedBundle, progress: progress) { result in
            switch result {
            case .success(let installed):
                completion(.success(installed))
                UpdateInstaller.relaunch(installed)
            case .failure(let error):
                Log.error("update install failed: \(UpdateInstaller.describe(error))")
                completion(.failure(error))
            }
        }
    }

    // MARK: - For the Settings pane

    var lastCheckDescription: String {
        guard let last = settings.lastUpdateCheck else { return "Never checked." }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last checked \(formatter.string(from: last))."
    }

    var versionDescription: String {
        guard let buildDescription else { return "MailSpace \(currentVersion)" }
        return "MailSpace \(currentVersion) · \(buildDescription)"
    }
}
