import Foundation

// MARK: - ConversationBackends (PLAN-V2 §9 Fala 3/C1)
//
// Wires the mocked `ConversationSession.items` (Fala 2/B3) to real backends:
// `AgentSessionController` → HermesGatewayClient (gateway :3777), one gateway
// `session_id` per tab. `ChatSessionController` → ClaudeCodeService (Sonnet/
// Opus, headless `claude -p`) or OllamaService (local/cloud), routed by
// `session.model`. Both mutate `session.items`/`session.draft`/token counters
// directly — no separate view-model layer, `ConversationSession` already is one.

// MARK: - HermesEventRouter

/// `HermesGatewayClient.events()` returns ONE cached `AsyncStream` for the
/// whole app (see its doc comment) — every open Agent tab shares the same
/// gateway connection and multiple gateway `session_id`s. A second `for await`
/// loop over that stream would just split events unpredictably between
/// consumers, so there is exactly ONE app-wide listener here, dispatching by
/// `session_id` to whichever `AgentSessionController` registered it.
@MainActor
final class HermesEventRouter {
    static let shared = HermesEventRouter()

    private var handlers: [String: (HermesGatewayClient.Event) -> Void] = [:]
    private var started = false

    private init() {}

    func register(sessionID: String, handler: @escaping (HermesGatewayClient.Event) -> Void) {
        handlers[sessionID] = handler
        startIfNeeded()
    }

    func unregister(sessionID: String) {
        handlers.removeValue(forKey: sessionID)
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        Task {
            for await event in await HermesGatewayClient.shared.events() {
                handlers[Self.sessionID(of: event)]?(event)
            }
        }
    }

    private static func sessionID(of event: HermesGatewayClient.Event) -> String {
        switch event {
        case .ready: ""
        case .messageStart(let id), .messageDelta(let id, _), .thinkingDelta(let id, _),
             .toolStart(let id, _, _, _), .toolComplete(let id, _, _, _, _, _, _),
             .subagentStart(let id, _, _), .subagentText(let id, _, _), .subagentComplete(let id, _),
             .approvalRequest(let id, _, _, _, _), .clarifyRequest(let id, _, _),
             .messageComplete(let id, _, _, _, _, _, _, _, _, _, _), .sessionTitle(let id, _):
            id
        case .turnError(let id, _): id ?? ""
        }
    }
}

// MARK: - AgentSessionController

@MainActor
@Observable
final class AgentSessionController {
    let session: ConversationSession
    /// Hermes gateway model list has no discovery endpoint wired yet — this is
    /// the curated set from Paweł's own Ollama cloud roster (see MEMORY.md).
    /// `provider` is always "ollama-launch": the only value verified against a
    /// live Hermes install (HermesChatService's F22 finding) — session.create's
    /// provider space for other values is undocumented, so we don't guess.
    static let availableModels = [
        "kimi-k2.7-code:cloud", "glm-5.2:cloud", "qwen3.5:cloud", "minimax-m3:cloud",
    ]

    private var lastModelUsed: String?
    private var lastReasoningEffortUsed: String?
    private var currentAIMessageID: UUID?
    private var currentThinking: ThinkingBlockModel?
    private var toolCalls: [String: ToolCall] = [:]

    /// Wired by `ConversationStore` at controller creation — saves the session
    /// snapshot to disk. Called at end-of-turn points only, never per-chunk.
    var onPersist: (() -> Void)?

    init(session: ConversationSession) {
        self.session = session
    }

    deinit {
        // ponytail: handlers dict cleanup is best-effort — a closed tab's gateway
        // session just stops receiving a live consumer, no resource leak (the
        // gateway process itself lives for the app's lifetime regardless).
    }

