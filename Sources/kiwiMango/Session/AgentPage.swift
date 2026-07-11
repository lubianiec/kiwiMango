import SwiftUI

// MARK: - AgentPage (PLAN-V2 §5, §9 Fala 2/B3)
//
// Thin wrapper: SessionTabsBar + ConversationView(kind: .agent) on mocked
// sessions. Fala 3/C1 TODO: replace `sessions`/`newSession()` with
// HermesGatewayClient-backed sessions (real gateway session list, live
// tool/thinking/permission events instead of `ConversationSession.mockAgent()`).

struct AgentPage: View {
    @State private var sessions: [ConversationSession] = [.mockAgent()]
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
                ConversationView(session: session, kind: .agent)
            }
        }
        .onAppear { selectedID = selectedID ?? sessions.first?.id }
    }

    // ponytail: brand-new tab = empty session, last-used model (Fala 3 reads
    // `@AppStorage("lastAgentModel")`; mock reuses the previous tab's model).
    private func newSession() {
        let model = sessions.last?.model ?? "kimi-k2.7-code:cloud"
        let session = ConversationSession(title: "Nowa sesja", model: model)
        sessions.append(session)
        selectedID = session.id
    }

    private func closeSession(_ id: ConversationSession.ID) {
        sessions.removeAll { $0.id == id }
        if selectedID == id { selectedID = sessions.first?.id }
    }
}
