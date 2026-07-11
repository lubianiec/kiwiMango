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
                .frame(minWidth: 560, minHeight: 640)
        }
        .defaultSize(width: 560, height: 700)
        .windowResizability(.contentSize)
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

    var body: some View {
        ZStack(alignment: .top) {
            Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                switch page {
                case .dashboard: DashboardView(page: $page)
                case .agent: AgentPage()
                case .chat: ChatPage()
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
