import SwiftUI
import UniformTypeIdentifiers
import AppKit

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

    // MARK: PLAN-VOICE-V4 — natywny SFSpeechRecognizer (v3 był Grok STT beta,
    // wymieniony po powtarzających się bugach i braku klucza — patrz VoiceAgentService).
    // Dyktowanie transkrybuje PROSTO DO POLA TEKSTOWEGO — user czyta/poprawia/wysyła sam.
    @State private var voiceService = VoiceAgentService()
    /// Treść pola PRZED kliknięciem mikrofonu — SFSpeechRecognizer zwraca
    /// zawsze CAŁĄ dotychczasową wypowiedź (nie delty), więc doklejamy do tego
    /// punktu startowego zamiast append-ować kawałek po kawałku.
    @State private var dictationBaseDraft = ""

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
                },
                onAttach: presentAttachmentPicker,
                modelOptions: modelOptions,
                model: $session.model,
                reasoningOptions: Self.reasoningEffortOptions,
                reasoningEffort: reasoningEffortBinding,
                voiceState: voiceService.state,
                voiceLevel: voiceService.audioLevel,
                onDictate: handleDictateTap
            )
            // F4 (PLAN-OKNO): margines od krawędzi okna, żeby composer "pływał"
            // jako wyodrębniony obszar zamiast przyklejać się do ramki.
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .padding(.top, 2)
        .onAppear {
            // PLAN-VOICE-V4: SFSpeechRecognizer zwraca CAŁĄ wypowiedź na każdym
            // update (nie delty) — doklejamy do treści sprzed startu dyktowania.
            voiceService.onTranscript = { fullUtterance in
                session.draft = dictationBaseDraft.isEmpty ? fullUtterance : dictationBaseDraft + " " + fullUtterance
            }
        }
    }

    // MARK: PLAN-VOICE-V4 — dyktowanie

    private func handleDictateTap() {
        if voiceService.state == .idle {
            dictationBaseDraft = session.draft
        }
        voiceService.toggle()
    }

    // MARK: Drag & drop images

    /// Shared by drag&drop and the composer's "+" file picker (F1, PLAN-OKNO) —
    /// same attachment pipeline, two entry points.
    private func addAttachment(fromFileAt url: URL) {
        guard let fileData = try? Data(contentsOf: url) else { return }
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

    /// "+" button in the composer's controls row (F1, PLAN-OKNO) — a native
    /// file panel as a second, discoverable way in alongside drag&drop.
    private func presentAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Załącz"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            addAttachment(fromFileAt: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    Task { @MainActor in
                        addAttachment(fromFileAt: url)
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
            // F2 (PLAN-OKNO): trzy fałszywe kropki okna (czerwona/bursztynowa/
            // zielona) usunięte — duplikowały prawdziwe przyciski okna macOS
            // tuż nad nimi i czytały się jak błąd renderowania.
            Text(session.title)
                .font(KiwiMangoFont.mono(11, weight: .medium))
                .foregroundStyle(Color.ink.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            // Sam status sesji — „co się teraz dzieje" siedzi w wierszu AGENT.
            // Model/tryb myślenia przeniesione do rzędu kontrolek w Composer (F1,
            // PLAN-OKNO) — leżą teraz tuż pod polem tekstowym, jednym gestem oka
            // od miejsca gdzie się pisze, zamiast osobno nad strumieniem.
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
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

                    // Stała kotwica dna. Wcześniej przewijaliśmy do
                    // `items.last.id` — a wywołania narzędzi są renderowane
                    // GRUPAMI pod id pierwszego wywołania, więc gdy ostatnim
                    // itemem było drugie (albo dziesiąte) wywołanie w grupie,
                    // proxy.scrollTo dostawał id, którego nie ma w hierarchii,
                    // i po cichu nie robił nic. Kotwica istnieje zawsze.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .bottom) {
                if session.autoscrollPaused {
                    scrollNote
                }
            }
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: session.scrollPulse) { _, _ in
                scrollToBottom(proxy)
            }
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

    private static let bottomAnchor = "kiwi.transcript.bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !session.autoscrollPaused, !session.items.isEmpty else { return }
        // pułapka #6: give SwiftUI one cycle to lay out the new item before scrolling.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
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
                // Wskaźnik „co się teraz dzieje" usunięty — wiersze narzędzi
                // mówią to samo, dokładniej i po polsku. Zostaje sam kursor.
                Spacer(minLength: 8)
                if isStreaming { StreamingCursor() }
            }
            TerminalMarkdown(content: text, textColor: Color.txt.opacity(0.97), style: .agentProse)
        }
        .padding(.top, 9)
        .padding(.trailing, 18)
        .padding(.bottom, 15)
        // F3 (PLAN-OKNO): jedna oś dla obu mówców — było .padding(.leading, 40)
        // + pionowa kreska w .overlay (offset x: 19); teraz agent startuje z
        // tego samego lewego marginesu co użytkownik (14 pt), tło+belka po
        // stronie usera to jedyny wyróżnik mówcy.
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Nazwy narzędzi (po angielsku — decyzja Pawła 2026-08-08)
//
// Wiersz ma mówić CO SIĘ DZIEJE, a nie jak nazywa się funkcja w gatewayu.
// Lista pochodzi z realnych zapisów sesji (`~/Library/Application Support/
// KiwiMango/sessions`), nie ze zgadywania. Nieznane narzędzie pokazuje swoją
// surową nazwę — lepiej to niż zmyślony opis.
//
// Forma: gerund („Running command"), jak w terminalowych logach — te wiersze
// czyta się w locie, imiesłów niesie „trwa" bez dodatkowego słowa.

