import Foundation

/// The Swift reference parser for Google Calendar's agenda HTML.
///
/// **This is not on the production path.** The parser that ships runs *inside*
/// the page (`AgendaScript`), because the response holds event titles and
/// nothing textual may cross the bridge (KTD-S14, S22). That leaves the shipped
/// parser untestable by `swift test`, so this is its executable spec: the same
/// rules written in Swift, run over the same hand-written fixtures, with
/// `MAILSPACE_SELFTEST=agenda` asserting the two agree on every one of them.
/// If they disagree, one is wrong and neither is trusted.
///
/// Every rule below exists because getting it wrong would show a *number*
/// rather than nothing, and a wrong countdown is worse than no countdown.
enum AgendaParser {
    /// What one agenda document says, in the shape the bridge carries.
    struct Result: Equatable {
        /// Seconds until the next event that has not started yet, or `nil` when
        /// today holds nothing more.
        let startsInSeconds: Int?
        /// How many events are still to start today.
        let remainingCount: Int
    }

    /// Parses an agenda response.
    ///
    /// Returns `nil` for *did not understand* — which the caller renders as
    /// nothing at all. The rules:
    ///
    /// - the document must carry `view-container`. A 200 is not an agenda: the
    ///   endpoint serves a marketing page with status 200 to a request it does
    ///   not like (KTD-S13).
    /// - a one-day window renders zero or one `.date-section`. Zero means today
    ///   is empty — an answer, not a failure. More than one means the window we
    ///   asked for is not the window we got.
    /// - the `.date` header must read as today, or the response is about some
    ///   other day and nothing it says applies.
    /// - a `.event` row whose `.event-time` cell is empty or absent is an
    ///   all-day event: it has no start to count down to, so it is skipped.
    /// - a time cell that does not parse fails the *whole* document rather than
    ///   that one row. A parser that skips what it cannot read is a parser that
    ///   counts down to the second meeting.
    static func parse(html: String, now: Date, timeZone: TimeZone) -> Result? {
        guard hasClassToken("view-container", in: html) else { return nil }

        let sections = elements(withClassToken: "date-section", in: html)
        if sections.isEmpty { return Result(startsInSeconds: nil, remainingCount: 0) }
        guard sections.count == 1, let section = sections.first else { return nil }

        guard let header = elements(withClassToken: "date", in: section).first,
              let day = parseHeaderDate(text(of: header))
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        guard day.year == today.year, day.month == today.month, day.day == today.day else { return nil }

        var starts: [Date] = []
        for row in elements(withClassToken: "event", in: section) {
            let cell = elements(withClassToken: "event-time", in: row).first
            let stamp = cell.map(text(of:)) ?? ""
            // All-day: no start time, so no countdown.
            if stamp.isEmpty { continue }
            guard let clock = parseClock(stamp) else { return nil }
            guard let start = calendar.date(from: DateComponents(
                year: day.year,
                month: day.month,
                day: day.day,
                hour: clock.hour,
                minute: clock.minute
            )) else { return nil }
            starts.append(start)
        }

        let remaining = starts.filter { $0 > now }.sorted()
        guard let next = remaining.first else { return Result(startsInSeconds: nil, remainingCount: 0) }
        return Result(
            startsInSeconds: Int(next.timeIntervalSince(now).rounded(.down)),
            remainingCount: remaining.count
        )
    }

    // MARK: - Time

    /// `3:30pm`, `3pm`, `12:05am`. Tolerant of case, of a space before the
    /// meridiem and of the dotted `p.m.` form; intolerant of anything else,
    /// because the shape on a real timed event is gate G-C2 and a time parser
    /// written against a guess is the definition of a wrong countdown.
    static func parseClock(_ text: String) -> (hour: Int, minute: Int)? {
        let pattern = "^([0-9]{1,2})(?::([0-9]{2}))?\\s*([ap])\\.?m\\.?$"
        guard let match = firstMatch(pattern, in: text.lowercased()) else { return nil }
        guard let hour12 = Int(match[1] ?? ""), (1...12).contains(hour12) else { return nil }
        let minute = Int(match[2] ?? "0") ?? 0
        guard (0...59).contains(minute) else { return nil }
        let isPM = (match[3] ?? "") == "p"
        let hour = isPM ? (hour12 == 12 ? 12 : hour12 + 12) : (hour12 == 12 ? 0 : hour12)
        return (hour, minute)
    }

