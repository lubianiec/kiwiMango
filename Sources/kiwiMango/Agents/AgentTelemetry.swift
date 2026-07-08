import Foundation
import Observation

// MARK: - F18.1 — AgentTelemetry: czytnik transkryptów JSONL Claude Code
//
// Źródło: `~/.claude/projects/<slug-cwd>/<sessionId>.jsonl`, dopisywane NA ŻYWO
// przez CLI. Zweryfikowane empirycznie 2026-07-07/08 na tym Macu (patrz
// PLAN.md F18 nagłówek) — kilka założeń oryginalnego planu było błędnych:
//
//   • Pierwsza linia pliku NIE zawsze jest user/assistant (bywają
//     queue-operation/attachment/last-prompt) — trzeba filtrować po "type".
//   • `isSidechain:true` w praktyce nigdy nie występuje na tym Macu — plan
//     mylił się co do subagentów. Subagent = wywołanie narzędzia
//     `tool_use.name == "Agent"` (lub legacy `"Task"`), zakończenie +
//     telemetria wraca jako odpowiadający `tool_result`, gdzie jeden z
//     bloków tekstowych zawiera surowy blok `<usage>...</usage>` do
//     sparsowania regexem.
//   • `TaskCreate`/`TaskUpdate` to ZUPEŁNIE INNY byt — wewnętrzna checklista
//     sesji (nie subagenci). `TaskCreate` NIE niesie `taskId` w swoim
//     `input` (tylko subject/description/activeForm) — id jest przydzielane
//     przez system sekwencyjnie w kolejności tworzenia i dopiero
//     `TaskUpdate` go referencjonuje. Stąd heurystyka: id = kolejny numer
//     (1-based) w kolejności napotkanych `TaskCreate` w tej sesji.

// MARK: - Model danych zadań sesji (F18.1 3b)

struct AgentTaskItem: Identifiable, Equatable {
    let id: String
    var subject: String
    var status: String
    var blockedBy: [String] = []

    var isCompleted: Bool { status == "completed" }
    var isInProgress: Bool { status == "in_progress" }
}

// MARK: - Model subagenta (F18.1 pkt 4 skorygowany)

struct SubagentInfo: Identifiable, Equatable {
    let id: String // tool_use id wywołania Agent/Task
    var subagentType: String?
    var description: String?
    var isFinished: Bool = false
    var tokens: Int?
    var toolUses: Int?
    var durationMs: Int?

    var displayName: String {
        description ?? subagentType ?? "subagent"
    }
}

// MARK: - Ostatnia/ostatnie czynności (F18.1 pkt 2-3)

struct ToolActivity: Identifiable, Equatable {
    let id = UUID()
    let humanDescription: String
    let rawName: String
    let timestamp: Date
}

// MARK: - Tłumaczenie tool → czynność po polsku (F18.1 pkt 3a)
// Czysta funkcja, testowalna niezależnie od aktora.

