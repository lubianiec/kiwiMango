import Foundation
import Observation

// MARK: - RoomState

/// Two cloud models debating a topic, one turn at a time (sequential, not
/// parallel like the Arena). Zero shared state with `ChatState` and nothing
/// written to the chat tables — the transcript only ever leaves as a Markdown
/// export. Lives in `RootView` so it survives navigating away and back.
@MainActor
@Observable
final class RoomState {

    enum Speaker: Equatable {
        case modelA
        case modelB
        case pawel
    }

    struct Turn: Identifiable {
        let id = UUID()
        let speaker: Speaker
        var text: String
        var isStreaming: Bool
    }

    private(set) var modelA = ""
    private(set) var modelB = ""
    private(set) var topic = ""
    private(set) var turnLimit = 6
    private(set) var currentTurnCount = 0
    var turns: [Turn] = []
    var isRunning = false
    var injectDraft = ""

    var hasStarted: Bool { !turns.isEmpty || isRunning }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var historyA: [OllamaService.ChatPayloadMessage] = []
    @ObservationIgnored private var historyB: [OllamaService.ChatPayloadMessage] = []
    @ObservationIgnored private var thinkingModels: Set<String> = []

    /// Starts a fresh debate. Any previous run is cancelled first.
    func start(
        modelA: String, modelB: String,
        personaA: Persona?, personaB: Persona?,
        topic: String, turnLimit: Int, thinkingModels: Set<String>
    ) {
        cancel()
        self.modelA = modelA
        self.modelB = modelB
        self.topic = topic
        self.turnLimit = turnLimit
        self.thinkingModels = thinkingModels
        turns = []
        currentTurnCount = 0

        historyA = [OllamaService.ChatPayloadMessage(role: "system", content: Self.systemPrompt(persona: personaA, topic: topic))]
        historyB = [OllamaService.ChatPayloadMessage(role: "system", content: Self.systemPrompt(persona: personaB, topic: topic))]

        isRunning = true
        task = Task { await self.runLoop() }
    }

    private static func systemPrompt(persona: Persona?, topic: String) -> String {
        var prompt = ""
        if let persona, !persona.systemPrompt.isEmpty {
            prompt += persona.systemPrompt + "\n\n"
        }
        prompt += "Dyskutujesz z drugim AI na temat: \(topic). Odpowiadaj zwięźle, max 150 słów."
        return prompt
    }

    private func runLoop() async {
        while currentTurnCount < turnLimit, !Task.isCancelled {
            await runTurn(.modelA)
            guard !Task.isCancelled else { break }
            currentTurnCount += 1
            guard currentTurnCount < turnLimit else { break }

            await runTurn(.modelB)
            guard !Task.isCancelled else { break }
            currentTurnCount += 1
        }
        isRunning = false
    }

    private func runTurn(_ speaker: Speaker) async {
        let model = speaker == .modelA ? modelA : modelB
        let history = speaker == .modelA ? historyA : historyB
        let think: Bool? = thinkingModels.contains(model) ? false : nil

        let turn = Turn(speaker: speaker, text: "", isStreaming: true)
        let turnID = turn.id
        turns.append(turn)

        let service = OllamaService()
        do {
            for try await delta in service.streamChat(model: model, messages: history, think: think) {
                guard !Task.isCancelled else { return }
                if case .content(let text) = delta {
                    appendText(text, to: turnID)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            appendText("⚠️ \(error.localizedDescription)", to: turnID)
        }
        markFinished(turnID)
        guard !Task.isCancelled else { return }

        let fullText = turns.first(where: { $0.id == turnID })?.text ?? ""
        // The opponent only ever sees a capped version — a model ignoring the
        // "max 150 words" instruction shouldn't make context balloon (pitfall b).
        let forOpponent = fullText.count > 2000 ? String(fullText.prefix(2000)) + "…" : fullText

        if speaker == .modelA {
            historyA.append(OllamaService.ChatPayloadMessage(role: "assistant", content: fullText))
            historyB.append(OllamaService.ChatPayloadMessage(role: "user", content: forOpponent))
        } else {
            historyB.append(OllamaService.ChatPayloadMessage(role: "assistant", content: fullText))
            historyA.append(OllamaService.ChatPayloadMessage(role: "user", content: forOpponent))
        }
        trimHistory(&historyA)
        trimHistory(&historyB)
    }

    /// Keeps the system prompt plus only the most recent 8 turns — otherwise
    /// tokens (and latency) grow with every exchange (pitfall a).
    private func trimHistory(_ history: inout [OllamaService.ChatPayloadMessage]) {
        guard history.count > 9 else { return }
        let system = history[0]
        history = [system] + Array(history.suffix(8))
    }

    private func appendText(_ text: String, to id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].text += text
    }

    private func markFinished(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].isStreaming = false
    }

    /// Paweł's interjection — injected into BOTH histories as a user turn,
    /// shown in the transcript, but doesn't consume a turn of the debate.
    func inject(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        turns.append(Turn(speaker: .pawel, text: trimmed, isStreaming: false))
        let message = OllamaService.ChatPayloadMessage(role: "user", content: "Paweł: \(trimmed)")
        historyA.append(message)
        historyB.append(message)
    }

    /// STOP button / Esc — cancels mid-stream immediately (pitfall c).
    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
        for index in turns.indices { turns[index].isStreaming = false }
    }

    func exportMarkdown() -> String {
        var markdown = "# Pokój agentów: \(topic)\n\n"
        markdown += "Modele: \(modelA) vs \(modelB)\n"
        markdown += "Data: \(Self.dateFormatter.string(from: Date()))\n\n"
        for turn in turns {
            let heading: String
            switch turn.speaker {
            case .modelA: heading = "## \(modelA)"
            case .modelB: heading = "## \(modelB)"
            case .pawel: heading = "## 🧑 Paweł"
            }
            markdown += "\(heading)\n\n\(turn.text)\n\n"
        }
        return markdown
    }

    /// ASCII-only, hyphenated slug for filenames (same shape as
    /// `ChatState.slug(from:)`, duplicated to keep Lab decoupled from Chat).
    static func fileSlug(_ title: String) -> String {
        let folded = title.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "pl_PL"))
        let dashed = String(folded.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        var collapsed = dashed
        while collapsed.contains("--") { collapsed = collapsed.replacingOccurrences(of: "--", with: "-") }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func uniqueFileURL(in dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }
        return url
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "pl_PL")
        return formatter
    }()
}
