import AppKit
import SwiftUI

// MARK: - TerminalMarkdown
//
// Renders chat content in a terminal-like monospace style: headings, paragraphs,
// fenced code blocks, markdown tables, clickable links, and image/link mockups.

private enum TerminalBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
    case list(items: [ListItem])
}

// MARK: - List items + status tokens
//
// A leading status emoji (✅⚠️❌ℹ️ and friends) becomes a `[OK]`/`[!]`/`[X]`/`[i]`
// token in the app's own palette instead of an emoji glyph (style D: zero
// emoji in the window). Only recognized when the emoji is the FIRST character
// of the item — an emoji mid-sentence is the author's, not a status, and stays
// untouched.

private enum ListMarker {
    case ok, warn, error, info, plain

    var token: String {
        switch self {
        case .ok: return "[OK]"
        case .warn: return "[!]"
        case .error: return "[X]"
        case .info: return "[i]"
        case .plain: return "·"
        }
    }

    func color(mutedColor: Color) -> Color {
        switch self {
        case .ok: return Color.green
        case .warn: return Color.accent
        case .error: return Color.danger
        case .info: return Color.txt.opacity(0.45)
        case .plain: return mutedColor
        }
    }
}

private struct ListItem {
    let marker: ListMarker
    let text: String
}

private enum TerminalMarkdownParser {

    static func parse(_ content: String) -> [TerminalBlock] {
        var blocks: [TerminalBlock] = []
        let lines = content.components(separatedBy: "\n")
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        while index < lines.count {
            let line = lines[index]

            // Fenced code
            if line.hasPrefix("```") {
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    content: codeLines.joined(separator: "\n")))
                continue
            }

            // Markdown table
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                flushParagraph()
                var tableLines: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    tableLines.append(lines[index])
                    index += 1
                }
                if let table = parseTable(tableLines) {
                    blocks.append(table)
                } else {
                    // Not a real table — fall back to plain lines.
                    paragraphLines.append(contentsOf: tableLines)
                    flushParagraph()
                }
                continue
            }

            // List (-, *, + after leading indentation)
            if let itemText = listItemPrefix(line) {
                flushParagraph()
                var items: [ListItem] = [parseListItem(itemText)]
                index += 1
                while index < lines.count, let next = listItemPrefix(lines[index]) {
                    items.append(parseListItem(next))
                    index += 1
                }
                blocks.append(.list(items: items))
                continue
            }

            // Heading
            if let heading = headingPrefix(line) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func listItemPrefix(_ line: String) -> String? {
        let indented = line.drop(while: { $0 == " " || $0 == "\t" })
        for marker in ["- ", "* ", "+ "] {
            if indented.hasPrefix(marker) {
                return String(indented.dropFirst(marker.count))
            }
        }
        return nil
    }

    private static let emojiMarkers: [(String, ListMarker)] = [
        ("✅", .ok), ("✓", .ok), ("🟢", .ok),
        ("⚠️", .warn), ("⚠", .warn), ("🟡", .warn),
        ("❌", .error), ("🔴", .error),
        ("ℹ️", .info),
    ]

    private static func parseListItem(_ raw: String) -> ListItem {
        for (emoji, marker) in emojiMarkers where raw.hasPrefix(emoji) {
            let rest = String(raw.dropFirst(emoji.count)).trimmingCharacters(in: .whitespaces)
            return ListItem(marker: marker, text: rest)
        }
        return ListItem(marker: .plain, text: raw)
    }

    private static func headingPrefix(_ line: String) -> (level: Int, text: String)? {
        if line.hasPrefix("### ") { return (3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ") { return (2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ") { return (1, String(line.dropFirst(2))) }
        return nil
    }

    private static func parseTable(_ lines: [String]) -> TerminalBlock? {
        guard lines.count >= 2 else { return nil }
        let cells: [[String]] = lines.map {
            $0.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: "|")
                .dropFirst()
                .dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard cells.count >= 2,
              cells.allSatisfy({ !$0.isEmpty }),
              cells[1].allSatisfy({ $0.range(of: "^-+\\s*$", options: .regularExpression) != nil })
        else { return nil }
        let headers = cells[0]
        let rows = Array(cells.dropFirst(2))
        return .table(headers: headers, rows: rows)
    }
}

// MARK: - Public view

struct TerminalMarkdown: View {
    /// Style knobs so the same block parser can render both the plain
    /// terminal look (user messages, default) and the agent prose look
    /// (SF Pro paragraphs, capsule headings) without a second renderer.
    struct Style {
        var paragraphFont: Font = KiwiMangoFont.mono(12)
        var paragraphLineSpacing: CGFloat = 2
        var headingFont: (Int) -> Font = { level in
            switch level {
            case 1: return KiwiMangoFont.mono(15, weight: .bold)
            case 2: return KiwiMangoFont.mono(13, weight: .bold)
            default: return KiwiMangoFont.mono(12, weight: .bold)
            }
        }
        /// Color for the "no status" list-item dot (`·`) and its token column.
        var mutedColor: Color = Color.txt.opacity(0.35)
        /// F3: heading renders as a small-caps eyebrow (`kiwiSectionLabel()`)
        /// with a hairline stretching to the right edge, instead of a big
        /// per-level mono heading.
        var showHeadingRule: Bool = false