enum ToolHumanizer {
    static func describe(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            let cmd = (input["command"] as? String) ?? ""
            return "⚙ wykonuję komendę: \(truncate(cmd))"
        case "Write", "Edit":
            let path = (input["file_path"] as? String) ?? ""
            return "✍ piszę plik \(lastComponent(path))"
        case "Read":
            let path = (input["file_path"] as? String) ?? ""
            return "czytam \(lastComponent(path))"
        case "Grep", "Glob":
            let pattern = (input["pattern"] as? String) ?? ""
            return "szukam w kodzie: \(truncate(pattern))"
        case "WebFetch", "WebSearch":
            return "sprawdzam w internecie"
        case "Agent", "Task":
            if let desc = input["description"] as? String, !desc.isEmpty {
                return "odpalam subagenta: \(truncate(desc))"
            }
            return "odpalam subagenta"
        default:
            return name
        }
    }

    private static func truncate(_ s: String, limit: Int = 60) -> String {
        let collapsed = s.replacingOccurrences(of: "\n", with: " ")
        guard collapsed.count > limit else { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return String(collapsed[..<idx]) + "…"
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// Fala 24 (F24.2): Hermes gateway tool names (`terminal`, `read_file`, …
    /// — full list confirmed live in F24.0's `session.info.tools` payload),
    /// distinct namespace from Claude Code's `Bash`/`Write`/`Read`/etc above.
    /// `context`/`command` come straight off `tool.start`/`tool.complete`
    /// payloads — no JSONL parsing involved here (that's Claude-Code-specific).
    static func describeHermes(name: String, context: String, command: String?) -> String {
        let cmd = command ?? context
        switch name {
        case "terminal", "process":
            return "⚙ wykonuję komendę: \(truncate(cmd))"
        case "write_file", "patch":
            return "✍ piszę plik: \(truncate(cmd))"
        case "read_file":
            return "czytam plik: \(truncate(cmd))"
        case "search_files":
            return "szukam w plikach: \(truncate(cmd))"
        case "execute_code":
            return "▶ wykonuję kod"
        case "browser_navigate", "browser_click", "browser_type", "browser_snapshot",
             "browser_scroll", "browser_press", "browser_back", "browser_console",
             "browser_get_images", "browser_vision":
            return "🌐 przeglądarka: \(truncate(context))"
        case "delegate_task":
            return "odpalam subagenta: \(truncate(context))"
        case "image_generate":
            return "🎨 generuję obraz"
        case "video_analyze":
            return "🎬 analizuję wideo"
        case "vision_analyze":
            return "👁 analizuję obraz"
        case "memory":
            return "🧠 pamięć: \(truncate(context))"
        case "cronjob":
            return "⏰ harmonogram: \(truncate(context))"
        case "text_to_speech":
            return "🔊 synteza mowy"
        case "todo":
            return "☑ lista zadań"
        default:
            return truncate(context.isEmpty ? name : context)
        }
    }
}

// MARK: - Zdarzenia sparsowane poza MainActor (Sendable, przekraczają granicę aktora)

struct ParsedUsageEvent: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let timestamp: Date
}

struct ParsedToolUseEvent: Sendable {
    let toolUseId: String
    let rawName: String
    let humanDescription: String
    let timestamp: Date
    let subagentType: String?
    let subagentDescription: String?
}

struct ParsedToolResultEvent: Sendable {
    let toolUseId: String?
    let text: String
}

enum ParsedTaskOpKind: Sendable {
    case create
    case update
}

struct ParsedTaskOpEvent: Sendable {
    let kind: ParsedTaskOpKind
    let subject: String?
    let taskId: String?
    let status: String?
    let blockedBy: [String]
}

struct ParsedBatch: Sendable {
    var usageEvents: [ParsedUsageEvent] = []
    var toolUseEvents: [ParsedToolUseEvent] = []
    var toolResultEvents: [ParsedToolResultEvent] = []
    var taskOpEvents: [ParsedTaskOpEvent] = []

    var isEmpty: Bool {
        usageEvents.isEmpty && toolUseEvents.isEmpty && toolResultEvents.isEmpty && taskOpEvents.isEmpty
    }
}

// MARK: - Parser czystych linii JSONL (nonisolated — działa poza MainActor)

enum TranscriptParser {
    /// Parsuje nowo doczytany tekst (może się kończyć w połowie linii),
    /// z buforem niedokończonej linii z poprzedniego ticku. Zwraca
    /// wyciągnięte zdarzenia + nowy bufor (końcowa niedokończona linia,
    /// jeśli jest).
    static func parse(newText: String, carryover: String) -> (batch: ParsedBatch, remainder: String) {
        var batch = ParsedBatch()
        let combined = carryover + newText
        guard !combined.isEmpty else { return (batch, "") }

        var lines = combined.components(separatedBy: "\n")
        var remainder = ""
        if !combined.hasSuffix("\n") {
            remainder = lines.removeLast()
        } else if lines.last == "" {
            lines.removeLast()
        }

        for line in lines where !line.isEmpty {
            parseLine(line, into: &batch)
        }
        return (batch, remainder)
    }

    private static func parseLine(_ line: String, into batch: inout ParsedBatch) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        let timestamp = isoDate(obj["timestamp"] as? String) ?? Date()

