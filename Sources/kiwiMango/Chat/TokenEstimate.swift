import Foundation

// ponytail: this is a local estimate, not a real BPE tokenizer — Foundation
// has no tokenizer API and pulling in a library just for a metadata line is
// overkill. Upgrade path: the gateway's `usage` field in `message.complete`
// (see `Chat/HermesGatewayClient.swift`), if Hermes ever starts reporting
// token counts per step instead of only once per whole turn.
enum TokenEstimate {
    /// Rough BPE-ish estimate: words × ~1.3, plus a bit more for punctuation,
    /// which usually splits into its own sub-token.
    static func count(_ text: String) -> Int {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return 0 }
        let punctuation = text.unicodeScalars.reduce(into: 0) { total, scalar in
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                total += 1
            }
        }
        let estimate = Double(words.count) * 1.3 + Double(punctuation) * 0.5
        return max(1, Int(estimate.rounded()))
    }

    /// Format dla POJEDYNCZEGO kroku. `formatCompactTokens` z DesignSystem
    /// zaokrągla do pełnych „k" (1200 → „1k", 4700 → „5k”), co przy sumie sesji
    /// jest w porządku, ale przy jednym kroku gubi różnicę między 1,2k a 1,9k.
    /// Dlatego osobny format tutaj, zamiast psuć tamten — ma innych odbiorców
    /// (AgentsWindow, web UI) i jest dopasowany do referencyjnego mockupu.
    static func formatStep(_ n: Int) -> String {
        n < 1_000
            ? "\(n)"
            : String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".", with: ",")
    }
}
