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
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
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
                : AnyShapeStyle(Color.clear)
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
    }

    private var elapsed: String {
        let seconds = Int(now.timeIntervalSince(session.startedAt))
        let minutes = seconds / 60
        if minutes < 1 { return "przed chwilą" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) godz."
    }
}

// MARK: - NewAgentPopover

/// Popover opened from "+ NOWY_AGENT" (sidebar) or ⌘T: pick one of the
/// installed Ollama models (same source as the sidebar MODELE section),
/// pick a working directory, spawn.
struct NewAgentPopover: View {
    let onSpawn: (OllamaService.ModelInfo, URL) -> Void

    @Environment(ChatState.self) private var chatState
    @AppStorage("agentLastWorkDir") private var lastWorkDirPath = ""
    @State private var workDirPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NOWY AGENT — WYBIERZ MODEL")
                .font(KiwiMangoFont.mono(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))

            modelList

            Divider().overlay(Color.white.opacity(0.12))

            VStack(alignment: .leading, spacing: 6) {
                Text("KATALOG ROBOCZY")
                    .font(KiwiMangoFont.mono(9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
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

    @ViewBuilder
    private var modelList: some View {
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
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
    }

    private func modelButton(_ model: OllamaService.ModelInfo) -> some View {
        Button {
            let url = URL(fileURLWithPath: displayWorkDir)
            lastWorkDirPath = displayWorkDir
            onSpawn(model, url)
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
            Text("Agent")
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
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
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
