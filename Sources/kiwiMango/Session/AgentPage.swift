import SwiftUI

// MARK: - AgentPage (PLAN-V2 §5, §9 Fala 3/C1)
//
// SessionTabsBar + ConversationView(kind: .agent), each tab backed by its own
// `AgentSessionController` (HermesGatewayClient — real gateway session,
// live tool/thinking/permission events replacing Fala 2/B3's mocks).

struct AgentPage: View {
    @State private var sessions: [ConversationSession] = []
    @State private var controllers: [ConversationSession.ID: AgentSessionController] = [:]
    @State private var selectedID: ConversationSession.ID?
    @AppStorage("lastAgentModel") private var lastAgentModel = AgentSessionController.availableModels[0]

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
                    kind: .agent,
                    modelOptions: AgentSessionController.availableModels,
                    quickActionItems: [
                        QuickActionItem(label: "📖 Kontekst z vaulta", action: controller.insertVaultContext),
                        QuickActionItem(label: "🖼 Wygeneruj obraz", action: nil),
                        QuickActionItem(label: "📋 Podsumuj dziennik", action: nil),
                        QuickActionItem(label: "⏰ Nowy cron", action: nil),
                    ],
                    onSend: controller.send
                )
            }
        }
        .onAppear {
            if sessions.isEmpty { newSession() }
        }
    }

    private func newSession() {
        let model = sessions.last?.model ?? lastAgentModel
        let session = ConversationSession(title: "Nowa sesja", model: model)
        sessions.append(session)
        controllers[session.id] = AgentSessionController(session: session)
        selectedID = session.id
        lastAgentModel = model
    }

    private func closeSession(_ id: ConversationSession.ID) {
        sessions.removeAll { $0.id == id }
        controllers.removeValue(forKey: id)
        if selectedID == id { selectedID = sessions.first?.id }
    }
}
