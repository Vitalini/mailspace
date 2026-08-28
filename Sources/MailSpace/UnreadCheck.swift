import Foundation

/// What one account's last unread check came back as.
///
/// The distinction the whole file exists for: `ok` and `signedOut` are answers
/// the app can stand behind, and every other case is *not a zero*. v1.1.0 had
/// exactly one path here — parse the body, `?? 0` — so "Gmail would not serve
/// this feed" and "your inbox is empty" arrived as the same number.
enum UnreadOutcome: Int, Equatable, CaseIterable {
    /// Gmail served the inbox feed and it carried a `<fullcount>`.
    case ok = 0
    /// The webview is not on Gmail — mid-navigation, mid-recycle, or a page
    /// that is neither the inbox nor the sign-in chain. Nothing to conclude.
    case notMail = 1
    /// Google itself says the session is gone: the tab is on the sign-in page,
    /// or the feed answered 401/403 from its own origin. A definite zero.
    case signedOut = 2
    /// A 4xx that is not an auth failure — the feed was refused. An answer, but
    /// not a count, and emphatically not a zero.
    case refused = 3
    /// A 2xx whose body carried no `<fullcount>`. Something came back; it was
    /// not a feed.
    case notUnderstood = 4
    /// A redirect was followed and the body came from a path that is not this
    /// account's inbox feed. The number in it counts something else.
    case wrongFeed = 5
    /// A thrown fetch, the 20s abort, or a 5xx. No answer at all.
    case noAnswer = 6
}

/// One account's last check, in the shape the Settings line reports it.
///
/// Numbers and shapes only: an HTTP status, a `Response.type`, a URL *path*,
/// and the count derived from the body. No part of a message can reach here —
/// the body is never carried out of `answer(from:)`.
struct UnreadFeedAnswer: Equatable {
    let outcome: UnreadOutcome
    /// The number this check settled on, or `nil` when it settled on none.
    ///
    /// `nil` is the whole point: the caller keeps the previous count and lets
    /// the ten-cycle bound retire it, exactly as a failed fetch already did.
    let count: Int?
    /// HTTP status; 0 for an opaque redirect, -1 when nothing was asked or
    /// nothing answered.
    let status: Int
    /// The `Response.type`, or the shape the poller decided from the URL.
    let type: String
    /// The path the body actually came from. Empty when nothing was served.
    let servedPath: String

    init(outcome: UnreadOutcome, count: Int?, status: Int, type: String, servedPath: String = "") {
        self.outcome = outcome
        self.count = count
        self.status = status
        self.type = type
        self.servedPath = servedPath
    }

    /// What the account's own line in Settings says. Never mail content, and
    /// never anything read out of the feed but the count itself.
    var text: String {
        switch outcome {
        case .ok:
            return "HTTP \(status) \(type), inbox feed — \(count ?? 0) unread"
        case .signedOut:
            return status > 0
                ? "HTTP \(status) — signed out, counted as 0"
                : "on the sign-in page — counted as 0"
        case .notMail:
            return "waiting for a signed-in Mail tab — no count"
        case .refused:
            return "HTTP \(status) — Gmail would not serve the feed, so no count"
        case .notUnderstood:
            return "HTTP \(status) \(type) — no count in the answer, so none taken"
        case .wrongFeed:
            let where_ = servedPath.isEmpty ? "an unknown path" : servedPath
            return "HTTP \(status) — answered from \(where_), not the inbox feed, so no count"
        case .noAnswer:
            return "no answer — the last count is kept"
        }
    }
}

/// What the Settings ▸ Accounts status line says about the unread counts, as a
/// value rather than a string built at the call site — the same shape, and the
/// same discipline, as `CalendarCountdownStatus`.
///
/// This is the diagnostic the owner runs himself: what was requested, what came
/// back, and the number derived, per account, without anyone going near his
/// session. It exists because the 999+ regression was invisible from inside the
/// code — nothing in `UnreadPoller` could tell an inflated `<fullcount>` from a
/// real one, and nothing on screen said which URL the number came from.
struct UnreadCheckReport: Equatable {
    struct Line: Equatable {
        let name: String
        let answer: UnreadFeedAnswer?

