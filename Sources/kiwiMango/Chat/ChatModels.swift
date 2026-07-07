import AppKit
import Foundation
import Observation

// MARK: - SidebarSelection

/// The single source of truth for what the sidebar has selected — one enum
/// instead of scattered optionals, so "no conversation" and "conversation X"
/// can't both be half-true at once.
enum SidebarSelection: Hashable {
    case conversation(Int64)
    case agent(UUID)
    /// Model Arena / Agent Room (F8) — single shared instance each, so there's
    /// nothing to key by id; the view's state lives in `RootView` instead.
    case arena
    case room
    /// A past (archived) agent session — Fala 13. Distinct from `.agent(UUID)`,
    /// which is a live/running session keyed by `AgentSession.id`.
    case agentHistory(Int64)
    /// The prompt vault (Fala 11) — one shared panel, no id to key by.
    case prompts
}

// MARK: - ChatMessage

/// A single message in the chat thread.
struct ChatMessage: Identifiable {
    let id: UUID
    var role: Role
    var content: String
    var images: [Data]
    /// Generation stats line ("128 tok • 24.3 tok/s"), shown under the bubble.
    /// Not persisted — recomputed only for the live stream, gone after reload.
    var statsLine: String?

    enum Role: String {
        case user
        case assistant
    }

    init(id: UUID = UUID(), role: Role, content: String, images: [Data] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.images = images
    }
}

// MARK: - AttachedImage

/// An image the user has attached to the current draft message.
struct AttachedImage: Identifiable {
    let id: UUID
    let data: Data
    let thumbnail: NSImage?

    init(id: UUID = UUID(), data: Data, thumbnail: NSImage? = nil) {
        self.id = id
        self.data = data
        self.thumbnail = thumbnail
    }
}

// MARK: - ChatState

/// Full chat state — streams replies from the local Ollama server, appending deltas live.
@MainActor
@Observable
final class ChatState {

    // MARK: State

    var messages: [ChatMessage] = []
    var draft: String = ""
    var attachedImages: [AttachedImage] = []
    var availableModels: [OllamaService.ModelInfo] = []
    var isStreaming: Bool = false

    /// F15.3: the model manager sheet is now opened only from the model picker
    /// in the chat header — RootView still owns the `.sheet`, it just reads
    /// this flag instead of its own `@State` (the picker lives in ChatView).
    var showingModelManager: Bool = false

    /// Fala 14: true while `send()` is waiting on `webSearch`/`webFetch`, before
    /// the actual chat stream starts — drives the "SZUKAM W SIECI…" indicator.
    var isSearchingWeb: Bool = false

    /// Set when a web search/fetch fails or times out during `send()` — shown as
    /// a small warning chip. The reply still streams normally (F14.3 pitfall b).
    var webSearchWarning: String?

    /// Last tok/s readings from completed responses (max 40, FIFO) — backs the
    /// status bar sparkline. Streaming deltas never touch this, only finished stats.
    var tokRateHistory: [Double] = []

    /// Rough tok/s estimate *while streaming* (chars-since-last-sample / ~4 per
    /// token, resampled every ~0.5s) — drives `BreathingBackdrop`'s pulse speed.
    /// Not exact (no real tokenizer), just needs to feel faster for faster models.
    var liveTokRate: Double = 0

    /// Id of a message that was just freshly appended (new user turn or a fresh
    /// assistant placeholder) — `MessageBubble` animates its "materialize in"
    /// ONLY for this id, then clears it. Loaded history and scroll-recycled
    /// rows (LazyVStack) must never replay the animation, hence the one-shot flag
    /// instead of e.g. "animate whenever this view appears".
    var lastAnimatedMessageID: UUID?

    /// Bumped every time an error bubble (`⚠️`) is created — `ChatView` watches
    /// this to trigger a brief chromatic-glitch flash over the transcript.
    var glitchTrigger: Int = 0

    /// All saved conversations, newest-updated first — backs the sidebar list.
    var conversations: [Conversation] = []

