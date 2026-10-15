import Foundation

/// The 1 s wait before a Calendar notification is posted (KTD19, R29).
///
/// The lookup and the deadline race; whichever finishes first settles the
/// run, and the other is ignored. The decision lives here, with the lookup and
/// the clock injected, so a test drives it without WebKit or real time. Only
/// Calendar notifications wait; Mail and session-health posts stay synchronous.
final class JoinLookup {
    /// How a Calendar notification is posted, and what the R32 line says.
    struct Outcome: Equatable {
        /// An allow-listed meeting URL, or `nil` for no Join button.
        let url: String?
        let source: JoinSource
        /// Distinct allow-listed links the page lookup found.
        let links: Int
    }

    static let deadline: TimeInterval = 1

    private let post: (Outcome) -> Void
    private var settled = false

    private init(post: @escaping (Outcome) -> Void) {
        self.post = post
    }

    /// The answer that needs no page lookup: the reminder's own `data` held
    /// one allow-listed link, or there is no webview to ask. `nil` means run
    /// the lookup.
    static func immediate(dataLink: String?, hasWebView: Bool) -> Outcome? {
        if let dataLink, MeetingLink.isAllowed(dataLink) {
            return Outcome(url: dataLink, source: .data, links: 0)
        }
        guard hasWebView else { return Outcome(url: nil, source: .noWebView, links: 0) }
        return nil
    }

    /// What a lookup answer becomes. A URL the allow-list rejects is no URL;
    /// `nil` means the script failed.
    static func outcome(for answer: MeetingLink.Match?) -> Outcome {
        guard let answer else { return Outcome(url: nil, source: .none, links: 0) }
        guard let url = answer.url, MeetingLink.isAllowed(url) else {
            return Outcome(url: nil, source: .none, links: answer.links)
        }
        return Outcome(url: url, source: answer.fallback ? .pageFallback : .page, links: answer.links)
    }

    /// Starts the lookup and the deadline. `post` is called exactly once.
    ///
    /// - Parameters:
    ///   - lookup: asks the page; calls back with its answer, or `nil` on failure.
    ///   - schedule: runs a closure after a delay (`DispatchQueue.main` in the app).
    static func start(
        deadline: TimeInterval = JoinLookup.deadline,
        lookup: (@escaping (MeetingLink.Match?) -> Void) -> Void,
        schedule: (TimeInterval, @escaping () -> Void) -> Void,
        post: @escaping (Outcome) -> Void
    ) {
        let run = JoinLookup(post: post)
        schedule(deadline) {
            run.settle(Outcome(url: nil, source: .timeout, links: 0))
        }
        lookup { answer in
            run.settle(outcome(for: answer))
        }
    }

    private func settle(_ outcome: Outcome) {
        guard !settled else { return }
        settled = true
        post(outcome)
    }
}