        switch type {
        case "assistant":
            parseAssistantLine(obj, timestamp: timestamp, into: &batch)
        case "user":
            parseUserLine(obj, into: &batch)
        default:
            break
        }
    }

    private static func parseAssistantLine(_ obj: [String: Any], timestamp: Date, into batch: inout ParsedBatch) {
        guard let message = obj["message"] as? [String: Any] else { return }

        if let usage = message["usage"] as? [String: Any] {
            batch.usageEvents.append(ParsedUsageEvent(
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                timestamp: timestamp
            ))
        }

        guard let content = message["content"] as? [[String: Any]] else { return }
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let toolName = block["name"] as? String,
                  let toolId = block["id"] as? String
            else { continue }
            let input = block["input"] as? [String: Any] ?? [:]

            // TaskCreate/TaskUpdate: checklista wewnętrzna sesji, NIE subagenci.
            if toolName == "TaskCreate" {
                batch.taskOpEvents.append(ParsedTaskOpEvent(
                    kind: .create,
                    subject: input["subject"] as? String,
                    taskId: nil,
                    status: nil,
                    blockedBy: []
                ))
                continue
            }
            if toolName == "TaskUpdate" {
                batch.taskOpEvents.append(ParsedTaskOpEvent(
                    kind: .update,
                    subject: nil,
                    taskId: input["taskId"] as? String,
                    status: input["status"] as? String,
                    blockedBy: input["addBlockedBy"] as? [String] ?? []
                ))
                continue
            }

            let isSubagentLaunch = toolName == "Agent" || toolName == "Task"
            batch.toolUseEvents.append(ParsedToolUseEvent(
                toolUseId: toolId,
                rawName: toolName,
                humanDescription: ToolHumanizer.describe(name: toolName, input: input),
                timestamp: timestamp,
                subagentType: isSubagentLaunch ? (input["subagent_type"] as? String) : nil,
                subagentDescription: isSubagentLaunch ? (input["description"] as? String) : nil
            ))
        }
    }

    private static func parseUserLine(_ obj: [String: Any], into batch: inout ParsedBatch) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }

        for block in content {
            guard block["type"] as? String == "tool_result" else { continue }
            let toolUseId = block["tool_use_id"] as? String
            var text = ""
            if let s = block["content"] as? String {
                text = s
            } else if let arr = block["content"] as? [[String: Any]] {
                text = arr.compactMap { $0["type"] as? String == "text" ? ($0["text"] as? String) : nil }
                    .joined(separator: "\n")
            }
            guard !text.isEmpty else { continue }
            batch.toolResultEvents.append(ParsedToolResultEvent(toolUseId: toolUseId, text: text))
        }
    }

    private static func isoDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return DateFormatters.withFraction.date(from: s) ?? DateFormatters.plain.date(from: s)
    }
}

private enum DateFormatters {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Parsowanie bloku `<usage>` z tool_result subagenta (regex, best-effort)

enum SubagentUsageParser {
    struct Stats {
        var agentId: String?
        var tokens: Int?
        var toolUses: Int?
        var durationMs: Int?
    }

    /// Zwraca `nil` gdy tekst w ogóle nie wygląda na wynik zakończenia
    /// subagenta (brak bloku `<usage>` i brak `agentId:`).
    static func parse(_ text: String) -> Stats? {
        let agentId = firstMatch(in: text, pattern: "agentId:\\s*(\\S+)")
        let tokens = firstIntMatch(in: text, pattern: "subagent_tokens:\\s*(\\d+)")
        let toolUses = firstIntMatch(in: text, pattern: "tool_uses:\\s*(\\d+)")
        let duration = firstIntMatch(in: text, pattern: "duration_ms:\\s*(\\d+)")

        guard agentId != nil || tokens != nil else { return nil }
        return Stats(agentId: agentId, tokens: tokens, toolUses: toolUses, durationMs: duration)
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func firstIntMatch(in text: String, pattern: String) -> Int? {
        firstMatch(in: text, pattern: pattern).flatMap { Int($0) }
    }
}

// MARK: - Stan telemetrii pojedynczej sesji (MainActor — czytany przez UI)

@MainActor
@Observable
final class SessionTelemetry {
    let sessionID: UUID
    let workDir: URL
    let startedAt: Date

    /// Znaleziony plik transkryptu tej sesji, jeśli już zmapowany (pkt 6/8).
    private(set) var fileURL: URL?
    private(set) var lookupAttempts = 0
    private(set) var gaveUpLookup = false

    private(set) var inputTokens = 0
    private(set) var outputTokens = 0
    private(set) var cacheReadTokens = 0
    private(set) var cacheCreationTokens = 0

    private(set) var currentActivity: ToolActivity?
    private(set) var recentActivities: [ToolActivity] = []
    /// (timestamp, delta tokenów) przycinane do okna 60 s — surowiec sparkline.
    private(set) var tokenRateSamples: [(Date, Int)] = []

    private(set) var tasks: [AgentTaskItem] = []
    private(set) var subagents: [SubagentInfo] = []

