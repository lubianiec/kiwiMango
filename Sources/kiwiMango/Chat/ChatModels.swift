import AppKit
import Foundation
import Observation

// MARK: - kiwi-card system prompt

let kiwiCardSystemPrompt = """
Język: polski.

Gdy Twoja odpowiedź zawiera dane pasujące do małej karty podsumowującej (pogoda, kroki, statystyki, porównanie A vs B), zakończ odpowiedź osobnym blokiem w formacie JSON otoczonym płotkiem ` ```kiwi-card ` ... ` ``` `.

Dostępne typy karty:
- `weather` — np. prognoza pogody. Pola: `title`, opcjonalnie `icon`, `rows` (tablica `{icon, label, value}`) i/lub `chart`.
- `stats` — np. metryki. Pola jak `weather`.
- `steps` — ponumerowane kroki. Pola: `title`, `steps` (tablica stringów).
- `compare` — porównanie dwóch rzeczy. Pola: `title`, `leftTitle`, `rightTitle`, `rows` (każdy rząd to jedna metryka: `value` = lewa, `label` = prawa).

Ikony (SF Symbols). Używaj TYLKO z tej listy: cloud.sun, cloud.rain, wind, thermometer, drop, chart.bar, list.number, checkmark.circle, exclamationmark.triangle, eurosign.circle, clock, calendar, location, arrow.up.right, info.circle. Nieznana ikona zostanie zastąpiona `info.circle`.

Wykres (opcjonalny):
```
"chart": {"kind":"bars", "label":"Temperatura w ciągu dnia", "points":[{"x":"6","y":11}, {"x":"12","y":16}, {"x":"18","y":17}]}
```
`kind` może być "bars" lub "line". Max 12 punktów.

Przykład pogody:
```kiwi-card
{"type":"weather","title":"Borkum — środa 8.07","icon":"cloud.sun","rows":[{"icon":"thermometer","label":"Temperatura","value":"16–18°C"},{"icon":"wind","label":"Wiatr NW","value":"22–37 km/h"}],"chart":{"kind":"bars","label":"Temp. w ciągu dnia","points":[{"x":"6","y":11},{"x":"12","y":16},{"x":"18","y":17}]}}
```

Zasady:
1. Karta jest BONUSEM — zwykła rozmowa, kod, długi tekst bez danych liczbowych = bez bloku.
2. Karta musi być rzadka i trafna.
3. Blok zawsze na KOŃCU odpowiedzi.
4. JSON ma być zwarty, jednoliniowy, bez komentarzy.
5. Nie każdą odpowiedź pakuj w kartę. Większość odpowiedzi ma jej nie mieć.
"""

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
    /// Centrum Dowodzenia (Fala 18) — live dashboard of running agent
    /// sessions. One shared panel (no id), reached only via the status bar's
    /// "Agenci [N]" segment — deliberately not a sidebar entry (F15 already
    /// slimmed the sidebar down).
    case missionControl
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

    /// Fala 24 (F24.2): Hermes gateway's `thinking.delta`/`reasoning.delta`
    /// stream, shown in a collapsed "MYŚLI…" section — separate from the
    /// F22 `reasoningAndContent` fenced-block hack (that one lives inside
    /// `content` for the headless fallback path). Not persisted.
    var gatewayThinking: String?
    /// Live `tool.start`/`tool.complete`/`subagent.*` status lines, PO POLSKU
    /// via `ToolHumanizer.describeHermes`, shown above the final text while
    /// (and after) a gateway turn runs. Not persisted — the DB only ever
    /// gets the final `content`.
    var gatewayToolLines: [String] = []
    /// F26.4: unified diffs from `write_file`/`patch` tool calls (`tool.complete`'s
    /// `inline_diff`, ANSI codes already stripped) — rendered as a diff view under
    /// the matching tool line instead of a plain status string. Not persisted.
    var gatewayDiffs: [String] = []
    /// Set while an `approval.request` is blocking the turn — `ChatView`
    /// renders ZATWIERDŹ/ODRZUĆ buttons. Not persisted.
    var pendingApproval: PendingApproval?
    /// Set while a `clarify.request` is blocking the turn. Not persisted.
    var pendingClarify: PendingClarify?
    /// Fala 24.5: whether `gatewayThinking`'s section is shown expanded.
    /// Defaults `true` so reasoning is visible LIVE while a turn streams
    /// (Paweł's complaint: "nie pokazuje na żywo") — `ChatState` flips it to
    /// `false` once the turn completes, so history stays uncluttered.
    var gatewayThinkingExpanded = true
    /// Fala 24.6: count of still-running subagents this session delegated —
    /// drives the "⏳ subagenci pracują… [N]" bar under the bubble. Survives
    /// past `message.complete` (unlike the fields above) since delegated work
    /// keeps going after the root reply finishes. Not persisted; reattached
    /// to the last assistant bubble on conversation reselect (`ChatState.
    /// reconcileHermesLiveAssistantIDs`).
    var backgroundSubagentCount = 0

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

// MARK: - PendingApproval / PendingClarify (Fala 24)

/// Mirrors `approval.request`'s payload shape (confirmed in source,
/// `tools/approval.py`) — `command`/`description` come pre-redacted by the
/// server, safe to render verbatim.
struct PendingApproval: Equatable {
    var command: String?
    var description: String?
}