        var text: String { "\(name) — \(answer?.text ?? "not checked yet")" }
    }

    /// The path every account is asked for. One constant, reported verbatim, so
    /// the URL behind the number is never something you have to read the source
    /// to know.
    let requestedPath: String
    let checkedAt: Date?
    let lines: [Line]

    /// The three outcomes that mean the source cannot deliver what it promises,
    /// and so deserve the red the Calendar line already uses. A no-answer and a
    /// tab that is not on Gmail are ordinary.
    var isBroken: Bool {
        lines.contains { line in
            guard let outcome = line.answer?.outcome else { return false }
            return outcome == .refused || outcome == .notUnderstood || outcome == .wrongFeed
        }
    }

    var text: String {
        guard !lines.isEmpty else { return "No account has Mail switched on." }
        guard let checkedAt else { return "Not checked yet." }
        let head = "Asked \(requestedPath) at \(Self.time(checkedAt))"
        return ([head] + lines.map(\.text)).joined(separator: "\n")
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

/// The seam the Settings Accounts pane uses to reach the unread poller, so the
/// pane never holds the poller and never reaches for `NSApp.delegate`.
///
/// The defaults make the whole thing inert, which is what lets the settings
/// self-test build the window with no poller behind it.
struct UnreadCheckControls {
    var report: () -> UnreadCheckReport = {
        UnreadCheckReport(requestedPath: UnreadPoller.feedPath, checkedAt: nil, lines: [])
    }
    /// Check again now, and call back once every account has answered.
    var recheck: (@escaping () -> Void) -> Void = { done in done() }
}

/// Turns the feed script's payload into an answer.
///
/// Pure, and the only place a `<fullcount>` is allowed to become a count. Every
/// guard below is a case that used to arrive as a confident number.
enum UnreadCheck {
    static func answer(from payload: [String: Any]?, requestedPath: String) -> UnreadFeedAnswer {
        guard let payload else {
            return UnreadFeedAnswer(outcome: .noAnswer, count: nil, status: -1, type: "error")
        }

        let status = payload["status"] as? Int ?? -1
        let type = payload["type"] as? String ?? "error"
        let host = payload["host"] as? String ?? ""
        let served = payload["path"] as? String ?? ""
        let ok = payload["ok"] as? Bool ?? false

        func answer(_ outcome: UnreadOutcome, _ count: Int?) -> UnreadFeedAnswer {
            UnreadFeedAnswer(outcome: outcome, count: count, status: status, type: type, servedPath: served)
        }

        // The page moved off Gmail between the reading and the fetch.
        if type == "not-gmail" { return answer(.notMail, nil) }
        // A thrown fetch, the abort, an unfollowable redirect, or a 5xx.
        guard ok else { return answer(.noAnswer, nil) }
        // Google saying the session is gone, from its own origin. The one 4xx
        // that is a real zero.
        if status == 401 || status == 403 { return answer(.signedOut, 0) }
        // Every other 4xx: an answer, and not a count. This is the hole the
        // 999+ investigation named — `feed: ''` used to become a confident 0,
        // so "this feed does not exist" and "nothing unread" were the same
        // number.
        guard (200..<300).contains(status) else { return answer(.refused, nil) }
        // A redirect can land on a different feed, and a different feed counts
        // a different set. Never attribute that body to the inbox.
        guard UnreadPoller.servesTheInboxFeed(host: host, path: served) else {
            return answer(.wrongFeed, nil)
        }
        let feed = payload["feed"] as? String ?? ""
        guard let count = AtomFeedParser.unreadCount(from: feed) else {
            return answer(.notUnderstood, nil)
        }
        return answer(.ok, count)
    }
}
