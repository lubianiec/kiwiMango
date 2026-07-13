import Foundation

// Fala 3/C1: real backends now drive `items` (see `ConversationBackends.swift` —
// `AgentSessionController`/`ChatSessionController`). The mock factories from
// Fala 2/B3 are gone; new tabs start empty (PLAN-V2 §7.3: "✦ Nowa sesja").

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
    /// Wired by the backend controller that created this request — carries the
    /// decision back to `HermesGatewayClient.respondApproval`. `nil` means no
    /// live backend is listening (shouldn't happen in practice: Chat never
    /// creates a `PermissionRequest` today, see `ChatSessionController`).
    var onDecide: ((Bool) -> Void)?

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
    var items: [ConversationItem] {
        didSet { scrollPulse += 1 }
    }
    /// Set true whenever ≥1 thinking block in THIS session is expanded.
    var autoscrollPaused: Bool = false

    /// Bumps on every `items` mutation so the transcript can scroll to bottom
    /// during streaming (when item count stays constant but text grows).
    var scrollPulse: Int = 0

    /// Real `@State`/`@Bindable` draft per session (was a dead `Binding` stub
    /// in Fala 2/B3) — lives on the session so switching tabs preserves it.
    var draft: String = ""

    // MARK: Backend bookkeeping (Fala 3/C1)

    /// Hermes gateway `session_id` for this tab, once created — `nil` until
    /// the first `send()`. Reset whenever `model` changes so the next send
    /// opens a fresh gateway session with the new model (PLAN-V2: model
    /// is fixed per `session.create`, not switchable mid-session).
    var gatewaySessionID: String?
    /// `claude -p --resume <id>` continuity for Chat's Claude route.
    var claudeResumeSessionID: String?
    /// Agent's "kontekst: X / Y tok." — from the gateway's `message.complete` usage.
    var contextUsed: Int?
    var contextMax: Int?
    /// Chat's "model · X tok. · koszt" — accumulated across turns in this tab.
    var totalTokens: Int = 0
    var totalCostUSD: Double = 0

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

}