    /// The conversation currently shown in the detail pane. `nil` until either
    /// a conversation is selected/created or the first message is sent (which
    /// lazily creates one — see `send()`).
    private(set) var currentConversationID: Int64?

    /// Persisted in UserDefaults "chatModel".
    var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "chatModel") }
    }

    /// All saved personas, in display order — backs the persona menu + editor.
    var personas: [Persona] = []

    /// All saved prompt snippets, in display order — backs the `/` popover + Settings CRUD.
    var snippets: [Snippet] = []

    /// Persisted in UserDefaults "activePersonaID". `nil` = no persona (plain chat).
    var activePersonaID: Int64? {
        didSet {
            if let activePersonaID {
                UserDefaults.standard.set(activePersonaID, forKey: "activePersonaID")
            } else {
                UserDefaults.standard.removeObject(forKey: "activePersonaID")
            }
        }
    }

    var activePersona: Persona? {
        personas.first { $0.id == activePersonaID }
    }

    // MARK: Private

    /// Reads assistant replies aloud when "ttsEnabled" is on (composer toggle)
    /// and backs the per-message "przeczytaj" hover action regardless of the
    /// toggle. See `Chat/SpeechSynthesizer.swift`.
    let speechSynthesizer = SpeechSynthesizer()
    @ObservationIgnored private lazy var speechFeeder = StreamingSpeechFeeder(synth: speechSynthesizer)

    @ObservationIgnored private var streamTask: Task<Void, Never>?

    /// Bookkeeping for `liveTokRate` — resets at the start of every `runStream`.
    @ObservationIgnored private var charsSinceRateSample = 0
    @ObservationIgnored private var lastRateSampleAt = Date()

    /// Models whose `/api/tags` capabilities include "thinking" → send `think:false`.
    @ObservationIgnored private var thinkingModels: Set<String> = []

    /// Fresh instance per use, so a host change in Settings takes effect immediately.
    private var service: OllamaService { OllamaService() }

    @ObservationIgnored private let db = DatabaseManager.shared

    // MARK: Init

    init() {
        selectedModel = UserDefaults.standard.string(forKey: "chatModel")
            ?? "llama3.2"
        if UserDefaults.standard.object(forKey: "activePersonaID") != nil {
            activePersonaID = Int64(UserDefaults.standard.integer(forKey: "activePersonaID"))
        }
        refreshConversations()
        refreshPersonas()
        refreshSnippets()
        if activePersonaID == nil {
            activePersonaID = personas.first?.id
        }
    }

    // MARK: - Personas

    func refreshPersonas() {
        do {
            personas = try db.fetchPersonas()
        } catch {
            print("[KiwiMango] Failed to load personas: \(error)")
        }
    }

    func selectPersona(_ id: Int64?) {
        activePersonaID = id
    }

    @discardableResult
    func savePersona(_ persona: Persona) -> Persona? {
        do {
            let saved = try db.savePersona(persona)
            refreshPersonas()
            return saved
        } catch {
            print("[KiwiMango] Failed to save persona: \(error)")
            return nil
        }
    }

    func deletePersona(_ id: Int64) {
        do {
            try db.deletePersona(id)
            if activePersonaID == id { activePersonaID = nil }
            refreshPersonas()
        } catch {
            print("[KiwiMango] Failed to delete persona \(id): \(error)")
        }
    }

    // MARK: - Conversations (sidebar)

    /// Reloads the conversation list from disk (call after create/delete/rename).
    func refreshConversations() {
        do {
            conversations = try db.fetchConversations()
        } catch {
            print("[KiwiMango] Failed to load conversations: \(error)")
        }
    }

    /// Starts a brand-new, empty conversation and selects it. The row is only
    /// persisted once the first message is sent (see `send()`) — an empty
    /// "Nowa rozmowa" that's never used shouldn't clutter the sidebar.
    ///
    /// Awaits any in-flight stream first: `send()` persists the assistant's
    /// final reply by re-reading it out of `messages` after streaming ends,
    /// so clearing `messages` while a stream is still running would drop
    /// that reply on the floor instead of saving it.
    func startNewConversation() async {
        await cancelAndWait()
        requestTLDRForCurrentConversation()
        currentConversationID = nil
        messages = []
        lastAnimatedMessageID = nil
    }

    /// Loads a previously saved conversation's messages into the transcript.
    /// See `startNewConversation` for why this waits on the pending stream.
    func selectConversation(_ id: Int64) async {
        guard id != currentConversationID else { return }
        await cancelAndWait()
        requestTLDRForCurrentConversation()
        currentConversationID = id
        lastAnimatedMessageID = nil
        do {
            let stored = try db.fetchMessagesWithImages(conversationId: id)
            messages = stored.map { message, images in
                ChatMessage(
                    role: ChatMessage.Role(rawValue: message.role) ?? .assistant,
                    content: message.content,
                    images: images
                )
            }
        } catch {
            print("[KiwiMango] Failed to load messages for conversation \(id): \(error)")
            messages = []
        }
    }

    /// Renames a saved conversation (sidebar context menu).
    func renameConversation(_ id: Int64, title: String) {
        do {
            try db.touchConversation(id, title: title)
            refreshConversations()
        } catch {
            print("[KiwiMango] Failed to rename conversation \(id): \(error)")
        }
    }

    /// Writes a conversation's full transcript to `~/Downloads/kiwiMango-<slug>-<date>.md`.
    /// Returns the destination URL on success (for a UI toast) — never opened automatically.
    @discardableResult
    func exportConversation(_ id: Int64) -> URL? {
        guard let conversation = conversations.first(where: { $0.id == id }),
              let markdown = try? conversationMarkdown(conversation) else { return nil }
        do {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let fileName = "kiwiMango-\(Self.slug(from: conversation.title))"
                + "-\(Self.fileDateFormatter.string(from: Date())).md"
            let url = downloads.appendingPathComponent(fileName)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[KiwiMango] Failed to export conversation \(id): \(error)")
            return nil
        }
    }

    /// Whole conversation, same markdown shape as `exportConversation`, written to
    /// the Obsidian vault's inbox instead of Downloads.
    func sendConversationToObsidian(_ id: Int64) -> URL? {
        guard let conversation = conversations.first(where: { $0.id == id }),
              let markdown = try? conversationMarkdown(conversation) else { return nil }
        do {
            let inbox = try Self.obsidianInbox()
            // Zasada vaulta: nazwa pliku = treściwy tytuł, bez dat i prefiksów —
            // Paweł szuka po nazwie; data/źródło siedzą we frontmatterze.
            let url = Self.uniqueURL(in: inbox, base: Self.slug(from: conversation.title))
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[KiwiMango] Failed to send conversation \(id) to Obsidian: \(error)")
            return nil
        }
    }

    /// A single assistant reply, written to the Obsidian vault's inbox with
    /// frontmatter (source/date/model). Used by the "→ Obsidian" hover action.
    func sendMessageToObsidian(content: String) -> URL? {
        do {
            let inbox = try Self.obsidianInbox()
            let now = Date()
            let iso = ISO8601DateFormatter().string(from: now)
            let slug = Self.slug(from: String(content.prefix(60)))
            let markdown = """
            ---
            source: kiwiMango
            date: \(iso)
            model: \(selectedModel)
            ---

            \(content)

            """
            let url = Self.uniqueURL(in: inbox, base: slug)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[KiwiMango] Failed to send message to Obsidian: \(error)")
            return nil
        }
    }

    /// An archived agent transcript, written to the Obsidian inbox — same
    /// simple pattern as `sendMessageToObsidian` (Fala 12's dedicated
    /// `AI/Agenci/` folder + full frontmatter lands with F12.3; until then
    /// this is the one path from F13.4's "→ OBSIDIAN" button).
    func sendAgentTranscriptToObsidian(title: String, content: String) -> URL? {
        do {
            let inbox = try Self.obsidianInbox()
            let iso = ISO8601DateFormatter().string(from: Date())
            let markdown = """
            ---
            source: kiwiMango
            typ: agent
            date: \(iso)
            ---

            # \(title)

            \(content)

            """
            let url = Self.uniqueURL(in: inbox, base: Self.slug(from: title))
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("[KiwiMango] Failed to send agent transcript to Obsidian: \(error)")
            return nil
        }
    }

    private func conversationMarkdown(_ conversation: Conversation) throws -> String {
        let messages = try db.fetchMessages(conversationId: conversation.id)
        var markdown = "# \(conversation.title)\n\n"
        markdown += "Data: \(Self.exportDateFormatter.string(from: conversation.createdAt))\n"
        markdown += "Model: \(selectedModel)\n\n"
        for message in messages {
            let heading = message.role == "user" ? "## 🧑 Ty" : "## 🤖 kiwiMango"
            markdown += "\(heading)\n\n\(message.content)\n\n"
        }
        return markdown
    }

    /// `~/Kazik/ObsidianSync/00-Inbox/`, created on first use.
    private static func obsidianInbox() throws -> URL {
        let vault = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Kazik/ObsidianSync/00-Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault
    }

    private static let obsidianTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    private static let exportDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "pl_PL")
        return formatter
    }()

    /// "wtorek, 7 lipca 2026" — full Polish date with weekday, for grounding
    /// the model against stale dates inside web search results.
    private static let webDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM yyyy"
        formatter.locale = Locale(identifier: "pl_PL")
        return formatter
    }()

    /// One line stating today and tomorrow explicitly. Search results are often
    /// scraped pages with old forecasts — without this the model happily quotes
    /// "tomorrow, June 15" from a stale page in July.
    private static func webDateContext() -> String {
        let today = webDateFormatter.string(from: Date())
        let tomorrow = webDateFormatter.string(from: Date().addingTimeInterval(86_400))
        return "DZIŚ jest \(today), JUTRO to \(tomorrow)."
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// First free `<base>.md` / `<base>-2.md` / … in the directory — title-first
    /// filenames have no timestamp, so collisions get a numeric suffix instead.
    private static func uniqueURL(in dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }
        return url
    }

    /// ASCII-only, hyphenated slug for filenames (Polish diacritics folded away).
    private static func slug(from title: String) -> String {
        let folded = title.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "pl_PL"))
        let dashed = String(folded.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        var collapsed = dashed
        while collapsed.contains("--") { collapsed = collapsed.replacingOccurrences(of: "--", with: "-") }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    func deleteConversation(_ id: Int64) {
        do {
            try db.deleteConversation(id)
            if currentConversationID == id {
                currentConversationID = nil
                messages = []
            }
            refreshConversations()
        } catch {
            print("[KiwiMango] Failed to delete conversation \(id): \(error)")
        }
    }

    /// Duplicates a conversation (title + all messages/images) and selects the copy —
    /// a lightweight "fork" for trying a different continuation.
    func duplicateConversation(_ id: Int64) {
        do {
            let copy = try db.duplicateConversation(id)
            refreshConversations()
            Task { await selectConversation(copy.id) }
        } catch {
            print("[KiwiMango] Failed to duplicate conversation \(id): \(error)")
        }
    }

    // MARK: - Snippets

    func refreshSnippets() {
        do {
            snippets = try db.fetchSnippets()
        } catch {
            print("[KiwiMango] Failed to load snippets: \(error)")
        }
    }

    @discardableResult
    func saveSnippet(_ snippet: Snippet) -> Snippet? {
        do {
            let saved = try db.saveSnippet(snippet)
            refreshSnippets()
            return saved
        } catch {
            print("[KiwiMango] Failed to save snippet: \(error)")
            return nil
        }
    }

    func deleteSnippet(_ id: Int64) {
        do {
            try db.deleteSnippet(id)
            refreshSnippets()
        } catch {
            print("[KiwiMango] Failed to delete snippet \(id): \(error)")
        }
    }

    /// Ensures a conversation row exists for the current thread, creating one
    /// titled from `firstUserText` (truncated) on first use.
    /// Fala 12 (F12.4): fires whenever the user is about to leave the current
    /// conversation (switch or start a new one) — the natural point to
    /// backfill its TL;DR if the note is still waiting on one.
    private func requestTLDRForCurrentConversation() {
        guard let id = currentConversationID,
              let title = conversations.first(where: { $0.id == id })?.title else { return }
        ObsidianSyncService.generateTLDRIfNeeded(conversationId: id, title: title, model: selectedModel)
    }

    private func ensureConversation(firstUserText: String) -> Int64 {
        if let id = currentConversationID { return id }
        let title = Self.title(from: firstUserText)
        do {
            let conversation = try db.createConversation(title: title)
            currentConversationID = conversation.id
            refreshConversations()
            return conversation.id
        } catch {
            print("[KiwiMango] Failed to create conversation: \(error)")
            // Fall back to an in-memory-only id so the chat still works this
            // session even if disk writes are failing.
            return -1
        }
    }

    private static func title(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Nowa rozmowa" }
        if trimmed.count <= 40 { return trimmed }
        let cut = trimmed.index(trimmed.startIndex, offsetBy: 40)
        return String(trimmed[..<cut]) + "…"
    }

    private func persist(_ message: ChatMessage, conversationId: Int64) {
        guard conversationId != -1 else { return }
        do {
            try db.addMessage(
                conversationId: conversationId,
                role: message.role.rawValue,
                content: message.content,
                images: message.images
            )
            try db.touchConversation(conversationId)
        } catch {
            print("[KiwiMango] Failed to persist message: \(error)")
        }
    }

    // MARK: - Actions

    /// Sends draft + attachments, then streams the assistant reply, appending
    /// deltas to the last message live. Errors become an assistant message.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachedImages.isEmpty else { return }
        guard !isStreaming else { return }

        let images = attachedImages.map(\.data)
        let userMessage = ChatMessage(role: .user, content: text, images: images)
        messages.append(userMessage)
        lastAnimatedMessageID = userMessage.id
        draft = ""
        attachedImages = []

        // Conversation row is created lazily, titled from this first message.
        let conversationId = ensureConversation(firstUserText: text)
        persist(userMessage, conversationId: conversationId)

        let history = await buildHistoryWithWebContext(userText: text)
        await runStream(history: history, conversationId: conversationId)
    }

    /// Fala 14: when the "[WEB]" toggle is on, runs a search (or fetches a URL
    /// found in the message) and splices an ephemeral system message with the
    /// results just before the last user turn. This block is built on the
    /// already-assembled history array — never written back to the transcript
    /// or the database (F14.3 pitfall a).
    private func buildHistoryWithWebContext(userText: String) async -> [OllamaService.ChatPayloadMessage] {
        var history = buildHistory()
        webSearchWarning = nil

        guard UserDefaults.standard.bool(forKey: "webSearchEnabled") else { return history }

        isSearchingWeb = true
        defer { isSearchingWeb = false }

        let urlPattern = #"https?://\S+"#
        let foundURL = userText.range(of: urlPattern, options: .regularExpression).map { String(userText[$0]) }

        do {
            let block: String
            if let foundURL {
                let result = try await service.webFetch(url: foundURL)
                block = """
                [TREŚĆ STRONY — \(Self.exportDateFormatter.string(from: Date()))]
                [1] \(result.title ?? foundURL) — \(foundURL)
                \(result.content)

                \(Self.webDateContext()) Daty w treści strony mogą być nieaktualne.
                Odpowiadaj na podstawie powyższej treści. Jeśli nie wystarcza — powiedz to wprost.
                """
            } else {
                guard let query = await generateSearchQuery(from: userText) else { return history }
                let results = try await service.webSearch(query: query, maxResults: 4)
                guard !results.isEmpty else { return history }
                var combined = "[WYNIKI WYSZUKIWANIA — \(Self.exportDateFormatter.string(from: Date()))]\n"
                for (index, result) in results.enumerated() {
                    combined += "[\(index + 1)] \(result.title) — \(result.url)\n\(result.content)\n"
                }
                combined = String(combined.prefix(6000))
                combined += """

                \(Self.webDateContext()) Treści stron bywają NIEAKTUALNE — wszystkie względne \
                określenia (dziś/jutro/wczoraj) odnoś WYŁĄCZNIE do powyższych dat, a daty \
                znalezione w treści wyników traktuj podejrzliwie: jeśli dane dotyczą innej \
                daty niż pytanie, powiedz to wprost zamiast je cytować.
                Odpowiadaj na podstawie powyższych wyników. Cytuj źródła numerami [1][2] \
                z URL-ami. Jeśli wyniki nie wystarczają — powiedz to wprost.
                """
                block = combined
            }

            if history.last?.role == "user" {
                history.insert(OllamaService.ChatPayloadMessage(role: "system", content: block), at: history.count - 1)
            } else {
                history.append(OllamaService.ChatPayloadMessage(role: "system", content: block))
            }
        } catch {
            webSearchWarning = "web niedostępny, odpowiadam bez sieci"
        }
        return history
    }

    /// Turns the raw user message into one short, date-resolved search query
    /// using the active model. Raw text as a query sent literal phrases like
    /// "masz dostęp do internetu, w czym masz problem?" to the search engine
    /// and got horoscopes back; "jutro" matched calendar pages instead of a
    /// forecast. Returns nil when the message needs no web at all (follow-up,
    /// complaint) — then nothing is injected. On model failure falls back to
    /// the raw text so a broken query generator never disables web search.
    private func generateSearchQuery(from userText: String) async -> String? {
        let prompt = """
        \(Self.webDateContext()) Zamień poniższą wiadomość użytkownika na JEDNO krótkie \
        zapytanie do wyszukiwarki internetowej (max 10 słów, bez cudzysłowów, bez \
        komentarza). Słowa "dziś"/"jutro"/"wczoraj" zamień na konkretne daty. \
        Jeśli wiadomość nie wymaga szukania w internecie (komentarz, pretensja, \
        kontynuacja rozmowy bez nowego tematu), odpowiedz dokładnie: SKIP

        Wiadomość: \(userText.prefix(400))
        """
        var reply = ""
        do {
            for try await delta in service.streamChat(
                model: selectedModel,
                messages: [OllamaService.ChatPayloadMessage(role: "user", content: prompt)],
                think: false
            ) {
                if case .content(let text) = delta { reply += text }
            }
        } catch {
            return String(userText.prefix(400))
        }
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.isEmpty { return String(userText.prefix(400)) }
        if line.uppercased().contains("SKIP") { return nil }
        return String(line.prefix(120))
    }

    /// Drops the last assistant reply (transcript + DB) and streams a fresh one
    /// against the same history. No-op if streaming or the last message isn't
    /// an assistant reply.
    func regenerateLast() async {
        guard !isStreaming else { return }
        guard let last = messages.last, last.role == .assistant else { return }
        guard let conversationId = currentConversationID else { return }

        messages.removeLast()
        do {
            try db.deleteLastAssistantMessage(conversationId: conversationId)
        } catch {
            print("[KiwiMango] Failed to delete last assistant message: \(error)")
        }

        await runStream(history: buildHistory(), conversationId: conversationId)
    }

    /// Builds the `/api/chat` history from the current transcript, prefixed with
    /// the active persona's system prompt (if any). Error/cancel bubbles (`⚠️`/`⏹`)
    /// and empty assistant placeholders are not replayed to the model.
    private func buildHistory() -> [OllamaService.ChatPayloadMessage] {
        var history = messages.compactMap { message -> OllamaService.ChatPayloadMessage? in
            if message.role == .assistant,
               message.content.isEmpty
                || message.content.hasPrefix("⚠️")
                || message.content.hasPrefix("⏹") {
                return nil
            }
            return OllamaService.ChatPayloadMessage(
                role: message.role.rawValue,
                content: message.content,
                images: message.images.isEmpty
                    ? nil
                    : message.images.map(OllamaService.base64(from:))
            )
        }
        if let systemPrompt = activePersona?.systemPrompt, !systemPrompt.isEmpty {
            history.insert(OllamaService.ChatPayloadMessage(role: "system", content: systemPrompt), at: 0)
        }
        return history
    }

    /// Appends an assistant placeholder, streams deltas into it, and persists the
    /// final result. Shared by `send()` (new user turn) and `regenerateLast()`
    /// (same history, fresh reply).
    private func runStream(
        history: [OllamaService.ChatPayloadMessage], conversationId: Int64
    ) async {
        speechSynthesizer.stopAll()
        speechFeeder.reset()

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        let assistantID = assistantMessage.id
        messages.append(assistantMessage)
        lastAnimatedMessageID = assistantID
        isStreaming = true
        liveTokRate = 0
        charsSinceRateSample = 0
        lastRateSampleAt = Date()

        let service = self.service
        let persona = activePersona
        let model = persona?.model ?? selectedModel
        let think: Bool? = thinkingModels.contains(model) ? false : nil
        let temperature = persona?.temperature

        streamTask = Task {
            var succeeded = false
            do {
                for try await delta in service.streamChat(
                    model: model, messages: history, think: think, temperature: temperature
                ) {
                    switch delta {
                    case .content(let text):
                        appendDelta(text, to: assistantID)
                        feedSpeechIfEnabled(assistantID)
                    case .stats(let stats):
                        applyStats(stats, to: assistantID)
                    }
                }
                if Task.isCancelled {
                    markCancelled(assistantID)
                } else {
                    feedSpeechIfEnabled(assistantID, isFinal: true)
                    succeeded = true
                }
            } catch is CancellationError {
                markCancelled(assistantID)
            } catch let urlError as URLError where urlError.code == .cancelled {
                markCancelled(assistantID)
            } catch {
                showError(error, on: assistantID, host: service.displayHost)
            }
            isStreaming = false
            liveTokRate = 0
            streamTask = nil
            if let final = messages.first(where: { $0.id == assistantID }) {
                persist(final, conversationId: conversationId)
            }
            // Fala 12: only a real, completed reply is worth a note — not a
            // cancelled or errored-out one.
            if succeeded, let title = conversations.first(where: { $0.id == conversationId })?.title {
                ObsidianSyncService.syncConversation(conversationId: conversationId, title: title, model: model)
            }
        }
        await streamTask?.value
    }

    /// Feeds the just-appended content to the streaming TTS feeder, sentence
    /// by sentence — only when the composer's "czytaj odpowiedzi" toggle is on.
    private func feedSpeechIfEnabled(_ id: UUID, isFinal: Bool = false) {
        guard UserDefaults.standard.bool(forKey: "ttsEnabled") else { return }
        guard let message = messages.first(where: { $0.id == id }) else { return }
        speechFeeder.consume(fullContent: message.content, isFinal: isFinal)
    }

    /// Cancels the in-progress streaming response (partial content is kept).
    func cancel() {
        streamTask?.cancel()
        speechSynthesizer.stopAll()
    }

    /// Cancels the in-progress stream and waits for its cleanup/persist to
    /// finish, so callers that are about to clear `messages` (switching or
    /// starting a conversation) never race the still-running `send()` task.
    private func cancelAndWait() async {
        streamTask?.cancel()
        await streamTask?.value
        speechSynthesizer.stopAll()
    }

    /// Reads an arbitrary chunk of text aloud (the "przeczytaj" hover action),
    /// independent of the streaming "ttsEnabled" toggle. Whole fenced code
    /// blocks are replaced with a single spoken placeholder.
    func readMessageAloud(_ content: String) {
        let parts = content.components(separatedBy: "```")
        var spoken = ""
        for (index, part) in parts.enumerated() {
            spoken += index.isMultiple(of: 2) ? part : " ...blok kodu... "
        }
        speechSynthesizer.speak(StreamingSpeechFeeder.stripMarkdown(spoken))
    }

    /// Fetches the model list (GET /api/tags) and caches thinking capabilities.
    func loadModels() async {
        do {
            let models = try await service.listModelsDetailed()
            availableModels = models
            thinkingModels = Set(models.filter(\.supportsThinking).map(\.name))
        } catch {
            // Offline → keep whatever we had; the picker falls back to selectedModel.
        }
    }

    /// Clears the thread (stops streaming first).
    func clear() {
        cancel()
        messages = []
    }

    // MARK: - Attachments

    /// Adds an attachment, normalizing non-PNG/JPEG inputs (e.g. HEIC) to JPEG
    /// — Ollama decodes only JPEG/PNG.
    func addAttachment(data: Data) {
        let normalized = ChatImage.normalize(data)
        let thumbnail = ChatImage.thumbnail(from: normalized)
        attachedImages.append(AttachedImage(data: normalized, thumbnail: thumbnail))
    }

    func removeAttachment(_ id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    // MARK: - Private helpers

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].content += delta

        charsSinceRateSample += delta.count
        let elapsed = Date().timeIntervalSince(lastRateSampleAt)
        if elapsed >= 0.5 {
            liveTokRate = (Double(charsSinceRateSample) / 4.0) / elapsed
            charsSinceRateSample = 0
            lastRateSampleAt = Date()
        }
    }

    private func applyStats(_ stats: OllamaService.ChatStats, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        let tokPerSec = String(format: "%.1f", stats.tokensPerSecond)
        messages[index].statsLine = "\(stats.evalCount) tok • \(tokPerSec) tok/s"

        tokRateHistory.append(stats.tokensPerSecond)
        if tokRateHistory.count > 40 {
            tokRateHistory.removeFirst(tokRateHistory.count - 40)
        }
    }

    private func markCancelled(_ id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        if messages[index].content.isEmpty {
            messages[index].content = "⏹ Przerwano."
        }
    }

    private func showError(_ error: Error, on id: UUID, host: String) {
        let text: String
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut,
                 .networkConnectionLost, .notConnectedToInternet:
                text = "⚠️ Ollama nie odpowiada (\(host)). Sprawdź, czy `ollama serve` działa."
            default:
                text = "⚠️ Błąd połączenia: \(urlError.localizedDescription)"
            }
        } else if case .http(let code, _) = error as? OllamaService.OllamaError, code == 401 || code == 403 {
            text = "⚠️ Sesja ollama.com wygasła. Zaloguj się: `ollama signin`"
        } else {
            text = "⚠️ \(error.localizedDescription)"
        }

        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        if messages[index].content.isEmpty {
            messages[index].content = text
        } else {
            messages[index].content += "\n\n" + text
        }
        glitchTrigger += 1
    }
}

// MARK: - ChatImage

/// Image helpers for chat attachments (normalization + thumbnails).
enum ChatImage {

    /// Returns PNG/JPEG data unchanged; re-encodes anything else (HEIC, TIFF…)
    /// as JPEG, since Ollama decodes only JPEG/PNG.
    static func normalize(_ data: Data) -> Data {
        if isPNG(data) || isJPEG(data) { return data }
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return data }
        return jpeg
    }

    /// Downscaled preview for composer/bubble thumbnails.
    static func thumbnail(from data: Data, maxSide: CGFloat = 160) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        return NSImage(size: target, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 3 && data.prefix(3) == Data([0xFF, 0xD8, 0xFF])
    }
}
