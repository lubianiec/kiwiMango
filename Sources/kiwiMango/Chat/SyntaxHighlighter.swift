import SwiftUI

// MARK: - SyntaxHighlighter

/// Lightweight, single-pass line tokenizer for the ~10 languages that show up
/// most often in chat code blocks. Not a real parser — good enough to color
/// keywords/strings/numbers/comments without pulling in a dependency.
enum SyntaxHighlighter {

    private enum TokenKind {
        case plain, keyword, string, comment, number
    }

    private static let aliases: [String: String] = [
        "js": "javascript", "jsx": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python",
        "sh": "bash", "zsh": "bash", "shell": "bash",
        "yml": "yaml",
    ]

    private static let jsKeywords: Set<String> = [
        "function", "const", "let", "var", "return", "if", "else", "for", "while",
        "switch", "case", "default", "class", "extends", "import", "export", "from",
        "async", "await", "try", "catch", "finally", "throw", "new", "this", "typeof",
        "instanceof", "true", "false", "null", "undefined", "of", "in", "yield", "void", "delete",
    ]

    private static let keywordSets: [String: Set<String>] = [
        "swift": [
            "import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let",
            "if", "else", "guard", "return", "for", "while", "switch", "case", "default",
            "private", "public", "internal", "fileprivate", "static", "self", "Self", "true",
            "false", "nil", "in", "try", "catch", "throw", "throws", "async", "await", "do",
            "break", "continue", "is", "as", "some", "any", "init", "deinit", "where",
            "typealias", "associatedtype", "mutating", "final", "override", "super", "weak",
            "lazy", "inout",
        ],
        "python": [
            "def", "class", "import", "from", "return", "if", "elif", "else", "for", "while",
            "in", "is", "not", "and", "or", "try", "except", "finally", "with", "as", "lambda",
            "pass", "break", "continue", "True", "False", "None", "self", "yield", "raise",
            "global", "nonlocal", "async", "await", "del", "assert",
        ],
        "javascript": jsKeywords,
        "typescript": jsKeywords.union([
            "interface", "type", "implements", "public", "private", "protected", "static",
            "enum", "namespace", "declare", "readonly", "abstract",
        ]),
        "bash": [
            "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
            "function", "return", "echo", "export", "local", "in", "exit", "set", "source",
        ],
        "json": ["true", "false", "null"],
        "yaml": ["true", "false", "null"],
        "sql": [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
            "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having",
            "as", "and", "or", "not", "null", "create", "table", "alter", "drop", "primary",
            "key", "foreign", "references", "default", "limit", "distinct", "union", "exists",
            "in", "like", "between",
        ],
    ]

    private static let lineCommentPrefixes: [String: String] = [
        "swift": "//", "javascript": "//", "typescript": "//",
        "python": "#", "bash": "#", "yaml": "#", "sql": "--",
    ]

    /// Case-insensitive keyword matching only makes sense for SQL; everything else is exact.
    private static let caseInsensitiveLanguages: Set<String> = ["sql"]

    static func highlight(line: String, language: String?) -> AttributedString {
        let lang = (language ?? "").lowercased()
        let resolved = aliases[lang] ?? lang

        if resolved == "html" {
            return highlightHTML(line)
        }

        let keywords = keywordSets[resolved]
        let commentPrefix = lineCommentPrefixes[resolved]
        let caseInsensitive = caseInsensitiveLanguages.contains(resolved)

        var result = AttributedString()
        let chars = Array(line)
        var i = 0

        func append(_ text: String, _ kind: TokenKind) {
            guard !text.isEmpty else { return }
            var chunk = AttributedString(text)
            chunk.foregroundColor = color(for: kind)
            result += chunk
        }

        while i < chars.count {
            let c = chars[i]

            // Line comment: rest of line, once seen (outside a string).
            if let prefix = commentPrefix, matches(chars, at: i, prefix: prefix) {
                append(String(chars[i...]), .comment)
                break
            }

            // String literal.
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                var j = i + 1
                while j < chars.count, chars[j] != quote {
                    if chars[j] == "\\", j + 1 < chars.count { j += 1 }
                    j += 1
                }
                let end = min(j + 1, chars.count)
                append(String(chars[i..<end]), .string)
                i = end
                continue
            }

            // Number literal (word-boundary: previous char isn't alnum/underscore).
            if c.isNumber, (i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." || chars[j] == "x" || chars[j] == "X" || chars[j].isHexDigit {
                    j += 1
                }
                append(String(chars[i..<j]), .number)
                i = j
                continue
            }

            // Identifier / keyword.
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    j += 1
                }
                let word = String(chars[i..<j])
                let isKeyword = keywords?.contains(caseInsensitive ? word.lowercased() : word) ?? false
                append(word, isKeyword ? .keyword : .plain)
                i = j
                continue
            }

            append(String(c), .plain)
            i += 1
        }

        return result
    }

    /// Minimal tag/attribute-aware pass for HTML: `<tag`, `</tag`, and `>` in
    /// the accent color, quoted attribute values as strings, rest plain.
    private static func highlightHTML(_ line: String) -> AttributedString {
        var result = AttributedString()
        let chars = Array(line)
        var i = 0

        func append(_ text: String, _ kind: TokenKind) {
            guard !text.isEmpty else { return }
            var chunk = AttributedString(text)
            chunk.foregroundColor = color(for: kind)
            result += chunk
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\"" || c == "'" {
                var j = i + 1
                while j < chars.count, chars[j] != c { j += 1 }
                let end = min(j + 1, chars.count)
                append(String(chars[i..<end]), .string)
                i = end
                continue
            }
            if c == "<" {
                var j = i + 1
                if j < chars.count, chars[j] == "/" { j += 1 }
                let tagStart = j
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" { j += 1 }
                append(String(chars[i..<tagStart]), .plain)
                append(String(chars[tagStart..<j]), .keyword)
                i = j
                continue
            }
            append(String(c), .plain)
            i += 1
        }
        return result
    }

    private static func matches(_ chars: [Character], at index: Int, prefix: String) -> Bool {
        let prefixChars = Array(prefix)
        guard index + prefixChars.count <= chars.count else { return false }
        for (offset, ch) in prefixChars.enumerated() where chars[index + offset] != ch {
            return false
        }
        return true
    }

    private static func color(for kind: TokenKind) -> Color {
        switch kind {
        case .plain: .kiwiMangoTextPrimary
        case .keyword: .kiwiMangoPurple
        case .string: .kiwiMangoAccent
        case .comment: .kiwiMangoTextPrimary.opacity(0.4)
        case .number: .kiwiMangoSyntaxNumber
        }
    }
}
