import SwiftUI

// MARK: - AgentRow

/// One agent session row in the "AGENCI" sidebar section: status dot,
/// title, elapsed time, close button on hover.
struct AgentRow: View {
    let session: AgentSession
    let isActive: Bool
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var confirmingClose = false
    @State private var now = Date()

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? Color.kiwiMangoPurple : Color.clear)
                .frame(width: 3)
                .shadow(color: isActive ? Color.kiwiMangoPurple.opacity(0.6) : .clear, radius: 4)

            HStack(spacing: 8) {
                statusDot

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(KiwiMangoFont.mono(12, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(
                            isActive ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.85)
                        )
                        .lineLimit(1)
                    Text(elapsed)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 7)

            Spacer(minLength: 0)

            if isHovered {
                Button {
                    if session.status == .running {
                        confirmingClose = true
                    } else {
                        onClose()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help("Zamknij agenta")
            }
        }
        .background(
            isActive
                ? AnyShapeStyle(Color.kiwiMangoAssistantBubble.opacity(0.55))
                : AnyShapeStyle(isHovered ? Color.white.opacity(0.04) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onReceive(ticker) { now = $0 }
        .confirmationDialog(
            "Agent nadal działa. Zamknąć sesję?",
            isPresented: $confirmingClose,
            titleVisibility: .visible
        ) {
            Button("Zamknij agenta", role: .destructive) { onClose() }
            Button("Anuluj", role: .cancel) {}
        }
    }

    private var statusDot: some View {
        Text("●")
            .font(.system(size: 8))
            .foregroundStyle(session.status == .running ? Color.kiwiMangoTextPrimary : Color.gray)
            .symbolEffect(.pulse, isActive: session.status == .running)
            .opacity(session.status == .running ? 1 : 0.5)
            .realBloom(strength: 1.6, radius: 2)
    }

    private var elapsed: String {
        let seconds = Int(now.timeIntervalSince(session.startedAt))
        let minutes = seconds / 60
        if minutes < 1 { return "przed chwilą" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz."
    }
}

// MARK: - AgentHistoryRow (Fala 13)

/// One archived session under the "HISTORIA" subheader: compact metadata only.
/// The saved transcript is now a summary, not a 2000-line terminal dump.
struct AgentHistoryRow: View {
    let record: AgentSessionRecord
    let isActive: Bool
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? Color.kiwiMangoPurple : Color.clear)
                .frame(width: 2)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(kindLabel) · \(shortModel)")
                        .font(KiwiMangoFont.sans(12, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(
                            isActive ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.85)
                        )
                        .lineLimit(1)

                    Text("\(folderName) · \(durationLabel)")
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                        .lineLimit(1)

                    Text(firstLine)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Text(relativeDate)
                    .font(KiwiMangoFont.mono(9))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help("Usuń z historii")
            }
        }
        .background(
            isActive
                ? AnyShapeStyle(Color.kiwiMangoAssistantBubble.opacity(0.55))
                : AnyShapeStyle(isHovered ? Color.white.opacity(0.04) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
    }

    private var kindLabel: String {
        AgentKind(rawValue: record.kind)?.shortName ?? record.kind
    }

    private var shortModel: String {
        record.model.split(separator: "/").last.map(String.init) ?? record.model
    }

    private var folderName: String {
        URL(fileURLWithPath: record.workDir).lastPathComponent
    }

    private var firstLine: String {
        record.transcript
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first { !$0.hasPrefix("[") && !$0.hasPrefix("▸") }
            ?? ""
    }

    private var durationLabel: String {
        let minutes = max(1, Int(record.endedAt.timeIntervalSince(record.startedAt) / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz."
    }

    private var relativeDate: String {
        let days = Calendar.current.dateComponents([.day], from: record.endedAt, to: Date()).day ?? 0
        if days > 7 {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = Locale(identifier: "pl_PL")
            return formatter.string(from: record.endedAt)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: record.endedAt, relativeTo: Date())
    }
}

// MARK: - NewAgentPopover

/// Minimalist bubble for spawning a new agent. Shown as a system popover
/// attached to the "NOWY HERMES" button; the chrome is left to the popover,
/// so this view is just the content.
/// ponytail: agent-kind picker removed 2026-07-11 — Hermes is the only
/// spawnable agent now (Paweł: "chce tylko hermes miec"). Kind selection
/// UI + Claude Pro model list deleted rather than hidden; AgentKind cases
/// stay in AgentManager so past sessions of other kinds still render.
struct NewAgentPopover: View {
    let onSpawn: (AgentKind, OllamaService.ModelInfo, URL) -> Void
    var onClose: () -> Void = {}

    @Environment(ChatState.self) private var chatState
    @AppStorage("kiwiMangoDefaultAgentModel") private var defaultAgentModel: String = ""
    @AppStorage("kiwiMangoDefaultAgentWorkDir") private var defaultAgentWorkDir: String = ""
    @AppStorage("agentLastWorkDir") private var lastWorkDirPath = ""
    @State private var workDirPath = ""
    @State private var preferredModel: String = ""

    private let selectedKind: AgentKind = .hermes

    /// Last-used model per kind, falling back to the global default.
    private var lastModelStorageKey: String { "agentLastModel_\(selectedKind.rawValue)" }
    private var resolvedDefaultModel: String {
        UserDefaults.standard.string(forKey: lastModelStorageKey)
            ?? defaultAgentModel
    }

    // ponytail: przeprojektowany dla czytelności (zadanie Pawła) — model
    // teraz TYLKO wybiera (nie spawnuje od razu), wyraźny przycisk startu
    // na dole. Większe fonty/odstępy, hover na wierszach modeli, szerszy
    // popover (300px zamiast 220px, było za ciasno).
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("NOWY HERMES")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.kiwiMangoTextPrimary)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Zamknij")
            }
            .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MODEL")
                        .kiwiSectionLabel()
                    ollamaModelList
                }

                Divider().overlay(Color.white.opacity(0.10))

                VStack(alignment: .leading, spacing: 8) {
                    Text("KATALOG ROBOCZY")
                        .kiwiSectionLabel()
                    HStack(spacing: 8) {
                        Text(displayWorkDir)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.75))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Wybierz…") { pickWorkDir() }
                            .font(.system(size: 11, weight: .medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.kiwiMangoAccent)
                    }
                }

                startButton
            }
        }
        .padding(18)
        .frame(width: 300)
        .background(Color.kiwiMangoPanelDeep)
        .onAppear {
            workDirPath = lastWorkDirPath.isEmpty
                ? (defaultAgentWorkDir.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Kazik").path : defaultAgentWorkDir)
                : lastWorkDirPath
            preferredModel = resolvedDefaultModel
            Task {
                await chatState.loadModels()
                await chatState.refreshClaudeAvailability()
            }
        }
    }

    private var displayWorkDir: String {
        workDirPath.isEmpty ? "~/Kazik" : workDirPath
    }

    /// Currently selected model, falling back to the first available one so
    /// the start button always has something to launch.
    private var selectedModel: OllamaService.ModelInfo? {
        chatState.availableModels.first { $0.name == preferredModel }
            ?? chatState.availableModels.first
    }

    @ViewBuilder
    private var startButton: some View {
        Button {
            guard let model = selectedModel else { return }
            let url = URL(fileURLWithPath: displayWorkDir)
            lastWorkDirPath = displayWorkDir
            UserDefaults.standard.set(model.name, forKey: lastModelStorageKey)
            onSpawn(selectedKind, model, url)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("Uruchom Hermesa")
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(Color.kiwiMangoAccentText)
            .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(selectedModel == nil)
        .opacity(selectedModel == nil ? 0.4 : 1)
    }

    @ViewBuilder
    private var ollamaModelList: some View {
        let local = chatState.availableModels.filter { !$0.isCloud }
        let cloud = chatState.availableModels.filter(\.isCloud)

        if local.isEmpty && cloud.isEmpty {
            Text("Brak modeli — Ollama offline?")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.kiwiMangoDanger)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !local.isEmpty {
                        sectionHeader("LOKALNE")
                        ForEach(local, id: \.name) { modelButton($0) }
                    }
                    if !cloud.isEmpty {
                        sectionHeader("CLOUD")
                            .padding(.top, local.isEmpty ? 0 : 8)
                        ForEach(cloud, id: \.name) { modelButton($0) }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.45))
    }

    private func modelButton(_ model: OllamaService.ModelInfo) -> some View {
        let selected = preferredModel == model.name || (preferredModel.isEmpty && chatState.availableModels.first?.name == model.name)
        return ModelRowButton(
            name: model.name,
            selected: selected,
            action: { preferredModel = model.name }
        )
    }

    private func pickWorkDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz katalog roboczy agenta"
        panel.prompt = "Wybierz"
        if !displayWorkDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: displayWorkDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workDirPath = url.path
        // runModal zamyka popover (transient) i niszczy jego @State —
        // bez natychmiastowego zapisu wybór ginie przed kliknięciem presetu.
        lastWorkDirPath = url.path
    }
}

