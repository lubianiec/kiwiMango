import Foundation
import GRDB

// MARK: - TokenUsageRecorder (PLAN-DASHBOARD.md Fala 2)

/// Turns a finished `/api/chat` stream's stats (`prompt_eval_count`/`eval_count`
/// on the final chunk) into a `token_usage` row — **cloud models only**, since
/// local models run for free and there's nothing worth tracking. The cloud
/// model list comes from `/api/tags` and is cached 1h (pitfall: hitting it on
/// every single assistant reply would be wasteful network chatter).
actor TokenUsageRecorder {
    static let shared = TokenUsageRecorder()

    private let client = OllamaAccountClient()
    private var cachedModels: [OllamaAccountClient.ModelEntry] = []
    private var cachedAt: Date = .distantPast

    /// No-op for local models. Never throws — a failed background token count
    /// must not disrupt the chat; the write error is logged instead (PLAN-DASHBOARD.md
    /// pitfall #7: no silent `try?`).
    func record(model: String, source: String, promptEvalCount: Int, evalCount: Int) async {
        guard promptEvalCount > 0 || evalCount > 0 else { return }
        let models = await cloudModels()
        // Pitfall #9: `ModelEntry.matches` already checks both the local
        // `:cloud`-suffixed name and the bare `remote_model`.
        guard models.contains(where: { $0.isCloud && $0.matches(model) }) else { return }
        do {
            try DatabaseManager.shared.recordTokenUsage(
                model: model, source: source, input: promptEvalCount, output: evalCount
            )
        } catch {
            print("[KiwiMango] Failed to record token usage for \(model): \(error)")
        }
    }

    private func cloudModels() async -> [OllamaAccountClient.ModelEntry] {
        if Date().timeIntervalSince(cachedAt) < 3600, !cachedModels.isEmpty {
            return cachedModels
        }
        let models = await client.models()
        if !models.isEmpty {
            cachedModels = models
            cachedAt = Date()
        }
        return models
    }

    // MARK: - Self-check (ponytail: one runnable check, no test framework)

    /// Exercises the real write path end-to-end against the live Ollama daemon
    /// and the app's actual database: cloud-model lookup + `token_usage` UPSERT
    /// + read-back, asserting the two writes accumulated correctly. Uses a
    /// `kiwi-chat-selfcheck` source so it never mixes into real dashboard stats.
    ///
    /// Run manually: `KIWI_SELFCHECK_TOKEN_USAGE=1 .build/debug/kiwiMango`
    /// (see the launch hook in `App.swift`).
    static func runSelfCheck() async {
        guard let testModel = await OllamaAccountClient().models().first(where: \.isCloud)?.name else {
            print("[KiwiMango] selfcheck token_usage: no cloud model in /api/tags — skipped")
            return
        }
        let source = "kiwi-chat-selfcheck"
        await shared.record(model: testModel, source: source, promptEvalCount: 10, evalCount: 5)
        await shared.record(model: testModel, source: source, promptEvalCount: 3, evalCount: 2)

        do {
            let row = try DatabaseManager.shared.dbQueue.read { db in
                try Row.fetchOne(
                    db, sql: "SELECT input, output FROM token_usage WHERE model = ? AND source = ?",
                    arguments: [testModel, source]
                )
            }
            let input: Int64 = row?["input"] ?? 0
            let output: Int64 = row?["output"] ?? 0
            let pass = input == 13 && output == 7
            print(
                "[KiwiMango] selfcheck token_usage \(pass ? "PASS" : "FAIL"): "
                    + "model=\(testModel) input=\(input) output=\(output) (expected 13/7)"
            )
        } catch {
            print("[KiwiMango] selfcheck token_usage FAILED to read back: \(error)")
        }
    }
}