/// Mirrors `clarify.request`'s payload shape.
struct PendingClarify: Equatable {
    var question: String
    var choices: [String]
}

// MARK: - HermesSessionRuntime (Fala 24.6)

/// Per Hermes gateway `session_id` runtime state, kept alive independent of
/// any single `Task` — a session might keep producing events (delegated
/// subagents, a follow-up report) long after its root turn's `message.
/// complete` and long after the user has switched to another conversation.
/// Reference type deliberately: `ChatState`'s event listener mutates it from
/// arbitrary event-handling call sites without re-fetching/re-storing a
/// value type on every field write.
private final class HermesSessionRuntime {
    let conversationId: Int64
    let model: String
    var startedAt = Date()

    /// The assistant bubble currently being written to, IF `conversationId`
    /// is the on-screen conversation right now — `nil` when off-screen
    /// (events accumulate into the `offscreen*` buffers instead) or between
    /// messages. Reattached by `ChatState.reconcileHermesLiveAssistantIDs`
    /// whenever the user switches conversations.
    var liveAssistantID: UUID?
    /// True from `prompt.submit` until THIS turn's `message.complete` —
    /// gates `isStreaming`/STOP for the on-screen case and lets
    /// `ChatState.cancel()` know an interrupt is actually meaningful.
    var isTurnRunning = false

    var offscreenThinking = ""
    var offscreenToolLines: [String] = []
    var offscreenText = ""

    /// Active subagent ids (`subagent.start` seen, no `.complete` yet) —
    /// backs the "⏳ subagenci pracują… [N]" bar.
    var activeSubagentIDs: Set<String> = []

    init(conversationId: Int64, model: String) {
        self.conversationId = conversationId
        self.model = model
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

    /// Fala 17: cached availability state for Anthropic models. The section is
    /// shown whenever `claude` is installed; models are selectable only when
    /// the state is `.available`. When unavailable the reason (e.g. rate-limit
    /// reset time) is shown next to the disabled entries.
    var claudeAvailability: ClaudeCodeService.ClaudeAvailability = .binaryNotFound

    /// Backwards-compatible shorthand used by legacy call sites.
    var claudeAvailable: Bool { claudeAvailability.isAvailable }

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

    /// Fala 24.6: conversations with unseen Hermes activity that arrived
    /// while they weren't on screen (a background subagent's follow-up
    /// report) — sidebar shows a badge dot, cleared on `selectConversation`.
    var hermesUnreadConversationIDs: Set<Int64> = []

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

    /// Fala 22 (F22.2): Hermes keeps conversation context on its own side via
    /// `hermes chat --resume <id>` — this only maps kiwiMango's `conversationId`
    /// to the last Hermes `session_id` seen for it, so the next turn in the
    /// same conversation resumes the right session. Deliberately in-memory
    /// only (not persisted to GRDB), same philosophy as Fala 4's agent
    /// sessions: this is a transport-continuity detail, not durable data —
    /// it lives only for the app run and is rebuilt (fresh Hermes session)
    /// on next launch.
    @ObservationIgnored private var hermesSessionIDs: [Int64: String] = [:]

    /// Fala 24: the gateway `session_id` + assistant message id currently
    /// waiting on an approval/clarify response or a STOP interrupt. `nil`
    /// whenever no gateway turn is in flight — `cancel()`/`respondApproval`/
    /// `respondClarify` all no-op without it.
    @ObservationIgnored private var activeHermesGatewaySessionID: String?
    @ObservationIgnored private var activeHermesGatewayAssistantID: UUID?

    /// Fala 24.6: one runtime per Hermes gateway `session_id`, alive for as
    /// long as that session might still produce background events (a
    /// delegated subagent, a follow-up report after it finishes) —
    /// deliberately NOT tied to `streamTask`/any single `Task`, unlike
    /// Ollama/Claude turns, so conversation switches never interrupt it.
    @ObservationIgnored private var hermesSessions: [String: HermesSessionRuntime] = [:]
    /// One persistent consumer of `HermesGatewayClient.shared.events()` for
    /// the whole app run (started lazily on first Hermes turn) — replaces
    /// F24.2's per-turn `for await` loop, which stopped listening at
    /// `message.complete` and dropped every background/subagent event after
    /// (F24.6 pułapka #1).
    @ObservationIgnored private var hermesListenerTask: Task<Void, Never>?

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
        // Fala 24.6: no conversation is on-screen now — any Hermes session
        // still running detaches to its offscreen buffers instead of a dead
        // bubble id. `cancelAndWait` above only touches Ollama/Claude's
        // `streamTask`; a Hermes root turn or its background subagents keep
        // running untouched (no `session.interrupt` sent here — see
        // `reconcileHermesLiveAssistantIDs` doc).
        reconcileHermesLiveAssistantIDs(selectedConversationId: nil)
        recomputeIsStreamingForCurrentConversation()
    }

