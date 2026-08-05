import SwiftUI

// MARK: - AgentPage (PLAN-V2 §5, §9 Fala 3/C1)
//
// Fix: sessions + controllers now live in ConversationStore (hoisted to
// ContentView), so switching pages no longer destroys agent history.
//
// Since the dashboard was deleted 2026-08-05, this is now the app's only
// page. The side panel and status footer were removed 2026-08-05 — the
// footer's live status now lives in ConversationView's title bar, and its
// two entry points (Agents window, launch Flow) moved to the app menu
// (see App.swift's `.commands`).

struct AgentPage: View {
    @Bindable var store: ConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTabsBar(
                sessions: store.agentSessions,
                selectedID: $store.agentSelectedID,
                onAdd: store.newAgentSession,
                onClose: store.closeAgentSession,
                history: store.history.filter { $0.kind == "agent" },
                onOpenHistory: store.openFromHistory,
                onDeleteHistory: store.deleteFromHistory
            )
            .padding(.bottom, 12)

            if let session = store.selectedAgentSession,
               let controller = store.agentController(for: session.id) {
                ConversationView(
                    session: session,
                    modelOptions: AgentSessionController.availableModels,
                    onSend: controller.send
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if store.agentSessions.isEmpty { store.newAgentSession() }
        }
    }
}
