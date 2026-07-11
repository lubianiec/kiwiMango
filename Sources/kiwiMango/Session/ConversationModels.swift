import Foundation

// ponytail: minimal mock-backed models for Fala 2/B3. Real Hermes/Claude wiring
// (Fala 3 / C1) replaces `ConversationSession.mock*` factories and the
// `ConversationStore` mutating methods with actual gateway/CLI event streams —
// the view layer above (ConversationView) is written against these shapes so
// that swap is additive, not a rewrite.

// ponytail: these three are reference types (not structs) so a nested toggle
// (thinking expand, permission decision) mutates in place and every view
// holding the enum case sees it — no reaching back into `session.items` by
// index to write a struct copy back.

/// One turn's tool invocation, rendered as a collapsible mono capsule (PLAN-V2 §7.3).
@Observable
final class ToolCall: Identifiable {
    let id = UUID()
    var name: String
    var argument: String
    var output: String
    var seconds: Double?
    var isRunning: Bool
    var isExpanded = false

    init(name: String, argument: String, output: String, seconds: Double?, isRunning: Bool) {
        self.name = name
        self.argument = argument
        self.output = output
        self.seconds = seconds
        self.isRunning = isRunning
    }
}

/// A collapsed-by-default "tok myśli" block (PLAN-V2 §7.3).
@Observable
final class ThinkingBlockModel: Identifiable {
    let id = UUID()
    var text: String
    var seconds: Double
    var isExpanded = false

    init(text: String, seconds: Double) {
        self.text = text
        self.seconds = seconds
    }
}

/// Permission/approval prompt, mapped from claude CLI's permission stream (Chat)
/// or the gateway's own approval events (Agent) — PLAN-V2 §7.3.
@Observable
final class PermissionRequest: Identifiable {
    let id = UUID()
    var command: String
    var decision: Decision = .pending
    var resultLine: String?

    enum Decision { case pending, allowed, allowedForSession, denied }

    init(command: String) {
        self.command = command
    }
}

/// One message in a conversation. Ordering within `ConversationSession.items`
/// is chronological; thinking/tool-call/permission each get their own item so
/// they interleave with messages exactly like the reference HTML.
enum ConversationItem: Identifiable {
    case userMessage(id: UUID, text: String)
    case aiMessage(id: UUID, senderLabel: String, text: String, isStreaming: Bool)
    case thinking(ThinkingBlockModel)
    case toolCall(ToolCall)
    case permission(PermissionRequest)

    var id: UUID {
        switch self {
        case .userMessage(let id, _): id
        case .aiMessage(let id, _, _, _): id
        case .thinking(let block): block.id
        case .toolCall(let call): call.id
        case .permission(let request): request.id
        }
    }
}

/// Which backend a `ConversationView` instance is pointed at — drives quick
/// actions visibility and the session/permission picker's options only;
/// message rendering is identical for both (PLAN-V2 §5: "ConversationView jest jeden").
enum ConversationKind {
    case agent, chat
}

/// One Safari-like session tab. Each tab owns an independent conversation +
/// model + autoscroll-pause flag (PLAN-V2 §7.3, pułapka #6: "NIE globalna").
@Observable
final class ConversationSession: Identifiable {
    let id = UUID()
    var title: String
    var model: String
    var items: [ConversationItem]
    /// Set true whenever ≥1 thinking block in THIS session is expanded.
    var autoscrollPaused: Bool = false

    init(title: String, model: String, items: [ConversationItem] = []) {
        self.title = title
        self.model = model
        self.items = items
    }

    /// True while any item is a still-streaming AI message or running tool call —
    /// drives the header status dot.
    var isWorking: Bool {
        items.contains { item in
            if case .aiMessage(_, _, _, let streaming) = item, streaming { return true }
            if case .toolCall(let call) = item, call.isRunning { return true }
            return false
        }
    }

    // MARK: - Mock factories (Fala 2/B3 — replaced by real backend in Fala 3/C1)

    static func mockAgent() -> ConversationSession {
        let thinking = ThinkingBlockModel(
            text: "Health endpoint najpierw — jeśli disconnected, muszę otworzyć kartę Flow w tle zanim odpalę generację.",
            seconds: 2.8
        )
        return ConversationSession(
            title: "Obraz kiwi — flow",
            model: "kimi-k2.7-code:cloud",
            items: [
                .userMessage(id: UUID(), text: "sprawdź czy flow-agent działa i zrób obraz kiwi w stylu manga"),
                .thinking(thinking),
                .toolCall(ToolCall(
                    name: "exec", argument: "curl 127.0.0.1:8765/health",
                    output: "{\"status\":\"connected\",\"browser\":\"chrome\",\"queue\":0}",
                    seconds: 0.3, isRunning: false
                )),
                .toolCall(ToolCall(
                    name: "flow-agent", argument: "image \"kiwi bird, dark manga style\"",
                    output: "▸ hermes_flow.py image — czekam na render… (12 s)",
                    seconds: nil, isRunning: true
                )),
                .aiMessage(
                    id: UUID(), senderLabel: "HERMES · KIMI-K2.7",
                    text: "Flow-agent **połączony** ✅ — kolejka pusta. Generuję obraz przez `hermes_flow.py`, zapiszę do `~/Kazik/Downloads/`. Nano Banana = zero kredytów",
                    isStreaming: true
                ),
            ]
        )
    }

    static func mockChat() -> ConversationSession {
        let thinking = ThinkingBlockModel(
            text: "Plik ma 872 linie — za duży. Widzę trzy naturalne granice podziału: KPI, wykresy, tabele.",
            seconds: 4.2
        )
        return ConversationSession(
            title: "Refactor Dashboard",
            model: "claude — Fable 5",
            items: [
                .userMessage(id: UUID(), text: "przeanalizuj DashboardView.swift i zaproponuj refactor"),
                .thinking(thinking),
                .toolCall(ToolCall(
                    name: "read", argument: "DashboardView.swift",
                    output: "struct DashboardView: View {\n    @State private var store = DashboardStore()\n    …",
                    seconds: nil, isRunning: false
                )),
                .permission(PermissionRequest(command: "$ swift build 2>&1 | tail -5")),
                .aiMessage(
                    id: UUID(), senderLabel: "CLAUDE · FABLE 5",
                    text: "Plik do podziału na 3: `DashboardKPI.swift`, `DashboardCharts.swift`, `DashboardTables.swift`. Wspólny wzorzec ViewThatFits → jeden `AdaptiveRow`. Zaczynam?",
                    isStreaming: true
                ),
            ]
        )
    }
}
