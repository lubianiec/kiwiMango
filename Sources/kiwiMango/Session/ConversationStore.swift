import Foundation

// MARK: - ConversationStore (fix: conversation history survives page switches)
//
// Root cause: ChatPage/AgentPage held sessions+controllers in their own @State.
// ContentView's `switch page` destroys the page view on tab change → @State
// goes to nil → coming back creates a fresh empty session. Fix: hoist state
// to this @Observable model owned by ContentView, which persists across
// page switches because ContentView itself is never destroyed.

@MainActor
@Observable
final class ConversationStore {
    // MARK: Chat
    private(set) var chatSessions: [ConversationSession] = []
    private(set) var chatControllers: [ConversationSession.ID: ChatSessionController] = [:]
    var chatSelectedID: ConversationSession.ID?
    var chatOllamaModels: [String] = []

    // MARK: Agent
    private(set) var agentSessions: [ConversationSession] = []
    private(set) var agentControllers: [ConversationSession.ID: AgentSessionController] = [:]
    var agentSelectedID: ConversationSession.ID?

    // MARK: History (PLAN-HISTORIA — persisted sessions, metadata only)
    private(set) var history: [SessionSnapshot] = []

    // ponytail: @AppStorage doesn't work inside @Observable classes —
    // the Observation macro rewrites it into @ObservationTracked which
    // doesn't support property wrappers. Plain UserDefaults read/write
    // is the shortest fix.
    private let defaults = UserDefaults.standard
    private var lastChatModel: String {
        get { defaults.string(forKey: "lastChatModel") ?? "claude:sonnet" }
        set { defaults.set(newValue, forKey: "lastChatModel") }
    }
    private var lastAgentModel: String {
        get { defaults.string(forKey: "lastAgentModel") ?? "glm-5.2:cloud" }
        set { defaults.set(newValue, forKey: "lastAgentModel") }
    }
    // ponytail: Paweł's own stated default — "nie chce mi się tego ciągle
    // zmieniać" — glm-5.2:cloud + xhigh reasoning as the standing default,
    // same persistence pattern as lastAgentModel above.
    private var lastAgentReasoningEffort: String {
        get { defaults.string(forKey: "lastAgentReasoningEffort") ?? "xhigh" }
        set { defaults.set(newValue, forKey: "lastAgentReasoningEffort") }
    }

    var chatModelOptions: [String] {
        ["claude:sonnet", "claude:opus"] + chatOllamaModels
    }

    func loadOllamaModels() async {
        chatOllamaModels = (try? await OllamaService().listModels()) ?? []
    }

    func loadHistory() {
        history = SessionPersistence.loadAll()
    }

    // MARK: Persistence (PLAN-HISTORIA §2/§3)

    /// Saves the full session to disk and refreshes its entry in `history`.
    /// Called at end-of-turn points only (not per streaming chunk — pułapka #4).
    func persist(_ session: ConversationSession, kind: ConversationKind) {
        let snapshot = SessionSnapshot(from: session, kind: kind)
        SessionPersistence.save(snapshot)
        history.removeAll { $0.id == snapshot.id }
        history.append(snapshot)
        history.sort { $0.updatedAt > $1.updatedAt }
    }

    func deleteFromHistory(id: UUID) {
        SessionPersistence.delete(id: id)
        history.removeAll { $0.id == id }
        // Close the live tab too, but skip the closeXSession persist-back-to-disk
        // step — the file is gone, re-saving it would resurrect the entry.
        if chatSessions.contains(where: { $0.id == id }) {
            chatSessions.removeAll { $0.id == id }
            chatControllers.removeValue(forKey: id)
            if chatSelectedID == id { chatSelectedID = chatSessions.first?.id }
        }
        if agentSessions.contains(where: { $0.id == id }) {
            agentSessions.removeAll { $0.id == id }
            agentControllers.removeValue(forKey: id)
            if agentSelectedID == id { agentSelectedID = agentSessions.first?.id }
        }
    }

    /// Opens a history entry as a live tab. If already open, just selects it.
    func openFromHistory(_ snapshot: SessionSnapshot) {
        if snapshot.kind == "agent" {
            if agentSessions.contains(where: { $0.id == snapshot.id }) {
                agentSelectedID = snapshot.id
                return
            }
            let session = snapshot.toSession()
            agentSessions.append(session)
            let controller = AgentSessionController(session: session)
            controller.onPersist = { [weak self] in self?.persist(session, kind: .agent) }
            agentControllers[session.id] = controller
            agentSelectedID = session.id
        } else {
            if chatSessions.contains(where: { $0.id == snapshot.id }) {
                chatSelectedID = snapshot.id
                return
            }
            let session = snapshot.toSession()
            chatSessions.append(session)
            let controller = ChatSessionController(session: session)
            controller.onPersist = { [weak self] in self?.persist(session, kind: .chat) }
            chatControllers[session.id] = controller
            chatSelectedID = session.id
        }
    }

    // MARK: Chat session management

    func newChatSession() {
        let model = chatSessions.last?.model ?? lastChatModel
        let session = ConversationSession(title: "Nowa rozmowa", model: model)
        chatSessions.append(session)
        let controller = ChatSessionController(session: session)
        controller.onPersist = { [weak self] in self?.persist(session, kind: .chat) }
        chatControllers[session.id] = controller
        chatSelectedID = session.id
        lastChatModel = model
    }

    func closeChatSession(_ id: ConversationSession.ID) {
        if let session = chatSessions.first(where: { $0.id == id }) {
            persist(session, kind: .chat) // file stays on disk — closing the tab isn't deleting history
        }
        chatSessions.removeAll { $0.id == id }
        chatControllers.removeValue(forKey: id)
        if chatSelectedID == id { chatSelectedID = chatSessions.first?.id }
    }

    var selectedChatSession: ConversationSession? {
        chatSessions.first { $0.id == chatSelectedID }
    }

    func chatController(for id: ConversationSession.ID) -> ChatSessionController? {
        chatControllers[id]
    }

    // MARK: Agent session management

    func newAgentSession() {
        let model = agentSessions.last?.model ?? lastAgentModel
        let effort = agentSessions.last?.reasoningEffort ?? lastAgentReasoningEffort
        let session = ConversationSession(title: "Nowa sesja", model: model)
        session.reasoningEffort = effort
        agentSessions.append(session)
        let controller = AgentSessionController(session: session)
        controller.onPersist = { [weak self] in self?.persist(session, kind: .agent) }
        agentControllers[session.id] = controller
        agentSelectedID = session.id
        lastAgentModel = model
        lastAgentReasoningEffort = effort
    }

    func closeAgentSession(_ id: ConversationSession.ID) {
        if let session = agentSessions.first(where: { $0.id == id }) {
            persist(session, kind: .agent) // file stays on disk — closing the tab isn't deleting history
        }
        agentSessions.removeAll { $0.id == id }
        agentControllers.removeValue(forKey: id)
        if agentSelectedID == id { agentSelectedID = agentSessions.first?.id }
    }

    var selectedAgentSession: ConversationSession? {
        agentSessions.first { $0.id == agentSelectedID }
    }

    func agentController(for id: ConversationSession.ID) -> AgentSessionController? {
        agentControllers[id]
    }
}