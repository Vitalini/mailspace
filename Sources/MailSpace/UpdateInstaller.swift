import AppKit
import Foundation

/// Downloads a release, proves it is genuine, and swaps it in.
///
/// Order is the whole design. Nothing touches the installed app until the
/// download has passed both checks and the staged bundle has said which app and
/// which version it is; and the swap itself is `replaceItemAt`, which is atomic
/// and leaves the old bundle in place if anything goes wrong.
///
/// No privileged helper, no separate installer process: the app is unsandboxed
/// and both `/Applications` and `~/Applications` are writable by this user, so
/// the replacement never raises an authentication prompt. Replacing a *running*
/// bundle is safe — the running image is held by inode and keeps working until
/// the process quits, which is the next thing that happens.
final class UpdateInstaller: NSObject {
    enum Stage {
        case downloading(fraction: Double?)
        case verifying
        case installing

        var label: String {
            switch self {
            case .downloading: return "Downloading…"
            case .verifying: return "Verifying the download…"
            case .installing: return "Installing…"
            }
        }
    }

    enum InstallError: Error, CustomStringConvertible {
        case download(String)
        case unpack(String)
        case noAppInArchive
        case cannotStage(String)
        case cannotReplace(String)

        var description: String {
            switch self {
            case .download(let detail): return "The download failed: \(detail)"
            case .unpack(let detail): return "The download could not be unpacked: \(detail)"
            case .noAppInArchive: return "The download contains no MailSpace.app."
            case .cannotStage(let detail): return "MailSpace could not stage the update: \(detail)"
            case .cannotReplace(let detail): return "MailSpace could not replace the installed app: \(detail)"
            }
        }
    }

    private let publicKey: String
    private let session: URLSession
    private var progressObservation: NSKeyValueObservation?

    init(publicKey: String) {
        self.publicKey = publicKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
        super.init()
    }

    /// - Parameter installedBundle: the bundle to replace, which is this app.
    func install(
        _ release: UpdateRelease,
        replacing installedBundle: URL,
        progress: @escaping (Stage) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let finish: (Result<URL, Error>) -> Void = { result in
            DispatchQueue.main.async {
                self.progressObservation = nil
                completion(result)
            }
        }

        guard !publicKey.isEmpty else {
            finish(.failure(UpdateSecurityError.noPublicKey))
            return
        }
        guard let signatureURL = release.signatureURL else {
            finish(.failure(UpdateSecurityError.noSignatureAsset))
            return
        }

        progress(.downloading(fraction: nil))
        // URLSession, never a WKWebView download: WebKit stamps
        // com.apple.quarantine on what it saves, and a quarantined replacement
        // would re-arm Gatekeeper on a bundle that is signed by a certificate
        // Gatekeeper does not know.
        let task = session.downloadTask(with: release.assetURL) { [weak self] location, response, error in
            guard let self else { return }
            if let error {
                finish(.failure(InstallError.download(error.localizedDescription)))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                finish(.failure(InstallError.download("HTTP \(http.statusCode) from \(release.assetURL.absoluteString)")))
                return
            }
            guard let location, let payload = try? Data(contentsOf: location) else {
                finish(.failure(InstallError.download("nothing was written to disk")))
                return
            }

            DispatchQueue.main.async { progress(.verifying) }
            self.fetchSignature(signatureURL) { signature in
                guard let signature else {
                    finish(.failure(InstallError.download("the detached signature could not be downloaded")))
                    return
                }
                guard UpdateSecurity.verifyDetachedSignature(
                    of: payload,
                    base64Signature: signature,
                    base64PublicKey: self.publicKey
                ) else {
                    finish(.failure(UpdateSecurityError.badSignature))
                    return
                }

                DispatchQueue.main.async { progress(.installing) }
                DispatchQueue.global(qos: .userInitiated).async {
                    finish(Result { try Self.stageAndSwap(payload: payload, release: release, installedBundle: installedBundle) })
                }
            }
        }
        // KVO on the task's own Progress rather than a download delegate: a task
        // created with a completion handler is not guaranteed to call the
        // delegate's progress methods, and a progress bar that never moves on a
        // 15 MB download reads as a hang.
        progressObservation = task.progress.observe(\.fractionCompleted) { value, _ in
            DispatchQueue.main.async { progress(.downloading(fraction: value.fractionCompleted)) }
        }
        task.resume()
    }

    private func fetchSignature(_ url: URL, completion: @escaping (String?) -> Void) {
        session.dataTask(with: url) { data, response, _ in
            guard
                let data,
                let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                let text = String(data: data, encoding: .utf8)
            else {
                completion(nil)
                return
            }
            completion(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }.resume()
    }

    // MARK: - The swap

    private static func stageAndSwap(payload: Data, release: UpdateRelease, installedBundle: URL) throws -> URL {
        let parent = installedBundle.deletingLastPathComponent()
        // Staged beside the target, so the replacement is a rename on one volume
        // rather than a copy across two.
        let staging = parent.appendingPathComponent(".MailSpace-update-\(UUID().uuidString.prefix(8))")
        let archive = staging.appendingPathComponent("MailSpace.zip")

        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try payload.write(to: archive)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw InstallError.cannotStage(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        // ditto, matching what the release script used to create the archive:
        // it is what Archive Utility itself runs, and it preserves the extended
        // attributes and symlinks a plain unzip would flatten.
        let unpacked = staging.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], as: InstallError.unpack)

        let contents = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)) ?? []
        guard let staged = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.noAppInArchive
        }

        // Belt and braces: nothing in this path should have set quarantine, and
        // a quarantined self-signed app does not launch at all.
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path], as: InstallError.unpack)

        try UpdateSecurity.verifyCodeSignature(of: staged)
        try UpdateSecurity.verifyIdentity(of: staged, expecting: release.version)

        do {
            // Atomic, and it keeps the old bundle under `backupItemName` until
            // the replacement has succeeded — a failure here leaves the working
            // app exactly where it was.
            let replaced = try FileManager.default.replaceItemAt(
                installedBundle,
                withItemAt: staged,
                backupItemName: installedBundle.lastPathComponent + ".old",
                options: []
            )
            return replaced ?? installedBundle
        } catch {
            throw InstallError.cannotReplace(error.localizedDescription)
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], as wrap: (String) -> Error) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            throw wrap("\(tool) would not start: \(error.localizedDescription)")
        }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw wrap("\(tool) exited \(process.terminationStatus)\(text.isEmpty ? "" : ": \(text)")")
        }
        return text
    }

    /// A sentence for the window and the alert. The updater's own errors already
    /// read as sentences; anything else falls back to what the system says.
    static func describe(_ error: Error) -> String {
        switch error {
        case let error as InstallError: return error.description
        case let error as UpdateSecurityError: return error.description
        default: return error.localizedDescription
        }
    }

    // MARK: - Relaunch

    /// Starts the freshly installed copy and quits this one.
    ///
    /// `createsNewApplicationInstance` is required: without it macOS sees an app
    /// with this bundle identifier already running and simply activates the old
    /// process, which is the copy being replaced.
    static func relaunch(_ bundle: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    Log.error("the updated app would not launch: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
        }
    }
}
