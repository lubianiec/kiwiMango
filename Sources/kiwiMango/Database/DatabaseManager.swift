import Foundation
import GRDB

// MARK: - Conversation

/// A saved chat thread. `id` is assigned by SQLite on insert (see `didInsert`) —
/// it must be non-optional by the time the row reaches the UI, otherwise SwiftUI's
/// `ForEach`/`List` identity collapses every row with `id == nil` into one.
struct Conversation: Identifiable, Hashable, Codable {
    var id: Int64
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

extension Conversation: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "conversation"

    /// Used only for inserts before the row has a real id (see `DatabaseManager.createConversation`).
    fileprivate init(pendingTitle title: String, now: Date) {
        self.id = 0
        self.title = title
        self.createdAt = now
        self.updatedAt = now
    }

    /// Omits `id` from the INSERT when it's still the `0` placeholder, so SQLite
    /// assigns a real autoincremented rowid instead of literally storing `0`.
    /// Without this override, GRDB encodes every stored property including `id`,
    /// so a second insert before the first row is re-fetched collides on the same
    /// `id == 0` primary key and silently fails.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["title"] = title
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - StoredMessage

/// A persisted chat message, linked to its conversation.
struct StoredMessage: Identifiable, Hashable, Codable {
    var id: Int64
    var conversationId: Int64
    var role: String
    var content: String
    var createdAt: Date
}

extension StoredMessage: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "message"

    fileprivate init(pendingConversationId conversationId: Int64, role: String, content: String, now: Date) {
        self.id = 0
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.createdAt = now
    }

    /// See `Conversation.encode(to:)` — same reasoning: omit the placeholder
    /// `id` so each insert gets its own autoincremented rowid instead of every
    /// message in a conversation colliding on `id == 0`.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["conversationId"] = conversationId
        container["role"] = role
        container["content"] = content
        container["createdAt"] = createdAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Persona

/// A saved chat persona: system prompt + optional model/temperature override.
struct Persona: Identifiable, Hashable, Codable {
    var id: Int64
    var name: String
    var systemPrompt: String
    var model: String?
    var temperature: Double
    var position: Int
}

extension Persona: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "persona"

    fileprivate init(
        pendingName name: String, systemPrompt: String, model: String?, temperature: Double, position: Int
    ) {
        self.id = 0
        self.name = name
        self.systemPrompt = systemPrompt
        self.model = model
        self.temperature = temperature
        self.position = position
    }

    /// See `Conversation.encode(to:)` — same id=0 placeholder pattern.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["name"] = name
        container["systemPrompt"] = systemPrompt
        container["model"] = model
        container["temperature"] = temperature
        container["position"] = position
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Snippet

/// A saved prompt snippet, inserted into the composer via `/<trigger>`.
struct Snippet: Identifiable, Hashable, Codable {
    var id: Int64
    var trigger: String
    var content: String
    var position: Int
}

extension Snippet: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "snippet"

    fileprivate init(pendingTrigger trigger: String, content: String, position: Int) {
        self.id = 0
        self.trigger = trigger
        self.content = content
        self.position = position
    }

    /// See `Conversation.encode(to:)` — same id=0 placeholder pattern.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["trigger"] = trigger
        container["content"] = content
        container["position"] = position
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - ArenaVote

/// A single vote cast in the Arena (F8.1) — which model won a given prompt.
/// Votes are the only thing Arena persists; the rounds themselves are ephemeral.
struct ArenaVote: Identifiable, Hashable, Codable {
    var id: Int64
    var model: String
    var prompt: String
    var votedAt: Date
}

extension ArenaVote: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "arenaVote"

    fileprivate init(pendingModel model: String, prompt: String, now: Date) {
        self.id = 0
        self.model = model
        self.prompt = prompt
        self.votedAt = now
    }

    /// See `Conversation.encode(to:)` — same id=0 placeholder pattern.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["model"] = model
        container["prompt"] = prompt
        container["votedAt"] = votedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - SavedPrompt (Fala 11)

/// One entry in the private prompt vault — image prompts, personas, drafts,
/// anything Paweł wants to keep. Deliberately separate from `Snippet` (the
/// `/` composer shortcuts, F2.6) — different feature, do not merge.
struct SavedPrompt: Identifiable, Hashable, Codable {
    var id: Int64
    var title: String
    var content: String
    var category: String
    var createdAt: Date
    var lastUsedAt: Date
}

extension SavedPrompt: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "savedPrompt"

