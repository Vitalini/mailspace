import Foundation

/// Which meeting a Calendar reminder is for, and whether a link may be opened.
///
/// **This is the reference, not the production lookup.** The lookup that ships
/// runs inside the Calendar page (`MeetingLinkScript`), because the page holds
/// event titles and only one allow-listed URL may cross back. This file is the
/// same rules in Swift, run over the same hand-written fixtures, and
/// `MAILSPACE_SELFTEST=meetinglink` asserts the two agree on every one. The
/// allow-list half *is* on the production path: the bridge and the Join
/// handler re-check every URL with it.
///
/// The lookup, in two tiers:
///
/// 1. **Event containers.** A text node whose normalised text equals the title
///    exactly marks its nearest `[data-eventid]` ancestor. The allow-listed
///    links inside the marked containers are collected. Containment is not a
///    match, and nothing outside a container counts in this tier.
/// 2. **Fallback, only when tier 1 collected no link.** A title-bearing
///    element outside every event container — a text node's parent, or an
///    element whose `aria-label` equals the title — that is not hidden
///    (`hidden`, `aria-hidden="true"`) looks for links in itself and then in at
///    most `fallbackDepth` ancestors. The walk never reaches `body`, and it
///    stops at any scope that holds an event container, so a link can never be
///    borrowed from a neighbouring event.
///
/// Either tier answers a URL only when it collected exactly one distinct
/// allow-listed URL. Two is ambiguity, and ambiguity is no button.
enum MeetingLink {
    /// What one lookup found. `url` is set only when `links == 1`.
    struct Match: Equatable {
        let url: String?
        /// Distinct allow-listed URLs the deciding tier collected.
        let links: Int
        /// Whether tier 2 decided.
        let fallback: Bool

        static let nothing = Match(url: nil, links: 0, fallback: false)
    }

    /// Ancestors tier 2 may climb above the title-bearing element.
    static let fallbackDepth = 3

    /// The attribute Google Calendar puts on an event element.
    static let eventAttribute = "data-eventid"

    // MARK: - Allow-list (R28)

    /// The allow-list, as patterns the page script carries verbatim. Scheme
    /// `https`, lowercase, exact host or dot-suffix (never substring):
    /// - `meet.google.com`, path exactly one meeting code, query allowed;
    /// - `zoom.us` or `*.zoom.us`, path `/j/<digits>`, query allowed;
    /// - `teams.microsoft.com`, path under `/l/meetup-join/`.
    static let allowPatterns = [
        "^https://meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(\\?[^\\s#\"'<>]*)?$",
        "^https://([a-z0-9-]+\\.)*zoom\\.us/j/[0-9]+(\\?[^\\s#\"'<>]*)?$",
        "^https://teams\\.microsoft\\.com/l/meetup-join/[^\\s#\"'<>]+$"
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

    static func find(html: String, title: String) -> Match {
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return .nothing }
        let root = Document.parse(html)

        // Tier 1.
        var events: [Element] = []
        for text in root.textNodes() where normalize(text.data) == wanted {
            guard let event = text.parent?.closest(where: { $0.attributes[eventAttribute] != nil }) else { continue }
            if !events.contains(where: { $0 === event }) { events.append(event) }
        }
        let tierOne = distinct(events.flatMap(links(in:)))
        if !tierOne.isEmpty {
            return Match(url: tierOne.count == 1 ? tierOne[0] : nil, links: tierOne.count, fallback: false)
        }

        // Tier 2.
        var bearers: [Element] = []
        for text in root.textNodes() where normalize(text.data) == wanted {
            if let parent = text.parent, !bearers.contains(where: { $0 === parent }) { bearers.append(parent) }
        }
        for element in root.elements() where normalize(element.attributes["aria-label"] ?? "") == wanted {
            if !bearers.contains(where: { $0 === element }) { bearers.append(element) }
        }
        var found: [String] = []
        for bearer in bearers {
            guard bearer.closest(where: { $0.attributes[eventAttribute] != nil }) == nil else { continue }
            guard bearer.closest(where: isHidden) == nil else { continue }
            var scope: Element? = bearer
            var climbed = 0
            while let current = scope, climbed <= fallbackDepth, !isDocumentLevel(current) {
                if current.elements().contains(where: { $0.attributes[eventAttribute] != nil }) { break }
                let here = links(in: current)
                if !here.isEmpty {
                    found += here
                    break
                }
                scope = current.parent
                climbed += 1
            }
        }
        let tierTwo = distinct(found)
        guard !tierTwo.isEmpty else { return .nothing }
        return Match(url: tierTwo.count == 1 ? tierTwo[0] : nil, links: tierTwo.count, fallback: true)
    }

    /// Whitespace runs (including no-break spaces) collapsed, then trimmed.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func isHidden(_ element: Element) -> Bool {
        element.attributes["hidden"] != nil || element.attributes["aria-hidden"] == "true"
    }

    private static func isDocumentLevel(_ element: Element) -> Bool {
        ["html", "head", "body", "#root"].contains(element.name)
    }

    /// Allow-listed anchor targets and link-shaped text under `element`.
    private static func links(in element: Element) -> [String] {
        var candidates: [String] = []
        for anchor in [element] + element.elements() where anchor.name == "a" {
            if let href = anchor.attributes["href"] {
                candidates.append(href.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let expression = try? NSRegularExpression(pattern: textLinkPattern)
        for text in element.textNodes() {
            let range = NSRange(text.data.startIndex..<text.data.endIndex, in: text.data)
            for match in expression?.matches(in: text.data, range: range) ?? [] {
                guard let found = Range(match.range, in: text.data) else { continue }
                var candidate = String(text.data[found])
                while let last = candidate.last, trailingPunctuation.contains(last) { candidate.removeLast() }
                candidates.append(candidate)
            }
        }
        return candidates.filter(isAllowed)
    }

    private static func distinct(_ urls: [String]) -> [String] {
        var seen: [String] = []
        for url in urls where !seen.contains(url) { seen.append(url) }
        return seen
    }

    // MARK: - A very small DOM

    // Deliberately not a general HTML parser: it reads the hand-written
    // fixtures in `MeetingLinkFixtures`, so the reference implementation has no
    // dependency. Script and style bodies are skipped, as the page script skips
    // their text.

    final class Element {
        let name: String
        let attributes: [String: String]
        weak var parent: Element?
        var children: [Node] = []

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
                    // The body is not markup and its text is never read.
                    index = position(of: "</\(name)", in: characters, from: index) ?? characters.count
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