        /// Agent replies: SF Pro prose (mockup direction D), the strongest
        /// text in the window.
        static let agentProse = Style(
            paragraphFont: KiwiMangoFont.sans(15),
            paragraphLineSpacing: 11,
            showHeadingRule: true
        )
    }

    let content: String
    /// Plain-text color for headings/paragraphs only — code blocks and tables
    /// keep their own syntax colors regardless (a pasted code snippet in a
    /// user prompt shouldn't turn amber). Defaults to the shared body color.
    var textColor: Color = Color.txt
    var style: Style = Style()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(TerminalMarkdownParser.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: TerminalBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            if style.showHeadingRule {
                HStack(spacing: 8) {
                    Text(inlineAttributed(text))
                        .kiwiSectionLabel()
                    Rectangle()
                        .fill(Color.txt.opacity(0.10))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(inlineAttributed(text))
                    .font(style.headingFont(level))
                    .foregroundStyle(textColor)
            }
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(style.paragraphFont)
                .foregroundStyle(textColor)
                .lineSpacing(style.paragraphLineSpacing)
        case .code(let language, let codeContent):
            CodeBlockView(language: language, content: codeContent)
        case .table(let headers, let rows):
            MarkdownTable(headers: headers, rows: rows)
        case .list(let items):
            MarkdownList(items: items, textColor: textColor, mutedColor: style.mutedColor, inlineAttributed: inlineAttributed)
        }
    }

    /// Renders **bold**, *italic*, `inline code`, and links; falls back to a
    /// plain string if the fragment isn't valid inline markdown. Must survive
    /// unclosed markdown mid-stream (e.g. "**Backup err") without throwing —
    /// keep the `try?` fallback.
    private func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Markdown list (two-column grid: status token + content)

private struct MarkdownList: View {
    let items: [ListItem]
    let textColor: Color
    let mutedColor: Color
    let inlineAttributed: (String) -> AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.marker.token)
                        .font(KiwiMangoFont.mono(11.5, weight: .semibold))
                        .foregroundStyle(item.marker.color(mutedColor: mutedColor))
                        .frame(width: 28, alignment: .leading)
                    Text(inlineAttributed(item.text))
                        .font(KiwiMangoFont.mono(13))
                        .foregroundStyle(textColor)
                }
            }
        }
    }
}

// MARK: - Markdown table

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    Text(header)
                        .font(KiwiMangoFont.mono(10, weight: .semibold))
                        .foregroundStyle(Color.txt)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.ink.opacity(0.08))
                    if index < headers.count - 1 {
                        Rectangle().fill(Color.ink.opacity(0.15)).frame(width: 1)
                    }
                }
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                        Text(cell)
                            .font(KiwiMangoFont.mono(10))
                            .foregroundStyle(Color.ink.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index < row.count - 1 {
                            Rectangle().fill(Color.ink.opacity(0.10)).frame(width: 1)
                        }
                    }
                }
                .background(Color.ink.opacity(0.03))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ink.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Code block

private struct CodeBlockView: View {
    let language: String?
    let content: String

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(KiwiMangoFont.mono(10, weight: .medium))
                    .foregroundStyle(Color.ink.opacity(0.8))
                Spacer()
                Button(action: copy) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10 + FontScale.bump))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ink.opacity(0.72))
                .help("Kopiuj kod")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Rectangle()
                .fill(Color.ink.opacity(0.15))
                .frame(height: 1)

            let lines = content.components(separatedBy: "\n")
            let numberWidth = String(lines.count).count
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    Text(numberedLine(index: i, width: numberWidth, line: line))
                        .font(KiwiMangoFont.mono(11))
                }
            }
            .padding(10)
        }
        .background(Color.kiwiMangoPanelDeep)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.kiwiMangoTextPrimary.opacity(0.3), lineWidth: 1)
        )
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
    }

    private func numberedLine(index: Int, width: Int, line: String) -> AttributedString {
        let number = String(index + 1)
        let padded = String(repeating: " ", count: max(0, width - number.count)) + number
        var gutter = AttributedString(padded + "  ")
        gutter.foregroundColor = Color.kiwiMangoTextPrimary.opacity(0.3)
        return gutter + SyntaxHighlighter.highlight(line: line.isEmpty ? " " : line, language: language)
    }
}

// MARK: - Image / mockup link detection

extension String {
    /// True for strings that look like an image or a link to a design mockup.
    var isVisualMockupURL: Bool {
        let lower = lowercased()
        return lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".svg")
    }
}
