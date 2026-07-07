import Foundation

// MARK: - KiwiCard

/// Structured data card that a model can append to the end of its reply.
/// Parsed from a fenced ` ```kiwi-card ` block; if parsing fails the block
/// is silently dropped and only the plain text remains.
struct KiwiCard: Codable {
    let type: CardType
    let title: String
    let icon: String?
    let rows: [CardRow]?
    let chart: CardChart?
    let leftTitle: String?
    let rightTitle: String?
    let steps: [String]?

    enum CardType: String, Codable {
        case weather
        case stats
        case steps
        case compare
    }
}

struct CardRow: Codable {
    let icon: String?
    let label: String
    let value: String
}

struct CardChart: Codable {
    let kind: String // "bars" or "line"
    let label: String?
    let points: [ChartPoint]

    struct ChartPoint: Codable {
        let x: String
        let y: Double
    }
}

// MARK: - KiwiCardParser

enum KiwiCardParser {

    /// Extracts the first ` ```kiwi-card ` fenced JSON block from content.
    /// Returns the card plus the content with that block removed.
    /// While streaming, the raw JSON is hidden from the returned text as soon
    /// as the opening fence is detected.
    static func extract(from content: String) -> (card: KiwiCard?, text: String) {
        let fence = "```kiwi-card"
        guard let openRange = content.range(of: fence) else {
            return (nil, content)
        }

        let afterOpen = String(content[openRange.upperBound...])
        let closeFence = "```"
        guard let closeRange = afterOpen.range(of: closeFence) else {
            // Streaming: opening fence present but not closed — hide everything from fence on.
            let prefix = String(content[..<openRange.lowerBound])
            return (nil, prefix)
        }

        let jsonBlock = String(afterOpen[..<closeRange.lowerBound])
        let suffixStart = afterOpen.index(closeRange.upperBound, offsetBy: 0)
        let suffix = String(afterOpen[suffixStart...])

        let prefix = String(content[..<openRange.lowerBound])
        let cleanedText = (prefix + suffix)
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonBlock.data(using: .utf8),
              let card = try? JSONDecoder().decode(KiwiCard.self, from: data)
        else {
            return (nil, cleanedText)
        }

        let validated = card.withValidated()
        return (validated, cleanedText)
    }

    static let allowedSymbols: Set<String> = [
        "cloud.sun", "cloud.rain", "wind", "thermometer", "drop",
        "chart.bar", "list.number", "checkmark.circle", "exclamationmark.triangle",
        "eurosign.circle", "clock", "calendar", "location", "arrow.up.right", "info.circle"
    ]

    static func sanitizedSymbol(_ name: String?) -> String? {
        guard let name, allowedSymbols.contains(name) else { return nil }
        return name
    }
}

private extension KiwiCard {
    func withValidated() -> KiwiCard {
        let validRows = rows?.map { row in
            CardRow(
                icon: KiwiCardParser.sanitizedSymbol(row.icon),
                label: row.label,
                value: row.value
            )
        }
        let validChart = chart?.validated()
        return KiwiCard(
            type: type,
            title: title,
            icon: KiwiCardParser.sanitizedSymbol(icon),
            rows: validRows,
            chart: validChart,
            leftTitle: leftTitle,
            rightTitle: rightTitle,
            steps: steps
        )
    }
}

private extension CardChart {
    func validated() -> CardChart {
        let trimmed = Array(points.prefix(12))
        return CardChart(kind: kind, label: label, points: trimmed)
    }
}
