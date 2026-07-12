import SwiftUI

// MARK: - AgentsMonitor (moved from AgentsSection.swift 2026-07-12 — full
// agent list left the Dashboard, lives in its own sheet now; polling logic
// unchanged, PLAN-V2 §7.2 pt.3 / pułapka #15).
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
        var project: String?
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
                project: session.cwd?.isEmpty == false ? session.cwd : nil,
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

    /// Sessions still active per the same 60s-since-last-token-change rule
    /// used for the row's own "pracuje" dot — this is the number the status
    /// line's "Agenci N" reads.
    var activeCount: Int { rows.filter(\.isWorking).count }
}

// MARK: - AgentsWindow ("Agenci" sheet, PLAN-V2 §7.2 pt.3 follow-up 2026-07-12)
//
// Grouped by project (`cwd`) — real column on `sessions`, verified populated
// on ~54% of recent rows. Sessions without a recorded cwd land in "Inne"
// rather than being guessed into a project.
//
// ponytail: no agent/subagent hierarchy here — `parent_session_id` is only
// populated on ~6% of recent sessions (8/130 over 7 days), too sparse to
// build a real tree without inventing structure for the other 94%. Flat list
// per project group instead. Revisit if Hermes starts populating it reliably.
struct AgentsWindow: View {
    // ponytail: owns its own poller instead of taking one from the Dashboard
    // — this view now lives in its own WindowGroup scene (App.swift), and
    // sharing @State across independent scenes isn't something SwiftUI
    // supports cleanly. Two independent 4s pollers (this + the Dashboard
    // status line's count) is simpler than plumbing a shared instance
    // across scenes.
    @State private var monitor = AgentsMonitor()
    @Environment(\.dismiss) private var dismiss
    @State private var expandedID: String?

    private var groups: [(key: String, rows: [AgentsMonitor.Row])] {
        let grouped = Dictionary(grouping: monitor.rows) { $0.project ?? "Inne" }
        return grouped
            .map { (key: $0.key, rows: $0.value) }
            .sorted { lhs, rhs in
                (lhs.rows.map(\.elapsed).min() ?? .infinity) < (rhs.rows.map(\.elapsed).min() ?? .infinity)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agenci").font(KiwiMangoFont.sans(15, weight: .medium))
                Spacer()
                Button("Zamknij") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ink.opacity(0.5))
            }
            .padding(.bottom, 12)

            if monitor.rows.isEmpty {
                Text("brak aktywnych agentów")
                    .font(KiwiMangoFont.sans(11))
                    .foregroundStyle(Color.txt.opacity(0.45))
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(groups, id: \.key) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(projectLabel(group.key).uppercased())
                                    .font(KiwiMangoFont.sans(8.5, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(Color.ink.opacity(0.45))
                                    .padding(.bottom, 6)

                                ForEach(group.rows) { row in
                                    AgentWindowRow(row: row, isOpen: expandedID == row.id) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            expandedID = expandedID == row.id ? nil : row.id
                                        }
                                    }
                                    if row.id != group.rows.last?.id {
                                        Divider().overlay(Color.ink.opacity(0.05))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        // Deliberately bigger than the 560×700 main window (§ that one is
        // compact by design) — this is a full standalone list that needs room
        // for project grouping + untruncated titles. Sheets inherit the
        // presenting window's size unless given their own frame, so this is
        // set explicitly rather than left to default.
        .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
        .background(Color.bg)
        .task {
            while !Task.isCancelled {
                await monitor.poll()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    /// Last path component only — the full cwd is noise at this width.
    private func projectLabel(_ key: String) -> String {
        guard key != "Inne" else { return key }
        return (key as NSString).lastPathComponent
    }
}

private struct AgentWindowRow: View {
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

                    Text(row.title)
                        .font(KiwiMangoFont.sans(11))
                        .foregroundStyle(Color.txt)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(row.model.uppercased())
                        .font(KiwiMangoFont.sans(8.5, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(Color.ink.opacity(0.4))

                    Text(formatCompactTokens(row.totalTokens))
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.ink.opacity(0.7))
                        .frame(width: 52, alignment: .trailing)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.ink.opacity(0.3))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                HStack(spacing: 20) {
                    StatColumn(value: row.isWorking ? "pracuje" : "bezczynny", label: "stan")
                    StatColumn(value: formatCompactTokens(row.inputTokens), label: "wejście")
                    StatColumn(value: formatCompactTokens(row.outputTokens), label: "wyjście")
                    StatColumn(value: "\(row.toolCalls)", label: "tool-calle")
                    StatColumn(value: Self.duration(row.elapsed), label: "czas pracy")
                }
                .padding(.leading, 16)
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
                .font(KiwiMangoFont.mono(12, weight: .light))
                .foregroundStyle(Color.txt)
            Text(label)
                .font(KiwiMangoFont.sans(9.5))
                .foregroundStyle(Color.ink.opacity(0.55))
        }
    }
}
