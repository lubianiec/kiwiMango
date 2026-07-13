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
        get { defaults.string(forKey: "lastAgentModel") ?? AgentSessionController.availableModels[0] }
        set { defaults.set(newValue, forKey: "lastAgentModel") }
    }

    var chatModelOptions: [String] {
        ["claude:sonnet", "claude:opus"] + chatOllamaModels
    }

    func loadOllamaModels() async {
        chatOllamaModels = (try? await OllamaService().listModels()) ?? []
    }

    // MARK: Chat session management

    func newChatSession() {
        let model = chatSessions.last?.model ?? lastChatModel
        let session = ConversationSession(title: "Nowa rozmowa", model: model)
        chatSessions.append(session)
        chatControllers[session.id] = ChatSessionController(session: session)
        chatSelectedID = session.id
        lastChatModel = model
    }

    func closeChatSession(_ id: ConversationSession.ID) {
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
        let session = ConversationSession(title: "Nowa sesja", model: model)
        agentSessions.append(session)
        agentControllers[session.id] = AgentSessionController(session: session)
        agentSelectedID = session.id
        lastAgentModel = model
    }

    func closeAgentSession(_ id: ConversationSession.ID) {
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