    /// `Wed Aug 26, 2026`, and the same without the weekday or with the names
    /// spelled out. `hl=en` in the request is what makes this deterministic.
    static func parseHeaderDate(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let pattern = "^(?:[a-z]{3,9},?\\s+)?([a-z]{3,9})\\s+([0-9]{1,2}),?\\s+([0-9]{4})$"
        guard let match = firstMatch(pattern, in: text.lowercased()) else { return nil }
        guard let month = monthNumber(match[1] ?? ""),
              let day = Int(match[2] ?? ""), (1...31).contains(day),
              let year = Int(match[3] ?? "")
        else { return nil }
        return (year, month, day)
    }

    private static let months = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]

    private static func monthNumber(_ name: String) -> Int? {
        if let index = months.firstIndex(of: name) { return index + 1 }
        guard name.count == 3,
              let index = months.firstIndex(where: { $0.hasPrefix(name) })
        else { return nil }
        return index + 1
    }

    // MARK: - A very small HTML reader

    // Deliberately not a general HTML parser. It reads one flat, server-rendered
    // document whose class names this file names explicitly, and it exists only
    // so the reference implementation has no dependency — the package has none,
    // and this is a test oracle, not the shipping code path.

    /// Whether any element in `html` carries `token` in its `class` attribute.
    static func hasClassToken(_ token: String, in html: String) -> Bool {
        for match in matches("class\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", in: html) {
            let value = match[2] ?? match[3] ?? ""
            if value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .contains(where: { $0 == token }) {
                return true
            }
        }
        return false
    }

    /// The inner HTML of every element carrying `token`, outermost first and
    /// never overlapping — a match inside a match belongs to the outer one.
    static func elements(withClassToken token: String, in html: String) -> [String] {
        let characters = Array(html)
        var found: [String] = []
        var index = 0

        while index < characters.count {
            guard let open = nextTag(in: characters, from: index) else { break }
            guard !open.isClosing, !open.isSelfClosing, classTokens(open.attributes).contains(token) else {
                index = open.end
                continue
            }
            guard let close = matchingClose(of: open.name, in: characters, from: open.end) else {
                index = open.end
                continue
            }
            found.append(String(characters[open.end..<close.start]))
            index = close.end
        }
        return found
    }

    private struct Tag {
        let name: String
        let attributes: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let start: Int
        let end: Int
    }

    private static func nextTag(in characters: [Character], from start: Int) -> Tag? {
        var index = start
        while index < characters.count {
            guard characters[index] == "<" else {
                index += 1
                continue
            }
            var cursor = index + 1
            let isClosing = cursor < characters.count && characters[cursor] == "/"
            if isClosing { cursor += 1 }
            var name = ""
            while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber {
                name.append(characters[cursor])
                cursor += 1
            }
            guard !name.isEmpty else {
                index += 1
                continue
            }
            var attributes = ""
            var quote: Character?
            while cursor < characters.count {
                let character = characters[cursor]
                if let open = quote {
                    if character == open { quote = nil }
                    attributes.append(character)
                } else if character == "\"" || character == "'" {
                    quote = character
                    attributes.append(character)
                } else if character == ">" {
                    break
                } else {
                    attributes.append(character)
                }
                cursor += 1
            }
            guard cursor < characters.count else { return nil }
            return Tag(
                name: name.lowercased(),
                attributes: attributes,
                isClosing: isClosing,
                isSelfClosing: attributes.hasSuffix("/"),
                start: index,
                end: cursor + 1
            )
        }
        return nil
    }

    private static func matchingClose(of name: String, in characters: [Character], from start: Int) -> Tag? {
        var depth = 1
        var index = start
        while let tag = nextTag(in: characters, from: index) {
            if tag.name == name, !tag.isSelfClosing {
                depth += tag.isClosing ? -1 : 1
                if depth == 0 { return tag }
            }
            index = tag.end
        }
        return nil
    }

    private static func classTokens(_ attributes: String) -> Set<String> {
        guard let match = firstMatch("class\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", in: attributes)
        else { return [] }
        let value = match[2] ?? match[3] ?? ""
        return Set(value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init))
    }

    /// The visible text of a fragment: tags dropped, the handful of entities the
    /// renderer emits decoded, whitespace collapsed. The same normalisation the
    /// injected script gets for free from `textContent`.
    static func text(of html: String) -> String {
        var text = ""
        var insideTag = false
        for character in html {
            if character == "<" { insideTag = true; continue }
            if character == ">" { insideTag = false; text.append(" "); continue }
            if !insideTag { text.append(character) }
        }
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: - Regex helpers

    private static func firstMatch(_ pattern: String, in text: String) -> [Int: String]? {
        matches(pattern, in: text).first
    }

    private static func matches(_ pattern: String, in text: String) -> [[Int: String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: full).map { match in
            var groups: [Int: String] = [:]
            for group in 0..<match.numberOfRanges {
                guard let range = Range(match.range(at: group), in: text) else { continue }
                groups[group] = String(text[range])
            }
            return groups
        }
    }
}
