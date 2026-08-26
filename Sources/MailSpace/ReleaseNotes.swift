import AppKit

/// Renders the Markdown subset `CHANGELOG.md` is written in — headings,
/// bullets, paragraphs, `**bold**` and `` `code` `` — into something readable in
/// the update window.
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
    static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                let text = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(text)) }
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
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
