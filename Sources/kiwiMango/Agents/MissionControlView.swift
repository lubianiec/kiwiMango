import SwiftUI

// MARK: - MissionControlView (F18.2 — Centrum Dowodzenia)

/// Live dashboard of running (and just-finished) agent sessions: what every
/// agent is doing RIGHT NOW, token burn, task progress, subagents. Reached
/// only via the status bar's "Agenci [N]" segment (F18.2 pkt 1) — no sidebar
/// entry, this is a panel, not a destination.
///
/// Lifecycle (F18.1 pkt 1 / F18.2 pkt 5): `AgentTelemetry.isActive` is only
/// `true` while this view is on screen, so the 2s JSONL-tailing timer is dead
/// the rest of the time. Every currently-known session gets `attach()`ed on
/// appear; sessions spawned while this view stays open (via the popover, not
/// possible today without leaving this view, but the `onChange` below covers
/// it defensively) get attached too.
struct MissionControlView: View {
    var onSelectAgent: (UUID) -> Void = { _ in }
    var onClose: () -> Void = {}

    @Environment(AgentManager.self) private var agentManager
    @Environment(AgentTelemetry.self) private var telemetry
    /// Fala 24.7: second telemetry source (Hermes gateway, live WS events) —
    /// rendered alongside Claude's `AgentMissionCard`s below, own card type
    /// (`HermesMissionCard`) since the underlying models aren't unified.
    @Environment(HermesTelemetry.self) private var hermesTelemetry

    /// First moment we observed a session as `.finished` — used to apply the
    /// "opacity 0.75 for an hour, then drop it" rule from F18.2 pkt 6. Not
    /// persisted; a fresh Centrum session just starts noticing from now on.
    @State private var finishedSeenAt: [UUID: Date] = [:]
    @State private var now = Date()

    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))

            if visibleSessions.isEmpty && hermesTelemetry.cards.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleSessions) { session in
                            AgentMissionCard(
                                session: session,
                                telemetry: telemetry.telemetry(for: session),
                                opacity: opacity(for: session),
                                onSelect: { onSelectAgent(session.id) }
                            )
                        }
                        ForEach(hermesTelemetry.cards) { card in
                            HermesMissionCard(card: card)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(Color.kiwiMangoSurface)
        .onAppear {
            telemetry.isActive = true
            attachAll()
        }
        .onDisappear {
            telemetry.isActive = false
        }
        .onChange(of: agentManager.sessions.map(\.id)) { _, _ in
            attachAll()
        }
        .onReceive(ticker) { date in
            now = date
            noteFinishedSessions()
            hermesTelemetry.pruneStale(now: date)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Text("← powrót")
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            }
            .buttonStyle(.plain)

            Text("CENTRUM DOWODZENIA")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            Spacer()

            Text(summaryLine)
                .font(KiwiMangoFont.mono(10.5, weight: .medium))
                .foregroundStyle(Color.kiwiMangoAccent)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
    }

    private var summaryLine: String {
        let agentCount = visibleSessions.count + hermesTelemetry.cards.count
        let subagentCount = visibleSessions.reduce(0) { $0 + (telemetry.telemetry(for: $1)?.subagents.count ?? 0) }
            + hermesTelemetry.cards.reduce(0) { $0 + $1.subagents.count }
        let totalTokens = visibleSessions.reduce(0) { sum, session in
            guard let t = telemetry.telemetry(for: session) else { return sum }
            return sum + t.inputTokens + t.outputTokens + t.cacheReadTokens + t.cacheCreationTokens
        } + hermesTelemetry.cards.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
        return "\(agentCount) agentów · \(subagentCount) subagentów · \(formatTokens(totalTokens)) tokenów"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("Brak aktywnych agentów")
                .font(KiwiMangoFont.mono(12, weight: .medium))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
            Text("Odpal agenta (⌘T), żeby zobaczyć go tutaj na żywo.")
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session visibility (F18.2 pkt 6)

    /// Running sessions always show; finished sessions show, wyszarzone, for
    /// up to an hour after we first noticed them finished — then they drop
    /// out of Centrum entirely (history lives elsewhere, F13).
    private var visibleSessions: [AgentSession] {
        agentManager.sessions.filter { session in
            guard session.status == .finished else { return true }
            guard let seenAt = finishedSeenAt[session.id] else { return true }
            return now.timeIntervalSince(seenAt) < 3600
        }
    }

    private func opacity(for session: AgentSession) -> Double {
        session.status == .running ? 1 : 0.75
    }

    private func noteFinishedSessions() {
        for session in agentManager.sessions where session.status == .finished {
            if finishedSeenAt[session.id] == nil {
                finishedSeenAt[session.id] = now
            }
        }
        // Stop tracking sessions the manager no longer knows about at all
        // (closed by the user) — keeps the dictionary from growing forever.
        let liveIDs = Set(agentManager.sessions.map(\.id))
        finishedSeenAt = finishedSeenAt.filter { liveIDs.contains($0.key) }
    }

    private func attachAll() {
        for session in agentManager.sessions {
            telemetry.attach(session)
        }
    }
}

