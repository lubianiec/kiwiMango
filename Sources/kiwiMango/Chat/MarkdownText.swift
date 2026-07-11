import AppKit
import SwiftUI

// MARK: - MarkdownBlock

/// A block-level chunk of chat content: heading, paragraph, or fenced code.
private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, content: String)
}

// MARK: - MarkdownParser

private enum MarkdownParser {

    /// Splits raw message content into blocks on lines. An unclosed ``` fence
    /// (mid-stream) swallows the rest of the content as code, so a partially
    /// streamed code block never flickers as plain text first.
    static func parse(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
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

            if line.hasPrefix("```") {
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                flushParagraph()
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !lines[index].hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 } // consume closing fence
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    content: codeLines.joined(separator: "\n")
                ))
                continue
            }

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

    private static func headingPrefix(_ line: String) -> (level: Int, text: String)? {
        if line.hasPrefix("### ") { return (3, String(line.dropFirst(4))) }
        if line.hasPrefix("## ") { return (2, String(line.dropFirst(3))) }
        if line.hasPrefix("# ") { return (1, String(line.dropFirst(2))) }
        return nil
    }
}

// MARK: - MarkdownText

/// Renders chat content with block-level markdown: headings, fenced code blocks
/// with a copy button, and inline styling (bold/italic/code/links) for everything else.
struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownParser.parse(content).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inlineAttributed(text))
                .font(headingFont(level))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
        case .paragraph(let text):
            Text(inlineAttributed(text))
                .font(KiwiMangoFont.sans(13))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
        case .code(let language, let codeContent):
            if language?.lowercased() == "mermaid" {
                MermaidBlockView(code: codeContent)
            } else {
                CodeBlockView(language: language, content: codeContent)
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: KiwiMangoFont.sans(17, weight: .bold)
        case 2: KiwiMangoFont.sans(15, weight: .bold)
        default: KiwiMangoFont.sans(14, weight: .bold)
        }
    }

    /// Renders **bold**, *italic*, `inline code`, and links; falls back to a
    /// plain string if the fragment isn't valid inline markdown.
    private func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - CodeBlockView

private struct CodeBlockView: View {
    let language: String?
    let content: String

    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(KiwiMangoFont.mono(10, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.8))
                Spacer()
                Button(action: copy) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                .help("Kopiuj kod")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Rectangle()
                .fill(Color.kiwiMangoTextPrimary.opacity(0.15))
                .frame(height: 1)

            let lines = content.components(separatedBy: "\n")
            let numberWidth = String(lines.count).count
            // No ScrollView here on purpose: a horizontal ScrollView nested inside the
            // transcript's vertical one renders its content at zero width on this macOS
            // build (reproduced even with the pre-existing, un-highlighted code path —
            // not something introduced by this fala). Long lines wrap instead of scrolling.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                    Text(numberedLine(index: i, width: numberWidth, line: line))
                        .font(KiwiMangoFont.mono(12))
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

// MARK: - MermaidBlockView

/// F26.9: ```mermaid renders to a static image via `MermaidRenderer`. Falls
/// back to the raw source in a `CodeBlockView` on any failure — never a blank
/// bubble (spec). No `ScrollView(.horizontal)` here either (same F26.3 finding).
private struct MermaidBlockView: View {
    let code: String

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 700)
                    .padding(10)
                    .background(Color.kiwiMangoPanelDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.kiwiMangoTextPrimary.opacity(0.3), lineWidth: 1)
                    )
            } else if failed {
                CodeBlockView(language: "mermaid", content: code)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("renderuję diagram…")
                        .font(KiwiMangoFont.mono(11))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                }
                .padding(10)
                .background(Color.kiwiMangoPanelDeep)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.kiwiMangoTextPrimary.opacity(0.3), lineWidth: 1)
                )
            }
        }
        .task(id: code) {
            let result = await MermaidRenderer.shared.render(code: code)
            if let result {
                image = result
            } else {
                failed = true
            }
        }
    }
}
