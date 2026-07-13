import SwiftUI

// MARK: - ConversationView (PLAN-V2 §5, §7.3)
//
// THE single conversation surface — Agent and Chat both render through this
// exact view. Terminal-styled transcript: dark panel, monospace text, syntax
// highlighting, clickable links, markdown tables, and a clear code block chrome.

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
            // Terminal title bar: traffic dots + title + model picker
            terminalTitleBar
                .padding(.bottom, 8)

            if kind == .agent {
                quickActions
                    .padding(.bottom, 12)
            }

            // Terminal window frame around transcript
            VStack(alignment: .leading, spacing: 0) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.panel2)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.ink.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

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
            .padding(.top, 10)
        }
        .padding(.top, 2)
    }

    // MARK: Terminal title bar

    private var terminalTitleBar: some View {
        HStack(spacing: 8) {
            // Traffic light dots in app palette colors
            HStack(spacing: 6) {
                Circle().fill(Color.danger).frame(width: 10, height: 10)
                Circle().fill(Color.accent).frame(width: 10, height: 10)
                Circle().fill(Color.green).frame(width: 10, height: 10)
            }

            Text(session.title)
                .font(KiwiMangoFont.mono(11, weight: .medium))
                .foregroundStyle(Color.ink.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // Status dot + model picker
            Circle()
                .fill(session.isWorking ? Color.accent : Color.green)
                .frame(width: 6, height: 6)
                .neonGlow(session.isWorking ? Color.accent : Color.green, intensity: session.isWorking ? 1.5 : 0.5)

            Picker("", selection: $session.model) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
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

    // MARK: Quick actions

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
                if session.items.isEmpty {
                    EmptySessionView(text: emptyText)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(session.items) { item in
                            itemView(item).id(item.id)
                        }
                    }
                    .padding(.all, 12)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) {
                if session.autoscrollPaused {
                    scrollNote
                }
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: session.scrollPulse) { _, _ in scrollToBottom(proxy) }
            .onChange(of: session.autoscrollPaused) { wasPaused, isPaused in
                if wasPaused && !isPaused { scrollToBottom(proxy) }
            }
        }
    }

    private func recomputeAutoscrollPause() {
        session.autoscrollPaused = session.items.contains {
            if case .thinking(let block) = $0 { return block.isExpanded }
            return false
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !session.autoscrollPaused, let last = session.items.last else { return }
        // pułapka #6: give SwiftUI one cycle to lay out the new item before scrolling.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
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
            userMessage(text)

        case .aiMessage(_, let label, let text, let isStreaming):
            aiMessage(label: label, text: text, isStreaming: isStreaming)

        case .thinking(let block):
            ThinkingBlockView(model: block, onToggle: recomputeAutoscrollPause)

        case .toolCall(let call):
            ToolCallView(call: call)

        case .permission(let request):
            PermissionCard(request: request)
        }
    }

    // MARK: User prompt — terminal prompt style

    private func userMessage(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("❯")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.accent)
            TerminalMarkdown(content: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.bubble.opacity(0.45))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AI reply — terminal panel style

    private func aiMessage(label: String, text: String, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label)
                    .font(KiwiMangoFont.mono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.ink.opacity(0.45))
                Spacer()
                if isStreaming { StreamingCursor() }
            }
            TerminalMarkdown(content: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.system(size: 8 + FontScale.bump))
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
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }
}
