import SwiftUI
import Yams

// MARK: - Settings window (F9)

/// Replaces the system Settings tab with a full-size, app-styled window.
/// ponytail: keeps existing @AppStorage keys alive instead of migrating them
/// to a new class — fewer moving parts, same behavior.
struct SettingsWindow: View {

    @Environment(ChatState.self) private var chatState

    @State private var selectedCategory: SettingsCategory = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category)
                    .padding(.vertical, 4)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 180)
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(selectedCategory.title)
                        .font(KiwiMangoFont.sans(24, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)

                    switch selectedCategory {
                    case .general: GeneralSettingsSection()
                    case .chat: ChatSettingsSection()
                    case .ollama: OllamaSettingsSection()
                    case .hermes: HermesSettingsSection()
                    case .agents: AgentSettingsSection()
                    case .obsidian: ObsidianSettingsSection()
                    case .advanced: AdvancedSettingsSection()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color.kiwiMangoBackground)
        }
        .background(Color.kiwiMangoBackground)
        .task { await chatState.loadModels() }
    }
}

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, chat, ollama, hermes, agents, obsidian, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Ogólne"
        case .chat: return "Czat"
        case .ollama: return "Ollama"
        case .hermes: return "Hermes"
        case .agents: return "Agenci"
        case .obsidian: return "Obsidian"
        case .advanced: return "Zaawansowane"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .chat: return "bubble.left.and.bubble.right"
        case .ollama: return "cpu"
        case .hermes: return "terminal"
        case .agents: return "person.2"
        case .obsidian: return "book"
        case .advanced: return "gearshape.2"
        }
    }
}

// MARK: - General

private struct GeneralSettingsSection: View {
    @AppStorage("kiwiMangoStartAtLogin") private var startAtLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Uruchamiaj przy logowaniu", isOn: $startAtLogin)

            Divider()

            LabeledContent("Wersja") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsCard()
    }
}

// MARK: - Chat