    func send(_ text: String) {
        if session.title == "Nowa sesja" { session.title = String(text.prefix(40)) } // fallback until sessionTitle event arrives
        session.items.append(.userMessage(id: UUID(), text: text))
        onPersist?()
        Task {
            do {
                try await HermesGatewayClient.shared.connectIfNeeded()
                // ponytail: resume after a gateway restart = gateway doesn't know
                // `existingSessionID` → resumeOrCreateSession silently makes a new
                // one, so the agent loses context while the UI still shows the old
                // transcript. Acceptable v1; upgrade: resend a summary of `items`
                // as the first prompt when a resume falls back to create.
                if session.gatewaySessionID == nil || lastModelUsed != session.model || lastReasoningEffortUsed != session.reasoningEffort {
                    let id = try await HermesGatewayClient.shared.resumeOrCreateSession(
                        existingSessionID: session.gatewaySessionID, model: session.model,
                        provider: "ollama-launch", cwd: nil, reasoningEffort: session.reasoningEffort
                    )
                    session.gatewaySessionID = id
                    lastModelUsed = session.model
                    lastReasoningEffortUsed = session.reasoningEffort
                    onPersist?()
                    HermesEventRouter.shared.register(sessionID: id) { [weak self] event in
                        self?.handle(event)
                    }
                }
                var fileRefs: [String] = []
                for attachment in session.pendingAttachments {
                    switch attachment.kind {
                    case .image:
                        try await HermesGatewayClient.shared.attachImageBytes(
                            sessionID: session.gatewaySessionID!, base64Data: attachment.base64, mimeType: attachment.mimeType
                        )
                    case .pdf:
                        try await HermesGatewayClient.shared.attachPDF(
                            sessionID: session.gatewaySessionID!, contentBase64: attachment.base64, filename: attachment.filename
                        )
                    case .file:
                        let ref = try await HermesGatewayClient.shared.attachFile(
                            sessionID: session.gatewaySessionID!, dataBase64: attachment.base64, filename: attachment.filename
                        )
                        fileRefs.append(ref)
                    }
                }
                session.pendingAttachments.removeAll()
                let promptText = fileRefs.isEmpty ? text : (fileRefs.joined(separator: "\n") + "\n" + text)
                try await HermesGatewayClient.shared.submitPrompt(sessionID: session.gatewaySessionID!, text: promptText)
            } catch {
                session.items.append(.aiMessage(
                    id: UUID(), senderLabel: "HERMES", text: "⚠️ \(error.localizedDescription)", isStreaming: false
                ))
                onPersist?()
            }
        }
    }

    /// "📖 Kontekst z vaulta" quick action — the only one with a wired backend
    /// this wave (PLAN-V2 §7.3 quick actions; the other three have none yet,
    /// see `AgentPage.quickActionItems`).
    func insertVaultContext() {
        guard let memory = HermesFilesReader.memoryFile() else { return }
        session.draft = "Kontekst z vaulta (MEMORY.md):\n\(memory.text)\n\n" + session.draft
    }