    // Wewnętrzny stan czytnika — niewidoczny dla UI.
    @ObservationIgnored var readOffset: UInt64 = 0
    @ObservationIgnored var pendingPartialLine = ""
    @ObservationIgnored private var subagentIndexByToolUseId: [String: Int] = [:]

    init(sessionID: UUID, workDir: URL, startedAt: Date) {
        self.sessionID = sessionID
        self.workDir = workDir
        self.startedAt = startedAt
    }

    func setFileURL(_ url: URL) {
        fileURL = url
    }

    func recordLookupAttempt(found: Bool) {
        lookupAttempts += 1
        if found {
            gaveUpLookup = false
        } else if lookupAttempts >= 2 {
            gaveUpLookup = true
            print("[AgentTelemetry] brak pliku transkryptu dla sesji \(sessionID) po \(lookupAttempts) próbach — degradacja do statusu bez tokenów")
        }
    }

    /// Aktualny tempo tokenów (suma delt w oknie 60s) — do sparkline w F18.2.
    var tokensPerMinuteWindow: [(Date, Int)] { tokenRateSamples }

    func apply(_ batch: ParsedBatch) {
        guard !batch.isEmpty else { return }

        for usage in batch.usageEvents {
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
            cacheReadTokens += usage.cacheReadTokens
            cacheCreationTokens += usage.cacheCreationTokens
            tokenRateSamples.append((usage.timestamp, usage.inputTokens + usage.outputTokens))
        }
        trimTokenRateWindow()

        for toolUse in batch.toolUseEvents {
            if let current = currentActivity {
                recentActivities.insert(current, at: 0)
                if recentActivities.count > 3 { recentActivities.removeLast() }
            }
            currentActivity = ToolActivity(
                humanDescription: toolUse.humanDescription,
                rawName: toolUse.rawName,
                timestamp: toolUse.timestamp
            )

            if toolUse.rawName == "Agent" || toolUse.rawName == "Task" {
                let info = SubagentInfo(
                    id: toolUse.toolUseId,
                    subagentType: toolUse.subagentType,
                    description: toolUse.subagentDescription
                )
                subagents.append(info)
                subagentIndexByToolUseId[toolUse.toolUseId] = subagents.count - 1
            }
        }

        for result in batch.toolResultEvents {
            guard let stats = SubagentUsageParser.parse(result.text) else { continue }
            let index: Int?
            if let toolUseId = result.toolUseId, let i = subagentIndexByToolUseId[toolUseId] {
                index = i
            } else {
                // Fallback best-effort: dopasuj do ostatniego niezakończonego
                // subagenta, gdy `tool_use_id` nie da się skorelować.
                index = subagents.lastIndex(where: { !$0.isFinished })
            }
            guard let idx = index else { continue }
            subagents[idx].tokens = stats.tokens
            subagents[idx].toolUses = stats.toolUses
            subagents[idx].durationMs = stats.durationMs
            subagents[idx].isFinished = true
            if let toolUseId = result.toolUseId {
                subagentIndexByToolUseId.removeValue(forKey: toolUseId)
            }
        }

        for op in batch.taskOpEvents {
            switch op.kind {
            case .create:
                // TaskCreate nie niesie taskId (zweryfikowane empirycznie) —
                // id = kolejny numer w kolejności tworzenia, zgodnie z tym
                // jak TaskUpdate potem referencjonuje "1", "2", "3"...
                let id = String(tasks.count + 1)
                tasks.append(AgentTaskItem(id: id, subject: op.subject ?? "?", status: "pending"))
            case .update:
                guard let taskId = op.taskId, let idx = tasks.firstIndex(where: { $0.id == taskId }) else { continue }
                if let status = op.status { tasks[idx].status = status }
                if !op.blockedBy.isEmpty { tasks[idx].blockedBy = op.blockedBy }
            }
        }
    }

    private func trimTokenRateWindow() {
        let cutoff = Date().addingTimeInterval(-60)
        tokenRateSamples.removeAll { $0.0 < cutoff }
    }
}

// MARK: - AgentTelemetry — orkiestracja per-sesja (F18.1)

@MainActor
@Observable
final class AgentTelemetry {
    /// Musi być ustawiane przez widok Centrum Dowodzenia (F18.2): `true` gdy
    /// widok jest otwarty. Timer działa TYLKO wtedy i tylko gdy jest ≥1
    /// śledzona sesja — inaczej zero kosztu (zasada F6.2/F9).
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            isActive ? startTimerIfNeeded() : stopTimer()
        }
    }