private struct ChatSettingsSection: View {
    @Environment(ChatState.self) private var chatState
    @AppStorage("ollamaHost") private var ollamaHost: String = "http://localhost:11434"
    @AppStorage("kiwiMangoMemoryEnabled") private var memoryEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPaneHeader(title: "Połączenie")
            HStack {
                Text("Host Ollama")
                    .frame(width: 120, alignment: .leading)
                TextField("http://localhost:11434", text: $ollamaHost)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsPaneHeader(title: "Domyślny model")
            if chatState.availableModels.isEmpty {
                Text("Brak połączenia z Ollama.")
                    .foregroundStyle(.secondary)
            } else {
                ModelPicker(models: chatState.availableModels, selection: chatState.selectedModel) { model in
                    chatState.selectedModel = model
                }
            }

            SettingsPaneHeader(title: "Auto-pamięć")
            Toggle("Włącz auto-pamięć długoterminową", isOn: $memoryEnabled)
            Text("kiwiMango będzie sam zapisywać ważne fakty z rozmów i przywracać je w nowych czatach.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .settingsCard()
    }
}

// MARK: - Ollama

private struct OllamaSettingsSection: View {
    @AppStorage("ollamaHost") private var ollamaHost: String = "http://localhost:11434"
    @AppStorage("kiwiMangoOllamaTimeout") private var timeout = 60
    @AppStorage("kiwiMangoOllamaFallback") private var fallbackOrder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPaneHeader(title: "Serwer")
            HStack {
                Text("Host")
                    .frame(width: 120, alignment: .leading)
                TextField("http://localhost:11434", text: $ollamaHost)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("Timeout (s)")
                    .frame(width: 120, alignment: .leading)
                TextField("60", value: $timeout, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            SettingsPaneHeader(title: "Fallback order")
            TextField("model1, model2, ...", text: $fallbackOrder)
                .textFieldStyle(.roundedBorder)
            Text("Lista zapasowych modeli oddzielonych przecinkiem, używana gdy wybrany model jest niedostępny.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .settingsCard()
    }
}

// MARK: - Hermes

private struct HermesSettingsSection: View {

    @State private var configText = ""
    @State private var configPath = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPaneHeader(title: "Hermes CLI config")
            Text(configPath)
                .font(KiwiMangoFont.mono(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            TextEditor(text: $configText)
                .font(KiwiMangoFont.mono(12))
                .frame(minHeight: 320)
                .settingsCard()

            if let saveError {
                Text(saveError)
                    .foregroundStyle(Color.kiwiMangoDanger)
                    .font(.caption)
            }

            HStack {
                Button("Zapisz") { saveConfig() }
                Button("Otwórz w edytorze") { NSWorkspace.shared.openFile(configPath) }
                    .buttonStyle(.borderless)
                Spacer()
                Text("Zrestartuj Hermesa, żeby zmiany zaczęły działać.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { loadConfig() }
    }

    private var hermesHome: String {
        ProcessInfo.processInfo.environment["HERMES_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path
    }

    private func loadConfig() {
        configPath = (hermesHome as NSString).appendingPathComponent("config.yaml")
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath),
              let text = String(data: data, encoding: .utf8) else {
            configText = "# Nie znaleziono config.yaml"
            return
        }
        configText = text
    }

    private func saveConfig() {
        do {
            // Validate YAML before writing.
            _ = try Yams.load(yaml: configText)
            try configText.write(toFile: configPath, atomically: true, encoding: .utf8)
            saveError = nil
        } catch {
            saveError = "Błąd zapisu: \(error.localizedDescription)"
        }
    }
}

// MARK: - Agents

private struct AgentSettingsSection: View {
    @AppStorage("agentLastKind") private var lastKindRaw = AgentKind.claude.rawValue
    @AppStorage("agentLastWorkDir") private var lastWorkDir = ""
    @AppStorage("kiwiMangoAgentTelemetry") private var telemetryEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsPaneHeader(title: "Domyślny agent")
            Picker("Agent", selection: $lastKindRaw) {
                ForEach(AgentKind.allCases, id: \.rawValue) { kind in
                    Text(kind.label).tag(kind.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Workdir")
                    .frame(width: 120, alignment: .leading)
                TextField("~/Kazik", text: $lastWorkDir)
                    .textFieldStyle(.roundedBorder)
            }

            SettingsPaneHeader(title: "Telemetria")
            Toggle("Pokazuj telemetryczne statusy agentów", isOn: $telemetryEnabled)
        }
        .settingsCard()
    }
}

// MARK: - Obsidian

private struct ObsidianSettingsSection: View {
    @AppStorage("obsidianLiveSync") private var liveSync = true
    @AppStorage("obsidianVaultPath") private var vaultPath: String = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Kazik/ObsidianSync").path
    @AppStorage("obsidianCategories") private var categories: String =
        "projekty, hydraulika, obrazy, muzyka, kod, inne"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Zapisuj do Obsidiana na żywo", isOn: $liveSync)

            HStack {
                Text("Vault")
                    .frame(width: 80, alignment: .leading)
                TextField("~/Kazik/ObsidianSync", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
                Button("Wybierz…") { pickVault() }
            }

            HStack {
                Text("Kategorie")
                    .frame(width: 80, alignment: .leading)
                TextField("projekty, hydraulika, ...", text: $categories)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .settingsCard()
    }

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz folder vaulta Obsidian"
        panel.prompt = "Wybierz"
        if !vaultPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: vaultPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultPath = url.path
    }
}

// MARK: - Advanced

private struct AdvancedSettingsSection: View {
    @AppStorage("kiwiMangoDebugMode") private var debugMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle("Tryb debug (więcej logów w konsoli)", isOn: $debugMode)

            Button("Otwórz folder wsparcia") {
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Kazik/Downloads")
                NSWorkspace.shared.open(url)
            }
        }
        .settingsCard()
    }
}

// MARK: - Helpers

private struct SettingsPaneHeader: View {
    let title: String

    init(title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(KiwiMangoFont.sans(14, weight: .bold))
            .foregroundStyle(Color.kiwiMangoAccent)
            .padding(.top, 8)
    }
}

private struct ModelPicker: View {
    let models: [OllamaService.ModelInfo]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { selection },
            set: { onSelect($0) }
        )) {
            ForEach(models, id: \.name) { model in
                Text(model.isCloud ? "☁️ \(model.name)" : model.name).tag(model.name)
            }
        }
        .pickerStyle(.menu)
    }
}

private extension View {
    func settingsCard() -> some View {
        self
            .padding(20)
            .background(Color.kiwiMangoSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private extension AgentKind {
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .claudePro: return "Claude Pro"
        case .hermes: return "Hermes"
        case .codex: return "Codex"
        }
    }
}

private extension NSWorkspace {
    func openFile(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }
}
