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
}
