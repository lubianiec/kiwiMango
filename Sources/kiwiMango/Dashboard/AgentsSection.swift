import SwiftUI

// MARK: - SectionHead (PLAN-V2 §7.2 — "01 AGENCI ───" header, shared by
// AgentsSection/CostsBlock/ProcessSection; one definition, reused across the
// three since they all live in the same target).

struct SectionHead: View {
    let number: String
    let label: String
    var trailing: AnyView?

    init(_ number: String, _ label: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) {
        self.number = number
        self.label = label
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(number)
                .font(KiwiMangoFont.sans(8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.ink.opacity(0.28))
            Text(label)
                .font(KiwiMangoFont.sans(8.5, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.ink.opacity(0.65))
            Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1)
            trailing
        }
        .padding(.vertical, 10)
    }
}

// MARK: - AgentsMonitor (PLAN-V2 §7.2 pt.3 / pułapka #15)
//
// Polls `HermesStateReader.recentSessions` — the gateway itself exposes no
// "list active agents" RPC (see doc comment on that method). "Pracuje" is
// derived, not reported: a session counts as working when its token total
// changed within the last 60s and it hasn't ended.
@MainActor
@Observable
final class AgentsMonitor {
    struct Row: Identifiable {
        let id: String
        var title: String
        var model: String
        var totalTokens: Int
        var inputTokens: Int
        var outputTokens: Int
        var toolCalls: Int
        var isWorking: Bool
        var elapsed: TimeInterval
        var history: [Int]
    }

    private(set) var rows: [Row] = []
    private var lastChangeAt: [String: Date] = [:]
    private var lastTotal: [String: Int] = [:]
    private var history: [String: [Int]] = [:]

    func poll() async {
        guard let sessions = try? await HermesStateReader.recentSessions(minutes: 15) else {
            rows = []
            return
        }
        let now = Date()
        var newRows: [Row] = []
        for session in sessions {
            let total = session.inputTokens + session.outputTokens
            if lastTotal[session.id] != total {
                lastChangeAt[session.id] = now
            }
            lastTotal[session.id] = total

            var hist = history[session.id] ?? []
            hist.append(total)
            if hist.count > 60 { hist.removeFirst(hist.count - 60) }
            history[session.id] = hist

            let working = session.endedAt == nil
                && now.timeIntervalSince(lastChangeAt[session.id] ?? now) < 60

            newRows.append(Row(
                id: session.id,
                title: session.title?.isEmpty == false ? session.title! : (session.model ?? "sesja"),
                model: session.model ?? "?",
                totalTokens: total,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                toolCalls: session.toolCallCount,
                isWorking: working,
                elapsed: now.timeIntervalSince(session.startedAt),
                history: hist
            ))
        }
        rows = newRows
        // stale ids never seen again fall out naturally on the next poll since
        // `newRows` is rebuilt from scratch — no separate GC needed.
    }
}

// MARK: - AgentsSection ("01 AGENCI", PLAN-V2 §7.2 pt.3)

struct AgentsSection: View {
    @State private var monitor = AgentsMonitor()
    @State private var expandedID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("01", "Agenci") {
                HStack(spacing: 4) {
                    Circle().fill(Color.accent).frame(width: 5, height: 5)
                    Text("LIVE")
                }
                .font(KiwiMangoFont.sans(7.5, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.accent)
            }

            if monitor.rows.isEmpty {
                Text("brak aktywnych agentów")
                    .font(KiwiMangoFont.sans(11))
                    .foregroundStyle(Color.txt.opacity(0.45))
                    .padding(.vertical, 8)
            } else {
                ForEach(monitor.rows) { row in
                    AgentRow(row: row, isOpen: expandedID == row.id) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedID = expandedID == row.id ? nil : row.id
                        }
                    }
                    if row.id != monitor.rows.last?.id {
                        Divider().overlay(Color.ink.opacity(0.05))
                    }
                }
            }
        }
        // ponytail: `.task` cancels automatically when this view leaves the
        // hierarchy (page switch away from Dashboard) — no manual start/stop
        // plumbing needed, unlike HardwareMonitor's timer (pułapka #5 there
        // exists because Timer doesn't get that for free; Task does).
        .task {
            while !Task.isCancelled {
                await monitor.poll()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }
}

private struct AgentRow: View {
    let row: AgentsMonitor.Row
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(row.isWorking ? Color.accent : Color.ink.opacity(0.25))
                        .frame(width: 6, height: 6)
                        .shadow(color: row.isWorking ? Color.accent.opacity(0.6) : .clear, radius: 4)
                        .modifier(PulseWhileWorking(active: row.isWorking))

                    Text(row.title)
                        .font(KiwiMangoFont.sans(10))
                        .foregroundStyle(Color.ink.opacity(0.45))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.model.uppercased())
                        .font(KiwiMangoFont.sans(8.5, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(Color.ink.opacity(0.4))

                    Text(formatCompactTokens(row.totalTokens))
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.ink.opacity(0.7))
                        .frame(width: 52, alignment: .trailing)

                    AgentSparkline(history: row.history)
                        .frame(width: 72, height: 18)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.ink.opacity(0.3))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text("Zadanie").font(KiwiMangoFont.sans(9)).foregroundStyle(Color.ink.opacity(0.45))
                        Spacer()
                        Text(row.title)
                            .font(KiwiMangoFont.sans(10.5))
                            .foregroundStyle(Color.txt)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Stan").font(KiwiMangoFont.sans(9)).foregroundStyle(Color.ink.opacity(0.45))
                        Spacer()
                        Text(row.isWorking ? "pracuje" : "bezczynny")
                            .font(KiwiMangoFont.sans(10.5))
                            .foregroundStyle(row.isWorking ? Color.accent : Color.ink.opacity(0.55))
                    }
                    HStack(spacing: 20) {
                        StatColumn(value: formatCompactTokens(row.inputTokens), label: "wejście")
                        StatColumn(value: formatCompactTokens(row.outputTokens), label: "wyjście")
                        StatColumn(value: "\(row.toolCalls)", label: "tool-calle")
                        StatColumn(value: Self.duration(row.elapsed), label: "czas pracy")
                    }
                    .padding(.top, 4)
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct StatColumn: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(KiwiMangoFont.mono(13, weight: .light))
                .foregroundStyle(Color.txt)
            Text(label)
                .font(KiwiMangoFont.sans(10))
                .foregroundStyle(Color.ink.opacity(0.55))
        }
    }
}

/// Amber pulse (scale + opacity, 1.4s) while an agent is working — mirrors
/// `.agdot.work`'s CSS `animation:pulse 1.4s ease-in-out infinite`.
private struct PulseWhileWorking: ViewModifier {
    let active: Bool
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && pulsing ? 1.6 : 1)
            .opacity(active && pulsing ? 0.5 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

/// 72×18pt token-history sparkline — filled line, reads accent from the
/// current theme (pułapka #13: draws directly from `history`, never caches
/// a width from `init`).
private struct AgentSparkline: View {
    let history: [Int]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1, let maxValue = history.max(), maxValue > 0 else { return }
            let minValue = history.min() ?? 0
            let range = max(1, maxValue - minValue)
            let stepX = size.width / CGFloat(history.count - 1)

            var path = Path()
            for (index, value) in history.enumerated() {
                let x = CGFloat(index) * stepX
                let normalized = CGFloat(value - minValue) / CGFloat(range)
                let y = size.height - normalized * size.height
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(.accent), lineWidth: 1.5)
        }
    }
}
