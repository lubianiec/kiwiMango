import SwiftUI

// MARK: - ChatPage (PLAN-V2 §5, §9 Fala 3/C1)
//
// Same shape as AgentPage, `kind: .chat` — each tab backed by a
// `ChatSessionController` routing to ClaudeCodeService (claude:sonnet/opus)
// or OllamaService (everything else), real streaming send().

struct ChatPage: View {
    @State private var sessions: [ConversationSession] = []
    @State private var controllers: [ConversationSession.ID: ChatSessionController] = [:]
    @State private var selectedID: ConversationSession.ID?
    @State private var ollamaModels: [String] = []
    @AppStorage("lastChatModel") private var lastChatModel = "claude:sonnet"

    private var modelOptions: [String] {
        ["claude:sonnet", "claude:opus"] + ollamaModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTabsBar(
                sessions: sessions,
                selectedID: $selectedID,
                onAdd: newSession,
                onClose: closeSession
            )
            .padding(.bottom, 12)

            if let session = sessions.first(where: { $0.id == selectedID }),
               let controller = controllers[session.id] {
                ConversationView(
                    session: session,
                    kind: .chat,
                    modelOptions: modelOptions,
                    onSend: controller.send
                )
            }
        }
        .onAppear {
            if sessions.isEmpty { newSession() }
        }
        .task {
            ollamaModels = (try? await OllamaService().listModels()) ?? []
        }
    }

    private func newSession() {
        let model = sessions.last?.model ?? lastChatModel
        let session = ConversationSession(title: "Nowa rozmowa", model: model)
        sessions.append(session)
        controllers[session.id] = ChatSessionController(session: session)
        selectedID = session.id
        lastChatModel = model
    }

    private func closeSession(_ id: ConversationSession.ID) {
        sessions.removeAll { $0.id == id }
        controllers.removeValue(forKey: id)
        if selectedID == id { selectedID = sessions.first?.id }
    }
}
