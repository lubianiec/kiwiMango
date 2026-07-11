import SwiftUI

// MARK: - ConversationView (PLAN-V2 §5, §7.3)
//
// THE single conversation surface — Agent and Chat both render through this
// exact view, differing only by `kind` (quick actions + composer copy) and by
// which backend feeds `session.items` (mocked here; Fala 3/C1 wires
// HermesGatewayClient for Agent and ClaudeCodeService/Ollama for Chat).

/// One quick-action capsule (Agent only). `action == nil` renders dimmed and
/// inert — PLAN-V2 §7.3/§9 C1: only "Kontekst z vaulta" has a real backend
/// this wave (`AgentSessionController.insertVaultContext`); the other three
/// have no wired service yet (flow-agent image gen, dziennik summarizer, a
/// cron-creation form are new infra, out of scope for an integration pass).
struct QuickActionItem: Identifiable {
    let id = UUID()
    let label: String
    let action: (() -> Void)?
}

struct ConversationView: View {
    @Bindable var session: ConversationSession
    var kind: ConversationKind
    var modelOptions: [String] = []
    var quickActionItems: [QuickActionItem] = []
    var onSend: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if kind == .agent {
                quickActions
                    .padding(.bottom, 12)
            }

            if session.items.isEmpty {
                EmptySessionView(text: emptyText)
            } else {
                transcript
            }

            Composer(
                draft: $session.draft,
                placeholder: kind == .agent ? "Napisz do Hermesa…" : "Napisz wiadomość… (⇧⏎ nowa linia)",
                counterText: counterText,
                thirdIcon: kind == .agent ? "mic" : "slash.circle",
                onSend: {
                    let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    session.draft = ""
                    onSend(text)
                }
            )
        }
        .padding(.top, 2)
    }

    private var emptyText: String {
        kind == .agent ? "Nowa sesja agenta — opisz zadanie, Hermes rusza" : "Nowy chat — opisz o co pytasz"
    }

    private var counterText: String {
        if kind == .agent {
            guard let used = session.contextUsed, let max = session.contextMax else { return "kontekst: — / — tok." }
            return "kontekst: \(Self.formatK(used)) / \(Self.formatK(max)) tok."
        } else {
            let cost = session.totalCostUSD > 0 ? String(format: "$%.2f", session.totalCostUSD) : "$0,00 (Pro)"
            return "\(session.model) · \(Self.formatK(session.totalTokens)) tok. · \(cost)"
        }
    }

    private static func formatK(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isWorking ? Color.accent : Color.green)
                .frame(width: 6, height: 6)
            Text(kind == .agent ? "Hermes" : "Chat")
                .font(KiwiMangoFont.sans(16, weight: .light))
            Picker("", selection: $session.model) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            Spacer()
            // ponytail: cosmetic only — real permission-mode switching needs
            // `claude -p --permission-mode`/interactive approval streaming,
            // which `ClaudeCodeService` doesn't implement yet (see
            // `ChatSessionController`). Left visible per PLAN-V2 §7.3 layout,
            // not wired to any backend this wave.
            Picker("", selection: .constant(0)) {
                Text(kind == .agent ? "Sesja: aktywna" : "Uprawnienia: pytaj").tag(0)
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
        .padding(.bottom, 14)
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            ForEach(quickActionItems) { item in
                QuickActionChip(label: item.label, action: item.action)
            }
        }
    }

    // MARK: Transcript + autoscroll (PLAN-V2 §7.3, pułapka #6)

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.items) { item in
                        itemView(item).id(item.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .overlay(alignment: .bottom) {
                if session.autoscrollPaused {
                    scrollNote
                }
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: session.items.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.autoscrollPaused) { wasPaused, isPaused in
                if wasPaused && !isPaused { scrollToBottom(proxy) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Rescans every thinking block for `isExpanded` — called after any toggle.
    /// One flag per session (not global), per PLAN-V2 pułapka #6.
    private func recomputeAutoscrollPause() {
        session.autoscrollPaused = session.items.contains {
            if case .thinking(let block) = $0 { return block.isExpanded }
            return false
        }
    }

    /// No-op while paused — new messages still land in the list, they just
    /// don't yank the viewport (PLAN-V2 §7.3: "Nowe wiadomości przy pauzie
    /// normalnie dochodzą poniżej").
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !session.autoscrollPaused, let last = session.items.last else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private var scrollNote: some View {
        Text("⏸ AUTOSCROLL WSTRZYMANY — ZWIŃ THINKING ABY WZNOWIĆ")
            .font(KiwiMangoFont.sans(8.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Color.bg.opacity(0.9))
            .overlay(Capsule().strokeBorder(Color.accent.opacity(0.3), lineWidth: 1))
            .clipShape(Capsule())
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func itemView(_ item: ConversationItem) -> some View {
        switch item {
        case .userMessage(_, let text):
            Text(text)
                .font(KiwiMangoFont.sans(12))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Color.bubble)
                .clipShape(RoundedCorners(radii: [12, 12, 3, 12]))
                .frame(maxWidth: 340, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)

        case .aiMessage(_, let label, let text, let isStreaming):
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(KiwiMangoFont.sans(8, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.ink.opacity(0.35))
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    MarkdownText(content: text)
                    if isStreaming { StreamingCursor() }
                }
            }
            .frame(maxWidth: 340, alignment: .leading)

        case .thinking(let block):
            ThinkingBlockView(model: block, onToggle: recomputeAutoscrollPause)

        case .toolCall(let call):
            ToolCallView(call: call)

        case .permission(let request):
            PermissionCard(request: request)
        }
    }
}

// MARK: - Streaming cursor (PLAN-V2 §7.3: 7×13pt accent blinking 0.9s)

private struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accent)
            .frame(width: 7, height: 13)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                    visible = false
                }
            }
    }
}

// MARK: - Quick action chip

private struct QuickActionChip: View {
    let label: String
    let action: (() -> Void)?
    @State private var isHovering = false

    private var isActive: Bool { action != nil }

    var body: some View {
        Text(label)
            .font(KiwiMangoFont.sans(9))
            .foregroundStyle(isActive ? (isHovering ? Color.accent : Color.ink.opacity(0.6)) : Color.ink.opacity(0.25))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(isActive && isHovering ? Color.accent.opacity(0.5) : Color.ink.opacity(0.14), lineWidth: 1))
            .animation(.easeInOut(duration: 0.2), value: isHovering)
            .contentShape(Capsule())
            .onTapGesture { action?() }
            .onHover { isHovering = isActive && $0 }
    }
}

// MARK: - Tool call capsule (PLAN-V2 §7.3)

private struct ToolCallView: View {
    @Bindable var call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                call.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(call.isRunning ? Color.accent : Color.green)
                        .frame(width: 5, height: 5)
                    Text("\(call.name) · \(call.argument)")
                        .lineLimit(1)
                    if let seconds = call.seconds {
                        Text(String(format: "%.1f s", seconds))
                            .foregroundStyle(Color.ink.opacity(0.35))
                    }
                    Text("▾")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.ink.opacity(0.3))
                }
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.ink.opacity(0.6))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.ink.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.ink.opacity(0.08), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            if call.isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(call.output)
                        .font(KiwiMangoFont.mono(9.5))
                        .foregroundStyle(Color.ink.opacity(0.65))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .background(Color.panel2)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
    }
}