enum ToolLabel {
    private static let map: [String: String] = [
        "terminal": "Running command",
        "image_generate": "Generating image",
        "read_file": "Reading file",
        "skill_view": "Reading skill",
        "memory": "Recalling memory",
        "browser_navigate": "Opening page",
        "session_search": "Searching sessions",
        "search_files": "Searching files",
        "vision_analyze": "Analyzing image",
        "browser_console": "Reading page console",
        "cronjob": "Scheduling job",
        "patch": "Editing file",
        "write_file": "Writing file",
        "x_search": "Searching X",
        "web_search": "Searching web",
        "todo": "Updating task list",
        "process": "Managing process",
        "execute_code": "Running code",
        "browser_snapshot": "Capturing page",
        "video_generate": "Generating video",
        "project_list": "Listing projects",
        "web_extract": "Extracting page content",
        "computer_use": "Controlling computer",
        "xai_video_extend": "Extending video",
        "browser_vision": "Viewing page",
    ]

    static func text(_ rawName: String) -> String {
        map[rawName] ?? rawName
    }
}

// MARK: - Shimmer — przebieg światła po napisie, gdy narzędzie pracuje
//
// ponytail: brak natywnego shimmera na Text w SwiftUI, więc minimum:
// maska z tego samego napisu + jeden gradient przesuwany w pętli. Bez
// GeometryReadera nie da się trafić szerokością pasma w długość napisu.
// Reduce-motion obsługuje wywołanie wyżej (podmienia na zwykły Text).

private struct ShimmerLabel: View {
    let text: String
    let font: Font
    let base: Color

