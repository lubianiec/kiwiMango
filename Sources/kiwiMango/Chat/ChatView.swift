import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - GlitchOverlay

/// Applies `chromaticGlitch` only while `amount > 0`. A `layerEffect` that's
/// merely `isEnabled: false` at rest is not equivalent to not attaching it —
/// verified empirically that the disabled-but-attached form blanks the whole
/// transcript subtree instead of passing content through (see F9.4 note at
/// the transcript's `.modifier` call site).
private struct GlitchOverlay: ViewModifier {
    let amount: CGFloat
    let time: Double

    func body(content: Content) -> some View {
        if amount > 0 {
            content.layerEffect(
                kiwiShaders.chromaticGlitch(.float(amount), .float(time)),
                maxSampleOffset: CGSize(width: 30, height: 0)
            )
        } else {
            content
        }
    }
}

// MARK: - ChatView

/// Main (and only) window content. Transcript + floating glass composer.
struct ChatView: View {

    @Environment(ChatState.self) private var chatState

    @State private var isDropTargeted = false
    @State private var showingPersonaEditor = false
    @State private var speech = SpeechRecognizer()
    @State private var draftBeforeDictation = ""
    @State private var toastMessage: String?
    @State private var snippetPopoverDismissed = false
    @State private var composerCursorVisible = false
    @State private var sendButtonHovered = false
    @AppStorage("ttsEnabled") private var ttsEnabled = false
    @AppStorage("webSearchEnabled") private var webSearchEnabled = false
    @AppStorage("ollamaWebSearchKey") private var webSearchKey = ""
    @State private var voiceLoop: VoiceLoopController?
    @State private var voiceListenPulse = false
    @State private var glitchAmount: CGFloat = 0
    @State private var glitchTime: Double = 0
    @FocusState private var composerFocused: Bool

