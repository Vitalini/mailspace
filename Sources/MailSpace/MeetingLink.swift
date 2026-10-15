import Foundation

/// Which meeting a Calendar reminder is for, and whether a link may be opened.
///
/// **This is the reference, not the production lookup.** The lookup that ships
/// runs inside the Calendar page (`MeetingLinkScript`), because the page holds
/// event titles and its event list, and only one allow-listed URL may cross
/// back. This file is the same rules in Swift, run over the same hand-written
/// fixtures, and `MAILSPACE_SELFTEST=meetinglink` asserts the two agree on
/// every one. The allow-list half *is* on the production path: the bridge and
/// the Join handler re-check every URL with it.
///
/// The lookup:
///
/// 1. **The event.** A text node whose normalised text equals the title
///    exactly marks its nearest `[data-eventid]` ancestor. Containment is not a
///    match. The marked chips must name exactly one event id (trailing `=`
///    ignored); none, or two different ids, is no link. Week-view chips do not
///    carry the meeting link, so nothing inside a chip is read as a link.
/// 2. **The record.** The page's inline `<script>` holds a JSON event list for
///    the visible week. A record is the innermost array or object with a
///    direct string member holding `/calendar/event?eid=<that id>`. No field
///    position is relied on.
/// 3. **The link.** Every string inside the record is scanned for link-shaped
///    text; the allow-listed ones are collected.
/// 4. **Fetch, only when no record was found.** The event's own page,
///    `/calendar/event?eid=<id>`, carries the same list for the event's week,
///    and steps 2–3 run on it. A failed or signed-out fetch is no link.
///
/// The answer is a URL only when exactly one distinct allow-listed URL was
/// collected. Two is ambiguity, and ambiguity is no button.
enum MeetingLink {
    /// What one lookup found. `url` is set only when `links == 1`.
    struct Match: Equatable {
        let url: String?
        /// Distinct allow-listed URLs in the event's record.
        let links: Int
        /// Whether the record came from the fetched event page.
        let fetched: Bool

        static let nothing = Match(url: nil, links: 0, fetched: false)
    }

    /// The attribute Google Calendar puts on an event chip.
    static let eventAttribute = "data-eventid"

    /// What an event record's own URL contains, followed by the event id.
    static let eventURLMarker = "/calendar/event?eid="

    /// The event page the fetch fallback asks for, relative to the page origin.
    static let eventPagePath = "/calendar/event?eid="

    /// An event id the fetch may put in a URL: base64url, optional padding.
    static let fetchableEventIdPattern = "^[A-Za-z0-9_-]+=*$"

    // MARK: - Allow-list (R28)

    /// The allow-list, as patterns the page script carries verbatim. Scheme
    /// `https`, lowercase, exact host or dot-suffix (never substring):
    /// - `meet.google.com`, path exactly one meeting code, query allowed;
    /// - `zoom.us` or `*.zoom.us`, path `/j/<digits>`, query allowed;
    /// - `teams.microsoft.com`, path under `/l/meetup-join/` with no segment
    ///   that starts with a dot, no `%2e` and no backslash, so the path cannot
    ///   be normalised out of `/l/meetup-join/`; query allowed.
    ///
    /// `MeetingLinkFixtures.allowedURLs` and `refusedURLs` are the one table
    /// both twins and the unit tests check these against.
    static let allowPatterns = [
        "^https://meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(\\?[^\\s#\"'<>]*)?$",
        "^https://([a-z0-9-]+\\.)*zoom\\.us/j/[0-9]+(\\?[^\\s#\"'<>]*)?$",
        "^https://teams\\.microsoft\\.com/l/meetup-join/(?!\\.)(?![^?]*(/\\.|%2[eE]))"
            + "[^\\s#\"'<>?\\\\]+(\\?[^\\s#\"'<>\\\\]*)?$"
    ]