/// One selectable model row in `NewAgentPopover` — hover highlight so the
/// list reads as clickable, not just a static log.
private struct ModelRowButton: View {
    let name: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                rowBackground,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(name)
    }

    private var rowBackground: Color {
        if selected { return Color.kiwiMangoAccent.opacity(0.14) }
        return hovering ? Color.white.opacity(0.06) : Color.clear
    }
}

// MARK: - AgentDetailView

/// Detail pane for `.agent(id)` selection: header (preset, model, cloud badge,
/// working dir) + the live terminal filling the rest of the space.
struct AgentDetailView: View {
    let session: AgentSession

    var body: some View {
        VStack(spacing: 0) {
            header
            TerminalHostView(terminal: session.terminal)
                .frame(minWidth: 380, minHeight: 420)
        }
        .background(Color.kiwiMangoSurface)
    }

    private var header: some View {
        HStack {
            Text("Agent: \(session.kind.displayName)")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            HStack(spacing: 4) {
                Text("⊕ \(session.model)")
                Text(session.isCloud ? "[Cloud]" : "[Local]")
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
            .font(KiwiMangoFont.mono(11, weight: .medium))
            .foregroundStyle(Color.kiwiMangoTextPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .neonBorder(Color.kiwiMangoTextPrimary, cornerRadius: 4)

            Spacer()

            Text(session.workDir.path)
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kiwiMangoTextPrimary.opacity(0.15)).frame(height: 1)
        }
    }
}

// MARK: - AgentTranscriptView (F13.4)

/// Read-only summary of a finished agent session. The archived text is already
/// compressed to start + tail; this view just renders it cleanly.
struct AgentTranscriptView: View {
    let record: AgentSessionRecord
    @Environment(ChatState.self) private var chatState
    @State private var toastMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Podsumowanie sesji")
                        .font(KiwiMangoFont.sans(13, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)

                    Text(record.transcript)
                        .font(KiwiMangoFont.mono(11))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color.kiwiMangoBackground)
        }
        .background(Color.kiwiMangoSurface)
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.callout)
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.kiwiMangoChrome, in: Capsule())
                    .padding(.bottom, 16)
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        self.toastMessage = nil
                    }
            }
        }
    }

    private var kindLabel: String {
        AgentKind(rawValue: record.kind)?.displayName ?? record.kind
    }

    private var durationLabel: String {
        let minutes = max(1, Int(record.endedAt.timeIntervalSince(record.startedAt) / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz. \(minutes % 60) min"
    }

    private var header: some View {
        HStack {
            Text("Agent: \(kindLabel)")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            HStack(spacing: 4) {
                Text("⊕ \(record.model)")
                Text(record.isCloud ? "[Cloud]" : "[Local]")
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
            .font(KiwiMangoFont.mono(11, weight: .medium))
            .foregroundStyle(Color.kiwiMangoTextPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .neonBorder(Color.kiwiMangoTextPrimary, cornerRadius: 4)

            Text(record.workDir)
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.head)

            Text("· \(durationLabel)")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))

            Spacer()

            Button("KOPIUJ CAŁOŚĆ") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.transcript, forType: .string)
                toastMessage = "Skopiowano ✓"
            }
            .font(KiwiMangoFont.mono(10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.kiwiMangoTextPrimary)

            Button("→ OBSIDIAN") {
                if chatState.sendAgentTranscriptToObsidian(title: "\(kindLabel) · \(URL(fileURLWithPath: record.workDir).lastPathComponent)", content: record.transcript) != nil {
                    toastMessage = "Zapisano w Obsidian ✓"
                }
            }
            .font(KiwiMangoFont.mono(10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.kiwiMangoTextPrimary)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kiwiMangoTextPrimary.opacity(0.15)).frame(height: 1)
        }
    }
}
