import SwiftUI

// MARK: - AgentPage (PLAN-V2 §5, §9 Fala 3/C1)
//
// Fix: sessions + controllers now live in ConversationStore (hoisted to
// ContentView), so switching pages no longer destroys agent history.

struct AgentPage: View {
    @Bindable var store: ConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTabsBar(
                sessions: store.agentSessions,
                selectedID: $store.agentSelectedID,
                onAdd: store.newAgentSession,
                onClose: store.closeAgentSession
            )
            .padding(.bottom, 12)

            if let session = store.selectedAgentSession,
               let controller = store.agentController(for: session.id) {
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
            if store.agentSessions.isEmpty { store.newAgentSession() }
        }
    }
}