    /// Pełny przebieg smugi, w sekundach.
    private static let period: Double = 1.5

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(base)
            .overlay {
                // ponytail: faza liczona z zegara, NIE z withAnimation(.repeatForever).
                // Wiersz narzędzia przebudowuje się przy każdej aktualizacji ToolCall
                // (dopisany output, czas, koniec pracy) — przy każdej takiej
                // przebudowie SwiftUI przeliczał offset bez animacji i pętla ginęła
                // po pierwszym przebiegu. TimelineView jest na to odporny: nie ma
                // stanu do zgubienia, faza wynika z bieżącego czasu.
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let phase = (t.truncatingRemainder(dividingBy: Self.period)) / Self.period

                    GeometryReader { geo in
                        let w = geo.size.width
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: Color.accent, location: 0.5),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(w * 0.5, 34))
                        .offset(x: -w * 0.6 + phase * w * 1.7)
                    }
                }
                .mask { Text(text).font(font) }
                .allowsHitTesting(false)
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
                        Text("\(calls.count) actions")
                    }
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.ink.opacity(0.45))
                }
                .buttonStyle(.plain)
                .padding(.leading, 14)
                .padding(.trailing, 18)
                .padding(.vertical, 3)

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    // ponytail: ToolCall (ConversationModels.swift, out of this task's file
    // scope) has no isError/isSuccess flag — this reads the rendered strings
    // instead. Good enough for the two states the mockup calls out (red tool
    // name on error, green "Build complete"); promote to a real field on
    // ToolCall next time that file is touched if this heuristic misfires.
    private var isErrorOutput: Bool {
        call.output.localizedCaseInsensitiveContains("error")
    }

    private var outputColor: Color {
        guard !isErrorOutput else { return Color.ink.opacity(0.42) }
        if call.name.localizedCaseInsensitiveContains("build") { return Color.green }
        return Color.ink.opacity(0.42)
    }

    /// Znacznik stanu zamiast `⎿`: kolor niesie informację, nie ozdobę.
    /// Bursztyn = trwa, czerwony = błąd, przygaszony = zrobione.
    private var stateColor: Color {
        if call.isRunning { return Color.accent }
        return isErrorOutput ? Color.danger : Color.ink.opacity(0.3)
    }

    /// Druga linia: czas i szczegół wywołania, rozdzielone kropką.
    private var metaLine: String {
        var parts: [String] = []
        if call.isRunning {
            parts.append("running…")
        } else if let seconds = call.seconds {
            // Kropka dziesiętna, nie przecinek — wiersz jest po angielsku.
            parts.append(String(format: "%.1f s", seconds))
        }
        // Tylda = szacunek z tekstu, nie odczyt z modelu (patrz TokenEstimate).
        // Brak liczby (stara sesja / pusty krok) → człon w ogóle się nie pojawia.
        if let tokens = call.tokens, tokens > 0 {
            parts.append("~\(TokenEstimate.formatStep(tokens)) tok")
        }
        if !call.argument.isEmpty { parts.append(call.argument) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if !call.output.isEmpty { call.isExpanded.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // Linia 1 — CO się dzieje, po polsku. Najjaśniejszy tekst wiersza.
                    HStack(spacing: 6) {
                        if call.isRunning && !reduceMotion {
                            ShimmerLabel(
                                text: ToolLabel.text(call.name),
                                font: KiwiMangoFont.mono(12),
                                base: Color.txt.opacity(0.6)
                            )
                        } else {
                            Text(ToolLabel.text(call.name))
                                .font(KiwiMangoFont.mono(12))
                                .foregroundStyle(isErrorOutput ? Color.danger : Color.txt.opacity(0.85))
                        }
                        if !call.output.isEmpty {
                            Text("›")
                                .font(KiwiMangoFont.mono(11))
                                .foregroundStyle(Color.ink.opacity(0.3))
                                .rotationEffect(.degrees(call.isExpanded ? 90 : 0))
                        }
                    }

                    // Linia 2 — metadane, przygaszone. Gwiazdka niesie stan kolorem
                    // i (gdy coś trwa) delikatnym pulsem.
                    HStack(spacing: 7) {
                        Text("✳")
                            .foregroundStyle(stateColor)
                            .opacity(dimmed ? 0.4 : 1)
                        Text(metaLine)
                            .foregroundStyle(Color.ink.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .monospacedDigit()
                    }
                    .font(KiwiMangoFont.mono(10))
                }
            }
            .buttonStyle(.plain)
            .onAppear {
                guard call.isRunning, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
            .onChange(of: call.isRunning) { _, running in
                // ponytail: repeatForever musi zostać zdjęte jawnie — bez tego
                // skończone wywołanie pulsuje w nieskończoność.
                guard !running else { return }
                withAnimation(.easeOut(duration: 0.25)) { dimmed = false }
            }

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
        // Ta sama oś 14 pt co wiadomości — koniec z wcięciem i rynną.
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 4)
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
