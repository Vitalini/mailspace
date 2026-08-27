import AppKit

/// Who owns `mailto:` on this Mac (G5, B3, B4).
///
/// The comparison is by **bundle path**, never by bundle identifier. Building
/// MailSpace registers another copy of `com.vitalii.MailSpace` with
/// LaunchServices every time it lands in a new directory, so an identifier
/// check happily reports "you are the default" while the handler is a build
/// inside a worktree that is about to be deleted — and every `mailto:` link
/// opens a copy the user never sees.
enum DefaultMailApp {
    enum State: Equatable {
        /// This exact bundle handles `mailto:`.
        case isMe
        /// Another build of MailSpace, at this path.
        case otherCopy(URL)
        /// A different mail app, at this path.
        case otherApp(URL)
        /// macOS names no handler at all.
        case unknown
    }

    /// Pure so the path comparison is a test rather than a machine's opinion.
    static func state(
        handler: URL?,
        me: URL,
        handlerIdentifier: String?,
        myIdentifier: String?
    ) -> State {
        guard let handler else { return .unknown }
        if normalized(handler) == normalized(me) { return .isMe }
        if let handlerIdentifier, let myIdentifier, handlerIdentifier == myIdentifier {
            return .otherCopy(handler)
        }
        return .otherApp(handler)
    }

    /// A bundle URL can arrive with a trailing slash, as a symlinked path, or
    /// with `/private` in front of it; all three name the same app.
    private static func normalized(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Reads the current handler. Free and prompt-free — no LaunchServices
    /// consent dialog, nothing written.
    static func current() -> State {
        guard let mailto = URL(string: "mailto:") else { return .unknown }
        let handler = NSWorkspace.shared.urlForApplication(toOpen: mailto)
        return state(
            handler: handler,
            me: Bundle.main.bundleURL,
            handlerIdentifier: handler.flatMap { Bundle(url: $0)?.bundleIdentifier },
            myIdentifier: Bundle.main.bundleIdentifier
        )
    }

    /// The status line in Settings ▸ General.
    static func statusText(_ state: State) -> String {
        switch state {
        case .isMe:
            return "MailSpace is your default mail app."
        case .otherCopy(let url):
            return "Another copy of MailSpace is the default — \(url.path)"
        case .otherApp(let url):
            return "\(appName(url)) is your default mail app."
        case .unknown:
            return "No app is set to open mailto: links."
        }
    }

    /// The File-menu item's title, which tells the same truth (B3).
    static func menuTitle(_ state: State) -> String {
        switch state {
        case .isMe: return "MailSpace Is Your Default Mail App"
        case .otherCopy: return "Another Copy of MailSpace Is the Default — Click to Fix"
        case .otherApp, .unknown: return "Make MailSpace the Default Mail App"
        }
    }

    /// Only the state that is already correct leaves nothing to click.
    static func canBecomeDefault(_ state: State) -> Bool {
        state != .isMe
    }

    static func appName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Raises macOS's own consent dialog — user-initiated, always. The error is
    /// handed back rather than logged: a declined dialog has to be visible
    /// where the click happened (B4).
    static func makeDefault(completion: @escaping (Error?) -> Void) {
        guard let mailto = URL(string: "mailto:"), let scheme = mailto.scheme else {
            completion(nil)
            return
        }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: scheme) { error in
            DispatchQueue.main.async { completion(error) }
        }
    }
}