    private static let allowExpressions: [NSRegularExpression] = allowPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// Whether `url` may be attached to a notification and opened.
    static func isAllowed(_ url: String) -> Bool {
        let range = NSRange(url.startIndex..<url.endIndex, in: url)
        return allowExpressions.contains { expression in
            // The whole string, not `$`: ICU's `$` also matches before a final
            // newline, and the page script's does not.
            expression.firstMatch(in: url, range: range)?.range == range
        }
    }

    // MARK: - Lookup (R27, KTD17)

    /// Link-shaped text: an `https://` run up to whitespace or a quote, with
    /// trailing sentence punctuation dropped.
    static let textLinkPattern = "https://[^\\s<>\"']+"
    static let trailingPunctuation = ".,;:!?)]}"

    private static let textLinkExpression = try? NSRegularExpression(pattern: textLinkPattern)
    private static let fetchableExpression = try? NSRegularExpression(pattern: fetchableEventIdPattern)

    /// - Parameter fetch: the event page for an event id, or `nil` when the
    ///   fetch failed or left the Calendar origin. Called at most once.
    static func find(html: String, title: String, fetch: (String) -> String?) -> Match {
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return .nothing }
        let root = Document.parse(html)
        guard let eventId = eventId(in: root, title: wanted) else { return .nothing }
        let key = normalizeEventId(eventId)

