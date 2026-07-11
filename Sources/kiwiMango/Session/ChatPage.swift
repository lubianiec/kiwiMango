import SwiftUI

// MARK: - ChatPage (PLAN-V2 §5, §9 Fala 2/B3)
//
// Same shape as AgentPage, `kind: .chat` (no quick actions, different composer
// copy/icons — handled inside ConversationView). Fala 3/C1 TODO: replace
// `sessions`/`newSession()` with ClaudeCodeService/Ollama-backed sessions
// (real streaming send(), permission prompts from claude CLI's stream-json).

struct ChatPage: View {
    @State private var sessions: [ConversationSession] = [.mockChat()]
    @State private var selectedID: ConversationSession.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTabsBar(
                sessions: sessions,
                selectedID: $selectedID,
                onAdd: newSession,
                onClose: closeSession
            )
            .padding(.bottom, 12)

            if let session = sessions.first(where: { $0.id == selectedID }) {
                ConversationView(session: session, kind: .chat)
            }
        }
        .onAppear { selectedID = selectedID ?? sessions.first?.id }
    }

    private func newSession() {
        let model = sessions.last?.model ?? "claude — Fable 5"
        let session = ConversationSession(title: "Nowa rozmowa", model: model)
        sessions.append(session)
        selectedID = session.id
    }

    private func closeSession(_ id: ConversationSession.ID) {
        sessions.removeAll { $0.id == id }
        if selectedID == id { selectedID = sessions.first?.id }
    }
}