    private func handle(_ event: HermesGatewayClient.Event) {
        switch event {
        case .messageStart:
            let id = UUID()
            currentAIMessageID = id
            session.items.append(.aiMessage(id: id, senderLabel: "HERMES · \(session.model.uppercased())", text: "", isStreaming: true))

        case .thinkingDelta(_, let text):
            if let block = currentThinking {
                block.text += text
            } else {
                let block = ThinkingBlockModel(text: text, seconds: 0)
                currentThinking = block
                session.items.append(.thinking(block))
            }

        case .toolStart(_, let toolID, let name, let context):
            let call = ToolCall(name: name, argument: context, output: "", seconds: nil, isRunning: true)
            toolCalls[toolID] = call
            session.items.append(.toolCall(call))

        case .toolComplete(_, let toolID, _, let output, _, let errorText, _):
            guard let call = toolCalls[toolID] else { return }
            call.output = errorText ?? output
            call.isRunning = false

        case .messageDelta(_, let text):
            guard let id = currentAIMessageID,
                  let index = session.items.firstIndex(where: { $0.id == id }),
                  case .aiMessage(_, let label, let existing, _) = session.items[index]
            else { return }
            session.items[index] = .aiMessage(id: id, senderLabel: label, text: existing + text, isStreaming: true)

        case .approvalRequest(_, let command, let description, _, _):
            let request = PermissionRequest(command: command ?? description ?? "polecenie")
            request.onDecide = { [weak self] approve in
                guard let sessionID = self?.session.gatewaySessionID else { return }
                Task { try? await HermesGatewayClient.shared.respondApproval(sessionID: sessionID, approve: approve) }
            }
            session.items.append(.permission(request))

        case .clarifyRequest:
            break // ponytail: no UI surface for clarify prompts this wave — not in PLAN-V2 §7.3 scope.

        case .messageComplete(_, let text, _, let inputTokens, let outputTokens, _, _, _, let contextUsed, let contextMax, _):
            if let id = currentAIMessageID, let index = session.items.firstIndex(where: { $0.id == id }),
               case .aiMessage(_, let label, _, _) = session.items[index] {
                session.items[index] = .aiMessage(id: id, senderLabel: label, text: text, isStreaming: false)
            }
            session.contextUsed = contextUsed
            session.contextMax = contextMax
            currentAIMessageID = nil
            currentThinking = nil
            toolCalls.removeAll()
            Task {
                await TokenUsageRecorder.shared.record(
                    model: session.model, source: "kiwi-agent", promptEvalCount: inputTokens, evalCount: outputTokens
                )
            }
            onPersist?()

        case .sessionTitle(_, let title):
            session.title = title
            onPersist?()

        case .turnError(_, let message):
            session.items.append(.aiMessage(id: UUID(), senderLabel: "HERMES", text: "⚠️ \(message)", isStreaming: false))
            currentAIMessageID = nil
            currentThinking = nil
            onPersist?()

        case .ready, .subagentStart, .subagentText, .subagentComplete:
            break // ponytail: subagent progress has no UI surface in ConversationView yet.
        }
    }
}

// MARK: - ChatSessionController

@MainActor
@Observable
final class ChatSessionController {
    let session: ConversationSession

    private var thinkingModelCache: Set<String> = []
    private var thinkingModelCacheLoaded = false

    /// Wired by `ConversationStore` at controller creation — saves the session
    /// snapshot to disk. Called at end-of-turn points only, never per-chunk.
    var onPersist: (() -> Void)?

    init(session: ConversationSession) {
        self.session = session
    }

    func send(_ text: String) {
        if session.title == "Nowa rozmowa" { session.title = String(text.prefix(40)) }
        session.items.append(.userMessage(id: UUID(), text: text))
        if session.pendingAttachments.contains(where: { $0.kind != .image }) {
            session.items.append(.aiMessage(
                id: UUID(), senderLabel: "CHAT",
                text: "⚠️ Chat obsługuje tylko załączniki obrazów — PDF/pliki działają wyłącznie w Agent.",
                isStreaming: false
            ))
            session.pendingAttachments.removeAll()
        }
        if let claudeModel = ClaudeCodeService.parseModelID(session.model) {
            if !session.pendingAttachments.isEmpty {
                session.items.append(.aiMessage(
                    id: UUID(), senderLabel: "CHAT",
                    text: "⚠️ Model Claude w Chacie nie obsługuje załączników obrazów — przełącz na model Ollama.",
                    isStreaming: false
                ))
                session.pendingAttachments.removeAll()
            }
            onPersist?()
            Task { await runClaude(text: text, model: claudeModel) }
        } else {
            onPersist?()
            Task { await runOllama(text: text, model: session.model) }
        }
    }

    // MARK: Claude — headless `claude -p`, no tool/permission events surfaced
    // by `ClaudeCodeService` today (its NDJSON parser only yields text_delta +
    // result — see its header comment), so Chat never shows a PermissionCard.
    // Extending the CLI invocation with `--permission-mode`/tool streaming is
    // real infra work, not a wiring change — left out of this wave.

    private func runClaude(text: String, model: ClaudeCodeService.ClaudeModel) async {
        let id = UUID()
        session.items.append(.aiMessage(id: id, senderLabel: "CLAUDE · \(model.displayName.uppercased())", text: "", isStreaming: true))

        let service = ClaudeCodeService()
        do {
            for try await delta in service.streamMessage(prompt: text, model: model, resumeSessionID: session.claudeResumeSessionID) {
                switch delta {
                case .content(let chunk):
                    appendToAIMessage(chunk, id: id)
                case .result(let info):
                    if let sessionID = info.sessionID { session.claudeResumeSessionID = sessionID }
                    if let cost = info.costUSD { session.totalCostUSD += cost }
                }
            }
            finishAIMessage(id: id)
        } catch {
            failAIMessage(id: id, message: error.localizedDescription)
        }
    }

