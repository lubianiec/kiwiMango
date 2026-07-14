import SwiftUI

// MARK: - KiwiMangoApp

/// Application entry point — V2 rebuild (PLAN-V2.md). One fixed-size window,
/// three pages (Dashboard/Agent/Chat) switched by the text nav, zero sidebar.
@main
struct KiwiMangoApp: App {
    @NSApplicationDelegateAdaptor(KiwiMangoAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, idealWidth: 720, minHeight: 640, idealHeight: 900)
        }
        .defaultSize(width: 720, height: 900)
        .windowResizability(.contentSize)

        // Real separate window for the Agenci list (opened via openWindow(id:
        // "agents") from the Dashboard status line) — a `.sheet` here would be
        // capped to the presenting window's 560pt width by AppKit regardless
        // of `idealWidth` (verified 2026-07-12), so this needs its own scene
        // to actually render bigger than the main window.
        WindowGroup(id: "agents") {
            AgentsWindow()
        }
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

// MARK: - Page router (PLAN-V2 §5)

enum Page: String, CaseIterable {
    case dashboard = "DASHBOARD"
    case agent = "AGENT"
    case chat = "CHAT"
}

struct ContentView: View {
    @State private var page: Page = .dashboard
    @State private var store = ConversationStore()

    var body: some View {
        ZStack(alignment: .top) {
            Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                switch page {
                case .dashboard: DashboardView()
                case .agent: AgentPage(store: store)
                case .chat: ChatPage(store: store)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 40)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color.txt)

            TopNav(page: $page)
                .padding(.top, 10)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .task {
            store.loadHistory()
            await store.loadOllamaModels()
        }
        .animation(.easeInOut(duration: 0.2), value: ThemeStore.shared.mode)
    }
}

// MARK: - KiwiMangoAppDelegate

/// Ensures kiwiMango's own gateway child process dies with the app instead of
/// becoming a zombie (carried over from v1 — `HermesGatewayProcessBox` still exists).
final class KiwiMangoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        HermesGatewayProcessBox.shared.terminate()
        return .terminateNow
    }
}
