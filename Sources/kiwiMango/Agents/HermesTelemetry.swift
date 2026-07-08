import Foundation
import Observation

// MARK: - HermesTelemetry (Fala 24.7)
//
// Second telemetry source for Centrum Dowodzenia (`MissionControlView`),
// alongside F18's `AgentTelemetry` (Claude Code, JSONL-tailed). This one is
// fed LIVE from `HermesGatewayClient`'s event stream via `ChatState`'s
// persistent listener (F24.6) — no file parsing, the WS events ARE the
// telemetry. `AgentTelemetry`/`AgentManager` are untouched; this is a
// parallel, independent model, deliberately not unified with theirs (they're
// shaped around Claude Code's JSONL transcript concepts that don't apply
// here — session.kind/workDir/etc).
//
// Singleton (like `HermesGatewayClient.shared`) so `ChatState` (a plain
// `@Observable` class instantiated in `App.swift`, no environment access)
// can push updates directly without needing dependency injection threaded
// through the view hierarchy — `App.swift` just holds `HermesTelemetry.shared`
// in a `@State` var so SwiftUI observes and injects it via `.environment`.
@MainActor
@Observable
final class HermesTelemetry {
    static let shared = HermesTelemetry()
    private init() {}

    struct SubagentCard: Identifiable, Equatable {
        let id: String
        var description: String
        var isFinished: Bool = false
    }

    struct SessionCard: Identifiable, Equatable {
        let id: String // gateway session_id
        var conversationTitle: String
        var isTurnRunning: Bool
        var currentActivity: String?
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var subagents: [SubagentCard] = []
        var startedAt: Date = Date()
        var lastActivityAt: Date = Date()

        /// A session with a running root turn OR unfinished subagents still
        /// counts as "active" for the status bar / Centrum visibility — the
        /// plan explicitly wants delegated background work to keep the card
        /// (and the count) alive even after the root reply completed.
        var isActive: Bool { isTurnRunning || subagents.contains { !$0.isFinished } }
    }

    private(set) var cards: [SessionCard] = []

    /// Count of sessions that are doing SOMETHING right now (root turn or
    /// live subagents) — feeds the status bar's `Agenci [N]` alongside
    /// `AgentManager.runningCount` (F24.7 pkt "Licznik w status barze").
    var activeCount: Int { cards.count { $0.isActive } }

    // MARK: - Mutators (all called from ChatState's MainActor listener)

    func ensureCard(sessionID: String, conversationTitle: String) {
        if let index = cards.firstIndex(where: { $0.id == sessionID }) {
            cards[index].conversationTitle = conversationTitle
            cards[index].lastActivityAt = Date()
        } else {
            cards.append(SessionCard(id: sessionID, conversationTitle: conversationTitle, isTurnRunning: true))
        }
    }

    func setTurnRunning(sessionID: String, running: Bool) {
        guard let index = cards.firstIndex(where: { $0.id == sessionID }) else { return }
        cards[index].isTurnRunning = running
        cards[index].lastActivityAt = Date()
    }

    func setActivity(sessionID: String, text: String) {
        guard let index = cards.firstIndex(where: { $0.id == sessionID }) else { return }
        cards[index].currentActivity = text
        cards[index].lastActivityAt = Date()
    }

    /// `message.complete.usage` carries CUMULATIVE totals for the session, so
    /// this is a plain overwrite, not an add — matches pułapka (b) in the
    /// plan: never zero the bar between turns, just replace with the latest
    /// known cumulative snapshot.
    func setUsage(sessionID: String, input: Int, output: Int) {
        guard let index = cards.firstIndex(where: { $0.id == sessionID }) else { return }
        cards[index].inputTokens = input
        cards[index].outputTokens = output
        cards[index].lastActivityAt = Date()
    }

    func subagentStarted(sessionID: String, subagentID: String, description: String?) {
        guard let index = cards.firstIndex(where: { $0.id == sessionID }) else { return }
        cards[index].lastActivityAt = Date()
        if let subIndex = cards[index].subagents.firstIndex(where: { $0.id == subagentID }) {
            cards[index].subagents[subIndex].isFinished = false
            return
        }
        cards[index].subagents.append(SubagentCard(id: subagentID, description: description ?? "subagent"))
    }

    func subagentCompleted(sessionID: String, subagentID: String) {
        guard let index = cards.firstIndex(where: { $0.id == sessionID }) else { return }
        cards[index].lastActivityAt = Date()
        guard let subIndex = cards[index].subagents.firstIndex(where: { $0.id == subagentID }) else { return }
        cards[index].subagents[subIndex].isFinished = true
    }

    /// Drops idle cards (no root turn, no live subagents, quiet >5 min) so
    /// Centrum doesn't accumulate every chat conversation ever opened —
    /// call periodically (Centrum's own ticker, like `AgentTelemetry`).
    func pruneStale(now: Date = Date()) {
        cards.removeAll { card in
            !card.isActive && now.timeIntervalSince(card.lastActivityAt) > 300
        }
        // Finished subagents linger briefly (visible "✓ zakończony" beat)
        // then drop out of their parent card entirely.
        for index in cards.indices {
            cards[index].subagents.removeAll { sub in
                sub.isFinished && now.timeIntervalSince(cards[index].lastActivityAt) > 20
            }
        }
    }
}
