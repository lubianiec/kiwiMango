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
    var kind: String // legacy field — always "agent" now, kept so old chat entries on disk still decode
    var updatedAt: Date
    var gatewaySessionID: String?
    var reasoningEffort: String?
    var contextUsed: Int?
    var contextMax: Int?
    var items: [ItemSnapshot]

    struct ItemSnapshot: Codable {
        var type: String // "user" | "ai" | "thinking" | "tool"
        var id: UUID
        var text: String
        var senderLabel: String?
        var toolName: String?
        var toolArgument: String?
        var seconds: Double?
        /// Optional so old sessions on disk (saved before this field existed)
        /// still decode — missing key just means "no estimate", not an error.
        var tokens: Int?
    }

    init(from session: ConversationSession) {
        id = session.id
        title = session.title
        model = session.model
        kind = "agent"
        updatedAt = Date()
        gatewaySessionID = session.gatewaySessionID
        reasoningEffort = session.reasoningEffort
        contextUsed = session.contextUsed
        contextMax = session.contextMax
        // ponytail: `.permission` skipped — its `onDecide` closure is dead after
        // a restart anyway, nothing to resume it into.
        items = session.items.compactMap { item -> ItemSnapshot? in
            switch item {
            case .userMessage(let id, let text):
                ItemSnapshot(type: "user", id: id, text: text)
            case .aiMessage(let id, let label, let text, _):
                ItemSnapshot(type: "ai", id: id, text: text, senderLabel: label)
            case .thinking(let block):
                ItemSnapshot(type: "thinking", id: block.id, text: block.text, seconds: block.seconds, tokens: block.tokens)
            case .toolCall(let call):
                ItemSnapshot(type: "tool", id: call.id, text: call.output, toolName: call.name, toolArgument: call.argument, seconds: call.seconds, tokens: call.tokens)
            case .permission:
                nil
            }
        }
    }

    func toSession() -> ConversationSession {
        var restoredItems: [ConversationItem] = []
        restoredItems.reserveCapacity(items.count)
        for item in items {
            switch item.type {
            case "ai":
                restoredItems.append(.aiMessage(id: item.id, senderLabel: item.senderLabel ?? "", text: item.text, isStreaming: false))
            case "thinking":
                let block = ThinkingBlockModel(text: item.text, seconds: item.seconds ?? 0)
                block.tokens = item.tokens
                restoredItems.append(.thinking(block))
            case "tool":
                let call = ToolCall(name: item.toolName ?? "", argument: item.toolArgument ?? "", output: item.text, seconds: item.seconds, isRunning: false)
                call.tokens = item.tokens
                restoredItems.append(.toolCall(call))
            default:
                restoredItems.append(.userMessage(id: item.id, text: item.text))
            }
        }
        let session = ConversationSession(id: id, title: title, model: model, items: restoredItems)
        session.gatewaySessionID = gatewaySessionID
        session.reasoningEffort = reasoningEffort
        session.contextUsed = contextUsed
        session.contextMax = contextMax
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
