import SwiftUI
import UniformTypeIdentifiers

// MARK: - ConversationView (PLAN-V2 §5, §7.3)
//
// THE single conversation surface — Agent and Chat both render through this
// exact view. Terminal-stream restyle (kiwimango-okno-rozmowy-final.html
// `.left`/`.stream`, "Anatomia rozróżnienia" in kiwimango-warsztat-terminal.html):
// the ty/agent distinction now carries three signals at once — a leading `❯`
// glyph only ty gets, SF Mono for ty + all machinery vs. SF Pro prose for the
// agent, and an amber-tinted row vs. no background at all (just a hairline
// spine in the gutter tying an agent reply to its tool calls).

struct ConversationView: View {
    @Bindable var session: ConversationSession
    var modelOptions: [String] = []
    var onSend: (String) -> Void = { _ in }

    @State private var isDropTargeted = false

    // MARK: Title bar activity indicator (moved from the deleted AgentPanel's
    // "TERAZ" section 2026-08-05 — the side panel and status footer are gone,
    // this is now the sole live "what's happening" surface, folded into the
    // terminal title bar instead of its own chrome.
    @State private var currentActionStartedAt: Date?
    @State private var clockNow = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Terminal title bar: traffic dots + title + activity + model picker
            terminalTitleBar
                .padding(.bottom, 8)

            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.bg)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accent.opacity(isDropTargeted ? 0.08 : 0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accent.opacity(isDropTargeted ? 0.5 : 0), lineWidth: 1.5)
                        )
                        .allowsHitTesting(false)
                )
                .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                    handleDrop(providers)
                    return true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Composer(
                draft: $session.draft,
                placeholder: "Napisz do Hermesa…",
                counterText: counterText,
                pendingAttachments: $session.pendingAttachments,
                onSend: {
                    let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    session.draft = ""
                    onSend(text)
                }
            )
        }
        .padding(.top, 2)
        .onChange(of: runningToolCall?.id) { _, newID in
            currentActionStartedAt = newID != nil ? Date() : nil
        }
        .task { await activityClockLoop() }
    }

    // MARK: Title bar activity — running tool / streaming reply / quiet idle dot

    private var runningToolCall: ToolCall? {
        for item in session.items.reversed() {
            if case .toolCall(let call) = item, call.isRunning { return call }
        }
        return nil
    }

    private var isStreamingReply: Bool {
        session.items.contains { if case .aiMessage(_, _, _, let streaming) = $0 { return streaming }; return false }
    }

    /// Same "while !cancelled / sleep 1s" polling idiom used elsewhere in the
    /// app (was `ServiceStatus`/`AgentPanel`'s clock loop) — ticks the elapsed
    /// label without pulling in Combine/`Timer.publish` for something this simple.
    @MainActor
    private func activityClockLoop() async {
        while !Task.isCancelled {
            clockNow = Date()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func elapsedLabel(since start: Date?) -> String {
        guard let start else { return "0,0 s" }
        let seconds = max(0, clockNow.timeIntervalSince(start))
        return String(format: "%.1f s", seconds).replacingOccurrences(of: ".", with: ",")
    }

    @ViewBuilder
    private var activityIndicator: some View {
        if let call = runningToolCall {
            HStack(spacing: 6) {
                activitySpinner
                Text(call.name)
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.teal)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(elapsedLabel(since: currentActionStartedAt))
                    .font(KiwiMangoFont.mono(9.5))
                    .foregroundStyle(Color.ink.opacity(0.28))
            }
        } else if isStreamingReply {
            HStack(spacing: 6) {
                activitySpinner
                Text("pisze…")
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.teal)
            }
        } else {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private var activitySpinner: some View {
        if reduceMotion {
            Circle().fill(Color.teal).frame(width: 6, height: 6)
        } else {
            TitleBarSpinner()
        }
    }

    // MARK: Drag & drop images

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let fileData = try? Data(contentsOf: url)
                    else { return }
                    Task { @MainActor in
                        let ext = url.pathExtension.lowercased()
                        let kind: PendingAttachment.Kind = ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(ext)
                            ? .image
                            : ext == "pdf" ? .pdf : .file
                        session.pendingAttachments.append(PendingAttachment(
                            kind: kind,
                            filename: url.lastPathComponent,
                            base64: fileData.base64EncodedString(),
                            mimeType: Self.mimeType(forFilename: url.lastPathComponent)
                        ))
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // ponytail: Photos.app (and some other sources) vend raw image
                // data with no file on disk — no `.fileURL` to load, so fall
                // back to the concrete registered image type (jpeg/png/tiff/…)
                // and read its bytes directly instead of requiring a real file.
                let imageTypeID = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .image) == true
                } ?? UTType.jpeg.identifier
                provider.loadDataRepresentation(forTypeIdentifier: imageTypeID) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        let ext = UTType(imageTypeID)?.preferredFilenameExtension ?? "jpg"
                        let filename = "zdjecie.\(ext)"
                        session.pendingAttachments.append(PendingAttachment(
                            kind: .image,
                            filename: filename,
                            base64: data.base64EncodedString(),
                            mimeType: Self.mimeType(forFilename: filename)
                        ))
                    }
                }
            }
        }
    }

    private static func mimeType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "pdf": "application/pdf"
        case "heic": "image/heic"
        case "tiff", "tif": "image/tiff"
        case "webp": "image/webp"
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

            Spacer(minLength: 8)

            // Live "what's happening" indicator — lowest layout priority so a
            // long tool name compresses before the fixed-width pickers ever move.
            activityIndicator
                .layoutPriority(-1)

            Picker("", selection: $session.model) {
                ForEach(modelOptions, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
            .layoutPriority(1)

            Picker("", selection: reasoningEffortBinding) {
                ForEach(Self.reasoningEffortOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 120)
            .help("Poziom myślenia agenta")
            .layoutPriority(1)
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

    private var counterText: String {
        guard let used = session.contextUsed, let max = session.contextMax else { return "kontekst: — / — tok." }
        return "kontekst: \(Self.formatK(used)) / \(Self.formatK(max)) tok."
    }

    private static func formatK(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
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
                    EmptySessionQuoteView()
                        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                } else {
                    // spacing: 0 — each row supplies its own margin (only the
                    // user-message row gets one, per the mockup); tool/thinking/
                    // agent blocks sit flush so their gutter spines read as one
                    // continuous line down the turn.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(renderGroups(session.items)) { group in
                            switch group {
                            case .single(let item):
                                itemView(item).id(item.id)
                            case .toolGroup(let calls):
                                ToolCallGroupView(calls: calls).id(calls.first!.id)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 10)
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

    // MARK: User row — looks like a typed command (mockup `.u`)
    //
    // No timestamp line: the mockup shows one under the text (mono 9.5,
    // ink 28%), but ConversationItem.userMessage carries no per-message
    // timestamp today — ConversationModels.swift is out of this task's file
    // scope, so this is left out rather than fabricated. Same for the
    // attachment pill in a *sent* message: nothing records which attachments
    // rode along with a past message (they're cleared from
    // session.pendingAttachments right after send), so it can't be rendered
    // here either. Add a `sentAt`/`attachments` field to `ConversationItem`
    // to unlock both.

    private func userMessage(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("❯")
                .font(KiwiMangoFont.mono(13))
                .foregroundStyle(Color.accent)
                .frame(width: 21, alignment: .leading)
            TerminalMarkdown(content: text, textColor: Color.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 9)
        .padding(.trailing, 16)
        .padding(.bottom, 9)
        .padding(.leading, 14)
        .background(Color.accent.opacity(0.07))
        .overlay(Rectangle().fill(Color.accent).frame(width: 2), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Agent row — no prompt glyph, indented, SF Pro prose (mockup `.a`)

    private func aiMessage(label: String, text: String, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("AGENT")
                    .font(KiwiMangoFont.sans(8.5, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.ink.opacity(0.42))
                Text(label)
                    .font(KiwiMangoFont.mono(9.5))
                    .foregroundStyle(Color.ink.opacity(0.28))
                Spacer(minLength: 8)
                if isStreaming { StreamingCursor() }
            }
            AgentProseText(text: text)
        }
        .padding(.top, 9)
        .padding(.trailing, 18)
        .padding(.bottom, 15)
        .padding(.leading, 40)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.ink.opacity(0.14))
                .frame(width: 1)
                .padding(.top, 9)
                .padding(.bottom, 14)
                .offset(x: 19)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent prose (mockup: SF Pro 15pt/1.72, the strongest text in the
// window — deliberately NOT Chat/TerminalMarkdown.swift, which hardcodes SF
// Mono for every block. That's exactly the "wall of monospace" look this
// redesign moves the agent's own words away from; mono stays for ty + all
// machinery around it.
//
// ponytail: handles paragraphs (split on blank lines) + inline `code` spans
// only — no headings/fenced code/tables, since the mockup's own content is
// plain prose with one inline code term. If agent replies start needing
// those inside this specific renderer, extend here rather than reusing
// TerminalMarkdown (its paragraph font isn't parameterized today).

private struct AgentProseText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Text(attributed(paragraph))
                    .lineSpacing(11)
                    .textSelection(.enabled)
            }
        }
    }

    private var paragraphs: [String] {
        let parts = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private func attributed(_ paragraph: String) -> AttributedString {
        var result = AttributedString()
        for (index, chunk) in paragraph.components(separatedBy: "`").enumerated() {
            var run = AttributedString(chunk)
            if index % 2 == 1 {
                run.font = KiwiMangoFont.mono(12.5)
                run.foregroundColor = Color.teal
                run.backgroundColor = Color.black.opacity(0.28)
            } else {
                run.font = KiwiMangoFont.sans(15)
                run.foregroundColor = Color.txt.opacity(0.97)
            }
            result.append(run)
        }
        return result
    }
}

// MARK: - Streaming cursor (PLAN-V2 §7.3: 7×13pt accent blinking 0.9s)
// "Kursor streamingu — zostaje jak jest" — untouched by the restyle.

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

// MARK: - Title bar spinner (moved from the deleted AgentPanel's "TERAZ"
// section 2026-08-05 — 11pt ring, teal arc, 1.1s rotation. Reduce-motion
// handling lives one level up in `activitySpinner`, which swaps this out
// for a static teal dot instead of rendering a frozen ring.

private struct TitleBarSpinner: View {
    @State private var rotating = false

    var body: some View {
        Circle()
            .strokeBorder(Color.ink.opacity(0.14), lineWidth: 1.5)
            .overlay(
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(Color.teal, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            )
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .frame(width: 11, height: 11)
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { rotating = true }
            }
    }
}

// MARK: - Machinery spine (shared rynna line for tool rows + fold toggle)

private extension View {
    /// The włoskowata pionowa line at x=19 in the mockup's `.m::before` — each
    /// row draws its own full-height segment; stacked with zero spacing
    /// between them (see `transcript`'s LazyVStack) they read as one
    /// continuous line down the group.
    func machineSpine() -> some View {
        overlay(alignment: .leading) {
            Rectangle().fill(Color.ink.opacity(0.14)).frame(width: 1).offset(x: 19)
        }
    }
}

// MARK: - Tool call group (terminal log style — ciasna lista, zwijana >3 akcji)

private struct ToolCallGroupView: View {
    let calls: [ToolCall]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if calls.count <= 3 {
                ForEach(calls) { call in
                    ToolCallRowView(call: call)
                }
            } else {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "▾" : "▸")
                        Text("Wykonano \(calls.count) akcji")
                    }
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.ink.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(.leading, 40)
                .padding(.trailing, 18)
                .padding(.vertical, 2)
                .machineSpine()

                if isExpanded {
                    ForEach(calls) { call in
                        ToolCallRowView(call: call)
                    }
                }
            }
        }
    }
}

