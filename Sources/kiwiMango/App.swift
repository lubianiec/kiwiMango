import SwiftUI

// MARK: - KiwiMangoApp

/// Application entry point. Standalone chat-only Ollama client — single main window,
/// starts directly in the chat view (regular Dock app, not a menu bar utility).
@main
struct KiwiMangoApp: App {

    @State private var chatState = ChatState()
    @State private var agentManager = AgentManager()
    @State private var agentTelemetry = AgentTelemetry()
    /// Fala 24.7: second Centrum Dowodzenia telemetry source (Hermes gateway,
    /// live WS events) — `HermesTelemetry.shared` so `ChatState` (no
    /// environment access) can push updates directly; held here in `@State`
    /// only so SwiftUI observes it and injects it down the view tree.
    @State private var hermesTelemetry = HermesTelemetry.shared
    /// HUD companion: local hermes-hudui server + web view.
    @State private var hermesHUDManager = HermesHUDManager()
    @NSApplicationDelegateAdaptor(KiwiMangoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatState)
                .environment(agentManager)
                .environment(agentTelemetry)
                .environment(hermesTelemetry)
                .environment(hermesHUDManager)
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
            CommandGroup(replacing: .printItem) {
                Button("Centrum Dowodzenia") {
                    NotificationCenter.default.post(name: .kiwiMangoRequestMissionControl, object: nil)
                }
                .keyboardShortcut("p")
            }
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
        // Fala 24: kiwiMango's own `hermes serve` child (spawned by
        // `HermesGatewayClient`, its own token/port — never a foreign
        // process) must die with the app too, same zombie-process hygiene
        // as `agentManager.killAll()` above.
        HermesGatewayProcessBox.shared.terminate()
        return .terminateNow
    }
}
