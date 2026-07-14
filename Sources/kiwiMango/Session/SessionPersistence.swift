import Foundation

// MARK: - SessionPersistence (PLAN-HISTORIA §1)
//
// `ConversationSession`/`ConversationItem` etc. are @Observable classes with
// closures (`PermissionRequest.onDecide`) — Codable doesn't apply to them
// directly. This is the flat DTO used only for disk round-trips.

struct SessionSnapshot: Codable {
    var id: UUID
    var title: String
    var model: String
    var kind: String // "chat" | "agent"
    var updatedAt: Date
    var gatewaySessionID: String?
    var reasoningEffort: String?
    var claudeResumeSessionID: String?
    var contextUsed: Int?
    var contextMax: Int?
    var totalTokens: Int
    var totalCostUSD: Double
    var items: [ItemSnapshot]

    struct ItemSnapshot: Codable {
        var type: String // "user" | "ai" | "thinking" | "tool"
        var id: UUID
        var text: String
        var senderLabel: String?
        var toolName: String?
        var toolArgument: String?
        var seconds: Double?
    }

    init(from session: ConversationSession, kind: ConversationKind) {
        id = session.id
        title = session.title
        model = session.model
        self.kind = kind == .agent ? "agent" : "chat"
        updatedAt = Date()
        gatewaySessionID = session.gatewaySessionID
        reasoningEffort = session.reasoningEffort
        claudeResumeSessionID = session.claudeResumeSessionID
        contextUsed = session.contextUsed
        contextMax = session.contextMax
        totalTokens = session.totalTokens
        totalCostUSD = session.totalCostUSD
        // ponytail: `.permission` skipped — its `onDecide` closure is dead after
        // a restart anyway, nothing to resume it into.
        items = session.items.compactMap { item -> ItemSnapshot? in
            switch item {
            case .userMessage(let id, let text):
                ItemSnapshot(type: "user", id: id, text: text)
            case .aiMessage(let id, let label, let text, _):
                ItemSnapshot(type: "ai", id: id, text: text, senderLabel: label)
            case .thinking(let block):
                ItemSnapshot(type: "thinking", id: block.id, text: block.text, seconds: block.seconds)
            case .toolCall(let call):
                ItemSnapshot(type: "tool", id: call.id, text: call.output, toolName: call.name, toolArgument: call.argument, seconds: call.seconds)
            case .permission:
                nil
            }
        }
    }

    func toSession() -> ConversationSession {
        let restoredItems: [ConversationItem] = items.map { item in
            switch item.type {
            case "ai":
                .aiMessage(id: item.id, senderLabel: item.senderLabel ?? "", text: item.text, isStreaming: false)
            case "thinking":
                .thinking(ThinkingBlockModel(text: item.text, seconds: item.seconds ?? 0))
            case "tool":
                .toolCall(ToolCall(name: item.toolName ?? "", argument: item.toolArgument ?? "", output: item.text, seconds: item.seconds, isRunning: false))
            default:
                .userMessage(id: item.id, text: item.text)
            }
        }
        let session = ConversationSession(id: id, title: title, model: model, items: restoredItems)
        session.gatewaySessionID = gatewaySessionID
        session.reasoningEffort = reasoningEffort
        session.claudeResumeSessionID = claudeResumeSessionID
        session.contextUsed = contextUsed
        session.contextMax = contextMax
        session.totalTokens = totalTokens
        session.totalCostUSD = totalCostUSD
        return session
    }
}

/// Flat file-per-session store under Application Support — no database, no
/// singleton config, just save/loadAll/delete against a fixed directory.
enum SessionPersistence {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("kiwiMango/sessions", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func save(_ snapshot: SessionSnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            let url = directory.appendingPathComponent("\(snapshot.id).json")
            try data.write(to: url, options: .atomic)
        } catch {
            print("SessionPersistence.save failed: \(error)")
        }
    }

    /// Sorted newest-first. Corrupt files are skipped, never deleted (pułapka #6).
    static func loadAll() -> [SessionSnapshot] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let snapshots = files.compactMap { url -> SessionSnapshot? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(SessionSnapshot.self, from: data)
        }
        return snapshots.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func delete(id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    }
}