    private static let bottomAnchor = "transcript-bottom"

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            transcriptOrEmpty
                .frame(minWidth: 380, minHeight: 420)
                .safeAreaInset(edge: .bottom, spacing: 0) { composerArea }
        }
        .kiwiMangoNoirBackground()
        .task { await chatState.loadModels() }
        .task { await chatState.refreshClaudeAvailability() }
        .onAppear {
            composerFocused = true
            if voiceLoop == nil {
                voiceLoop = VoiceLoopController(chatState: chatState)
            }
        }
        .onChange(of: chatState.currentConversationID) {
            voiceLoop?.stop()
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay { dropTargetOverlay }
        .background {
            Button("") { voiceLoop?.stop() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!(voiceLoop?.isActive ?? false))
                .hidden()
        }
        .sheet(isPresented: $showingPersonaEditor) {
            PersonaEditorView()
        }
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.callout)
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.kiwiMangoChrome, in: Capsule())
                    .padding(.bottom, 70)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.toastMessage = nil }
                    }
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Text("Chat: \(currentTitle)")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .lineLimit(1)

            Spacer()

            personaPicker
            modelPicker

            Button {
                chatState.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("Wyczyść rozmowę")
            .disabled(chatState.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kiwiMangoAccent.opacity(0.15)).frame(height: 1)
        }
    }

    private var currentTitle: String {
        chatState.conversations.first(where: { $0.id == chatState.currentConversationID })?.title
            ?? "kiwiMango"
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptOrEmpty: some View {
        if chatState.messages.isEmpty {
            ContentUnavailableView {
                Label("kiwiMango", systemImage: "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            } description: {
                VStack(spacing: 6) {
                    Text("Rozmowa z lokalnym modelem Ollama.\nWpisz wiadomość lub upuść obraz.")
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                    Text("⌘N nowa rozmowa · ⌘F szukaj · ⇧⏎ nowa linia · przeciągnij obraz aby załączyć")
                        .font(KiwiMangoFont.mono(10.5))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.63))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(chatState.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(
                            message: message,
                            isLastAssistant: message.role == .assistant
                                && index == chatState.messages.count - 1
                                && !chatState.isStreaming,
                            isStreamingReply: message.role == .assistant
                                && index == chatState.messages.count - 1
                                && chatState.isStreaming,
                            onRegenerate: {
                                let state = chatState
                                Task { await state.regenerateLast() }
                            },
                            onToast: { toastMessage = $0 }
                        )
                        .id(message.id)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if chatState.isStreaming {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .padding(.leading, 4)
                            .padding(.bottom, 8)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            .onAppear {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
            .onChange(of: chatState.messages.count) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: chatState.messages.last?.content) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
        // Forces a fresh ScrollView/NSScrollView per conversation. Without this,
        // switching conversations sometimes leaves the underlying NSScrollView
        // showing a stale, blank viewport — the transcript's `messages` state is
        // correct, but the scroll content never redraws until something else
        // (e.g. a window resize) forces a relayout.
        .id(chatState.currentConversationID)
        // NOT `.layerEffect(..., isEnabled: glitchAmount > 0)` — on this SwiftUI/
        // Metal build, a `layerEffect` with `isEnabled: false` still blanks the
        // whole subtree instead of passing content through untouched (verified:
        // even loaded history rendered empty while this was attached at rest).
        // Only ever attach the modifier while the glitch is actually running.
        .modifier(GlitchOverlay(amount: glitchAmount, time: glitchTime))
        .onChange(of: chatState.glitchTrigger) {
            glitchTime = Date.timeIntervalSinceReferenceDate
            glitchAmount = 1
            withAnimation(.easeOut(duration: 0.4)) {
                glitchAmount = 0
            }
        }
    }

    // MARK: - Persona picker

    private var personaPicker: some View {
        Menu {
            ForEach(chatState.personas) { persona in
                Button(activePersonaLabel(persona)) { chatState.selectPersona(persona.id) }
            }
            Divider()
            Button("Edytuj persony…") { showingPersonaEditor = true }
        } label: {
            HStack(spacing: 4) {
                Text((chatState.activePersona?.name ?? "kiwiMango").uppercased())
                Text("▾")
            }
            .font(KiwiMangoFont.mono(11, weight: .medium))
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Persona")
    }

    private func activePersonaLabel(_ persona: Persona) -> String {
        chatState.activePersonaID == persona.id ? "✓ \(persona.name)" : persona.name
    }

    // MARK: - Model picker

    /// Fix (2026-07-08): a `Button` nested inside a `Picker`'s content closure
    /// does not fire its action on macOS — the enclosing Picker's own tap
    /// handling swallows the click before the Button sees it (confirmed live:
    /// clicking a HERMES/ANTHROPIC row closed the menu without changing
    /// `selectedModel`). Every section is now a plain `Button` directly inside
    /// the `Menu`'s content — no `Picker` wrapper anywhere in this menu.
    private var modelPicker: some View {
        Menu {
            if !localModels.isEmpty {
                Section("💻 LOKALNE") {
                    ForEach(localModels, id: \.self) { name in
                        modelRow(id: name, label: displayName(for: name))
                    }
                }
            }
            if !cloudModels.isEmpty {
                Section("☁️ CLOUD") {
                    ForEach(cloudModels, id: \.self) { name in
                        modelRow(id: name, label: displayName(for: name))
                    }
                }
            }
            if chatState.claudeAvailability.isInstalled {
                Section("🤖 ANTHROPIC") {
                    ForEach(ClaudeCodeService.pickerModels, id: \.self) { model in
                        let id = "claude:\(model.rawValue)"
                        let isAvailable = chatState.claudeAvailability.isAvailable
                        let isSelected = chatState.selectedModel == id
                        Button {
                            if isAvailable {
                                chatState.selectedModel = id
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(isSelected ? "✓ \(claudeDisplayName(model))" : "  \(claudeDisplayName(model))")
                                    .foregroundStyle(isAvailable ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.42))
                                Spacer()
                                if !isAvailable {
                                    Text(chatState.claudeAvailability.reason)
                                        .font(KiwiMangoFont.mono(10, weight: .medium))
                                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
                                }
                            }
                        }
                        .disabled(!isAvailable)
                        .help(isAvailable ? claudeDisplayName(model) : chatState.claudeAvailability.reason)
                    }
                }
            }
            if !chatState.availableModels.isEmpty {
                Section("🦉 HERMES") {
                    ForEach(chatState.availableModels, id: \.name) { model in
                        modelRow(id: "hermes:\(model.name)", label: displayName(for: model.name))
                            .help("\(displayName(for: model.name)) przez Hermes Agent")
                    }
                }
            }

            Divider()
            Button("ZARZĄDZAJ MODELAMI…") {
                chatState.showingModelManager = true
            }
        } label: {
            HStack(spacing: 4) {
                Text("⊕ \(displayName(for: chatState.selectedModel))")
                Text(isHermesModelSelected ? "[Hermes]" : (selectedModelIsCloud ? "[Cloud]" : "[Local]"))
                    .foregroundStyle(Color.kiwiMangoPurple)
                Text("▾")
            }
            .font(KiwiMangoFont.mono(11, weight: .medium))
            .foregroundStyle(Color.kiwiMangoAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model Ollama")
    }

    /// Shared row for LOKALNE/CLOUD/HERMES — plain `Button`, no `Picker` tag
    /// (see the fix note on `modelPicker`). `id` is the full value stored into
    /// `chatState.selectedModel` (bare model name, or `"hermes:<model>"`).
    private func modelRow(id: String, label: String) -> some View {
        let isSelected = chatState.selectedModel == id
        return Button {
            chatState.selectedModel = id
        } label: {
            Text(isSelected ? "✓ \(label)" : "  \(label)")
        }
    }

    /// Fala 17: `claude:*` ids are Anthropic subscription models, not Ollama —
    /// always treated as "[Cloud]" but never routed through the Ollama picker lists.
    private var selectedModelIsCloud: Bool {
        if ClaudeCodeService.parseModelID(chatState.selectedModel) != nil { return true }
        return chatState.availableModels.first { $0.name == chatState.selectedModel }?.isCloud
            ?? isKnownCloud(chatState.selectedModel)
    }

    /// Always contains the persisted selection, even when /api/tags is unreachable.
    /// Excludes `claude:*` ids — those live in their own ANTHROPIC section.
    private var pickerModels: [String] {
        var models = chatState.availableModels.map(\.name)
        if ClaudeCodeService.parseModelID(chatState.selectedModel) != nil { return models }
        if HermesChatService.parseModelID(chatState.selectedModel) != nil { return models }
        if models.isEmpty { return [chatState.selectedModel] }
        if !models.contains(chatState.selectedModel) {
            models.insert(chatState.selectedModel, at: 0)
        }
        return models
    }

    private var localModels: [String] {
        let names = Set(chatState.availableModels.filter { !$0.isCloud }.map(\.name))
        return pickerModels.filter { names.contains($0) || (!isKnownCloud($0) && chatState.availableModels.isEmpty) }
    }

    private var cloudModels: [String] {
        let names = Set(chatState.availableModels.filter(\.isCloud).map(\.name))
        return pickerModels.filter { names.contains($0) || (isKnownCloud($0) && chatState.availableModels.isEmpty) }
    }

    private func isKnownCloud(_ name: String) -> Bool {
        name.hasSuffix(":cloud")
    }

    private func claudeDisplayName(_ model: ClaudeCodeService.ClaudeModel) -> String {
        model.displayName
    }

    private func displayName(for model: String, cloudBadge: Bool = false) -> String {
        if let claudeModel = ClaudeCodeService.parseModelID(model) {
            return claudeModel.displayName
        }
        if let hermesModel = HermesChatService.parseModelID(model) {
            let base = hermesModel.split(separator: "/").last.map(String.init) ?? hermesModel
            return "🦉 " + base
        }
        let base = model.split(separator: "/").last.map(String.init) ?? model
        guard cloudBadge, isKnownCloud(model) else { return base }
        return "☁️ " + base
    }

    // MARK: - Composer (floating glass)

    private var composerArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let voiceLoop, voiceLoop.isActive {
                voiceLoopBar(voiceLoop)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            } else {
                if !filteredSnippets.isEmpty && !snippetPopoverDismissed {
                    snippetPopover
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                if !chatState.attachedImages.isEmpty {
                    attachmentsRow
                        .padding(.horizontal, 16)
                }
                if claudeImageBlock {
                    Text("⚠️ Obrazy nie działają z Claude w tej wersji — przełącz na model Ollama z vision")
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoDanger)
                        .padding(.horizontal, 16)
                }
                if chatState.isSearchingWeb {
                    Text("SZUKAM W SIECI…")
                        .font(KiwiMangoFont.mono(10, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Color.kiwiMangoAccent)
                        .padding(.horizontal, 16)
                }
                if let webSearchWarning = chatState.webSearchWarning {
                    Text("⚠️ \(webSearchWarning)")
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoDanger)
                        .padding(.horizontal, 16)
                }
                composer
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
            }
        }
        .background(Color.clear)
        .onChange(of: chatState.draft) { snippetPopoverDismissed = false }
    }

    // MARK: - Voice loop (F7.2)

    private func voiceLoopBar(_ loop: VoiceLoopController) -> some View {
        HStack {
            Text(voiceStateLabel(loop.state))
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(voiceStateColor(loop.state))
                .opacity(loop.state == .listening ? (voiceListenPulse ? 1 : 0.4) : 1)
                .animation(
                    loop.state == .listening
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: voiceListenPulse
                )
                .onAppear { voiceListenPulse = true }

            Spacer()

            Button {
                loop.stop()
            } label: {
                Text("[■ STOP]")
                    .font(KiwiMangoFont.mono(12, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoDanger)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.kiwiMangoComposerBg)
        .neonBorder(Color.kiwiMangoPurple, cornerRadius: 4, active: true)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func voiceStateLabel(_ state: VoiceLoopController.State) -> String {
        switch state {
        case .idle: return ""
        case .listening: return "● SŁUCHAM…"
        case .thinking: return "◐ MYŚLĘ…"
        case .speaking: return "▶ MÓWIĘ…"
        }
    }

    private func voiceStateColor(_ state: VoiceLoopController.State) -> Color {
        switch state {
        case .listening: return Color.kiwiMangoAccent
        case .speaking: return Color.kiwiMangoPurple
        default: return Color.kiwiMangoTextPrimary.opacity(0.7)
        }
    }

    // MARK: - Snippet popover

    private var filteredSnippets: [Snippet] {
        guard chatState.draft.hasPrefix("/") else { return [] }
        let query = chatState.draft.dropFirst().lowercased()
        if query.isEmpty { return chatState.snippets }
        return chatState.snippets.filter { $0.trigger.lowercased().hasPrefix(query) }
    }

    private var snippetPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredSnippets) { snippet in
                Button {
                    insertSnippet(snippet)
                } label: {
                    HStack {
                        Text("/\(snippet.trigger)")
                            .font(KiwiMangoFont.mono(11, weight: .medium))
                            .foregroundStyle(Color.kiwiMangoAccent)
                        Text(snippet.content)
                            .font(KiwiMangoFont.sans(11))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.kiwiMangoComposerBg)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func insertSnippet(_ snippet: Snippet) {
        chatState.draft = snippet.content + " "
        snippetPopoverDismissed = true
    }

    private var composer: some View {
        @Bindable var state = chatState
        return HStack(alignment: .bottom, spacing: 10) {
            Button(action: pickImages) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            .help("Załącz obraz")

            micButton
            ttsToggleButton
            voiceLoopButton
            webSearchToggleButton

            Text(">>")
                .font(KiwiMangoFont.mono(12.5, weight: .bold))
                .foregroundStyle(Color.kiwiMangoAccent.opacity(0.7))
                .realBloom(strength: 1.2, radius: 2)

            ZStack(alignment: .leading) {
                if state.draft.isEmpty {
                    if composerFocused {
                        Text("_")
                            .font(KiwiMangoFont.mono(12.5))
                            .foregroundStyle(Color.kiwiMangoAccent)
                            .opacity(composerCursorVisible ? 1 : 0)
                            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: composerCursorVisible)
                            .onAppear { composerCursorVisible = false }
                            .allowsHitTesting(false)
                    } else {
                        Text("napisz coś, enter aby wysłać")
                            .font(KiwiMangoFont.mono(12.5))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
                            .allowsHitTesting(false)
                    }
                }
                TextField("", text: $state.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        // Shift+Enter = newline, plain Enter falls through to onSubmit.
                        if press.modifiers.contains(.shift) {
                            chatState.draft += "\n"
                            return .handled
                        }
                        if !filteredSnippets.isEmpty && !snippetPopoverDismissed,
                           let first = filteredSnippets.first {
                            insertSnippet(first)
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(keys: [.escape], phases: .down) { _ in
                        guard !filteredSnippets.isEmpty && !snippetPopoverDismissed else { return .ignored }
                        snippetPopoverDismissed = true
                        return .handled
                    }
                    .onSubmit(submit)
            }

            sendOrStopButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Color.kiwiMangoComposerBg)
        .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4, active: composerFocused)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var sendOrStopButton: some View {
        Button {
            if chatState.isStreaming {
                chatState.cancel()
            } else {
                submit()
            }
        } label: {
            Text(chatState.isStreaming ? "[STOP]" : "[SEND]")
                .font(KiwiMangoFont.mono(11, weight: .bold))
                .foregroundStyle(Color.kiwiMangoAccentText)
                .frame(height: 30)
                .padding(.horizontal, 10)
                .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!chatState.isStreaming && !canSend)
        .opacity((!chatState.isStreaming && !canSend) ? 0.4 : 1)
        .shadow(color: Color.kiwiMangoAccent.opacity(sendButtonHovered ? 0.7 : 0), radius: sendButtonHovered ? 10 : 0)
        .onHover { sendButtonHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: sendButtonHovered)
        .help(chatState.isStreaming ? "Zatrzymaj" : "Wyślij")
        .animation(.default, value: chatState.isStreaming)
    }

    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chatState.attachedImages) { attachment in
                    AttachmentThumb(attachment: attachment) {
                        chatState.removeAttachment(attachment.id)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Actions

    /// Fala 17: images don't go to Claude in v1 (vision stays on Ollama) —
    /// block sending rather than silently dropping the attachment.
    private var claudeImageBlock: Bool {
        isClaudeModelSelected && !chatState.attachedImages.isEmpty
    }

    private var canSend: Bool {
        guard !claudeImageBlock else { return false }
        return !chatState.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !chatState.attachedImages.isEmpty
    }

    private func submit() {
        guard !chatState.isStreaming, canSend else { return }
        let state = chatState
        Task { await state.send() }
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .symbolEffect(.pulse, isActive: speech.isRecording)
        }
        .buttonStyle(.plain)
        .foregroundStyle(speech.isRecording ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary.opacity(0.72))
        .help(speech.isRecording ? "Zatrzymaj dyktowanie" : "Dyktuj wiadomość")
        .onChange(of: speech.transcript) {
            let separator = draftBeforeDictation.isEmpty ? "" : " "
            chatState.draft = draftBeforeDictation + separator + speech.transcript
        }
        .alert("Brak dostępu do mikrofonu/rozpoznawania mowy", isPresented: Binding(
            get: { speech.authorizationDenied },
            set: { _ in }
        )) {
            Button("OK") {}
        } message: {
            Text("Włącz w Ustawieniach systemowych → Prywatność i bezpieczeństwo → Mikrofon / Rozpoznawanie mowy.")
        }
    }

    private var ttsToggleButton: some View {
        Button {
            ttsEnabled.toggle()
            if !ttsEnabled {
                chatState.speechSynthesizer.stopAll()
            }
        } label: {
            Image(systemName: ttsEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(ttsEnabled ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary.opacity(0.72))
        .help(ttsEnabled ? "Wyłącz czytanie odpowiedzi" : "Czytaj odpowiedzi na głos")
    }

    /// Fala 17: Claude has its own tools + fresher knowledge — the Ollama-side
    /// web search plumbing (F14) doesn't apply, so the toggle is disabled
    /// rather than silently ignored.
    private var isClaudeModelSelected: Bool {
        ClaudeCodeService.parseModelID(chatState.selectedModel) != nil
    }

    /// Fala 22 (F22.2): Hermes also has its own tools/context (own agent
    /// loop) — the Ollama-side web search plumbing doesn't apply to it either,
    /// same reasoning as `isClaudeModelSelected`.
    private var isHermesModelSelected: Bool {
        HermesChatService.parseModelID(chatState.selectedModel) != nil
    }

    private var webSearchToggleButton: some View {
        Button {
            // F14.2 pt. 2: no key yet → open the manager instead of silently
            // flipping a toggle that would do nothing.
            if !webSearchEnabled, webSearchKey.trimmingCharacters(in: .whitespaces).isEmpty {
                chatState.showingModelManager = true
                return
            }
            webSearchEnabled.toggle()
        } label: {
            Text("[WEB]")
                .font(KiwiMangoFont.mono(11, weight: .bold))
                .frame(height: 26)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isClaudeModelSelected || isHermesModelSelected)
        .foregroundStyle(
            (isClaudeModelSelected || isHermesModelSelected)
                ? Color.kiwiMangoTextPrimary.opacity(0.3)
                : (webSearchEnabled ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary.opacity(0.72))
        )
        .help(
            (isClaudeModelSelected || isHermesModelSelected)
                ? "Ten model ma własne narzędzia i świeżą wiedzę"
                : (webSearchEnabled ? "Wyłącz internet" : "Model korzysta z internetu")
        )
    }

    private var voiceLoopButton: some View {
        Button {
            voiceLoop?.start()
        } label: {
            Text("[ROZMOWA]")
                .font(KiwiMangoFont.mono(10.5, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .neonBorder(Color.kiwiMangoPurple, cornerRadius: 3)
        }
        .buttonStyle(.plain)
        .help("Tryb rozmowy głosowej — mówisz, kiwiMango odpowiada głosem")
    }

    private func toggleDictation() {
        if speech.isRecording {
            speech.stop()
        } else {
            draftBeforeDictation = chatState.draft
            let recognizer = speech
            Task { await recognizer.start() }
        }
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Wybierz obrazy do załączenia"
        panel.prompt = "Załącz"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            chatState.addAttachment(data: data)
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let state = chatState
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url,
                          let type = UTType(filenameExtension: url.pathExtension),
                          type.conforms(to: .image),
                          let data = try? Data(contentsOf: url)
                    else { return }
                    Task { @MainActor in state.addAttachment(data: data) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                accepted = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in state.addAttachment(data: data) }
                }
            }
        }
        return accepted
    }

    @ViewBuilder
    private var dropTargetOverlay: some View {
        if isDropTargeted {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(10)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - MessageBubble

/// One transcript row. User = right-aligned with `.quaternary` bubble (content layer,
/// no glass); assistant = left-aligned, no background.
private struct MessageBubble: View {
    let message: ChatMessage
    var isLastAssistant: Bool = false
    var isStreamingReply: Bool = false
    var onRegenerate: () -> Void = {}
    var onToast: (String) -> Void = { _ in }

    @Environment(ChatState.self) private var chatState
    @State private var isHovered = false
    @State private var cursorVisible = true

    private var isUser: Bool { message.role == .user }

    /// Hermes reasoning (F22.5, Paweł: "chcę widzieć proces myślowy, jak w
    /// terminalu") is stripped out HERE, before `KiwiCardParser`/`MarkdownText`
    /// ever see the text — routing it through the generic ```-fence code-block
    /// pipeline (`CodeBlockView`'s per-line `ScrollView`) rendered visually
    /// blank for reasons that didn't reproduce outside that exact view (content
    /// verified correct via clipboard + DB dump; only the ScrollView rows
    /// stayed empty). A dedicated plain `Text` below sidesteps that entirely.
    private var reasoningAndContent: (reasoning: String?, content: String) {
        let fence = "```reasoning\n"
        guard let openRange = message.content.range(of: fence) else {
            return (nil, message.content)
        }
        let afterOpen = String(message.content[openRange.upperBound...])
        guard let closeRange = afterOpen.range(of: "\n```") else {
            return (nil, message.content)
        }
        let reasoning = String(afterOpen[..<closeRange.lowerBound])
        let suffix = String(afterOpen[closeRange.upperBound...])
        let prefix = String(message.content[..<openRange.lowerBound])
        let cleaned = (prefix + suffix).trimmingCharacters(in: .whitespacesAndNewlines)
        return (reasoning.isEmpty ? nil : reasoning, cleaned)
    }

    private var cardAndText: (card: KiwiCard?, text: String) {
        KiwiCardParser.extract(from: reasoningAndContent.content)
    }
    private var card: KiwiCard? { cardAndText.card }
    private var renderedText: String { cardAndText.text }

    var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 48) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if !isUser {
                    Text(modelPrefixLine)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                }
                if !isUser, let reasoning = reasoningAndContent.reasoning {
                    reasoningBlock(reasoning)
                }
                if !isUser, let thinking = message.gatewayThinking, !thinking.isEmpty {
                    gatewayThinkingBlock(thinking)
                }
                if !isUser, !message.gatewayToolLines.isEmpty {
                    gatewayToolLinesBlock(message.gatewayToolLines)
                }
                if !isUser {
                    ForEach(Array(message.gatewayDiffs.enumerated()), id: \.offset) { _, diff in
                        gatewayDiffBlock(diff)
                    }
                }
                if !isUser, message.backgroundSubagentCount > 0 {
                    gatewayBackgroundSubagentsBar(count: message.backgroundSubagentCount)
                }
                if !isUser, let approval = message.pendingApproval {
                    gatewayApprovalBlock(approval)
                }
                if !isUser, let clarify = message.pendingClarify {
                    gatewayClarifyBlock(clarify)
                }
                if !message.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                            BubbleImage(data: data)
                        }
                    }
                }
                if !message.content.isEmpty {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 10) {
                        if !isUser, let card {
                            KiwiCardView(card: card)
                                .frame(maxWidth: 420, alignment: .leading)
                        }
                        if isUser {
                            Text(renderedText)
                                .font(KiwiMangoFont.sans(13, weight: .medium))
                                .foregroundStyle(Color.kiwiMangoTextPrimary)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.kiwiMangoPurple.opacity(0.10), in: UserBubbleShape())
                                .overlay(
                                    UserBubbleShape()
                                        .stroke(Color.kiwiMangoPurple.opacity(0.65), lineWidth: 1)
                                )
                                .shadow(color: Color.kiwiMangoPurple.opacity(0.3), radius: 8)
                                .modifier(HoloTilt(isActive: !isStreamingReply))
                        } else {
                            HStack(alignment: .bottom, spacing: 0) {
                                MarkdownText(content: renderedText)
                                if isStreamingReply {
                                    Text("▌")
                                        .font(KiwiMangoFont.mono(13))
                                        .foregroundStyle(Color.kiwiMangoAccent)
                                        .opacity(cursorVisible ? 1 : 0)
                                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: cursorVisible)
                                        .onAppear { cursorVisible = false }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.kiwiMangoAccent.opacity(0.05), in: AssistantBubbleShape())
                            .overlay(
                                AssistantBubbleShape()
                                    .stroke(Color.kiwiMangoAccent.opacity(0.45), lineWidth: 1)
                            )
                            .shadow(color: Color.kiwiMangoAccent.opacity(0.18), radius: 8)
                            .modifier(HoloTilt(isActive: !isStreamingReply))
                        }
                    }
                }
                if let statsLine = message.statsLine {
                    Text(statsLine)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.63))
                }
                if !message.content.isEmpty {
                    hoverActions
                }
            }
            .materializeIn(isActive: chatState.lastAnimatedMessageID == message.id) {
                if chatState.lastAnimatedMessageID == message.id {
                    chatState.lastAnimatedMessageID = nil
                }
            }

            if !isUser { Spacer(minLength: 48) }
        }
        .onHover { isHovered = $0 }
    }

    private var modelPrefixLine: String {
        let name = chatState.selectedModel.split(separator: "/").last.map(String.init) ?? chatState.selectedModel
        let isCloud = chatState.availableModels.first { $0.name == chatState.selectedModel }?.isCloud ?? false
        return "\(name)@\(isCloud ? "Cloud" : "Local")>"
    }

    /// Plain `Text` (no `ScrollView`/per-line `ForEach`, unlike `CodeBlockView`)
    /// — same visual styling, deliberately simpler rendering path.
    private func reasoningBlock(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REASONING")
                .font(KiwiMangoFont.mono(10, weight: .medium))
                .foregroundStyle(Color.kiwiMangoPurple.opacity(0.8))
            Text(reasoning)
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.75))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color(hex: "050507"))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.kiwiMangoPurple.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Hermes gateway blocks (Fala 24)

    /// "MYŚLI…" — Fala 24.5: expanded by DEFAULT while a turn streams
    /// (`ChatMessage.gatewayThinkingExpanded` starts `true`, so reasoning is
    /// visible live per Paweł's "nie pokazuje na żywo" complaint), collapsed
    /// by `ChatState.finishHermesTurn` once the turn completes so history
    /// stays uncluttered. Toggle state lives on the MODEL (not local
    /// `@State`) and is mutated via `chatState.toggleGatewayThinking` — a
    /// plain `Button`, not `DisclosureGroup` (that one's default macOS style
    /// turned out NOT clickable in this view hierarchy, verified live in F24.2).
    private func gatewayThinkingBlock(_ thinking: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                chatState.toggleGatewayThinking(on: message.id)
            } label: {
                HStack(spacing: 4) {
                    Text(message.gatewayThinkingExpanded ? "▾" : "▸")
                    Text("MYŚLI…")
                }
                .font(KiwiMangoFont.mono(10, weight: .medium))
                .foregroundStyle(Color.kiwiMangoPurple.opacity(0.8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if message.gatewayThinkingExpanded {
                Text(thinking)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color(hex: "050507"))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.kiwiMangoPurple.opacity(0.3), lineWidth: 1)
        )
    }

    /// Live `tool.start`/`tool.complete`/`subagent.*` status lines, PO
    /// POLSKU — subagent lines already carry a "  ↳" indent prefix from
    /// `ChatState.handleHermesEvent`.
    private func gatewayToolLinesBlock(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoAccent.opacity(0.75))
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    /// F26.4: unified diff from a `write_file`/`patch` tool call — one block per
    /// edited file. No horizontal ScrollView (F26.3 found it renders at zero
    /// width nested inside the transcript's vertical one on this macOS build);
    /// long lines wrap instead.
    private func gatewayDiffBlock(_ diff: String) -> some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fileLabel = lines.first(where: { $0.hasPrefix("+++ ") }).map { String($0.dropFirst(4)) }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(fileLabel ?? "DIFF")
                    .font(KiwiMangoFont.mono(10, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoPurple.opacity(0.8))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Rectangle()
                .fill(Color.kiwiMangoAccent.opacity(0.15))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    diffLineView(line)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color(hex: "050507"))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.kiwiMangoAccent.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func diffLineView(_ line: String) -> some View {
        let font = KiwiMangoFont.mono(11)
        if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
            Text(line).font(font).foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
        } else if line.hasPrefix("@@") {
            Text(line).font(font).foregroundStyle(Color.kiwiMangoPurple.opacity(0.8))
        } else if line.hasPrefix("+") {
            Text(line).font(font).foregroundStyle(Color.kiwiMangoAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.kiwiMangoAccent.opacity(0.08))
        } else if line.hasPrefix("-") {
            Text(line).font(font).foregroundStyle(Color.kiwiMangoDanger)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.kiwiMangoDanger.opacity(0.08))
        } else {
            Text(line.isEmpty ? " " : line).font(font).foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }

    /// Fala 24.6: shown under a bubble whose turn already completed but
    /// which delegated subagents still running in the background — survives
    /// past `message.complete` and past conversation switches (reattached by
    /// `ChatState.reconcileHermesLiveAssistantIDs` on reselect).
    private func gatewayBackgroundSubagentsBar(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("⏳")
            Text("subagenci pracują w tle… [\(count)]")
        }
        .font(KiwiMangoFont.mono(10.5, weight: .medium))
        .foregroundStyle(Color.kiwiMangoPurple.opacity(0.85))
    }

    private func gatewayApprovalBlock(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⚠ HERMES CHCE WYKONAĆ KOMENDĘ")
                .font(KiwiMangoFont.mono(10, weight: .bold))
                .foregroundStyle(Color.kiwiMangoDanger)
            if let command = approval.command {
                Text(command)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .textSelection(.enabled)
            }
            if let description = approval.description, !description.isEmpty {
                Text(description)
                    .font(KiwiMangoFont.mono(10))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
            }
            HStack(spacing: 10) {
                Button("ZATWIERDŹ") { chatState.respondApproval(approve: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kiwiMangoAccent)
                Button("ODRZUĆ") { chatState.respondApproval(approve: false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kiwiMangoDanger)
            }
            .font(KiwiMangoFont.mono(11, weight: .bold))
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.kiwiMangoDanger.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.kiwiMangoDanger.opacity(0.5), lineWidth: 1)
        )
    }

    private func gatewayClarifyBlock(_ clarify: PendingClarify) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(clarify.question)
                .font(KiwiMangoFont.mono(11, weight: .medium))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            if clarify.choices.isEmpty {
                ClarifyTextField { answer in chatState.respondClarify(answer: answer) }
            } else {
                HStack(spacing: 8) {
                    ForEach(clarify.choices, id: \.self) { choice in
                        Button(choice) { chatState.respondClarify(answer: choice) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.kiwiMangoAccent)
                    }
                }
                .font(KiwiMangoFont.mono(11, weight: .bold))
            }
        }
        .padding(10)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color.kiwiMangoPurple.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.kiwiMangoPurple.opacity(0.4), lineWidth: 1)
        )
    }

    private var hoverActions: some View {
        HStack(spacing: 10) {
            Button(action: copyContent) {
                Label("kopiuj", systemImage: "doc.on.doc")
            }
            .buttonStyle(HoverActionButtonStyle())

            if isLastAssistant {
                Button(action: onRegenerate) {
                    Label("regeneruj", systemImage: "arrow.clockwise")
                }
                .buttonStyle(HoverActionButtonStyle())
            }

            if !isUser {
                Button(action: readAloud) {
                    Label("przeczytaj", systemImage: "speaker.wave.2")
                }
                .buttonStyle(HoverActionButtonStyle())

                Button(action: sendToObsidian) {
                    Label("→ Obsidian", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(HoverActionButtonStyle())
            }
        }
        .frame(height: 20)
        .opacity(isHovered ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }

    private func copyContent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func sendToObsidian() {
        if chatState.sendMessageToObsidian(content: message.content) != nil {
            onToast("Zapisano w Obsidian ✓")
        }
    }

    private func readAloud() {
        chatState.readMessageAloud(message.content)
    }
}

// MARK: - ClarifyTextField (Fala 24)

/// Free-text answer field for `clarify.request` when the server offers no
/// fixed `choices` — Enter submits, mirrors the composer's plain-text feel.
private struct ClarifyTextField: View {
    let onSubmit: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField("odpowiedz…", text: $text)
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.mono(11))
                .onSubmit(submit)
            Button("WYŚLIJ", action: submit)
                .buttonStyle(.plain)
                .foregroundStyle(Color.kiwiMangoAccent)
                .font(KiwiMangoFont.mono(11, weight: .bold))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        text = ""
    }
}