// MARK: - Tool call row — single stdout line: ⎿ name argument time (mockup `.m-line`)

private struct ToolCallRowView: View {
    @Bindable var call: ToolCall

    // ponytail: ToolCall (ConversationModels.swift, out of this task's file
    // scope) has no isError/isSuccess flag — this reads the rendered strings
    // instead. Good enough for the two states the mockup calls out (red tool
    // name on error, green "Build complete"); promote to a real field on
    // ToolCall next time that file is touched if this heuristic misfires.
    private var isErrorOutput: Bool {
        call.output.localizedCaseInsensitiveContains("error")
    }

    private var nameColor: Color {
        isErrorOutput ? Color.danger : Color.teal
    }

    private var outputColor: Color {
        guard !isErrorOutput else { return Color.ink.opacity(0.42) }
        if call.name.localizedCaseInsensitiveContains("build") { return Color.green }
        return Color.ink.opacity(0.42)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if !call.output.isEmpty { call.isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("⎿").foregroundStyle(Color.ink.opacity(0.28))
                    Text(call.name).foregroundStyle(nameColor)
                    Text(call.argument)
                        .foregroundStyle(Color.ink.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let seconds = call.seconds {
                        Text(String(format: "%.1f s", seconds))
                            .foregroundStyle(Color.ink.opacity(0.28))
                    }
                    if !call.output.isEmpty {
                        Text(call.isExpanded ? "▾" : "▸")
                            .foregroundStyle(Color.ink.opacity(0.28))
                    }
                }
                .font(KiwiMangoFont.mono(10.5))
            }
            .buttonStyle(.plain)

            if call.isExpanded && !call.output.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(call.output)
                        .font(KiwiMangoFont.mono(10.5))
                        .foregroundStyle(outputColor)
                        .fixedSize(horizontal: true, vertical: false)
                        .textSelection(.enabled)
                }
                .padding(.leading, 20)
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 18)
        .padding(.vertical, 2)
        .machineSpine()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Empty session quote (moved from Dashboard/DashboardView.swift's
// QuoteBlock 2026-08-05 — the dashboard page was deleted, but this exact
// typographic composition is too good to lose: a session with no messages
// yet now shows a quote instead of a blank panel with placeholder copy.

private struct EmptySessionQuoteView: View {
    @State private var quote: Quote?
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            if let quote {
                // ponytail: był tu `Text("„")` 74pt w ramce o wysokości 30 —
                // glif polskiego cudzysłowu siedzi nisko w swoim boksie, więc
                // wystawał poza ramkę (frame nie przycina) i lądował wprost na
                // pierwszej linii cytatu jak plama brudu. SF Symbol ma
                // przewidywalny bounding box i nie da się tak rozjechać.
                Image(systemName: "quote.opening")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Color.accent.opacity(0.42))
                    .padding(.bottom, 24)
                    .allowsHitTesting(false)

                Text(quote.text)
                    .font(.system(size: 25 + FontScale.bump, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.txt.opacity(0.97), Color.txt.opacity(0.64)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .multilineTextAlignment(.center)
                    .lineSpacing(9)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)

                HStack(spacing: 10) {
                    Rectangle().fill(Color.accent.opacity(0.45)).frame(width: 22, height: 1)
                    Text(quote.author)
                        .font(.system(size: 10 + FontScale.bump, weight: .semibold))
                        .tracking(1.8)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.ink.opacity(0.42))
                }
                .padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .task {
            quote = await QuoteProvider.shared.nextQuote()
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
        }
    }
}
