import Foundation
import AppKit

// ponytail: ChatModels.swift/MarkdownText.swift are the v1 "reuse, don't
// rewrite" files (PLAN-V2 §3), but they call into v1 services that PLAN-V2 §4
// explicitly does NOT carry over (Speech*, MermaidRenderer) or that just
// weren't part of this scaffold (HermesTelemetry, ObsidianSyncService,
// ToolHumanizer, MemoryService). Fala 1's job is a green build with placeholder
// pages — Agent/Chat aren't wired into ContentView yet, so these are no-op
// stubs, not real implementations. Fala 3 (AgentPage/ChatPage integration)
// replaces this whole file with the real services or trims the call sites
// that no longer apply in V2 (e.g. TTS/Mermaid may just not return in V2).

final class SpeechSynthesizer {
    func speak(_ text: String) {}
    func stopAll() {}
}

final class StreamingSpeechFeeder {
    init(synth: SpeechSynthesizer) {}
    func reset() {}
    func consume(fullContent: String, isFinal: Bool) {}
    static func stripMarkdown(_ text: String) -> String { text }
}

enum ObsidianSyncService {
    static func syncConversation(conversationId: Int64, title: String, model: String) {}
    static func generateTLDRIfNeeded(conversationId: Int64, title: String, model: String) {}
}

enum MemoryService {
    static func extractFacts(from content: String, model: String, conversationId: Int64) async -> [MemoryFact] { [] }
}

enum ToolHumanizer {
    static func describeHermes(name: String, context: String?, command: String?) -> String { name }
}

@MainActor
final class HermesTelemetry {
    static let shared = HermesTelemetry()
    private init() {}

    func ensureCard(sessionID: String, conversationTitle: String) {}
    func setTurnRunning(sessionID: String, running: Bool) {}
    func setActivity(sessionID: String, text: String) {}
    func subagentStarted(sessionID: String, subagentID: String, description: String?) {}
    func subagentCompleted(sessionID: String, subagentID: String) {}
    func setUsage(sessionID: String, input: Int, output: Int, model: String?, total: Int?, calls: Int?, contextUsed: Int?, contextMax: Int?, contextPercent: Double?) {}
}

@MainActor
final class MermaidRenderer {
    static let shared = MermaidRenderer()
    private init() {}
    func render(code: String) async -> NSImage? { nil }
}