// MARK: - HoloTilt (F9.5)

/// Subtle hologram-style tilt following the cursor — max ±7°, only on the
/// bubble under the mouse. `isActive` is `false` while a reply is still
/// streaming/growing, so the tilt transform doesn't fight the relayout.
private struct HoloTilt: ViewModifier {
    let isActive: Bool

    @State private var hover: CGPoint?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
            .rotation3DEffect(
                .degrees(tiltX),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.3
            )
            .rotation3DEffect(
                .degrees(tiltY),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center,
                perspective: 0.3
            )
            .animation(.interactiveSpring(response: 0.25), value: hover)
            .onContinuousHover { phase in
                guard isActive else { hover = nil; return }
                switch phase {
                case .active(let location): hover = location
                case .ended: hover = nil
                }
            }
    }

    private var tiltX: Double {
        guard let hover, size.width > 0 else { return 0 }
        return (hover.x / size.width - 0.5) * 7
    }

    private var tiltY: Double {
        guard let hover, size.height > 0 else { return 0 }
        return -(hover.y / size.height - 0.5) * 5
    }
}

// MARK: - HoverActionButtonStyle

private struct HoverActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(KiwiMangoFont.mono(10))
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(configuration.isPressed ? 0.9 : 0.5))
    }
}

// MARK: - BubbleImage

/// Decodes a thumbnail once per image (kept in @State across streaming re-renders).
private struct BubbleImage: View {
    let data: Data
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: data) {
            image = ChatImage.thumbnail(from: data, maxSide: 192)
        }
    }
}

// MARK: - AttachmentThumb

/// Composer attachment preview with a remove (✕) button.
private struct AttachmentThumb: View {
    let attachment: AttachedImage
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail = attachment.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .background(Circle().fill(.thickMaterial))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Usuń załącznik")
        }
    }
}