    init(pendingTitle title: String, content: String, category: String, now: Date) {
        self.id = 0
        self.title = title
        self.content = content
        self.category = category
        self.createdAt = now
        self.lastUsedAt = now
    }

    /// See `Conversation.encode(to:)` — same id=0 placeholder pattern.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["title"] = title
        container["content"] = content
        container["category"] = category
        container["createdAt"] = createdAt
        container["lastUsedAt"] = lastUsedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - MemoryFact (F1)

/// A single long-term memory fact extracted from assistant replies.
struct MemoryFact: Identifiable, Hashable, Codable {
    var id: Int64
    var content: String
    var sourceConversationId: Int64?
    var sourceSessionId: Int64?
    var scope: String  // "global" or a directory path for project scope
    var createdAt: Date
    var lastUsedAt: Date
    var useCount: Int
}

extension MemoryFact: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "memoryFact"

    init(pendingContent content: String, scope: String, sourceConversationId: Int64? = nil, sourceSessionId: Int64? = nil) {
        self.id = 0
        self.content = content
        self.sourceConversationId = sourceConversationId
        self.sourceSessionId = sourceSessionId
        self.scope = scope
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.useCount = 0
    }

    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["content"] = content
        container["sourceConversationId"] = sourceConversationId
        container["sourceSessionId"] = sourceSessionId
        container["scope"] = scope
        container["createdAt"] = createdAt
        container["lastUsedAt"] = lastUsedAt
        container["useCount"] = useCount
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - AgentSessionRecord (Fala 13)

/// A finished agent terminal session, archived to survive app restart.
/// `transcript` already comes in pre-truncated (max 2000 lines — see
/// `AgentManager.dumpTranscript`), so SQLite just stores a plain TEXT blob.
struct AgentSessionRecord: Identifiable, Hashable, Codable {
    var id: Int64
    var kind: String
    var model: String
    var isCloud: Bool
    var workDir: String
    var startedAt: Date
    var endedAt: Date
    var transcript: String
}

extension AgentSessionRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "agentSession"

    init(pendingKind kind: String, model: String, isCloud: Bool, workDir: String, startedAt: Date, endedAt: Date, transcript: String) {
        self.id = 0
        self.kind = kind
        self.model = model
        self.isCloud = isCloud
        self.workDir = workDir
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
    }

