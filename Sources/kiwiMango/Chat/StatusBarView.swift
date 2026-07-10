import AppKit
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

/// 24px status bar: Ollama state, live token burn, context budget with a
/// compression trigger, session time, agent count, and app version.
struct StatusBarView: View {
    @Environment(ChatState.self) private var chatState
    @Environment(AgentManager.self) private var agentManager
    @Environment(HermesTelemetry.self) private var hermesTelemetry

    @State private var monitor = OllamaStatusMonitor()
    @State private var appLaunchTime = Date()
    @State private var now = Date()
    @State private var isCompressing = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let contextLimit = 8192
    private let compressionThreshold = 6554 // 80% of 8192

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    private var usedTokens: Int {
        let chars = chatState.messages.reduce(0) { $0 + $1.content.count }
        return chars / 4
    }

    private var contextPercent: Double {
        Double(usedTokens) / Double(contextLimit)
    }

    private var tokensUntilCompress: Int {
        max(0, compressionThreshold - usedTokens)
    }

    private var tokPerMinute: Int {
        if chatState.isStreaming {
            return Int(chatState.liveTokRate * 60)
        }
        let avg = chatState.tokRateHistory.isEmpty
            ? 0
            : chatState.tokRateHistory.reduce(0, +) / Double(chatState.tokRateHistory.count)
        return Int(avg * 60)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftSection
            Spacer(minLength: 8)
            centerSection
            Spacer(minLength: 8)
            rightSection
        }
        .font(KiwiMangoFont.mono(9))
        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.kiwiMangoAccent.opacity(0.25))
                .frame(height: 1)
        }
        .task {
            monitor.start()
            appLaunchTime = Date()
        }
        .onReceive(ticker) { _ in now = Date() }
    }

    // MARK: - Left: Ollama icon + status

    private var leftSection: some View {
        HStack(spacing: 6) {
            ollamaIcon
                .frame(width: 16, height: 16)

            Text("●")
                .font(.system(size: 7))
                .foregroundStyle(monitor.isOnline ? Color.kiwiMangoAccent : Color.kiwiMangoDanger)
                .realBloom(strength: 1.4, radius: 2)

            Text(monitor.isOnline ? "Ollama" : "offline")
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            if let latency = monitor.latencyMs {
                Text("\(latency)ms")
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            }
        }
    }

    private var ollamaIcon: some View {
        Group {
            if let nsImage = ollamaAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "circle.hexagongrid.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.kiwiMangoAccent)
            }
        }
    }

    // MARK: - Center: tokens / burn / context / compress

    private var centerSection: some View {
        HStack(spacing: 8) {
            tokenBadge
            burnBadge
            contextBadge
            percentBadge
            compressButton
        }
    }

    private var tokenBadge: some View {
        HStack(spacing: 3) {
            Text("TOKENS")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            Text("\(usedTokens)")
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .monospacedDigit()
        }
    }

    private var burnBadge: some View {
        HStack(spacing: 3) {
            Text("AVG")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            Text("\(tokPerMinute)/min")
                .foregroundStyle(chatState.isStreaming ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary)
                .monospacedDigit()
            if chatState.isStreaming {
                StreamingPulse()
            }
        }
    }

    private var contextBadge: some View {
        HStack(spacing: 3) {
            Text("CTX")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            Text("\(usedTokens)/\(contextLimit)")
                .foregroundStyle(contextPercent >= 0.8 ? Color.kiwiMangoDanger : Color.kiwiMangoTextPrimary)
                .monospacedDigit()
        }
    }

    private var percentBadge: some View {
        HStack(spacing: 3) {
            Text("\(Int(contextPercent * 100))%")
                .foregroundStyle(percentColor)
                .monospacedDigit()
            MiniBar(fill: contextPercent)
        }
    }

    private var percentColor: Color {
        if contextPercent >= 0.8 { return Color.kiwiMangoDanger }
        if contextPercent >= 0.6 { return Color.kiwiMangoAccent }
        return Color.kiwiMangoTextPrimary
    }

    private var compressButton: some View {
        Button {
            guard !isCompressing && !chatState.isStreaming else { return }
            isCompressing = true
            Task {
                await chatState.compressContext()
                isCompressing = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(isCompressing ? "compressing…" : "/ compress")
                if !isCompressing, tokensUntilCompress > 0 {
                    Text("in \(tokensUntilCompress)")
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isCompressing || chatState.isStreaming)
        .foregroundStyle(contextPercent >= 0.75 ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary.opacity(0.45))
        .help("Kompresuj kontekst (model podsumowuje starszą część rozmowy)")
    }

    // MARK: - Right: uptime + agents + version

    private var rightSection: some View {
        HStack(spacing: 8) {
            Text(sessionTimeLabel)
                .monospacedDigit()

            Text("·")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))

            Button {
                NotificationCenter.default.post(name: .kiwiMangoRequestMissionControl, object: nil)
            } label: {
                let total = agentManager.sessions.count + hermesTelemetry.activeCount
                Text("Agenci \(total)")
                    .foregroundStyle(total == 0 ? Color.kiwiMangoTextPrimary.opacity(0.45) : Color.kiwiMangoAccent)
            }
            .buttonStyle(.plain)
            .help("Otwórz Centrum Dowodzenia")

            Text("·")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))

            Text("v\(appVersion)")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.45))
        }
    }

    private var sessionTimeLabel: String {
        let seconds = Int(now.timeIntervalSince(appLaunchTime))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        return "\(m)m \(s)s"
    }
}

// MARK: - Ollama app icon loader

private func ollamaAppIcon() -> NSImage? {
    guard let url = Bundle.module.url(forResource: "OllamaIcon", withExtension: "icns") else { return nil }
    let image = NSImage(contentsOf: url)
    image?.isTemplate = false
    return image
}

// MARK: - MiniBar

/// 8-segment ASCII bar for the context-fill ratio.
private struct MiniBar: View {
    let fill: Double
    private let segments = 8

    var body: some View {
        Text(barText)
            .font(KiwiMangoFont.mono(8))
            .foregroundStyle(barColor)
    }

    private var barColor: Color {
        if fill >= 0.8 { return Color.kiwiMangoDanger }
        if fill >= 0.6 { return Color.kiwiMangoAccent }
        return Color.kiwiMangoTextPrimary
    }

    private var barText: String {
        let clamped = max(0, min(1, fill))
        let filled = Int(round(clamped * Double(segments)))
        return "[" + String(repeating: "█", count: filled)
            + String(repeating: "░", count: segments - filled) + "]"
    }
}

// MARK: - StreamingPulse

private struct StreamingPulse: View {
    @State private var phase = 0.0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.kiwiMangoAccent)
                    .frame(width: 2, height: 6)
                    .opacity(opacity(for: i))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                phase = 1
            }
        }
    }

    private func opacity(for index: Int) -> Double {
        let offset = Double(index) * 0.3
        let value = sin((phase + offset) * .pi)
        return 0.3 + 0.7 * max(0, value)
    }
}

// MARK: - TokRateSparkline

/// Tiny line chart of recent tok/s readings — no axes, no animation.
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
    }
}
