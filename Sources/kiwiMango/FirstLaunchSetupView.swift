import SwiftUI
import AppKit

// MARK: - FirstLaunchSetupView

/// One-time setup sheet shown on first launch. Lets the user configure their
// own Ollama host, default model, agent work directory, and optional Obsidian
/// vault before touching the main UI.
struct FirstLaunchSetupView: View {
    @AppStorage("ollamaHost") private var ollamaHost: String = "http://localhost:11434"
    @AppStorage("chatModel") private var chatModel: String = ""
    @AppStorage("kiwiMangoDefaultAgentWorkDir") private var agentWorkDir: String = ""
    @AppStorage("obsidianVaultPath") private var vaultPath: String = ""
    @AppStorage("kiwiMangoCompletedFirstLaunch") private var hasCompleted: Bool = false

    @State private var models: [OllamaService.ModelInfo] = []
    @State private var connectionState: ConnectionState = .idle
    @State private var isTesting = false
    @FocusState private var hostFocused: Bool

    private let defaultVault = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Documents/kiwiMango/ObsidianVault").path

    enum ConnectionState: Equatable {
        case idle
        case checking
        case ok(latencyMs: Int)
        case error(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hostSection
                    modelSection
                    workDirSection
                    vaultSection
                }
                .padding(24)
            }
            footer
        }
        .frame(width: 520, height: 540)
        .background(Color.kiwiMangoBackground)
        .onAppear {
            if vaultPath.isEmpty { vaultPath = defaultVault }
            if agentWorkDir.isEmpty { agentWorkDir = FileManager.default.homeDirectoryForCurrentUser.path }
            hostFocused = true
            Task { await testConnection() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Witaj w kiwiMango")
                .font(KiwiMangoFont.mono(18, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text("Skonfiguruj podstawowe ustawienia. Wszystko można później zmienić w Preferencjach.")
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    // MARK: - Ollama host

    private var hostSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POŁĄCZENIE Z OLLAMA")
                .font(KiwiMangoFont.mono(10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))

            HStack(spacing: 8) {
                TextField("http://localhost:11434", text: $ollamaHost)
                    .textFieldStyle(.roundedBorder)
                    .font(KiwiMangoFont.mono(12))
                    .focused($hostFocused)
                    .frame(maxWidth: .infinity)

                Button {
                    Task { await testConnection() }
                } label: {
                    Text(isTesting ? "…" : "Testuj")
                        .font(KiwiMangoFont.mono(11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .disabled(isTesting)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(statusColor)
            }
        }
    }

    // MARK: - Default model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DOMYŚLNY MODEL")
                .font(KiwiMangoFont.mono(10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))

            if models.isEmpty {
                Text("Wybierz dostępny model po podłączeniu do Ollamy.")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            } else {
                Picker("", selection: $chatModel) {
                    ForEach(models, id: \.name) { model in
                        Text(model.isCloud ? "☁️ \(model.name)" : model.name)
                            .tag(model.name)
                    }
                }
                .pickerStyle(.radioGroup)
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
        }
    }

    // MARK: - Work directory

    private var workDirSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("KATALOG ROBOCZY AGENTÓW")
                .font(KiwiMangoFont.mono(10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))

            HStack(spacing: 8) {
                Text(agentWorkDir.isEmpty ? "Brak" : agentWorkDir)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Wybierz…") { pickWorkDir() }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
            .padding(10)
            .background(Color.kiwiMangoComposerBg)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.kiwiMangoBorder.opacity(0.40)))

            Text("Agentowie będą tu domyślnie uruchamiać terminal. Możesz zmienić to przy każdym agencie.")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
        }
    }

    // MARK: - Obsidian vault

    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VAULT OBSIDIAN (opcjonalnie)")
                .font(KiwiMangoFont.mono(10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))

            HStack(spacing: 8) {
                Text(vaultPath.isEmpty ? "Wyłączone" : vaultPath)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .lineLimit(1)
                Spacer()
                Button("Wybierz…") { pickVault() }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
            .padding(10)
            .background(Color.kiwiMangoComposerBg)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.kiwiMangoBorder.opacity(0.40)))

            Text("Jeśli nie używasz Obsidiana, zostaw to pole puste — synchronizacja zostanie wyłączona.")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Pomiń") { finish() }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))

            Spacer()

            Button {
                finish()
            } label: {
                Text("Gotowe")
                    .font(KiwiMangoFont.mono(12, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(canFinish ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.35))
                    .foregroundStyle(Color.kiwiMangoAccentText)
                    .clipShape(.rect(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!canFinish)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Actions

    private func testConnection() async {
        guard !ollamaHost.isEmpty else {
            connectionState = .error("Podaj adres hosta")
            return
        }
        isTesting = true
        connectionState = .checking
        do {
            let service = OllamaService(host: ollamaHost)
            let list = try await service.listModelsDetailed()
            let ping = await service.ping()
            await MainActor.run {
                models = list
                if !list.isEmpty, !list.contains(where: { $0.name == chatModel }) {
                    chatModel = list.first?.name ?? ""
                }
                connectionState = ping.online ? .ok(latencyMs: ping.latencyMs) : .error("Brak odpowiedzi")
                isTesting = false
            }
        } catch {
            await MainActor.run {
                connectionState = .error(error.localizedDescription)
                models = []
                isTesting = false
            }
        }
    }

    private func pickWorkDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz domyślny katalog roboczy"
        panel.prompt = "Wybierz"
        if !agentWorkDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: agentWorkDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        agentWorkDir = url.path
    }

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz folder vaulta Obsidian (lub nowy folder)"
        panel.prompt = "Wybierz"
        if !vaultPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: vaultPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultPath = url.path
    }

    private func finish() {
        if vaultPath.isEmpty {
            UserDefaults.standard.set(false, forKey: "obsidianLiveSync")
        } else {
            UserDefaults.standard.set(true, forKey: "obsidianLiveSync")
            try? FileManager.default.createDirectory(at: URL(fileURLWithPath: vaultPath), withIntermediateDirectories: true)
        }
        if chatModel.isEmpty {
            chatModel = models.first?.name ?? "llama3.2"
        }
        if agentWorkDir.isEmpty {
            agentWorkDir = FileManager.default.homeDirectoryForCurrentUser.path
        }
        hasCompleted = true
    }

    // MARK: - Helpers

    private var canFinish: Bool {
        !ollamaHost.isEmpty && !chatModel.isEmpty
    }

    private var statusColor: Color {
        switch connectionState {
        case .idle: return Color.kiwiMangoTextPrimary.opacity(0.4)
        case .checking: return Color.kiwiMangoTextPrimary.opacity(0.65)
        case .ok: return Color.kiwiMangoTextPrimary
        case .error: return Color.kiwiMangoDanger
        }
    }

    private var statusText: String {
        switch connectionState {
        case .idle: return "Kliknij Testuj, żeby sprawdzić połączenie."
        case .checking: return "Sprawdzam…"
        case .ok(let ms): return "Połączono (\(ms)ms), modele: \(models.count)"
        case .error(let msg): return "Błąd: \(msg)"
        }
    }
}