    // MARK: Ollama — local or cloud model, routed by bare name in `session.model`.

    private func runOllama(text: String, model: String) async {
        let id = UUID()
        session.items.append(.aiMessage(id: id, senderLabel: "OLLAMA · \(model.uppercased())", text: "", isStreaming: true))

        await loadThinkingModelsIfNeeded()
        // ponytail: same local/cloud fallback heuristic as v1's ChatState.isLocalOllamaModel —
        // ":cloud" suffix when we haven't fetched capabilities for this exact name.
        let isLocal = !model.hasSuffix(":cloud")
        let think: Bool? = thinkingModelCache.contains(model) ? false : nil
        var history = historyMessages()
        // ponytail: images ride only on this turn's outgoing request, not saved
        // into session.items — reopening the session from history replays text
        // only, same as the rest of Chat's history today.
        if !session.pendingAttachments.isEmpty, let last = history.last {
            history[history.count - 1] = OllamaService.ChatPayloadMessage(
                role: last.role, content: last.content, images: session.pendingAttachments.map(\.base64)
            )
            session.pendingAttachments.removeAll()
        }

        let service = OllamaService()
        do {
            for try await delta in service.streamChat(model: model, messages: history, think: think, isLocal: isLocal) {
                switch delta {
                case .content(let chunk):
                    appendToAIMessage(chunk, id: id)
                case .stats(let stats):
                    session.totalTokens += stats.evalCount
                    Task {
                        await TokenUsageRecorder.shared.record(
                            model: model, source: "kiwi-chat",
                            promptEvalCount: stats.promptEvalCount, evalCount: stats.evalCount
                        )
                    }
                }
            }
            finishAIMessage(id: id)
        } catch {
            failAIMessage(id: id, message: error.localizedDescription)
        }
    }

    private func loadThinkingModelsIfNeeded() async {
        guard !thinkingModelCacheLoaded else { return }
        thinkingModelCacheLoaded = true
        guard let models = try? await OllamaService().listModelsDetailed() else { return }
        thinkingModelCache = Set(models.filter(\.supportsThinking).map(\.name))
    }

    /// Prior turns as plain text — the light equivalent of v1 ChatState's
    /// `buildHistory()`, minus persona/memory/web-context/image-window features
    /// (out of scope: this wave wires transport, not chat feature parity).
    private func historyMessages() -> [OllamaService.ChatPayloadMessage] {
        session.items.compactMap { item -> OllamaService.ChatPayloadMessage? in
            switch item {
            case .userMessage(_, let text): .init(role: "user", content: text)
            case .aiMessage(_, _, let text, _) where !text.isEmpty: .init(role: "assistant", content: text)
            default: nil
            }
        }
    }

    // MARK: Shared item mutation helpers

    private func appendToAIMessage(_ chunk: String, id: UUID) {
        guard let index = session.items.firstIndex(where: { $0.id == id }),
              case .aiMessage(_, let label, let existing, _) = session.items[index]
        else { return }
        session.items[index] = .aiMessage(id: id, senderLabel: label, text: existing + chunk, isStreaming: true)
    }

    private func finishAIMessage(id: UUID) {
        guard let index = session.items.firstIndex(where: { $0.id == id }),
              case .aiMessage(_, let label, let text, _) = session.items[index]
        else { return }
        session.items[index] = .aiMessage(id: id, senderLabel: label, text: text, isStreaming: false)
        onPersist?()
    }

    private func failAIMessage(id: UUID, message: String) {
        guard let index = session.items.firstIndex(where: { $0.id == id }) else { return }
        session.items[index] = .aiMessage(id: id, senderLabel: "SYSTEM", text: "⚠️ \(message)", isStreaming: false)
        onPersist?()
    }
}
