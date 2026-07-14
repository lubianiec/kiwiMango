import SwiftUI
import UniformTypeIdentifiers

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

    @State private var isDropTargeted = false

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
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accent.opacity(isDropTargeted ? 0.08 : 0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.accent.opacity(isDropTargeted ? 0.5 : 0), lineWidth: 1.5)
                    )
                    .allowsHitTesting(false)
            )
            .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Composer(
                draft: $session.draft,
                placeholder: kind == .agent ? "Napisz do Hermesa…" : "Napisz wiadomość… (⇧⏎ nowa linia)",
                counterText: counterText,
                pendingAttachments: $session.pendingAttachments,
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

    // MARK: Drag & drop images

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            let filename = provider.suggestedName ?? "obraz"
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    session.pendingAttachments.append(PendingAttachment(
                        filename: filename,
                        base64: data.base64EncodedString(),
                        mimeType: Self.mimeType(forFilename: filename)
                    ))
                }
            }
        }
    }

    private static func mimeType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        default: "image/png"
        }
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

            if kind == .agent {
                Picker("", selection: reasoningEffortBinding) {
                    ForEach(Self.reasoningEffortOptions, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)
                .help("Poziom myślenia agenta")
            }
        }
    }

    // ponytail: plain-String Picker binding with "" = default, instead of
    // wrestling SwiftUI's Optional<String> tag matching — same pattern as
    // the existing model picker, just with an empty-string sentinel.
    private static let reasoningEffortOptions: [(label: String, value: String)] = [
        ("domyślny", ""), ("minimalny", "minimal"), ("niski", "low"),
        ("średni", "medium"), ("wysoki", "high"), ("bardzo wysoki", "xhigh"), ("max", "max"),
    ]

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: { session.reasoningEffort ?? "" },
            set: { session.reasoningEffort = $0.isEmpty ? nil : $0 }
        )
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

    // Grouping is render-only: session.items stays flat, this just batches
    // adjacent .toolCall items so the terminal-log view (pkt 3) can collapse them.
    private enum RenderGroup: Identifiable {
        case single(ConversationItem)
        case toolGroup([ToolCall])

        var id: AnyHashable {
            switch self {
            case .single(let item): item.id
            case .toolGroup(let calls): calls.first!.id
            }
        }
    }

    private func renderGroups(_ items: [ConversationItem]) -> [RenderGroup] {
        var result: [RenderGroup] = []
        var pending: [ToolCall] = []
        func flush() {
            if !pending.isEmpty { result.append(.toolGroup(pending)); pending = [] }
        }
        for item in items {
            if case .toolCall(let call) = item {
                pending.append(call)
            } else {
                flush()
                result.append(.single(item))
            }
        }
        flush()
        return result
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if session.items.isEmpty {
                    EmptySessionView(text: emptyText)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(renderGroups(session.items)) { group in
                            switch group {
                            case .single(let item):
                                itemView(item).id(item.id)
                            case .toolGroup(let calls):
                                ToolCallGroupView(calls: calls).id(calls.first!.id)
                            }
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
            // ponytail: unreachable in practice — renderGroups() always routes .toolCall
            // items through ToolCallGroupView. Kept for switch exhaustiveness only.
            ToolCallRowView(call: call)

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
            TerminalMarkdown(content: text, textColor: Color.accent.opacity(0.65))
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
                    .foregroundStyle(Color.accent.opacity(0.8))
                Spacer()
                if isStreaming { StreamingCursor() }
            }
            TerminalMarkdown(content: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // ponytail: whisper-light tint, not a full card — enough to separate
        // an AI turn from the user prompt row without a boxed/bordered look.
        .background(Color.ink.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

// MARK: - Tool call group (terminal log style — ciasna lista, zwijana >3 akcji)

private struct ToolCallGroupView: View {
    let calls: [ToolCall]
    @State private var isExpanded = false

    var body: some View {
        if calls.count <= 3 {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(calls) { call in
                    ToolCallRowView(call: call)
                }
            }
            .padding(.horizontal, 12)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "▾" : "▸")
                        Text("Wykonano \(calls.count) akcji")
                    }
                    .font(KiwiMangoFont.mono(10))
                    .foregroundStyle(Color.ink.opacity(0.45))
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ForEach(calls) { call in
                        ToolCallRowView(call: call)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Tool call row — single terminal line, no box (PLAN-V2 §7.3)

private struct ToolCallRowView: View {
    @Bindable var call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if !call.output.isEmpty { call.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(call.isRunning ? Color.accent : Color.green)
                        .frame(width: 5, height: 5)
                    Text("\(call.name) · \(call.argument)")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let seconds = call.seconds {
                        Text(String(format: "%.1f s", seconds))
                            .foregroundStyle(Color.ink.opacity(0.35))
                    }
                    if !call.output.isEmpty {
                        Text(call.isExpanded ? "▾" : "▸")
                            .font(.system(size: 8 + FontScale.bump))
                            .foregroundStyle(Color.ink.opacity(0.3))
                    }
                }
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.ink.opacity(0.6))
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            if call.isExpanded && !call.output.isEmpty {
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
    }
}
