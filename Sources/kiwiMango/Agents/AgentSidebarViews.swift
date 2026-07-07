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
                .frame(width: 2)
                .shadow(color: isActive ? Color.kiwiMangoPurple.opacity(0.6) : .clear, radius: 4)

            HStack(spacing: 8) {
                statusDot

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(KiwiMangoFont.mono(12, weight: isActive ? .bold : .medium))
                        .foregroundStyle(
                            isActive ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.8)
                        )
                        .lineLimit(1)
                    Text(elapsed)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
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
                ? AnyShapeStyle(LinearGradient(
                    colors: [Color.kiwiMangoPurple.opacity(0.30), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                : AnyShapeStyle(isHovered ? Color.white.opacity(0.04) : Color.clear)
        )
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
            .foregroundStyle(session.status == .running ? Color.kiwiMangoAccent : Color.gray)
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

/// One archived session row under the "HISTORIA" subheader — grey dot (never
/// running, it's history), title + folder, relative date + duration.
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
                Text("●")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.gray.opacity(0.6))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(kindLabel) · \(folderName)")
                        .font(KiwiMangoFont.mono(11.5, weight: isActive ? .bold : .medium))
                        .foregroundStyle(
                            isActive ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.8)
                        )
                        .lineLimit(1)
                    Text("\(relativeDate) · \(durationLabel)")
                        .font(KiwiMangoFont.mono(9.5))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 6)

            Spacer(minLength: 0)

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
        .background(isHovered ? Color.white.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
    }

    /// Falls back to the raw string if a future enum change makes `rawValue`
    /// stop matching (PLAN.md F13.5 pitfall #4).
    private var kindLabel: String {
        AgentKind(rawValue: record.kind)?.shortName ?? record.kind
    }

    private var folderName: String {
        URL(fileURLWithPath: record.workDir).lastPathComponent
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

/// Popover opened from "+ NOWY_AGENT" (sidebar) or ⌘T: pick one of the
/// installed Ollama models (same source as the sidebar MODELE section),
/// pick a working directory, spawn.
struct NewAgentPopover: View {
    let onSpawn: (AgentKind, OllamaService.ModelInfo, URL) -> Void

    @Environment(ChatState.self) private var chatState
    @AppStorage("agentLastWorkDir") private var lastWorkDirPath = ""
    @AppStorage("agentLastKind") private var lastKindRaw = AgentKind.claude.rawValue
    @State private var workDirPath = ""

    private var selectedKind: AgentKind {
        AgentKind(rawValue: lastKindRaw) ?? .claude
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOWY AGENT")
                .font(KiwiMangoFont.mono(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))

            kindPicker

            Text("MODEL")
                .font(KiwiMangoFont.mono(9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))

            modelList

            Divider().overlay(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 6) {
                Text("KATALOG ROBOCZY")
                    .font(KiwiMangoFont.mono(9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
                HStack(spacing: 6) {
                    Text(displayWorkDir)
                        .font(KiwiMangoFont.mono(10.5))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Wybierz…") { pickWorkDir() }
                        .font(KiwiMangoFont.mono(10))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.kiwiMangoPurple)
                }
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(Color.kiwiMangoChrome)
        .onAppear {
            workDirPath = lastWorkDirPath.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Kazik").path
                : lastWorkDirPath
        }
    }

    private var displayWorkDir: String {
        workDirPath.isEmpty ? "~/Kazik" : workDirPath
    }

    /// `.claudePro` only shows up once `claude` is confirmed present + logged
    /// in — hidden entirely rather than greyed out (no point advertising an
    /// option that can't work yet).
    private var visibleKinds: [AgentKind] {
        AgentKind.allCases.filter { $0 != .claudePro || chatState.claudeAvailable }
    }

    private var kindPicker: some View {
        HStack(spacing: 6) {
            ForEach(visibleKinds) { kind in
                Button {
                    lastKindRaw = kind.rawValue
                } label: {
                    Text(kind.displayName)
                        .font(KiwiMangoFont.mono(10, weight: .bold))
                        .foregroundStyle(
                            selectedKind == kind
                                ? Color.kiwiMangoAccent
                                : Color.kiwiMangoTextPrimary.opacity(0.72)
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .neonBorder(
                            selectedKind == kind ? Color.kiwiMangoAccent : Color.white.opacity(0.25),
                            cornerRadius: 2,
                            active: selectedKind == kind
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var modelList: some View {
        if selectedKind == .claudePro {
            claudeProModelList
        } else {
            ollamaModelList
        }
    }

    /// Claude Pro doesn't pick from the Ollama model list — just Sonnet/Opus.
    private var claudeProModelList: some View {
        VStack(alignment: .leading, spacing: 4) {
            claudeProModelButton(id: "claude:sonnet", label: "Sonnet")
            claudeProModelButton(id: "claude:opus", label: "Opus")
        }
    }

    private func claudeProModelButton(id: String, label: String) -> some View {
        Button {
            let url = URL(fileURLWithPath: displayWorkDir)
            lastWorkDirPath = displayWorkDir
            let model = OllamaService.ModelInfo(name: id, capabilities: [], size: 0, isCloud: true)
            onSpawn(selectedKind, model, url)
        } label: {
            Text(label)
                .font(KiwiMangoFont.mono(11, weight: .medium))
                .foregroundStyle(Color.kiwiMangoAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .neonBorder(Color.kiwiMangoAccent, cornerRadius: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    @ViewBuilder
    private var ollamaModelList: some View {
        let local = chatState.availableModels.filter { !$0.isCloud }
        let cloud = chatState.availableModels.filter(\.isCloud)

        if local.isEmpty && cloud.isEmpty {
            Text("Brak modeli — Ollama offline?")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoDanger)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if !local.isEmpty {
                        sectionHeader("💻 LOKALNE")
                        ForEach(local, id: \.name) { modelButton($0) }
                    }
                    if !cloud.isEmpty {
                        sectionHeader("☁️ CLOUD")
                            .padding(.top, local.isEmpty ? 0 : 6)
                        ForEach(cloud, id: \.name) { modelButton($0) }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(KiwiMangoFont.mono(9, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.63))
    }

    private func modelButton(_ model: OllamaService.ModelInfo) -> some View {
        Button {
            let url = URL(fileURLWithPath: displayWorkDir)
            lastWorkDirPath = displayWorkDir
            onSpawn(selectedKind, model, url)
        } label: {
            Text(model.name)
                .font(KiwiMangoFont.mono(11, weight: .medium))
                .foregroundStyle(Color.kiwiMangoAccent)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .neonBorder(Color.kiwiMangoAccent, cornerRadius: 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.name)
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
                    .foregroundStyle(Color.kiwiMangoPurple)
            }
            .font(KiwiMangoFont.mono(11, weight: .medium))
            .foregroundStyle(Color.kiwiMangoAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4)

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
            Rectangle().fill(Color.kiwiMangoAccent.opacity(0.15)).frame(height: 1)
        }
    }
}

// MARK: - AgentTranscriptView (F13.4)

/// Read-only view of an archived session's transcript. No editing, no
/// "resume" — the PTY is gone, and pretending otherwise would be dishonest
/// (PLAN.md F13.4 pt. 3).
struct AgentTranscriptView: View {
    let record: AgentSessionRecord
    @Environment(ChatState.self) private var chatState
    @State private var toastMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Text(record.transcript)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(hex: "050507"))
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
                    .foregroundStyle(Color.kiwiMangoPurple)
            }
            .font(KiwiMangoFont.mono(11, weight: .medium))
            .foregroundStyle(Color.kiwiMangoAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .neonBorder(Color.kiwiMangoAccent, cornerRadius: 4)

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
            .foregroundStyle(Color.kiwiMangoAccent)

            Button("→ OBSIDIAN") {
                if chatState.sendAgentTranscriptToObsidian(title: "\(kindLabel) · \(URL(fileURLWithPath: record.workDir).lastPathComponent)", content: record.transcript) != nil {
                    toastMessage = "Zapisano w Obsidian ✓"
                }
            }
            .font(KiwiMangoFont.mono(10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.kiwiMangoPurple)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kiwiMangoAccent.opacity(0.15)).frame(height: 1)
        }
    }
}
