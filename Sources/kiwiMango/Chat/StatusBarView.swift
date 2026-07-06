import SwiftUI

// MARK: - OllamaStatusMonitor

/// Polls `/api/tags` every 30s to report real online/offline + round-trip latency.
/// No mock data — every number here comes from an actual network call.
@MainActor
@Observable
final class OllamaStatusMonitor {
    private(set) var isOnline = false
    private(set) var latencyMs: Int?

    private var pollTask: Task<Void, Never>?

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pingOnce()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pingOnce() async {
        let result = await OllamaService().ping()
        isOnline = result.online
        latencyMs = result.online ? result.latencyMs : nil
    }
}

// MARK: - StatusBarView

/// Terminal-style bottom status bar: connection state, active model, latency, app version.
struct StatusBarView: View {
    let selectedModel: String

    @Environment(AgentManager.self) private var agentManager
    @State private var monitor = OllamaStatusMonitor()

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("Ollama")
                Text("●")
                    .foregroundStyle(monitor.isOnline ? Color.kiwiMangoAccent : Color.kiwiMangoDanger)
                Text(monitor.isOnline ? "online" : "offline")
            }

            statusDivider

            Text("Model: \(selectedModel.isEmpty ? "—" : selectedModel)")

            statusDivider

            Text("Latency [\(monitor.latencyMs.map { "\($0)ms" } ?? "—")]")

            statusDivider

            Text("Agenci [\(agentManager.runningCount)]")
                .opacity(agentManager.runningCount == 0 ? 0.5 : 1)

            Spacer()

            Text("kiwiMango v\(appVersion)")
        }
        .font(KiwiMangoFont.mono(10))
        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.kiwiMangoAccent.opacity(0.15))
                .frame(height: 1)
        }
        .task { monitor.start() }
    }

    private var statusDivider: some View {
        Text("·").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.3))
    }
}