// MARK: - AgentMissionCard

/// One agent's live status card: status dot, header, ASCII runner, current
/// activity, recent activities, task progress, token bar + sparkline. Every
/// mark here is a plain `Text`/`Canvas`/`Rectangle` — no shaders, no
/// `layerEffect`, per F9 iron rule #2 (this is a scrolling list).
private struct AgentMissionCard: View {
    let session: AgentSession
    let telemetry: SessionTelemetry?
    let opacity: Double
    let onSelect: () -> Void

    @State private var expanded = false
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isRunning: Bool { session.status == .running }
    private var degraded: Bool { telemetry == nil || telemetry?.gaveUpLookup == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardBody
                .padding(12)
                .background(Color.kiwiMangoChrome)
                .overlay(
                    Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)

            if let telemetry, !telemetry.subagents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(telemetry.subagents) { info in
                        SubagentRow(info: info)
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 6)
            }
        }
        .opacity(opacity)
        .onReceive(ticker) { now = $0 }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(session.kind.shortName)/\(session.shortModel) · \(session.workDir.lastPathComponent)")
                        .font(KiwiMangoFont.mono(12, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .lineLimit(1)
                    Text(elapsed)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                }
                Spacer()
                runner
            }

            if degraded {
                Text(telemetry == nil ? "brak telemetrii" : "telemetria niedostępna dla tej sesji")
                    .font(KiwiMangoFont.mono(10))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.45))
            } else if let telemetry {
                activityBlock(telemetry)

                if !telemetry.tasks.isEmpty {
                    tasksBlock(telemetry)
                }

                tokenBar(telemetry)
                sparkline(telemetry)
            }
        }
    }

    // MARK: Status dot

    private var statusDot: some View {
        Text("●")
            .font(.system(size: 9))
            .foregroundStyle(isRunning ? Color.kiwiMangoAccent : Color.gray)
            .symbolEffect(.pulse, isActive: isRunning)
            .opacity(isRunning ? 1 : 0.5)
            .realBloom(strength: 1.6, radius: 2)
    }

    private var elapsed: String {
        let seconds = Int(now.timeIntervalSince(session.startedAt))
        let minutes = seconds / 60
        if minutes < 1 { return "przed chwilą" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz. \(minutes % 60) min"
    }

    // MARK: Braille spinner (F18.2 pkt 2)

    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @ViewBuilder
    private var runner: some View {
        if isRunning {
            TimelineView(.periodic(from: session.startedAt, by: 0.08)) { context in
                let tick = Int(context.date.timeIntervalSince(session.startedAt) / 0.08)
                Text(Self.spinnerFrames[tick % Self.spinnerFrames.count])
                    .font(KiwiMangoFont.mono(15, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccent)
            }
        } else {
            Text("✓")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
        }
    }

    // MARK: Activity (F18.1 pkt 3a)

    private func activityBlock(_ telemetry: SessionTelemetry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let current = telemetry.currentActivity {
                Text(current.humanDescription)
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.92))
                    .lineLimit(1)
            } else {
                Text("czekam na pierwszą czynność…")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
            }
            ForEach(telemetry.recentActivities) { activity in
                Text(activity.humanDescription)
                    .font(KiwiMangoFont.mono(9.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
                    .lineLimit(1)
            }
        }
    }

    // MARK: Tasks (F18.1 pkt 3b)

    private func tasksBlock(_ telemetry: SessionTelemetry) -> some View {
        let done = telemetry.tasks.filter(\.isCompleted).count
        let total = telemetry.tasks.count
        let fraction = total > 0 ? Double(done) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text("ZADANIA \(done)/\(total) ✓")
                        .font(KiwiMangoFont.mono(9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
                }
            }
            .buttonStyle(.plain)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Rectangle()
                        .fill(Color.kiwiMangoAccent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(telemetry.tasks) { task in
                        HStack(spacing: 6) {
                            Text(taskMarker(task))
                                .foregroundStyle(taskColor(task))
                            Text(task.subject)
                                .foregroundStyle(
                                    task.isCompleted
                                        ? Color.kiwiMangoTextPrimary.opacity(0.4)
                                        : Color.kiwiMangoTextPrimary.opacity(0.85)
                                )
                                .lineLimit(1)
                        }
                        .font(KiwiMangoFont.mono(9.5))
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func taskMarker(_ task: AgentTaskItem) -> String {
        if task.isCompleted { return "✓" }
        if task.isInProgress { return "▸" }
        return "○"
    }

    private func taskColor(_ task: AgentTaskItem) -> Color {
        if task.isCompleted { return Color.kiwiMangoTextPrimary.opacity(0.4) }
        if task.isInProgress { return Color.kiwiMangoAccent }
        return Color.kiwiMangoTextPrimary.opacity(0.5)
    }

    // MARK: Token bar

    private func tokenBar(_ telemetry: SessionTelemetry) -> some View {
        let input = telemetry.inputTokens
        let output = telemetry.outputTokens
        let cache = telemetry.cacheReadTokens + telemetry.cacheCreationTokens
        let total = max(input + output + cache, 1)
        let cachePercent = Int((Double(cache) / Double(total)) * 100)

        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.kiwiMangoAccent)
                        .frame(width: proxy.size.width * CGFloat(input) / CGFloat(total))
                    Rectangle().fill(Color.white.opacity(0.18))
                        .frame(width: proxy.size.width * CGFloat(cache) / CGFloat(total))
                    Rectangle().fill(Color.kiwiMangoPurple)
                        .frame(width: proxy.size.width * CGFloat(output) / CGFloat(total))
                }
            }
            .frame(height: 5)

            Text("IN \(formatTokens(input)) / OUT \(formatTokens(output)) / cache \(cachePercent)%")
                .font(KiwiMangoFont.mono(9.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }

    // MARK: Sparkline (reuse F6.2 pattern)

    @ViewBuilder
    private func sparkline(_ telemetry: SessionTelemetry) -> some View {
        let values = telemetry.tokenRateSamples.map { Double($0.1) }
        if values.count > 1 {
            Canvas { context, size in
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
            .frame(height: 18)
        }
    }
}

// MARK: - SubagentRow

/// Indented child card under a parent agent — 2px purple left edge, per
/// F18.2 pkt 3. No timer of its own: subagents report tokens/duration only
/// once, in their closing `tool_result` (`SubagentUsageParser`).
private struct SubagentRow: View {
    let info: SubagentInfo

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.kiwiMangoPurple)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(info.displayName)
                    .font(KiwiMangoFont.mono(10.5, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
                    .lineLimit(1)
                Text(subtitle)
                    .font(KiwiMangoFont.mono(9))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .background(Color.kiwiMangoChrome.opacity(0.6))
    }

    private var subtitle: String {
        if info.isFinished {
            var parts = ["zakończony"]
            if let tokens = info.tokens { parts.append("\(formatTokens(tokens)) tok.") }
            if let toolUses = info.toolUses { parts.append("\(toolUses) narzędzi") }
            return parts.joined(separator: " · ")
        }
        return "w toku…"
    }
}

// MARK: - HermesMissionCard (Fala 24.7)

/// Hermes gateway session card — same visual language as `AgentMissionCard`
/// (spinner, activity line, token bar) but a separate, simpler view: the
/// underlying model (`HermesTelemetry.SessionCard`) isn't unified with
/// Claude's `AgentSession`/`SessionTelemetry` (deliberately, per PLAN.md —
/// "NIE dotykać logiki JSONL AgentTelemetry").
private struct HermesMissionCard: View {
    let card: HermesTelemetry.SessionCard

    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardBody
                .padding(12)
                .background(Color.kiwiMangoChrome)
                .overlay(
                    Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )

            if !card.subagents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.subagents) { sub in
                        HermesSubagentRow(subagent: sub)
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 6)
            }
        }
        .opacity(card.isActive ? 1 : 0.75)
        .onReceive(ticker) { now = $0 }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("●")
                    .font(.system(size: 9))
                    .foregroundStyle(card.isActive ? Color.kiwiMangoAccent : Color.gray)
                    .symbolEffect(.pulse, isActive: card.isActive)
                    .opacity(card.isActive ? 1 : 0.5)
                    .realBloom(strength: 1.6, radius: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("🦉 HERMES · \(card.conversationTitle)")
                        .font(KiwiMangoFont.mono(12, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .lineLimit(1)
                    Text(elapsed)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                }
                Spacer()
                runner
            }

            if let activity = card.currentActivity {
                Text(activity)
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.92))
                    .lineLimit(1)
            } else {
                Text(idleActivityText)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
            }

            if card.inputTokens + card.outputTokens > 0 {
                tokenBar
            }
        }
    }

    @ViewBuilder
    private var runner: some View {
        if card.isActive {
            TimelineView(.periodic(from: card.startedAt, by: 0.08)) { context in
                let tick = Int(context.date.timeIntervalSince(card.startedAt) / 0.08)
                Text(Self.spinnerFrames[tick % Self.spinnerFrames.count])
                    .font(KiwiMangoFont.mono(15, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccent)
            }
        } else {
            Text("✓")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
        }
    }

    private var elapsed: String {
        let seconds = Int(now.timeIntervalSince(card.startedAt))
        let minutes = seconds / 60
        if minutes < 1 { return "przed chwilą" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz. \(minutes % 60) min"
    }

    private var idleActivityText: String {
        if card.isTurnRunning { return "czekam na pierwszą czynność…" }
        if card.subagents.contains(where: { !$0.isFinished }) { return "czeka na subagentów…" }
        return "zakończone"
    }

    private var tokenBar: some View {
        let input = card.inputTokens
        let output = card.outputTokens
        let total = max(input + output, 1)

        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.kiwiMangoAccent)
                        .frame(width: proxy.size.width * CGFloat(input) / CGFloat(total))
                    Rectangle().fill(Color.kiwiMangoPurple)
                        .frame(width: proxy.size.width * CGFloat(output) / CGFloat(total))
                }
            }
            .frame(height: 5)

            Text("IN \(formatTokens(input)) / OUT \(formatTokens(output))")
                .font(KiwiMangoFont.mono(9.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }
}

private struct HermesSubagentRow: View {
    let subagent: HermesTelemetry.SubagentCard

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.kiwiMangoPurple)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(subagent.description)
                    .font(KiwiMangoFont.mono(10.5, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
                    .lineLimit(1)
                Text(subagent.isFinished ? "zakończony" : "w toku…")
                    .font(KiwiMangoFont.mono(9))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .background(Color.kiwiMangoChrome.opacity(0.6))
        .opacity(subagent.isFinished ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.3), value: subagent.isFinished)
    }
}

// MARK: - Formatting helpers

private func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}
