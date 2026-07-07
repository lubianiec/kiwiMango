import SwiftUI

// MARK: - RoomView

/// Sets up and displays a "Room" debate between two cloud models. See `RoomState`.
struct RoomView: View {
    @Environment(ChatState.self) private var chatState
    let room: RoomState

    @State private var modelA = ""
    @State private var modelB = ""
    @State private var personaAID: Int64?
    @State private var personaBID: Int64?
    @State private var topicDraft = ""
    @State private var turnLimit = 6
    @State private var toastMessage: String?

    private static let bottomAnchor = "room-bottom"

    private var cloudModels: [OllamaService.ModelInfo] {
        chatState.availableModels.filter(\.isCloud)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if room.hasStarted {
                transcriptView
            } else {
                setupView
            }
        }
        .kiwiMangoNoirBackground()
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.callout)
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.kiwiMangoChrome, in: Capsule())
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.toastMessage = nil }
                    }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            if room.hasStarted {
                Text("🤖 \(shortName(room.modelA)) vs \(shortName(room.modelB))")
                    .font(KiwiMangoFont.mono(12, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                Text("· \(room.topic)")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                    .lineLimit(1)
                Spacer()
                Text("\(room.currentTurnCount)/\(room.turnLimit)")
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoPurple)
                Button {
                    room.cancel()
                } label: {
                    Text("[⏹ STOP]")
                        .font(KiwiMangoFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
            } else {
                Text("🤖 POKÓJ AGENTÓW")
                    .font(KiwiMangoFont.mono(13, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccent)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kiwiMangoAccent.opacity(0.15)).frame(height: 1)
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if cloudModels.isEmpty {
                    Text("Brak modeli cloud — sprawdź połączenie z Ollama.")
                        .font(KiwiMangoFont.mono(11.5))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }

                modelPicker(title: "Model A", selection: $modelA)
                personaPicker(title: "Persona A", selection: $personaAID)
                modelPicker(title: "Model B", selection: $modelB)
                personaPicker(title: "Persona B", selection: $personaBID)

                VStack(alignment: .leading, spacing: 6) {
                    Text("TEMAT")
                        .font(KiwiMangoFont.mono(9.5, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                    TextField("O czym mają dyskutować?", text: $topicDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(KiwiMangoFont.mono(12.5))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(Color.kiwiMangoComposerBg)
                        .neonBorder(Color.kiwiMangoPurple, cornerRadius: 4)
                }

                HStack {
                    Text("LICZBA TUR")
                        .font(KiwiMangoFont.mono(9.5, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                    Stepper("\(turnLimit)", value: $turnLimit, in: 2...12)
                        .font(KiwiMangoFont.mono(11.5, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .fixedSize()
                }

                Button(action: startRoom) {
                    Text("[ START ROZMOWY ]")
                        .font(KiwiMangoFont.mono(12, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccentText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.kiwiMangoPurple, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .opacity(canStart ? 1 : 0.4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var canStart: Bool {
        !modelA.isEmpty && !modelB.isEmpty
            && !topicDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func modelPicker(title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(KiwiMangoFont.mono(9.5, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            Menu {
                ForEach(cloudModels, id: \.name) { model in
                    Button(model.name) { selection.wrappedValue = model.name }
                }
            } label: {
                Text(selection.wrappedValue.isEmpty ? "wybierz model cloud…" : selection.wrappedValue)
                    .font(KiwiMangoFont.mono(11.5))
                    .foregroundStyle(
                        selection.wrappedValue.isEmpty
                            ? Color.kiwiMangoTextPrimary.opacity(0.66)
                            : Color.kiwiMangoAccent
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func personaPicker(title: String, selection: Binding<Int64?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(KiwiMangoFont.mono(9.5, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            Menu {
                Button("Brak") { selection.wrappedValue = nil }
                ForEach(chatState.personas) { persona in
                    Button(persona.name) { selection.wrappedValue = persona.id }
                }
            } label: {
                Text(personaName(for: selection.wrappedValue))
                    .font(KiwiMangoFont.mono(11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func personaName(for id: Int64?) -> String {
        guard let id, let persona = chatState.personas.first(where: { $0.id == id }) else { return "brak persony" }
        return persona.name
    }

    private func startRoom() {
        guard canStart else { return }
        let personaA = personaAID.flatMap { id in chatState.personas.first { $0.id == id } }
        let personaB = personaBID.flatMap { id in chatState.personas.first { $0.id == id } }
        let thinking = Set(chatState.availableModels.filter(\.supportsThinking).map(\.name))
        room.start(
            modelA: modelA, modelB: modelB,
            personaA: personaA, personaB: personaB,
            topic: topicDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            turnLimit: turnLimit, thinkingModels: thinking
        )
    }

    // MARK: - Transcript

    private var transcriptView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(room.turns) { turn in
                            turnBubble(turn)
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(16)
                }
                .onChange(of: room.turns.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
                .onChange(of: room.turns.last?.text) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }

            if !room.isRunning && !room.turns.isEmpty {
                exportBar
            }
            injectBar
        }
    }

    private func turnBubble(_ turn: RoomState.Turn) -> some View {
        let isA = turn.speaker == .modelA
        let isPawel = turn.speaker == .pawel
        return HStack(spacing: 0) {
            if turn.speaker == .modelB { Spacer(minLength: 48) }

            VStack(alignment: isPawel ? .center : (isA ? .leading : .trailing), spacing: 6) {
                Text(prefixLabel(turn.speaker))
                    .font(KiwiMangoFont.mono(10))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))

                HStack(alignment: .bottom, spacing: 0) {
                    MarkdownText(content: turn.text)
                    if turn.isStreaming {
                        Text("▌")
                            .font(KiwiMangoFont.mono(13))
                            .foregroundStyle(isA ? Color.kiwiMangoAccent : Color.kiwiMangoPurple)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleFill(isPawel: isPawel, isA: isA), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(bubbleStroke(isPawel: isPawel, isA: isA), lineWidth: 1)
                )
            }

            if turn.speaker == .modelA { Spacer(minLength: 48) }
        }
    }

    private func bubbleFill(isPawel: Bool, isA: Bool) -> Color {
        if isPawel { return Color.white.opacity(0.06) }
        return isA ? Color.kiwiMangoAccent.opacity(0.06) : Color.kiwiMangoPurple.opacity(0.10)
    }

    private func bubbleStroke(isPawel: Bool, isA: Bool) -> Color {
        if isPawel { return Color.white.opacity(0.2) }
        return isA ? Color.kiwiMangoAccent.opacity(0.4) : Color.kiwiMangoPurple.opacity(0.5)
    }

    private func prefixLabel(_ speaker: RoomState.Speaker) -> String {
        switch speaker {
        case .modelA: return "\(shortName(room.modelA))>"
        case .modelB: return "\(shortName(room.modelB))>"
        case .pawel: return "Paweł>"
        }
    }

    private func shortName(_ model: String) -> String {
        model.split(separator: "/").last.map(String.init) ?? model
    }

    // MARK: - Interjection + export

    private var injectBar: some View {
        HStack {
            TextField("Wtrąć się…", text: injectBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.mono(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .lineLimit(1...4)
                .padding(8)
                .background(Color.kiwiMangoComposerBg)
                .neonBorder(Color.kiwiMangoPurple, cornerRadius: 4)
                .onSubmit(sendInjection)

            Button(action: sendInjection) {
                Text("[WYŚLIJ]")
                    .font(KiwiMangoFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccentText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(room.injectDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(Color.kiwiMangoChrome)
    }

    private var injectBinding: Binding<String> {
        Binding(get: { room.injectDraft }, set: { room.injectDraft = $0 })
    }

    private func sendInjection() {
        room.inject(room.injectDraft)
        room.injectDraft = ""
    }

    private var exportBar: some View {
        HStack(spacing: 14) {
            Button(action: exportToDownloads) {
                Text("[Eksportuj MD]")
                    .font(KiwiMangoFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.8))
            }
            .buttonStyle(.plain)

            Button(action: sendToObsidian) {
                Text("[→ Obsidian]")
                    .font(KiwiMangoFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.8))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func exportToDownloads() {
        let markdown = room.exportMarkdown()
        do {
            let downloads = try FileManager.default.url(
                for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            let base = "kiwiMango-pokoj-\(RoomState.fileSlug(room.topic))"
            let url = RoomState.uniqueFileURL(in: downloads, base: base)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            toastMessage = "Zapisano: \(url.lastPathComponent)"
        } catch {
            print("[KiwiMango] Failed to export room transcript: \(error)")
        }
    }

    private func sendToObsidian() {
        let markdown = room.exportMarkdown()
        do {
            let vault = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Kazik/ObsidianSync/00-Inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            let url = RoomState.uniqueFileURL(in: vault, base: RoomState.fileSlug(room.topic))
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            toastMessage = "Zapisano w Obsidian ✓"
        } catch {
            print("[KiwiMango] Failed to send room transcript to Obsidian: \(error)")
        }
    }
}