    /// See `Conversation.encode(to:)` — same id=0 placeholder pattern.
    func encode(to container: inout PersistenceContainer) {
        if id != 0 { container["id"] = id }
        container["kind"] = kind
        container["model"] = model
        container["isCloud"] = isCloud
        container["workDir"] = workDir
        container["startedAt"] = startedAt
        container["endedAt"] = endedAt
        container["transcript"] = transcript
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - DatabaseManager

/// Owns the GRDB queue + migrations. One instance for the app's lifetime.
///
/// Storage: `~/Library/Application Support/KiwiMango/kiwiMango.sqlite` — the standard
/// macOS location for app-owned data (not user documents, not caches).
final class DatabaseManager: Sendable {

    static let shared = DatabaseManager()

    let dbQueue: DatabaseQueue

    private init() {
        do {
            let fileManager = FileManager.default
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = appSupport.appendingPathComponent("KiwiMango", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            let dbURL = directory.appendingPathComponent("kiwiMango.sqlite")
            dbQueue = try DatabaseQueue(path: dbURL.path)
            try Self.migrator.migrate(dbQueue)

            print("[KiwiMango] Database ready at \(dbURL.path)")
        } catch {
            // A broken database is fatal — there is no sane degraded mode for a
            // chat-history feature that silently can't store anything.
            fatalError("[KiwiMango] Failed to open/migrate database: \(error)")
        }
    }

    // MARK: - Migrations

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createConversationAndMessage") { db in
            try db.create(table: "conversation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("conversation", onDelete: .cascade).notNull()
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("addMessageImages") { db in
            try db.create(table: "messageImage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("message", onDelete: .cascade).notNull()
                t.column("data", .blob).notNull()
                t.column("position", .integer).notNull()
            }
        }

        migrator.registerMigration("addPersona") { db in
            try db.create(table: "persona") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("systemPrompt", .text).notNull()
                t.column("model", .text)
                t.column("temperature", .double).notNull()
                t.column("position", .integer).notNull()
            }

            let seeds: [(String, String, String?, Double)] = [
                (
                    "kiwiMango",
                    "",
                    nil,
                    0.8
                ),
                (
                    "KREATYWNY",
                    """
                    Jesteś partnerem do burzy mózgów. Proponuj śmiałe, nieoczywiste pomysły \
                    zamiast bezpiecznych banałów — im więcej kątów podejścia, tym lepiej. Nie \
                    oceniaj pomysłu jako "zły" zanim go nie rozwiniesz, oceń dopiero na końcu. \
                    Mów po polsku, konkretnie, bez lania wody.
                    """,
                    nil,
                    1.2
                ),
                (
                    "PROMPTMASTER",
                    """
                    Jesteś ekspertem od promptów do generatorów obrazów (Stable Diffusion, \
                    SeaArt, Flux). Na podstawie opisu użytkownika budujesz precyzyjny prompt \
                    w języku angielskim: kompozycja, oświetlenie, styl, jakość, negative prompt. \
                    Unikaj ogólników — każde słowo ma dodawać kontrolę nad wynikiem. Odpowiadaj \
                    tylko gotowym promptem (i negative prompt), bez zbędnych wyjaśnień.
                    """,
                    nil,
                    0.9
                ),
                (
                    "HYDRAULIK",
                    """
                    Jesteś doświadczonym fachowcem od instalacji sanitarnych i grzewczych. \
                    Odpowiadasz konkretnie i fachowo po polsku — normy, materiały, kolejność \
                    prac, typowe błędy. Nie owijasz w bawełnę i nie tłumaczysz podstaw, chyba że \
                    użytkownik wyraźnie o to prosi. Jeśli czegoś nie da się ocenić bez zdjęcia \
                    lub wizji lokalnej, mów to wprost.
                    """,
                    nil,
                    0.5
                ),
            ]
            for (index, seed) in seeds.enumerated() {
                var persona = Persona(
                    pendingName: seed.0, systemPrompt: seed.1, model: seed.2, temperature: seed.3, position: index
                )
                try persona.insert(db)
            }
        }

        migrator.registerMigration("addSnippet") { db in
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trigger", .text).notNull()
                t.column("content", .text).notNull()
                t.column("position", .integer).notNull()
            }

            let seeds: [(String, String)] = [
                ("tlumacz", "Przetłumacz poniższy tekst na polski, zachowaj ton:"),
                ("popraw", "Popraw literówki i gramatykę, nie zmieniaj sensu:"),
                ("streszcz", "Streść poniższy tekst w 3-5 zdaniach:"),
            ]
            for (index, seed) in seeds.enumerated() {
                var snippet = Snippet(pendingTrigger: seed.0, content: seed.1, position: index)
                try snippet.insert(db)
            }
        }

        migrator.registerMigration("addArenaVote") { db in
            try db.create(table: "arenaVote") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("model", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("votedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("addObsidianColumns") { db in
            // Fala 12: which vault file a conversation lives in (assigned once,
            // stable across renames) and its auto-classified category.
            try db.alter(table: "conversation") { t in
                t.add(column: "obsidianFile", .text)
                t.add(column: "category", .text)
            }
        }

        migrator.registerMigration("addSavedPrompt") { db in
            try db.create(table: "savedPrompt") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.column("content", .text).notNull()
                t.column("category", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
            }

            let now = Date()
            let seeds: [(String, String, String)] = [
                (
                    "Prompt SD — portret cyberpunk",
                    "cyberpunk portrait, neon rim light, rain-soaked street, cinematic, highly detailed, 85mm",
                    "OBRAZY"
                ),
                (
                    "Persona — brutalnie szczery recenzent",
                    "Jesteś bezlitosnym, ale rzeczowym recenzentem. Wytykasz słabe punkty wprost, bez owijania w bawełnę, ale zawsze uzasadniasz.",
                    "ROLE"
                ),
                (
                    "Szkic maila do klienta",
                    "Krótko, konkretnie, bez lania wody: co zrobiono, co dalej, jaki termin.",
                    "INNE"
                ),
            ]
            for seed in seeds {
                var prompt = SavedPrompt(
                    pendingTitle: seed.0, content: seed.1, category: seed.2, now: now
                )
                try prompt.insert(db)
            }
        }

        migrator.registerMigration("addAgentSession") { db in
            try db.create(table: "agentSession") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("model", .text).notNull()
                t.column("isCloud", .boolean).notNull()
                t.column("workDir", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime).notNull()
                t.column("transcript", .text).notNull()
            }
        }

        migrator.registerMigration("addClaudeSessionID") { db in
            // Fala 17: `claude -p --resume <id>` needs the CLI's own session id
            // (returned on the `result` line) to continue a conversation — this
            // is unrelated to `conversation.id` and only ever set for Anthropic
            // model threads.
            try db.alter(table: "conversation") { t in
                t.add(column: "claudeSessionID", .text)
            }
        }

        migrator.registerMigration("addHermesGatewaySessionID") { db in
            // Fala 24 (F24.3): the WebSocket gateway's `session_id` (short
            // 8-hex, from `session.create`'s result) — needed to `session.resume`
            // the right agent session when the user switches back to this
            // conversation. Distinct from F22's in-memory `hermesSessionIDs`
            // dict (headless CLI `--resume`, still used by the fallback path).
            try db.alter(table: "conversation") { t in
                t.add(column: "hermesGatewaySessionID", .text)
            }
        }

        migrator.registerMigration("addMemoryFact") { db in
            // F1: auto long-term memory extracted from assistant replies.
            try db.create(table: "memoryFact") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("content", .text).notNull()
                t.column("sourceConversationId", .integer)
                t.column("sourceSessionId", .integer)
                t.column("scope", .text).notNull().defaults(to: "global")
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("useCount", .integer).notNull().defaults(to: 0)
            }
        }

        return migrator
    }

    // MARK: - Conversations

    @discardableResult
    func createConversation(title: String) throws -> Conversation {
        try dbQueue.write { db in
            var conversation = Conversation(pendingTitle: title, now: Date())
            try conversation.insert(db)
            return conversation
        }
    }

    func fetchConversations() throws -> [Conversation] {
        try dbQueue.read { db in
            try Conversation
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
    }

    func touchConversation(_ id: Int64, title: String? = nil) throws {
        try dbQueue.write { db in
            if let title {
                try db.execute(
                    sql: "UPDATE conversation SET title = ?, updatedAt = ? WHERE id = ?",
                    arguments: [title, Date(), id]
                )
            } else {
                try db.execute(
                    sql: "UPDATE conversation SET updatedAt = ? WHERE id = ?",
                    arguments: [Date(), id]
                )
            }
        }
    }

    func deleteConversation(_ id: Int64) throws {
        _ = try dbQueue.write { db in
            try Conversation.deleteOne(db, key: id)
        }
    }

    /// Duplicates a conversation — new row titled "<title> (kopia)" plus a copy of
    /// every message and its images, all in one transaction (lightweight "fork").
    @discardableResult
    func duplicateConversation(_ id: Int64) throws -> Conversation {
        try dbQueue.write { db in
            guard let original = try Conversation.fetchOne(db, key: id) else {
                throw NSError(domain: "KiwiMango", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Conversation \(id) not found",
                ])
            }
            var copy = Conversation(pendingTitle: "\(original.title) (kopia)", now: Date())
            try copy.insert(db)

            let messages = try StoredMessage
                .filter(Column("conversationId") == id)
                .order(Column("createdAt"))
                .fetchAll(db)
            for message in messages {
                var messageCopy = StoredMessage(
                    pendingConversationId: copy.id, role: message.role, content: message.content, now: message.createdAt
                )
                try messageCopy.insert(db)
                let images = try Data.fetchAll(
                    db,
                    sql: "SELECT data FROM messageImage WHERE messageId = ? ORDER BY position",
                    arguments: [message.id]
                )
                for (position, data) in images.enumerated() {
                    try db.execute(
                        sql: "INSERT INTO messageImage (messageId, data, position) VALUES (?, ?, ?)",
                        arguments: [messageCopy.id, data, position]
                    )
                }
            }
            return copy
        }
    }

    /// Conversation ids whose messages contain `query` (case-insensitive substring).
    func searchConversationIDs(matching query: String) throws -> Set<Int64> {
        try dbQueue.read { db in
            let ids = try Int64.fetchAll(
                db,
                sql: "SELECT DISTINCT conversationId FROM message WHERE content LIKE ?",
                arguments: ["%\(query)%"]
            )
            return Set(ids)
        }
    }

    // MARK: - Messages

    @discardableResult
    func addMessage(
        conversationId: Int64, role: String, content: String, images: [Data] = []
    ) throws -> StoredMessage {
        try dbQueue.write { db in
            var message = StoredMessage(
                pendingConversationId: conversationId, role: role, content: content, now: Date()
            )
            try message.insert(db)
            for (position, data) in images.enumerated() {
                try db.execute(
                    sql: "INSERT INTO messageImage (messageId, data, position) VALUES (?, ?, ?)",
                    arguments: [message.id, data, position]
                )
            }
            return message
        }
    }

    func fetchMessages(conversationId: Int64) throws -> [StoredMessage] {
        try dbQueue.read { db in
            try StoredMessage
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Deletes the most recent assistant message in a conversation (used by "regenerate").
    func deleteLastAssistantMessage(conversationId: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM message WHERE id = (
                    SELECT id FROM message WHERE conversationId = ? AND role = 'assistant'
                    ORDER BY id DESC LIMIT 1)
                """,
                arguments: [conversationId]
            )
        }
    }

    /// Messages for a conversation, paired with their attached images (ordered by `position`).
    func fetchMessagesWithImages(conversationId: Int64) throws -> [(StoredMessage, [Data])] {
        try dbQueue.read { db in
            let messages = try StoredMessage
                .filter(Column("conversationId") == conversationId)
                .order(Column("createdAt"))
                .fetchAll(db)
            return try messages.map { message in
                let images = try Data.fetchAll(
                    db,
                    sql: "SELECT data FROM messageImage WHERE messageId = ? ORDER BY position",
                    arguments: [message.id]
                )
                return (message, images)
            }
        }
    }

    // MARK: - Personas

    func fetchPersonas() throws -> [Persona] {
        try dbQueue.read { db in
            try Persona.order(Column("position")).fetchAll(db)
        }
    }

    /// Inserts a new persona (id == 0) or updates an existing one in place.
    @discardableResult
    func savePersona(_ persona: Persona) throws -> Persona {
        try dbQueue.write { db in
            var persona = persona
            if persona.id == 0 {
                let maxPosition = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM persona") ?? -1
                persona.position = maxPosition + 1
                try persona.insert(db)
            } else {
                try persona.update(db)
            }
            return persona
        }
    }

    func deletePersona(_ id: Int64) throws {
        _ = try dbQueue.write { db in
            try Persona.deleteOne(db, key: id)
        }
    }

    // MARK: - Snippets

    func fetchSnippets() throws -> [Snippet] {
        try dbQueue.read { db in
            try Snippet.order(Column("position")).fetchAll(db)
        }
    }

    @discardableResult
    func saveSnippet(_ snippet: Snippet) throws -> Snippet {
        try dbQueue.write { db in
            var snippet = snippet
            if snippet.id == 0 {
                let maxPosition = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position), -1) FROM snippet") ?? -1
                snippet.position = maxPosition + 1
                try snippet.insert(db)
            } else {
                try snippet.update(db)
            }
            return snippet
        }
    }

    func deleteSnippet(_ id: Int64) throws {
        _ = try dbQueue.write { db in
            try Snippet.deleteOne(db, key: id)
        }
    }

    // MARK: - Arena votes

    func addArenaVote(model: String, prompt: String) throws {
        try dbQueue.write { db in
            var vote = ArenaVote(pendingModel: model, prompt: prompt, now: Date())
            try vote.insert(db)
        }
    }

    /// Vote counts per model across all rounds ever played, highest first.
    func fetchArenaRanking() throws -> [(model: String, votes: Int)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT model, COUNT(*) AS votes FROM arenaVote GROUP BY model ORDER BY votes DESC"
            )
            return rows.map { (model: $0["model"], votes: $0["votes"]) }
        }
    }

    // MARK: - Agent session history (Fala 13)

    @discardableResult
    func saveAgentSession(
        kind: String, model: String, isCloud: Bool, workDir: String, startedAt: Date, endedAt: Date, transcript: String
    ) throws -> AgentSessionRecord {
        try dbQueue.write { db in
            var record = AgentSessionRecord(
                pendingKind: kind, model: model, isCloud: isCloud, workDir: workDir,
                startedAt: startedAt, endedAt: endedAt, transcript: transcript
            )
            try record.insert(db)
            return record
        }
    }

    func fetchAgentSessions(limit: Int = 15) throws -> [AgentSessionRecord] {
        try dbQueue.read { db in
            try AgentSessionRecord
                .order(Column("endedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func deleteAgentSession(_ id: Int64) throws {
        _ = try dbQueue.write { db in
            try AgentSessionRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Saved prompts (Fala 11)

    func fetchSavedPrompts() throws -> [SavedPrompt] {
        try dbQueue.read { db in
            try SavedPrompt.order(Column("lastUsedAt").desc).fetchAll(db)
        }
    }

    /// Inserts a new prompt (id == 0) or updates an existing one in place —
    /// same convention as `savePersona`/`saveSnippet`.
    @discardableResult
    func saveSavedPrompt(_ prompt: SavedPrompt) throws -> SavedPrompt {
        try dbQueue.write { db in
            var prompt = prompt
            if prompt.id == 0 {
                try prompt.insert(db)
            } else {
                try prompt.update(db)
            }
            return prompt
        }
    }

    func touchSavedPromptUsage(_ id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE savedPrompt SET lastUsedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
    }

    func deleteSavedPrompt(_ id: Int64) throws {
        _ = try dbQueue.write { db in
            try SavedPrompt.deleteOne(db, key: id)
        }
    }

    // MARK: - Obsidian metadata (Fala 12)

    /// `(obsidianFile, category)` for a conversation — read via raw SQL rather
    /// than through the `Conversation` record, so the Fala-12 columns don't
    /// need to be threaded through every other call site that decodes one.
    func fetchConversationObsidianMeta(_ id: Int64) throws -> (file: String?, category: String?) {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT obsidianFile, category FROM conversation WHERE id = ?", arguments: [id]
            ) else { return (nil, nil) }
            return (row["obsidianFile"], row["category"])
        }
    }

    func setConversationObsidianFile(_ id: Int64, file: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET obsidianFile = ? WHERE id = ?", arguments: [file, id])
        }
    }

    func setConversationCategory(_ id: Int64, category: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE conversation SET category = ? WHERE id = ?", arguments: [category, id])
        }
    }

    // MARK: - Claude session id (Fala 17)

    /// Raw-SQL accessor, same pattern as the Obsidian metadata above — the
    /// `claude -p --resume <id>` session id only matters for Anthropic-model
    /// threads, so it doesn't need to be threaded through `Conversation`.
    func fetchConversationClaudeSessionID(_ id: Int64) throws -> String? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT claudeSessionID FROM conversation WHERE id = ?", arguments: [id]
            ) else { return nil }
            return row["claudeSessionID"]
        }
    }

    func setConversationClaudeSessionID(_ id: Int64, sessionID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET claudeSessionID = ? WHERE id = ?", arguments: [sessionID, id]
            )
        }
    }

    // MARK: - Hermes gateway session id (Fala 24)

    func fetchConversationHermesGatewaySessionID(_ id: Int64) throws -> String? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT hermesGatewaySessionID FROM conversation WHERE id = ?", arguments: [id]
            ) else { return nil }
            return row["hermesGatewaySessionID"]
        }
    }

    func setConversationHermesGatewaySessionID(_ id: Int64, sessionID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversation SET hermesGatewaySessionID = ? WHERE id = ?", arguments: [sessionID, id]
            )
        }
    }

    // MARK: - Memory facts (F1)

    @discardableResult
    func saveMemoryFact(_ fact: MemoryFact) throws -> MemoryFact {
        try dbQueue.write { db in
            var fact = fact
            if fact.id == 0 {
                try fact.insert(db)
            } else {
                try fact.update(db)
            }
            return fact
        }
    }

    func deleteMemoryFact(_ id: Int64) throws {
        _ = try dbQueue.write { db in
            try MemoryFact.deleteOne(db, key: id)
        }
    }

    func fetchMemoryFacts(limit: Int = 100) throws -> [MemoryFact] {
        try dbQueue.read { db in
            try MemoryFact.order(Column("lastUsedAt").desc).limit(limit).fetchAll(db)
        }
    }

    /// Returns the most relevant facts: global top + project-scoped top for the given directory.
    /// ponytail: O(n log n) in-memory sort rather than a custom SQLite ranking query —
    /// fact counts stay small, so simplicity beats a one-off complex query.
    func fetchRelevantMemoryFacts(projectPath: String? = nil, globalLimit: Int = 5, projectLimit: Int = 5) throws -> [MemoryFact] {
        try dbQueue.read { db in
            let all = try MemoryFact.fetchAll(db)
            let global = all
                .filter { $0.scope == "global" }
                .sorted { compareRelevance($0, $1) }
                .prefix(globalLimit)
            let project = all
                .filter { fact in
                    guard let projectPath else { return false }
                    return fact.scope != "global" && projectPath.hasPrefix(fact.scope)
                }
                .sorted { compareRelevance($0, $1) }
                .prefix(projectLimit)
            return Array(global) + Array(project)
        }
    }

    func bumpMemoryFactUsage(_ id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memoryFact SET lastUsedAt = ?, useCount = useCount + 1 WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }
}

private func compareRelevance(_ a: MemoryFact, _ b: MemoryFact) -> Bool {
    if a.useCount != b.useCount { return a.useCount > b.useCount }
    return a.lastUsedAt > b.lastUsedAt
}
