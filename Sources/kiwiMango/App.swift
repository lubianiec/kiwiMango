import SwiftUI

// MARK: - KiwiMangoApp

/// Application entry point. Standalone chat-only Ollama client — single main window,
/// starts directly in the chat view (regular Dock app, not a menu bar utility).
@main
struct KiwiMangoApp: App {

    @State private var chatState = ChatState()
    @State private var agentManager = AgentManager()
    @State private var agentTelemetry = AgentTelemetry()
    @NSApplicationDelegateAdaptor(KiwiMangoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatState)
                .environment(agentManager)
                .environment(agentTelemetry)
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
            // ⌘P normally prints — this app has nothing to print, so it's free
            // to repurpose for the prompt vault (F11.1).
            CommandGroup(replacing: .printItem) {
                Button("Prompty") {
                    NotificationCenter.default.post(name: .kiwiMangoRequestPrompts, object: nil)
                }
                .keyboardShortcut("p")
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
    /// Posted by the ⌘P command; `RootView` listens and switches to the prompt vault.
    static let kiwiMangoRequestPrompts = Notification.Name("kiwiMangoRequestPrompts")
    /// Posted by the status bar's "Agenci [N]" segment (F18.2); `RootView`
    /// listens and switches to Centrum Dowodzenia.
    static let kiwiMangoRequestMissionControl = Notification.Name("kiwiMangoRequestMissionControl")
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