    /// Loads a previously saved conversation's messages into the transcript.
    /// See `startNewConversation` for why this waits on the pending stream.
    func selectConversation(_ id: Int64) async {
        guard id != currentConversationID else { return }
        await cancelAndWait()
        requestTLDRForCurrentConversation()
        currentConversationID = id
        lastAnimatedMessageID = nil
        hermesUnreadConversationIDs.remove(id)
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
        // Fala 24.6: if a Hermes session for THIS conversation kept working
        // while the user was elsewhere, re-point it at the freshly reloaded
        // last assistant bubble (a fresh `ChatMessage` struct — reload
        // doesn't preserve the old, now-dead UUID) so live subagent-progress
        // events resume landing somewhere instead of silently no-op'ing.
        reconcileHermesLiveAssistantIDs(selectedConversationId: id)
        recomputeIsStreamingForCurrentConversation()
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
    /// Fala 19: the kiwi-card contract is appended as a final system message for
    /// all non-Claude models, so the model can emit a structured card when data fits.
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
        if !selectedModel.hasPrefix("claude:") && !selectedModel.hasPrefix("hermes:") {
            history.insert(OllamaService.ChatPayloadMessage(role: "system", content: kiwiCardSystemPrompt), at: 0)
        }
        return history
    }

    /// Appends an assistant placeholder, streams deltas into it, and persists the
    /// final result. Shared by `send()` (new user turn) and `regenerateLast()`
    /// (same history, fresh reply).
    ///
    /// Fala 17: `claude:*` model ids route to `ClaudeCodeService` instead of
    /// `OllamaService` — everything else (bubble append, persist, Obsidian
    /// sync) is shared via the same assistant-placeholder pattern.
    private func runStream(
        history: [OllamaService.ChatPayloadMessage], conversationId: Int64
    ) async {
        let persona = activePersona
        let model = persona?.model ?? selectedModel

        if let claudeModel = ClaudeCodeService.parseModelID(model) {
            await runClaudeStream(claudeModel: claudeModel, history: history, conversationId: conversationId)
            return
        }
        if let hermesModel = HermesChatService.parseModelID(model) {
            await runHermesGatewayStream(hermesModel: hermesModel, history: history, conversationId: conversationId)
            return
        }

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

    /// Fala 17: `claude -p` takes a single prompt string + `--resume <id>` for
    /// continuity — NOT the full message array `OllamaService` uses. Only the
    /// last user turn from `history` is sent as the prompt; the CLI's own
    /// session (looked up/persisted via `claudeSessionID`) carries the rest
    /// of the context. TTS/speechFeeder is intentionally skipped — Claude
    /// replies are typically longer/code-heavy and the feeder is tuned for
    /// Ollama's sentence-by-sentence cadence.
    private func runClaudeStream(
        claudeModel: ClaudeCodeService.ClaudeModel,
        history: [OllamaService.ChatPayloadMessage],
        conversationId: Int64
    ) async {
        let prompt = history.last { $0.role == "user" }?.content ?? ""

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        let assistantID = assistantMessage.id
        messages.append(assistantMessage)
        lastAnimatedMessageID = assistantID
        isStreaming = true
        liveTokRate = 0

        let resumeSessionID = conversationId != -1
            ? try? db.fetchConversationClaudeSessionID(conversationId)
            : nil
        let service = ClaudeCodeService()
        let startedAt = Date()

        streamTask = Task {
            var succeeded = false
            do {
                for try await delta in service.streamMessage(
                    prompt: prompt, model: claudeModel, resumeSessionID: resumeSessionID ?? nil
                ) {
                    switch delta {
                    case .content(let text):
                        appendDelta(text, to: assistantID)
                    case .result(let info):
                        if let sessionID = info.sessionID, conversationId != -1 {
                            try? db.setConversationClaudeSessionID(conversationId, sessionID: sessionID)
                        }
                        if !info.isError {
                            applyClaudeStats(startedAt: startedAt, to: assistantID)
                        }
                    }
                }
                if Task.isCancelled {
                    markCancelled(assistantID)
                } else {
                    succeeded = true
                }
            } catch is CancellationError {
                markCancelled(assistantID)
            } catch {
                showClaudeError(error, on: assistantID)
            }
            isStreaming = false
            liveTokRate = 0
            streamTask = nil
            if let final = messages.first(where: { $0.id == assistantID }) {
                persist(final, conversationId: conversationId)
            }
            if succeeded, let title = conversations.first(where: { $0.id == conversationId })?.title {
                ObsidianSyncService.syncConversation(conversationId: conversationId, title: title, model: "claude:\(claudeModel.rawValue)")
            }
        }
        await streamTask?.value
    }

    /// Claude has no `eval_count`/tok-s equivalent to Ollama's — show elapsed
    /// wall-clock time only, never a fabricated tok/s number (F17.2 pt. 3).
    private func applyClaudeStats(startedAt: Date, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        let seconds = Date().timeIntervalSince(startedAt)
        messages[index].statsLine = String(format: "%.1f s", seconds)
    }

    /// Fala 17: same "readable Polish message, not raw JSON" bar as `showError`.
    /// `ClaudeCodeService.ClaudeCodeError` already has Polish `errorDescription`
    /// for the rate-limit/not-logged-in/binary-missing cases from F17.1.
    private func showClaudeError(_ error: Error, on id: UUID) {
        let text = "⚠️ \(error.localizedDescription)"
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        if messages[index].content.isEmpty {
            messages[index].content = text
        } else {
            messages[index].content += "\n\n" + text
        }
        glitchTrigger += 1
    }

    /// Placeholder shown in the assistant bubble while `hermes chat` runs —
    /// unlike Ollama/Claude there are no deltas, just one blob at the end
    /// (F22 pułapka 5), so without this the bubble would stay blank for up
    /// to 5 minutes with only the global "isStreaming" dot as feedback.
    private static let hermesPlaceholder = "🦉 HERMES pracuje…"

    // MARK: - Hermes gateway (Fala 24) — full agent via WebSocket

    /// Fala 24: routes `hermes:*` turns through `HermesGatewayClient` — a
    /// full agent (tools, subagents, approvals) over the WS gateway, instead
    /// of F22's one-shot headless CLI. Falls back to `runHermesStream` (F22,
    /// below) ONLY if the gateway can't even connect (binary missing, server
    /// failed to spawn) — a genuine "catastrophe at step zero", per PLAN.md's
    /// own framing of the old path as plan B.
    ///
    /// Fala 24.6 rewrite: this function no longer consumes the event stream
    /// itself (the old per-turn `for await ... turnLoop` stopped listening at
    /// `message.complete`, silently dropping every background subagent event
    /// after — pułapka #1). `ensureHermesListener()` starts ONE persistent
    /// consumer for the whole app run; this function's job is now just:
    /// resolve/create the session, submit the prompt, and return — the
    /// listener (`handleHermesEvent`) does all the actual event handling,
    /// on-screen or off, for as long as the session keeps producing events.
    /// Deliberately does NOT use `streamTask` (unlike Ollama/Claude) so
    /// `cancelAndWait()` (conversation switch) never touches a Hermes turn —
    /// F24.6 pułapka #2: interrupt must be explicit-STOP-only.
    private func runHermesGatewayStream(
        hermesModel: String,
        history: [OllamaService.ChatPayloadMessage],
        conversationId: Int64
    ) async {
        let client = HermesGatewayClient.shared
        do {
            try await client.connectIfNeeded()
        } catch {
            await runHermesStream(hermesModel: hermesModel, history: history, conversationId: conversationId)
            return
        }
        ensureHermesListener()

        let prompt = history.last { $0.role == "user" }?.content ?? ""
        let userImages = messages.last { $0.role == .user }?.images ?? []

        let assistantMessage = ChatMessage(role: .assistant, content: "")
        let assistantID = assistantMessage.id
        messages.append(assistantMessage)
        lastAnimatedMessageID = assistantID
        isStreaming = true
        liveTokRate = 0
        activeHermesGatewayAssistantID = assistantID

        do {
            let existingSessionID = conversationId != -1
                ? try? db.fetchConversationHermesGatewaySessionID(conversationId)
                : nil
            let sessionID = try await client.resumeOrCreateSession(
                existingSessionID: existingSessionID, model: hermesModel, provider: "ollama-launch", cwd: nil
            )
            activeHermesGatewaySessionID = sessionID
            if conversationId != -1, sessionID != existingSessionID {
                try? db.setConversationHermesGatewaySessionID(conversationId, sessionID: sessionID)
            }

            let runtime = hermesSessions[sessionID] ?? HermesSessionRuntime(conversationId: conversationId, model: hermesModel)
            runtime.liveAssistantID = assistantID
            runtime.isTurnRunning = true
            runtime.startedAt = Date()
            hermesSessions[sessionID] = runtime

            let title = conversations.first(where: { $0.id == conversationId })?.title ?? "Nowa rozmowa"
            HermesTelemetry.shared.ensureCard(sessionID: sessionID, conversationTitle: title)

            if let firstImage = userImages.first {
                let isPNG = firstImage.count >= 4 && firstImage.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
                try? await client.attachImageBytes(
                    sessionID: sessionID,
                    base64Data: firstImage.base64EncodedString(),
                    mimeType: isPNG ? "image/png" : "image/jpeg"
                )
            }
            if userImages.count > 1 {
                appendGatewayToolLine("(Hermes przyjmuje 1 obraz na wiadomość — wysłano tylko pierwszy)", to: assistantID)
            }

            try await client.submitPrompt(sessionID: sessionID, text: prompt)
            // Returns here — `handleHermesEvent` (via the persistent listener)
            // takes it from here, including flipping `isStreaming` back to
            // false at `message.complete`. Nothing left to await: `send()`'s
            // caller doesn't need the full reply to exist before regaining
            // control, only before the composer would let you double-submit,
            // and `isStreaming` already blocks that.
        } catch {
            showGatewayError(error.localizedDescription, on: assistantID)
            isStreaming = false
            liveTokRate = 0
            activeHermesGatewaySessionID = nil
            activeHermesGatewayAssistantID = nil
        }
    }

    // MARK: - Persistent event listener (Fala 24.6)

    /// Starts the ONE consumer of `HermesGatewayClient.shared.events()` for
    /// the app's lifetime. Idempotent — safe to call on every turn.
    private func ensureHermesListener() {
        guard hermesListenerTask == nil else { return }
        hermesListenerTask = Task { [weak self] in
            guard let self else { return }
            let stream = await HermesGatewayClient.shared.events()
            for await event in stream {
                self.handleHermesEvent(event)
            }
        }
    }

    /// Central dispatch for every Hermes gateway event, on-screen or off.
    /// Runs on `ChatState`'s MainActor (the listener `Task` inherits it —
    /// same pattern the old per-turn `streamTask` already relied on).
    private func handleHermesEvent(_ event: HermesGatewayClient.Event) {
        switch event {
        case .ready, .sessionTitle, .subagentText:
            return
        case .messageStart(let sid):
            guard let runtime = hermesSessions[sid] else { return }
            runtime.isTurnRunning = true
            beginHermesBubble(runtime: runtime)
            HermesTelemetry.shared.setTurnRunning(sessionID: sid, running: true)
        case .messageDelta(let sid, let text):
            guard let runtime = hermesSessions[sid] else { return }
            if isOnScreen(runtime), let liveID = runtime.liveAssistantID {
                appendDelta(text, to: liveID)
            } else {
                runtime.offscreenText += text
            }
        case .thinkingDelta(let sid, let text):
            guard let runtime = hermesSessions[sid] else { return }
            if isOnScreen(runtime), let liveID = runtime.liveAssistantID {
                appendGatewayThinking(text, to: liveID)
            } else {
                runtime.offscreenThinking += text
            }
        case .toolStart(let sid, _, let name, let context):
            guard let runtime = hermesSessions[sid] else { return }
            let line = ToolHumanizer.describeHermes(name: name, context: context, command: nil)
            recordHermesLine(line, runtime: runtime)
            HermesTelemetry.shared.setActivity(sessionID: sid, text: line)
        case .toolComplete(let sid, _, _, _, let exitCode, let errorText, let inlineDiff):
            guard let runtime = hermesSessions[sid] else { return }
            if let errorText, !errorText.isEmpty {
                recordHermesLine("⚠️ błąd narzędzia: \(errorText)", runtime: runtime)
            } else if let exitCode, exitCode != 0 {
                recordHermesLine("⚠️ kod wyjścia \(exitCode)", runtime: runtime)
            }
            if let inlineDiff, !inlineDiff.isEmpty {
                recordHermesDiff(inlineDiff, runtime: runtime)
            }
        case .subagentStart(let sid, let subID, let description):
            guard let runtime = hermesSessions[sid] else { return }
            runtime.activeSubagentIDs.insert(subID)
            recordHermesLine("  ↳ subagent: \(description ?? "…")", runtime: runtime)
            updateBackgroundSubagentCount(runtime: runtime)
            HermesTelemetry.shared.subagentStarted(sessionID: sid, subagentID: subID, description: description)
        case .subagentComplete(let sid, let subID):
            guard let runtime = hermesSessions[sid] else { return }
            runtime.activeSubagentIDs.remove(subID)
            recordHermesLine("  ↳ subagent zakończony", runtime: runtime)
            updateBackgroundSubagentCount(runtime: runtime)
            HermesTelemetry.shared.subagentCompleted(sessionID: sid, subagentID: subID)
        case .approvalRequest(let sid, let command, let description):
            guard let runtime = hermesSessions[sid] else { return }
            if isOnScreen(runtime), let liveID = runtime.liveAssistantID {
                setPendingApproval(PendingApproval(command: command, description: description), to: liveID)
            }
            // Off-screen approval requests have no UI surface yet (would need
            // a global banner independent of any bubble) — out of scope for
            // this fala; the agent thread just blocks server-side until the
            // user comes back to this conversation and the model times out
            // or the user notices via the unread badge.
        case .clarifyRequest(let sid, let question, let choices):
            guard let runtime = hermesSessions[sid] else { return }
            if isOnScreen(runtime), let liveID = runtime.liveAssistantID {
                setPendingClarify(PendingClarify(question: question, choices: choices), to: liveID)
            }
        case .messageComplete(let sid, let text, _, let inputTokens, let outputTokens):
            guard let runtime = hermesSessions[sid] else { return }
            HermesTelemetry.shared.setUsage(sessionID: sid, input: inputTokens, output: outputTokens)
            finishHermesTurn(sessionID: sid, runtime: runtime, text: text, errorMessage: nil)
        case .turnError(let sid, let message):
            guard let sid, let runtime = hermesSessions[sid] else { return }
            finishHermesTurn(sessionID: sid, runtime: runtime, text: nil, errorMessage: message)
        }
    }

    private func isOnScreen(_ runtime: HermesSessionRuntime) -> Bool {
        runtime.conversationId == currentConversationID
    }

    /// Opens a fresh assistant bubble for a background wake-up (a follow-up
    /// report after subagents finish) IF the conversation is on-screen and
    /// no bubble is currently open for it — the root turn's own bubble is
    /// already appended synchronously by `runHermesGatewayStream` before
    /// `message.start` ever arrives, so this only fires for later turns.
    private func beginHermesBubble(runtime: HermesSessionRuntime) {
        guard isOnScreen(runtime) else { return }
        guard runtime.liveAssistantID == nil else { return }
        let msg = ChatMessage(role: .assistant, content: "")
        messages.append(msg)
        lastAnimatedMessageID = msg.id
        runtime.liveAssistantID = msg.id
    }

    private func recordHermesLine(_ line: String, runtime: HermesSessionRuntime) {
        if isOnScreen(runtime), let liveID = runtime.liveAssistantID {
            appendGatewayToolLine(line, to: liveID)
        } else {
            runtime.offscreenToolLines.append(line)
        }
    }

    /// F26.4: `inline_diff` only ever reaches the live bubble as a rendered diff
    /// view — off-screen turns fall back to plain text (still legible, just not
    /// colorized) so a background edit's diff isn't silently lost.
    private func recordHermesDiff(_ diff: String, runtime: HermesSessionRuntime) {
        let stripped = Self.stripANSI(diff)
        if isOnScreen(runtime), let liveID = runtime.liveAssistantID,
           let index = messages.lastIndex(where: { $0.id == liveID }) {
            messages[index].gatewayDiffs.append(stripped)
        } else {
            runtime.offscreenToolLines.append(stripped)
        }
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func updateBackgroundSubagentCount(runtime: HermesSessionRuntime) {
        guard isOnScreen(runtime), let liveID = runtime.liveAssistantID,
              let index = messages.lastIndex(where: { $0.id == liveID }) else { return }
        messages[index].backgroundSubagentCount = runtime.activeSubagentIDs.count
    }

    /// Domyka one message.start→message.complete cycle for a session —
    /// called for BOTH the root turn and every later background wake-up.
    /// Only flips `isStreaming`/clears `activeHermesGateway*` when this was
    /// the on-screen ROOT turn (subsequent background turns never touched
    /// those in the first place).
    private func finishHermesTurn(
        sessionID: String, runtime: HermesSessionRuntime, text: String?, errorMessage: String?
    ) {
        let wasRootTurnOnScreen = runtime.isTurnRunning && isOnScreen(runtime)
            && runtime.liveAssistantID == activeHermesGatewayAssistantID
        runtime.isTurnRunning = false
        HermesTelemetry.shared.setTurnRunning(sessionID: sessionID, running: false)

        if isOnScreen(runtime), let liveID = runtime.liveAssistantID {
            if let errorMessage {
                showGatewayError(errorMessage, on: liveID)
            } else if let text {
                setContent(text, on: liveID)
                applyHermesStats(startedAt: runtime.startedAt, to: liveID)
            }
            collapseGatewayThinking(on: liveID)
            if let final = messages.first(where: { $0.id == liveID }) {
                persist(final, conversationId: runtime.conversationId)
            }
            runtime.liveAssistantID = nil
        } else {
            var combined = ""
            if !runtime.offscreenToolLines.isEmpty {
                combined += runtime.offscreenToolLines.joined(separator: "\n") + "\n\n"
            }
            combined += errorMessage.map { "⚠️ \($0)" } ?? (text ?? runtime.offscreenText)
            persistOffscreenHermesMessage(combined, conversationId: runtime.conversationId)
            hermesUnreadConversationIDs.insert(runtime.conversationId)
            runtime.offscreenThinking = ""
            runtime.offscreenToolLines = []
            runtime.offscreenText = ""
        }

        if wasRootTurnOnScreen {
            isStreaming = false
            liveTokRate = 0
            activeHermesGatewaySessionID = nil
            activeHermesGatewayAssistantID = nil
        }

        if errorMessage == nil, let title = conversations.first(where: { $0.id == runtime.conversationId })?.title {
            ObsidianSyncService.syncConversation(conversationId: runtime.conversationId, title: title, model: "hermes:\(runtime.model)")
        }
    }

    private func persistOffscreenHermesMessage(_ content: String, conversationId: Int64) {
        guard conversationId != -1 else { return }
        do {
            try db.addMessage(conversationId: conversationId, role: "assistant", content: content, images: [])
            try db.touchConversation(conversationId)
            refreshConversations()
        } catch {
            print("[KiwiMango] Failed to persist offscreen Hermes message: \(error)")
        }
    }

    /// Fala 24.6: called after every conversation switch. Reattaches each
    /// live Hermes session to the freshly (re)loaded `messages` array — the
    /// old `liveAssistantID` always points at a dead struct instance after a
    /// reload (GRDB round-trip mints new `UUID`s), so without this every
    /// live event for a just-reselected conversation would silently no-op.
    private func reconcileHermesLiveAssistantIDs(selectedConversationId: Int64?) {
        for runtime in hermesSessions.values {
            guard runtime.conversationId == selectedConversationId else {
                runtime.liveAssistantID = nil
                continue
            }
            guard let lastAssistant = messages.last(where: { $0.role == .assistant }) else {
                runtime.liveAssistantID = nil
                continue
            }
            runtime.liveAssistantID = lastAssistant.id
            if let index = messages.lastIndex(where: { $0.id == lastAssistant.id }) {
                messages[index].backgroundSubagentCount = runtime.activeSubagentIDs.count
            }
        }
    }

    /// Fala 24.6: recomputes `isStreaming`/`activeHermesGateway*` for
    /// whatever conversation is now on-screen — needed because switching
    /// conversations no longer cancels a Hermes root turn (F24.6 pułapka
    /// #2), so the flag must be derived fresh rather than left over from
    /// whichever conversation set it last.
    private func recomputeIsStreamingForCurrentConversation() {
        guard let match = hermesSessions.first(where: { _, runtime in
            runtime.conversationId == currentConversationID && runtime.isTurnRunning
        }) else {
            isStreaming = false
            activeHermesGatewaySessionID = nil
            activeHermesGatewayAssistantID = nil
            return
        }
        isStreaming = true
        activeHermesGatewaySessionID = match.key
        activeHermesGatewayAssistantID = match.value.liveAssistantID
    }

    /// ZATWIERDŹ/ODRZUĆ button action (F24.2) — no-op if no approval is
    /// currently pending (defensive; buttons are only shown when it is).
    func respondApproval(approve: Bool) {
        guard let assistantID = activeHermesGatewayAssistantID,
              let sessionID = activeHermesGatewaySessionID else { return }
        clearPendingApproval(on: assistantID)
        Task { try? await HermesGatewayClient.shared.respondApproval(sessionID: sessionID, approve: approve) }
    }

    /// `clarify.request` text-field submit action (F24.2).
    func respondClarify(answer: String) {
        guard let assistantID = activeHermesGatewayAssistantID,
              let sessionID = activeHermesGatewaySessionID else { return }
        clearPendingClarify(on: assistantID)
        Task { try? await HermesGatewayClient.shared.respondClarify(sessionID: sessionID, answer: answer) }
    }

    private func appendGatewayThinking(_ delta: String, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].gatewayThinking = (messages[index].gatewayThinking ?? "") + delta
        // Fala 24.5: keep it expanded WHILE streaming — collapsed only once
        // `finishHermesTurn` calls `collapseGatewayThinking` at the end.
        messages[index].gatewayThinkingExpanded = true
    }

    /// Fala 24.5: flip to collapsed once the turn's done — the live-expanded
    /// default (`ChatMessage.gatewayThinkingExpanded`) would otherwise leave
    /// every past turn's reasoning permanently unrolled in the history.
    private func collapseGatewayThinking(on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].gatewayThinkingExpanded = false
    }

