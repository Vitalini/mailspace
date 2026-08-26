import AppKit

/// Renders the Markdown subset `CHANGELOG.md` is written in — headings,
/// hard-wrapped bullets, paragraphs, `**bold**` and `` `code` `` — into
/// something readable in the update window.
///
/// A subset on purpose: no fenced or indented code blocks, no thematic breaks,
/// no nesting, no hard line breaks. Anything outside it reads as the text it is
/// made of rather than disappearing.
///
/// Hand-rolled rather than `NSAttributedString(markdown:)`, because that API
/// flattens list items into ordinary paragraphs: the release notes would arrive
/// as a wall of sentences with the bullets stripped, which is exactly the part
/// that makes them scannable.
enum ReleaseNotes {
    enum Block: Equatable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    enum Run: Equatable {
        case plain(String)
        case strong(String)
        case code(String)
    }

    /// Structure only — pure, so the parsing is a test rather than something
    /// judged by eye in a window.
    ///
    /// The rule that matters is CommonMark's lazy continuation: a non-blank line
    /// that does not itself start a block continues whatever is open. `CHANGELOG.md`
    /// is hard-wrapped at 80 columns, so most bullets arrive as two or three
    /// lines — without this they used to break apart, and every line after the
    /// first lost its bullet and its indent.
    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []

        /// The block still accepting continuation lines, and the lines it has
        /// gathered so far.
        var open: (isBullet: Bool, lines: [String])?

        func flush() {
            guard let block = open else { return }
            open = nil
            let text = block.lines.filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { return }
            blocks.append(block.isBullet ? .bullet(text) : .paragraph(text))
        }

        // GitHub serves a body with whatever line endings it was authored with.
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            // A hard wrap indents what it wrapped, and trailing whitespace is
            // invisible either way. Newlines are trimmed too, so a lone carriage
            // return cannot end up inside a word.
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if line.isEmpty {
                flush()  // a blank line ends the list, and the paragraph
                continue
            }
            if let text = headingText(line) {
                flush()
                if !text.isEmpty { blocks.append(.heading(text)) }
                continue
            }
            if let text = bulletText(line) {
                flush()
                open = (isBullet: true, lines: [text])
                continue
            }
            // Not a block start, so it belongs to whatever is open: the bullet
            // above it, or a paragraph of its own.
            if open == nil { open = (isBullet: false, lines: []) }
            open?.lines.append(line)
        }
        flush()
        return blocks
    }

    /// One to six `#` followed by a space or nothing. The space is what keeps
    /// `#1 in the charts` a sentence.
    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// `-`, `*` or `+` followed by a space, or standing alone — the space being
    /// the whole difference between a bullet and `-5 degrees`. An indented
    /// marker is a nested item in Markdown; here it flattens into a plain
    /// bullet, which loses the nesting but never glues the item into the prose
    /// above it.
    private static func bulletText(_ line: String) -> String? {
        guard let marker = line.first, "-*+".contains(marker) else { return nil }
        let rest = line.dropFirst()
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Inline spans within one block. Unclosed markers stay literal rather than
    /// swallowing the rest of the line.
    static func runs(in text: String) -> [Run] {
        var runs: [Run] = []
        var plain = ""
        var index = text.startIndex

        func flushPlain() {
            if !plain.isEmpty {
                runs.append(.plain(plain))
                plain = ""
            }
        }

        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("**"), let close = rest.dropFirst(2).range(of: "**") {
                flushPlain()
                runs.append(.strong(String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close.lowerBound])))
                index = close.upperBound
                continue
            }
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                flushPlain()
                runs.append(.code(String(rest[rest.index(after: rest.startIndex)..<close])))
                index = rest.index(after: close)
                continue
            }
            plain.append(text[index])
            index = text.index(after: index)
        }
        flushPlain()
        return runs
    }

    // MARK: - Rendering

    static func attributed(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let headingFont = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        let codeFont = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.paragraphSpacing = 6
        bodyParagraph.lineSpacing = 1

        let bulletParagraph = NSMutableParagraphStyle()
        bulletParagraph.headIndent = 16
        bulletParagraph.firstLineHeadIndent = 2
        bulletParagraph.paragraphSpacing = 4
        bulletParagraph.lineSpacing = 1

        let headingParagraph = NSMutableParagraphStyle()
        headingParagraph.paragraphSpacingBefore = 10
        headingParagraph.paragraphSpacing = 4

        func append(_ runs: [Run], font: NSFont, style: NSParagraphStyle, prefix: String = "") {
            if !prefix.isEmpty {
                output.append(NSAttributedString(string: prefix, attributes: [
                    .font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            for run in runs {
                switch run {
                case .plain(let text):
                    output.append(NSAttributedString(string: text, attributes: [
                        .font: font, .paragraphStyle: style, .foregroundColor: NSColor.labelColor
                    ]))
                case .strong(let text):
                    output.append(NSAttributedString(string: text, attributes: [
                        .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                        .paragraphStyle: style, .foregroundColor: NSColor.labelColor
                    ]))
                case .code(let text):
                    output.append(NSAttributedString(string: text, attributes: [
                        .font: codeFont, .paragraphStyle: style, .foregroundColor: NSColor.labelColor
                    ]))
                }
            }
            output.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        }

        let parsed = blocks(from: markdown)
        if parsed.isEmpty {
            return NSAttributedString(string: "This release came with no notes.", attributes: [
                .font: body, .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
        for block in parsed {
            switch block {
            case .heading(let text):
                append(runs(in: text), font: headingFont, style: headingParagraph)
            case .bullet(let text):
                append(runs(in: text), font: body, style: bulletParagraph, prefix: "•  ")
            case .paragraph(let text):
                append(runs(in: text), font: body, style: bodyParagraph)
            }
        }
        return output
    }
}