        if let links = recordLinks(in: root, eventId: key) {
            return decide(links, fetched: false)
        }
        guard isFetchable(eventId) else { return .nothing }
        guard let page = fetch(eventId), let links = recordLinks(in: Document.parse(page), eventId: key) else {
            return Match(url: nil, links: 0, fetched: true)
        }
        return decide(links, fetched: true)
    }

    /// Whitespace runs (including no-break spaces) collapsed, then trimmed.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// An event id without its base64 padding, the form the record URL and the
    /// chip attribute share.
    static func normalizeEventId(_ id: String) -> String {
        var id = id
        while id.hasSuffix("=") { id.removeLast() }
        return id
    }

    static func isFetchable(_ id: String) -> Bool {
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        return fetchableExpression?.firstMatch(in: id, range: range)?.range == range
    }

    /// The one event the title names, as its chip spells the id; `nil` when no
    /// chip carries the title or two different events do.
    private static func eventId(in root: Element, title: String) -> String? {
        var ids: [String] = []
        for text in root.textNodes() where normalize(text.data) == title {
            guard let id = text.parent?.closest(where: { $0.attributes[eventAttribute] != nil })?
                .attributes[eventAttribute], !normalizeEventId(id).isEmpty else { continue }
            if !ids.contains(where: { normalizeEventId($0) == normalizeEventId(id) }) { ids.append(id) }
        }
        return ids.count == 1 ? ids[0] : nil
    }

    /// The distinct allow-listed links of every record for `eventId` in the
    /// document's scripts, or `nil` when no script holds such a record.
    private static func recordLinks(in root: Element, eventId: String) -> [String]? {
        var records: [Any] = []
        for script in [root] + root.elements() where script.name == "script" {
            guard let body = script.rawText, body.contains(eventURLMarker),
                  let data = body.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            collectRecords(in: json, eventId: eventId, into: &records)
        }
        guard !records.isEmpty else { return nil }
        var strings: [String] = []
        for record in records { collectStrings(in: record, into: &strings) }
        return distinct(strings.flatMap(links(inText:)))
    }

    /// Whether `string` is an event URL for `eventId`.
    static func isEventURL(_ string: String, for eventId: String) -> Bool {
        guard let marker = string.range(of: eventURLMarker) else { return false }
        let rest = string[marker.upperBound...]
        let raw = String(rest.prefix { $0 != "&" && $0 != "#" })
        let decoded = raw.removingPercentEncoding ?? raw
        return normalizeEventId(decoded) == eventId
    }

    private static func collectRecords(in value: Any, eventId: String, into records: inout [Any]) {
        let members: [Any]
        if let array = value as? [Any] {
            members = array
        } else if let object = value as? [String: Any] {
            members = Array(object.values)
        } else {
            return
        }
        if members.contains(where: { ($0 as? String).map { isEventURL($0, for: eventId) } ?? false }) {
            records.append(value)
            return
        }
        for member in members { collectRecords(in: member, eventId: eventId, into: &records) }
    }

    private static func collectStrings(in value: Any, into strings: inout [String]) {
        if let string = value as? String {
            strings.append(string)
        } else if let array = value as? [Any] {
            for member in array { collectStrings(in: member, into: &strings) }
        } else if let object = value as? [String: Any] {
            for member in object.values { collectStrings(in: member, into: &strings) }
        }
    }

    /// Allow-listed link-shaped runs in one string.
    private static func links(inText text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var candidates: [String] = []
        for match in textLinkExpression?.matches(in: text, range: range) ?? [] {
            guard let found = Range(match.range, in: text) else { continue }
            var candidate = String(text[found])
            while let last = candidate.last, trailingPunctuation.contains(last) { candidate.removeLast() }
            candidates.append(candidate)
        }
        return candidates.filter(isAllowed)
    }

    private static func decide(_ links: [String], fetched: Bool) -> Match {
        Match(url: links.count == 1 ? links[0] : nil, links: links.count, fetched: fetched)
    }

    private static func distinct(_ urls: [String]) -> [String] {
        var seen: [String] = []
        for url in urls where !seen.contains(url) { seen.append(url) }
        return seen
    }

    // MARK: - A very small DOM

    // Deliberately not a general HTML parser: it reads the hand-written
    // fixtures in `MeetingLinkFixtures`, so the reference implementation has no
    // dependency. Script and style bodies are kept raw on their element, never
    // as text nodes, as the page script skips their text.

    final class Element {
        let name: String
        let attributes: [String: String]
        weak var parent: Element?
        var children: [Node] = []
        /// A `script` or `style` body, verbatim (no entity decoding).
        var rawText: String?

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        /// Self first, then ancestors, like `Element.closest`.
        func closest(where predicate: (Element) -> Bool) -> Element? {
            var current: Element? = self
            while let element = current {
                if predicate(element) { return element }
                current = element.parent
            }
            return nil
        }

        /// Descendant elements in document order, not including self.
        func elements() -> [Element] {
            children.flatMap { child -> [Element] in
                guard case .element(let element) = child else { return [] }
                return [element] + element.elements()
            }
        }

        /// Descendant text nodes in document order.
        func textNodes() -> [Text] {
            children.flatMap { child -> [Text] in
                switch child {
                case .text(let text): return [text]
                case .element(let element): return element.textNodes()
                }
            }
        }
    }

    final class Text {
        let data: String
        weak var parent: Element?

        init(data: String) {
            self.data = data
        }
    }

    enum Node {
        case element(Element)
        case text(Text)
    }

    enum Document {
        private static let voidElements: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"
        ]
        private static let rawTextElements: Set<String> = ["script", "style"]

        static func parse(_ html: String) -> Element {
            let root = Element(name: "#root", attributes: [:])
            var stack: [Element] = [root]
            let characters = Array(html)
            var index = 0
            var text = ""

            func flushText() {
                guard !text.isEmpty else { return }
                let node = Text(data: decode(text))
                node.parent = stack.last
                stack.last?.children.append(.text(node))
                text = ""
            }

            while index < characters.count {
                let character = characters[index]
                guard character == "<" else {
                    text.append(character)
                    index += 1
                    continue
                }
                if starts(with: "<!--", in: characters, at: index) {
                    flushText()
                    index = position(of: "-->", in: characters, from: index + 4).map { $0 + 3 } ?? characters.count
                    continue
                }
                if starts(with: "<!", in: characters, at: index) {
                    flushText()
                    index = position(of: ">", in: characters, from: index).map { $0 + 1 } ?? characters.count
                    continue
                }
                let isClosing = index + 1 < characters.count && characters[index + 1] == "/"
                var cursor = index + (isClosing ? 2 : 1)
                var name = ""
                while cursor < characters.count, characters[cursor].isLetter || characters[cursor].isNumber {
                    name.append(characters[cursor])
                    cursor += 1
                }
                guard !name.isEmpty else {
                    text.append(character)
                    index += 1
                    continue
                }
                flushText()
                name = name.lowercased()
                let (attributes, selfClosing, end) = readAttributes(characters, from: cursor)
                index = end

                if isClosing {
                    if let match = stack.lastIndex(where: { $0.name == name }), match > 0 {
                        stack.removeSubrange(match...)
                    }
                    continue
                }

                let element = Element(name: name, attributes: attributes)
                element.parent = stack.last
                stack.last?.children.append(.element(element))
                if rawTextElements.contains(name) {
                    // The body is not markup: kept raw, never a text node.
                    let close = position(of: "</\(name)", in: characters, from: index) ?? characters.count
                    element.rawText = String(characters[index..<close])
                    index = close
                    continue
                }
                if !selfClosing, !voidElements.contains(name) {
                    stack.append(element)
                }
            }
            flushText()
            return root
        }

        private static func readAttributes(
            _ characters: [Character],
            from start: Int
        ) -> (attributes: [String: String], selfClosing: Bool, end: Int) {
            var attributes: [String: String] = [:]
            var index = start
            var selfClosing = false
            while index < characters.count {
                let character = characters[index]
                if character == ">" { return (attributes, selfClosing, index + 1) }
                if character == "/" {
                    selfClosing = true
                    index += 1
                    continue
                }
                if character.isWhitespace {
                    index += 1
                    continue
                }
                selfClosing = false
                var name = ""
                while index < characters.count,
                      !characters[index].isWhitespace,
                      !["=", ">", "/"].contains(characters[index]) {
                    name.append(characters[index])
                    index += 1
                }
                var value = ""
                if index < characters.count, characters[index] == "=" {
                    index += 1
                    if index < characters.count, characters[index] == "\"" || characters[index] == "'" {
                        let quote = characters[index]
                        index += 1
                        while index < characters.count, characters[index] != quote {
                            value.append(characters[index])
                            index += 1
                        }
                        index += 1
                    } else {
                        while index < characters.count, !characters[index].isWhitespace, characters[index] != ">" {
                            value.append(characters[index])
                            index += 1
                        }
                    }
                }
                let key = name.lowercased()
                if attributes[key] == nil { attributes[key] = decode(value) }
            }
            return (attributes, selfClosing, characters.count)
        }

        private static func starts(with prefix: String, in characters: [Character], at index: Int) -> Bool {
            let prefix = Array(prefix)
            guard index + prefix.count <= characters.count else { return false }
            return Array(characters[index..<index + prefix.count]).map { $0.lowercased() } == prefix.map { $0.lowercased() }
        }

        private static func position(of needle: String, in characters: [Character], from start: Int) -> Int? {
            let needle = Array(needle)
            guard needle.count <= characters.count else { return nil }
            var index = start
            while index + needle.count <= characters.count {
                if starts(with: String(needle), in: characters, at: index) { return index }
                index += 1
            }
            return nil
        }

        /// The handful of entities the fixtures use, plus numeric ones.
        static func decode(_ text: String) -> String {
            guard text.contains("&") else { return text }
            var output = ""
            var index = text.startIndex
            while index < text.endIndex {
                guard text[index] == "&", let semicolon = text[index...].firstIndex(of: ";") else {
                    output.append(text[index])
                    index = text.index(after: index)
                    continue
                }
                let entity = String(text[text.index(after: index)..<semicolon])
                if let decoded = decodeEntity(entity) {
                    output.append(decoded)
                    index = text.index(after: semicolon)
                } else {
                    output.append("&")
                    index = text.index(after: index)
                }
            }
            return output
        }

        private static func decodeEntity(_ entity: String) -> String? {
            switch entity {
            case "amp": return "&"
            case "lt": return "<"
            case "gt": return ">"
            case "quot": return "\""
            case "apos", "#39": return "'"
            case "nbsp": return "\u{00a0}"
            default:
                let scalar: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst())
                } else {
                    scalar = nil
                }
                return scalar.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            }
        }
    }
}
