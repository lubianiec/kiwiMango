import Foundation

// MARK: - ModelPricing (moved from Dashboard/TokensBlock.swift 2026-08-05 —
// dashboard page deleted, but Remote/StaticWebServer.swift still needs this
// table to compute the "ile by kosztowało w API" comparison.)

enum ModelPricing {
    struct Price { let inputPerMillion: Double; let outputPerMillion: Double }

    private static let table: [(needle: String, price: Price)] = [
        ("kimi", Price(inputPerMillion: 0.6, outputPerMillion: 2.5)),
        ("glm", Price(inputPerMillion: 0.6, outputPerMillion: 2.2)),
        ("minimax", Price(inputPerMillion: 0.3, outputPerMillion: 1.2)),
        ("qwen", Price(inputPerMillion: 0.4, outputPerMillion: 1.2)),
        ("deepseek", Price(inputPerMillion: 0.55, outputPerMillion: 2.19)),
    ]
    private static let fallback = Price(inputPerMillion: 0.5, outputPerMillion: 2.0)

    static func price(for model: String) -> Price {
        let lower = model.lowercased()
        return table.first(where: { lower.contains($0.needle) })?.price ?? fallback
    }
}
