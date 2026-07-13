import SwiftUI

// MARK: - ChatPage (PLAN-V2 §5, §9 Fala 3/C1)
//
// Fix: sessions + controllers now live in ConversationStore (hoisted to
// ContentView), so switching pages no longer destroys chat history.

struct ChatPage: View {
    @Bindable var store: ConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionTabsBar(
                sessions: store.chatSessions,
                selectedID: $store.chatSelectedID,
                onAdd: store.newChatSession,
                onClose: store.closeChatSession,
                history: store.history.filter { $0.kind == "chat" },
                onOpenHistory: store.openFromHistory,
                onDeleteHistory: store.deleteFromHistory
            )
            .padding(.bottom, 12)

            if let session = store.selectedChatSession,
               let controller = store.chatController(for: session.id) {
                ConversationView(
                    session: session,
                    kind: .chat,
                    modelOptions: store.chatModelOptions,
                    onSend: controller.send
                )
            }
        }
        .onAppear {
            if store.chatSessions.isEmpty { store.newChatSession() }
        }
    }
}