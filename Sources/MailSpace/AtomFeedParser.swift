import Foundation

/// Reads the unread count out of Gmail's inbox atom feed.
///
/// The feed's `<fullcount>` element is the whole payload we need, so a scan
/// beats standing up an `XMLParser` delegate. Anything that is not a feed —
/// an empty body, a sign-in page, malformed XML — yields `nil`, which the
/// poller treats as "this account contributes nothing right now".
enum AtomFeedParser {
    private static let openTag = "<fullcount>"
    private static let closeTag = "</fullcount>"

    static func unreadCount(from feed: String) -> Int? {
        guard
            let open = feed.range(of: openTag),
            let close = feed.range(of: closeTag, range: open.upperBound..<feed.endIndex)
        else { return nil }

        let value = feed[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(value), count >= 0 else { return nil }
        return count
    }
}
