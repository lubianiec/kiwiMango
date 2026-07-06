import SwiftUI

// MARK: - KiwiMangoApp

/// Application entry point. Standalone chat-only Ollama client — single main window,
/// starts directly in the chat view (regular Dock app, not a menu bar utility).
@main
struct KiwiMangoApp: App {

    @State private var chatState = ChatState()
    @State private var agentManager = AgentManager()
    @NSApplicationDelegateAdaptor(KiwiMangoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatState)
                .environment(agentManager)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear { appDelegate.agentManager = agentManager }
        }
        .defaultSize(width: 860, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nowa rozmowa") {
                    NotificationCenter.default.post(name: .kiwiMangoRequestNewConversation, object: nil)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(after: .newItem) {
                Button("Nowy agent") {
                    NotificationCenter.default.post(name: .kiwiMangoRequestNewAgent, object: nil)
                }
                .keyboardShortcut("t")
            }
        }

        Settings {
            SettingsView()
                .environment(chatState)
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by the ⌘T command; `RootView` listens and opens the new-agent popover.
    static let kiwiMangoRequestNewAgent = Notification.Name("kiwiMangoRequestNewAgent")
    /// Posted by the ⌘N command; `RootView` listens, wraca z agenta na czat
    /// i dopiero wtedy startuje nową rozmowę (samo `startNewConversation`
    /// nie zmienia `selection`, więc przy aktywnym agencie nic nie było widać).
    static let kiwiMangoRequestNewConversation = Notification.Name("kiwiMangoRequestNewConversation")
}

// MARK: - KiwiMangoAppDelegate

/// Ensures every agent's child process (`ollama launch claude`, and Ollama's
/// own subprocess underneath it) dies with the app instead of becoming a
/// zombie — PLAN.md F4 pitfall #3.
final class KiwiMangoAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var agentManager: AgentManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            agentManager?.killAll()
        }
        return .terminateNow
    }
}