    private(set) var states: [UUID: SessionTelemetry] = [:]

    @ObservationIgnored
    private var timer: Timer?

    /// Rejestruje sesję do śledzenia (wołane przy otwarciu Centrum lub
    /// spawn'ie nowej sesji podczas gdy Centrum jest otwarte — F18.2).
    func attach(_ session: AgentSession) {
        guard states[session.id] == nil else { return }
        states[session.id] = SessionTelemetry(
            sessionID: session.id,
            workDir: session.workDir,
            startedAt: session.startedAt
        )
        startTimerIfNeeded()
    }

    /// Wyrejestrowuje sesję (zamknięcie Centrum lub koniec sesji).
    func detach(_ session: AgentSession) {
        states.removeValue(forKey: session.id)
        if states.isEmpty { stopTimer() }
    }

    func telemetry(for session: AgentSession) -> SessionTelemetry? {
        states[session.id]
    }

    // MARK: Timer

    private func startTimerIfNeeded() {
        guard isActive, !states.isEmpty, timer == nil else { return }
        let newTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.tick()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        for state in states.values {
            if state.fileURL == nil {
                if !state.gaveUpLookup {
                    tryLocateFile(for: state)
                }
                continue
            }
            readNewBytes(for: state)
        }
    }

    // MARK: Mapowanie sesja→plik (F18.1 pkt 6)

    /// Slug katalogu projektu: `workDir` z `/` zamienionymi na `-`
    /// (bez innych zmian znaków — zweryfikowane empirycznie).
    nonisolated static func slug(forWorkDir workDir: URL) -> String {
        workDir.path.replacingOccurrences(of: "/", with: "-")
    }

    /// Znajduje plik jsonl odpowiadający danej sesji: najnowszy `.jsonl`
    /// w katalogu slugu, zmodyfikowany PO `session.startedAt`, którego
    /// pierwsza linia typu user/assistant nie ma `isSidechain:true`.
    nonisolated static func mapSession(_ session: AgentSession) -> URL? {
        mapSession(workDir: session.workDir, startedAt: session.startedAt)
    }

    nonisolated static func mapSession(workDir: URL, startedAt: Date) -> URL? {
        let slug = slug(forWorkDir: workDir)
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)", isDirectory: true)

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let candidates = entries
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { url -> (URL, Date)? in
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      mtime > startedAt
                else { return nil }
                return (url, mtime)
            }
            .sorted { $0.1 > $1.1 }

        for (url, _) in candidates where !isSidechainTranscript(url) {
            return url
        }
        return nil
    }

    /// Sprawdza pierwszą linię typu user/assistant w pliku (ograniczone do
    /// pierwszych ~64KB — wystarczające, bo transkrypt zaczyna się od
    /// nagłówka sesji). Zwraca `true` gdy jest to sidechain (subagent),
    /// czyli NIE jest to główna sesja, którą chcemy śledzić.
    private nonisolated static func isSidechainTranscript(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let chunk = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: chunk, encoding: .utf8)
        else { return false }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "user" || type == "assistant"
            else { continue }
            return (obj["isSidechain"] as? Bool) == true
        }
        return false
    }

    private func tryLocateFile(for state: SessionTelemetry) {
        let workDir = state.workDir
        let startedAt = state.startedAt
        Task.detached(priority: .utility) {
            let url = Self.mapSession(workDir: workDir, startedAt: startedAt)
            await MainActor.run {
                if let url {
                    state.setFileURL(url)
                    state.recordLookupAttempt(found: true)
                } else {
                    state.recordLookupAttempt(found: false)
                }
            }
        }
    }

    // MARK: Czytanie przyrostowe (F18.1 pkt 3-4)

    private func readNewBytes(for state: SessionTelemetry) {
        guard let url = state.fileURL else { return }
        let offset = state.readOffset
        let carryover = state.pendingPartialLine

        Task.detached(priority: .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }

            guard let size = try? handle.seekToEnd(), size > offset else { return }
            (try? handle.seek(toOffset: offset))
            guard let data = try? handle.read(upToCount: Int(size - offset)),
                  let text = String(data: data, encoding: .utf8)
            else { return }

            let (batch, remainder) = TranscriptParser.parse(newText: text, carryover: carryover)

            await MainActor.run {
                state.apply(batch)
                state.pendingPartialLine = remainder
                state.readOffset = size
            }
        }
    }
}
