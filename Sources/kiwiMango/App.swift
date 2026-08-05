import SwiftUI

// MARK: - KiwiMangoApp

/// Application entry point — V2 rebuild (PLAN-V2.md). One fixed-size window,
/// single page (Agent) — the Dashboard page was deleted 2026-08-05, zero sidebar.
@main
struct KiwiMangoApp: App {
    @NSApplicationDelegateAdaptor(KiwiMangoAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, idealWidth: 720, minHeight: 640, idealHeight: 900)
        }
        .defaultSize(width: 720, height: 900)
        .windowResizability(.contentSize)
        .commands {
            // Moved here from the deleted StatusFooter 2026-08-05 — the footer
            // was the only entry point to the Agents window and to launching
            // Flow, so both survive as native menu items instead.
            CommandGroup(after: .windowList) {
                Button("Agenci") { openWindow(id: "agents") }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Uruchom Flow w tle") { launchFlow() }
            }
        }

        // Real separate window for the Agenci list (opened via openWindow(id:
        // "agents") from the app menu) — a `.sheet` here would be capped to
        // the presenting window's 560pt width by AppKit regardless of
        // `idealWidth` (verified 2026-07-12), so this needs its own scene
        // to actually render bigger than the main window.
        WindowGroup(id: "agents") {
            AgentsWindow()
        }
        .defaultSize(width: 900, height: 700)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }

    /// `-g` = don't raise Chrome (pułapka #7) — the tab opens in the background.
    /// Moved verbatim from the deleted `StatusFooter.swift`'s `ServiceStatus.launchFlow`.
    private func launchFlow() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", "Google Chrome", "https://labs.google/fx/tools/flow"]
        try? process.run()
    }
}

// MARK: - ContentView (PLAN-V2 §5 — one page since the dashboard was deleted)

struct ContentView: View {
    @State private var store = ConversationStore()

    var body: some View {
        ZStack(alignment: .top) {
            Color.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                AgentPage(store: store)
            }
            .padding(.horizontal, 22)
            .padding(.top, 40)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(Color.txt)

            ThemeToggle()
                .padding(.top, 10)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
        .task {
            store.loadHistory()
        }
        .animation(.easeInOut(duration: 0.2), value: ThemeStore.shared.mode)
    }
}

// MARK: - KiwiMangoAppDelegate

/// Ensures kiwiMango's own gateway child process dies with the app instead of
/// becoming a zombie (carried over from v1 — `HermesGatewayProcessBox` still exists).
final class KiwiMangoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        StaticWebServer.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        HermesGatewayProcessBox.shared.terminate()
        StaticWebServer.shared.stop()
        return .terminateNow
    }
}