    /// Manual toggle for the "MYŚLI…" button (F24.2/F24.5) — `MessageBubble`
    /// has no direct binding into `chatState.messages[i]`, so it calls this
    /// instead of managing its own `@State` (which broke: see F24.2 history).
    func toggleGatewayThinking(on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].gatewayThinkingExpanded.toggle()
    }

    private func appendGatewayToolLine(_ line: String, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].gatewayToolLines.append(line)
    }

    private func setPendingApproval(_ approval: PendingApproval, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].pendingApproval = approval
    }

    private func clearPendingApproval(on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].pendingApproval = nil
    }

    private func setPendingClarify(_ clarify: PendingClarify, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].pendingClarify = clarify
    }

    private func clearPendingClarify(on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].pendingClarify = nil
    }

    /// Fala 24 (F24.4): Polish error surface for `HermesGatewayClient.ClientError`
    /// and turn-level `error` events — `ClientError.errorDescription` is
    /// already Polish (server nie wstał / WS zerwany / sesja martwa), this
    /// just applies the same "⚠️" bubble convention as every other error path.
    private func showGatewayError(_ message: String, on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        let text = "⚠️ \(message)"
        if messages[index].content.isEmpty {
            messages[index].content = text
        } else {
            messages[index].content += "\n\n" + text
        }
        glitchTrigger += 1
    }

    // MARK: - Hermes headless fallback (Fala 22 — plan B, patrz F24 kontekst)

    /// Fala 22 (F22.2): `hermes chat -q <tekst>` takes a single message,
    /// NOT the full message array `OllamaService`/Claude's NDJSON stream use —
    /// Hermes keeps its own conversation context server-side via
    /// `--resume <session_id>` (pułapka 1). Only the last user turn from
    /// `history` is sent; kiwi-card prompt / persona system messages are never
    /// forwarded (Hermes has its own SOUL.md). No streaming: `send()` returns
    /// once at the end, so the bubble shows `hermesPlaceholder` until then
    /// instead of growing token-by-token.
    ///
    /// Fala 24: no longer the primary path for `hermes:*` models — kept as
    /// the "catastrophe at step zero" fallback `runHermesGatewayStream` calls
    /// when the WS gateway can't even connect (binary missing / spawn failed).
    private func runHermesStream(
        hermesModel: String,
        history: [OllamaService.ChatPayloadMessage],
        conversationId: Int64
    ) async {
        let prompt = history.last { $0.role == "user" }?.content ?? ""

        // Fala 22 (F22.3): `history` only carries base64 strings (built for the
        // Ollama payload shape) — the raw `Data` attachments still live on the
        // last user `ChatMessage` we just appended in `send()`/`regenerateLast()`,
        // so we read them from `messages`, not `history`.
        let userImages = messages.last { $0.role == .user }?.images ?? []
        let imagePath = userImages.first.flatMap(Self.writeTempImageFile)
        // Hermes only takes one `--image` per turn (pułapka F22.3) — extra
        // attachments are silently dropped from the request but surfaced to
        // the user as a note on the reply, never as a blocked send.
        let multiImageNote = userImages.count > 1
            ? "(Hermes przyjmuje 1 obraz na wiadomość — wysłano tylko pierwszy)"
            : nil

        let assistantMessage = ChatMessage(role: .assistant, content: Self.hermesPlaceholder)
        let assistantID = assistantMessage.id
        messages.append(assistantMessage)
        lastAnimatedMessageID = assistantID
        isStreaming = true
        liveTokRate = 0

        // -1 marks a conversation row whose DB insert failed (see
        // `ensureConversation`) — never trust it as a stable key, same guard
        // `runClaudeStream` applies to the GRDB-backed Claude session id.
        let resumeSessionID = conversationId != -1 ? hermesSessionIDs[conversationId] : nil
        let service = HermesChatService()
        let startedAt = Date()

        streamTask = Task {
            var succeeded = false
            do {
                let response = try await service.send(
                    message: prompt, sessionID: resumeSessionID, model: hermesModel, imagePath: imagePath
                )
                if conversationId != -1 {
                    hermesSessionIDs[conversationId] = response.sessionID
                }
                var text = response.text
                // Paweł: chce widzieć proces myślowy, tak jak w terminalu —
                // fenced block reużywa istniejący CodeBlockView (mono, kopiuj,
                // zwijalny scroll), więc wygląda spójnie z resztą appki.
                if let reasoning = response.reasoning, !reasoning.isEmpty {
                    text = "```reasoning\n\(reasoning)\n```\n\n\(text)"
                }
                if let multiImageNote {
                    text += "\n\n" + multiImageNote
                }
                setContent(text, on: assistantID)
                applyHermesStats(startedAt: startedAt, to: assistantID)
                succeeded = true
            } catch is CancellationError {
                markHermesCancelled(assistantID)
            } catch {
                showHermesError(error, on: assistantID)
            }
            isStreaming = false
            liveTokRate = 0
            streamTask = nil
            if let final = messages.first(where: { $0.id == assistantID }) {
                persist(final, conversationId: conversationId)
            }
            if succeeded, let title = conversations.first(where: { $0.id == conversationId })?.title {
                ObsidianSyncService.syncConversation(conversationId: conversationId, title: title, model: "hermes:\(hermesModel)")
            }
        }
        await streamTask?.value
    }

    /// Writes one attachment to a uniquely-named file under the system temp
    /// directory so it can be passed as `--image <path>` — `hermes chat` reads
    /// a file path, not in-memory bytes. Extension follows the PNG/JPEG magic
    /// bytes `ChatImage.normalize` already guarantees (Ollama-compatible
    /// formats only), so the CLI's own content sniffing sees a sane suffix.
    /// Cleanup of the temp file is intentionally out of scope for F22.3 (per
    /// PLAN.md) — just avoid leaving open file handles, which `Data.write`
    /// doesn't (it's a single synchronous write, no handle kept open).
    private static func writeTempImageFile(_ data: Data) -> String? {
        let isPNG = data.count >= 4 && data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])
        let ext = isPNG ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiwimango-hermes-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        do {
            try data.write(to: url)
            return url.path
        } catch {
            print("[KiwiMango] Failed to write temp image for Hermes: \(error)")
            return nil
        }
    }

    /// Hermes has no tok/s equivalent either — same "elapsed wall-clock time
    /// only" bar as `applyClaudeStats`.
    private func applyHermesStats(startedAt: Date, to id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        let seconds = Date().timeIntervalSince(startedAt)
        messages[index].statsLine = String(format: "%.1f s", seconds)
    }

    /// Replaces the placeholder/partial bubble content outright — unlike
    /// `appendDelta`, Hermes delivers the full answer in one shot, so there's
    /// nothing to append to.
    private func setContent(_ text: String, on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].content = text
    }

    /// Fala 22: unlike `markCancelled` (Ollama/Claude), the bubble already
    /// holds `hermesPlaceholder` — not empty — when STOP is pressed, so this
    /// always overwrites rather than checking for emptiness first.
    private func markHermesCancelled(_ id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].content = "⏹ Przerwano."
    }

    /// Fala 22 (F22.4): Polish error surface for `HermesChatService.ServiceError`.
    /// Timeout gets the same "⏹" marker as a user-triggered STOP (both mean
    /// "proces przerwany", just for different reasons) — everything else
    /// (binary missing, provider mismatch, unparsable output) is a genuine
    /// error and keeps the "⚠️" marker used elsewhere in the app.
    private func showHermesError(_ error: Error, on id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        if case HermesChatService.ServiceError.timedOut = error {
            messages[index].content = "⏹ \(error.localizedDescription)"
        } else {
            messages[index].content = "⚠️ \(error.localizedDescription)"
        }
        glitchTrigger += 1
    }

    /// Feeds the just-appended content to the streaming TTS feeder, sentence
    /// by sentence — only when the composer's "czytaj odpowiedzi" toggle is on.
    private func feedSpeechIfEnabled(_ id: UUID, isFinal: Bool = false) {
        guard UserDefaults.standard.bool(forKey: "ttsEnabled") else { return }
        guard let message = messages.first(where: { $0.id == id }) else { return }
        speechFeeder.consume(fullContent: message.content, isFinal: isFinal)
    }

    /// Cancels the in-progress streaming response (partial content is kept).
    /// Fala 24: also sends `session.interrupt` to the gateway when a Hermes
    /// turn is in flight — cancelling only the local `Task` would stop us
    /// listening but leave the agent still running server-side.
    /// Fala 24.6 pułapka #2: this is the ONLY call site that ever sends
    /// `session.interrupt` — `cancelAndWait()` (conversation switch) never
    /// does, so background subagent work survives switching away.
    func cancel() {
        streamTask?.cancel()
        speechSynthesizer.stopAll()
        if let sessionID = activeHermesGatewaySessionID {
            // Immediate feedback — the actual `message.complete`/`error` that
            // settles the bubble's final content still comes from the
            // persistent listener whenever the server confirms the stop,
            // which isn't instant (F24.6 architecture, no local fake-cancel).
            if let assistantID = activeHermesGatewayAssistantID {
                appendGatewayToolLine("⏹ wysłano przerwanie…", to: assistantID)
            }
            Task { try? await HermesGatewayClient.shared.interrupt(sessionID: sessionID) }
        }
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

    /// F17.0: probes `claude` binary presence and login/limit state, caches the
    /// result in `claudeAvailability`. Called once alongside `loadModels()` —
    /// both are startup-time capability probes, not per-message checks.
    func refreshClaudeAvailability() async {
        claudeAvailability = await ClaudeCodeService.checkAvailability()
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
