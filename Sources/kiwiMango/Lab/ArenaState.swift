import Foundation
import Observation

// MARK: - ArenaState

/// N cloud models racing the same prompt side by side. Deliberately has zero
/// shared state with `ChatState` — rounds and columns are ephemeral, only
/// votes are persisted (see `DatabaseManager.addArenaVote`). Lives in
/// `RootView` (not inside `ArenaView`) so it survives navigating away and back.
@MainActor
@Observable
final class ArenaState {

    struct Column: Identifiable {
        let id = UUID()
        let model: String
        var text: String = ""
        var statsLine: String?
        var errorMessage: String?
        var isStreaming = true
        var voted = false
    }

    var selectedModels: Set<String> = []
    var promptDraft: String = ""
    var columns: [Column] = []
    var votingRanking: [(model: String, votes: Int)] = []

    var isRunning: Bool { columns.contains { $0.isStreaming } }
    private var currentPrompt = ""

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let db = DatabaseManager.shared

    /// Starts a fresh round: cancels any still-running columns, resets the
    /// grid, then fires one independent stream per model.
    func start(models: [String], prompt: String, thinkingModels: Set<String>) {
        cancelAll()
        currentPrompt = prompt
        columns = models.map { Column(model: $0) }

        let payload = [OllamaService.ChatPayloadMessage(role: "user", content: prompt)]

        for index in columns.indices {
            let model = columns[index].model
            let think: Bool? = thinkingModels.contains(model) ? false : nil
            let service = OllamaService()

            let task = Task {
                do {
                    for try await delta in service.streamChat(model: model, messages: payload, think: think) {
                        guard !Task.isCancelled else { return }
                        switch delta {
                        case .content(let text):
                            self.appendText(text, columnIndex: index)
                        case .stats(let stats):
                            self.setStats(stats, columnIndex: index)
                        }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.setError(error, columnIndex: index)
                }
                self.finishColumn(index)
            }
            tasks.append(task)
        }
    }

    /// Cancels every in-flight column stream — each model has its own error
    /// state, so one 401/timeout never stops the others (pitfall F8.1-a).
    func cancelAll() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func appendText(_ text: String, columnIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        columns[columnIndex].text += text
    }

    private func setStats(_ stats: OllamaService.ChatStats, columnIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        let tokPerSec = String(format: "%.1f", stats.tokensPerSecond)
        columns[columnIndex].statsLine = "\(stats.evalCount) tok • \(tokPerSec) tok/s"
    }

    private func setError(_ error: Error, columnIndex: Int) {
        guard columns.indices.contains(columnIndex) else { return }
        columns[columnIndex].errorMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    private func finishColumn(_ index: Int) {
        guard columns.indices.contains(index) else { return }
        columns[index].isStreaming = false
    }

    /// Casts (and persists) a vote for the winning column of the current round.
    func vote(for columnIndex: Int) {
        guard columns.indices.contains(columnIndex), !columns[columnIndex].voted else { return }
        columns[columnIndex].voted = true
        do {
            try db.addArenaVote(model: columns[columnIndex].model, prompt: currentPrompt)
            refreshRanking()
        } catch {
            print("[KiwiMango] Failed to save arena vote: \(error)")
        }
    }

    /// Vote totals across every round ever played (survives app restarts).
    func refreshRanking() {
        do {
            votingRanking = try db.fetchArenaRanking()
        } catch {
            print("[KiwiMango] Failed to fetch arena ranking: \(error)")
        }
    }
}
