import Foundation

/// The wait before a Calendar notification is posted (KTD19, R29).
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

    /// What the page lookup reported.
    enum Answer: Equatable {
        /// The script ran and answered.
        case match(MeetingLink.Match)
        /// The script threw, or answered something that is not its payload.
        case failed
        /// The Calendar webview was gone before it could be asked.
        case noWebView
    }

    /// The inline event list answers in milliseconds; the fetch fallback takes
    /// 0.7–1.4 s on a warm session, so the whole page path gets 3 s.
    static let deadline: TimeInterval = 3

    /// When the page script gives up its fetch: half a second before the
    /// deadline, so its own answer still arrives in time.
    static var scriptAbortMilliseconds: Int { Int((deadline - 0.5) * 1000) }

    private let post: (Outcome) -> Void
    private var settled = false

    private init(post: @escaping (Outcome) -> Void) {
        self.post = post
    }

    /// The answer that needs no page lookup: the reminder's own `data` held
    /// one allow-listed link. `nil` means run the lookup.
    static func immediate(dataLink: String?) -> Outcome? {
        guard let dataLink, MeetingLink.isAllowed(dataLink) else { return nil }
        return Outcome(url: dataLink, source: .data, links: 0)
    }

    /// What a lookup answer becomes. A URL the allow-list rejects is no URL.
    static func outcome(for answer: Answer) -> Outcome {
        switch answer {
        case .failed:
            return Outcome(url: nil, source: .error, links: 0)
        case .noWebView:
            return Outcome(url: nil, source: .noWebView, links: 0)
        case .match(let match):
            guard let url = match.url, MeetingLink.isAllowed(url) else {
                return Outcome(url: nil, source: .none, links: match.links)
            }
            return Outcome(url: url, source: match.fetched ? .fetch : .page, links: match.links)
        }
    }

    /// Starts the lookup and the deadline. `post` is called exactly once.
    ///
    /// - Parameters:
    ///   - lookup: asks the page; calls back with its answer.
    ///   - schedule: runs a closure after a delay (`DispatchQueue.main` in the app).
    static func start(
        deadline: TimeInterval = JoinLookup.deadline,
        lookup: (@escaping (Answer) -> Void) -> Void,
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
