import Darwin
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
    @Environment(ChatState.self) private var chatState
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

            if chatState.tokRateHistory.count > 1 {
                statusDivider
                TokRateSparkline(values: chatState.tokRateHistory)
            }

            statusDivider

            Text("Agenci [\(agentManager.runningCount)]")
                .opacity(agentManager.runningCount == 0 ? 0.5 : 1)

            statusDivider

            RAMIndicatorView()

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

// MARK: - TokRateSparkline

/// Tiny lime line chart of recent tok/s readings — no axes, no animation.
/// Only redraws when `values` gains a new point (finished responses only,
/// never per-token streaming deltas — see PLAN.md F6.2 pitfall).
private struct TokRateSparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let maxValue = values.max() ?? 1
            let minValue = min(values.min() ?? 0, maxValue - 0.001)
            let range = max(maxValue - minValue, 0.001)

            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let normalized = (value - minValue) / range
                let y = size.height - CGFloat(normalized) * size.height
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            context.stroke(path, with: .color(Color.kiwiMangoAccent), lineWidth: 1)
        }
        .frame(width: 50, height: 12)
    }
}

// MARK: - RAMIndicatorView

/// App's own resident memory, read every 2s via `task_info`. Isolated in its
/// own tiny view + `@State` so the tick doesn't redraw the whole status bar
/// (or the chat above it) — and the timer stops when the window isn't active.
private struct RAMIndicatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var residentMB: Int = 0
    @State private var timer: Timer?

    var body: some View {
        Text("RAM [\(residentMB) MB]")
            .onAppear { startTimer() }
            .onDisappear { stopTimer() }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    startTimer()
                } else {
                    stopTimer()
                }
            }
    }

    private func startTimer() {
        guard timer == nil else { return }
        updateReading()
        let newTimer = Timer(timeInterval: 2, repeats: true) { _ in
            Task { @MainActor in updateReading() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateReading() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        residentMB = Int(info.resident_size / 1024 / 1024)
    }
}
