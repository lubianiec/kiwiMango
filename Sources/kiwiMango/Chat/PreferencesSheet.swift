import SwiftUI

// MARK: - PreferencesSheet

/// Compact settings: Obsidian, memory, agents, app. ponytail: one sheet,
/// no scrolling novel; agent defaults live here because the spawn popover
/// is too small for defaults + model selection.
struct PreferencesSheet: View {
    @Environment(ChatState.self) private var chatState
    @Environment(AgentManager.self) private var agentManager

    @AppStorage("obsidianLiveSync") private var liveSync = true
    @AppStorage("obsidianVaultPath") private var vaultPath: String = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Kazik/ObsidianSync").path
    @AppStorage("obsidianCategories") private var categories: String =
        "projekty, hydraulika, obrazy, muzyka, kod, inne"
    @AppStorage("kiwiMangoMemoryEnabled") private var memoryEnabled = true
    @AppStorage("kiwiMangoDebugMode") private var debugMode = false
    @AppStorage("kiwiMangoAgentTelemetry") private var telemetryEnabled = true
    @AppStorage("kiwiMangoStartAtLogin") private var startAtLogin = false

    @AppStorage("kiwiMangoDefaultAgentModel") private var defaultAgentModel: String = ""
    @AppStorage("kiwiMangoDefaultAgentWorkDir") private var defaultAgentWorkDir: String = ""

    @State private var selectedTab: PreferencesTab = .agents

    enum PreferencesTab: String, CaseIterable, Identifiable {
        case agents = "Agenci"
        case obsidian = "Obsidian"
        case memory = "Pamięć"
        case app = "Aplikacja"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            tabContent
        }
        .frame(width: 520, height: 420)
        .background(Color.kiwiMangoBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.kiwiMangoBorder.opacity(0.35), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text("Preferencje")
                .font(KiwiMangoFont.mono(16, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Spacer()
            Button("Gotowe") { }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(12, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .disabled(true)
                .opacity(0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(PreferencesTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
                } label: {
                    Text(tab.rawValue.uppercased())
                        .font(KiwiMangoFont.mono(10, weight: selectedTab == tab ? .bold : .medium))
                        .tracking(0.5)
                        .foregroundStyle(selectedTab == tab ? Color.kiwiMangoAccentText : Color.kiwiMangoTextPrimary.opacity(0.6))
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            selectedTab == tab ? Color.kiwiMangoTextPrimary : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var tabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch selectedTab {
                case .agents:
                    agentsSection
                case .obsidian:
                    obsidianSection
                case .memory:
                    memorySection
                case .app:
                    appSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Domyślne ustawienia nowego Hermesa")
                .font(KiwiMangoFont.sans(12, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            HStack(spacing: 8) {
                Text("Model")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                    .frame(width: 70, alignment: .leading)
                TextField("np. qwen3.5:397b-cloud", text: $defaultAgentModel)
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(11))
                    .padding(8)
                    .background(Color.kiwiMangoComposerBg)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.kiwiMangoBorder.opacity(0.40)))
            }

            HStack(spacing: 8) {
                Text("Katalog")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                    .frame(width: 70, alignment: .leading)
                Text(defaultAgentWorkDir.isEmpty ? "~/Kazik" : defaultAgentWorkDir)
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                    .lineLimit(1)
                Spacer()
                Button("Wybierz…") { pickDefaultWorkDir() }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }

            Divider().overlay(Color.kiwiMangoBorder.opacity(0.35))

            Toggle("Pokazuj telemetryczne statusy agentów", isOn: $telemetryEnabled)
                .font(KiwiMangoFont.sans(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            Text("Telemetry wymaga restartu uruchomionych agentów, żeby zacząć/ przestać zbierać metryki.")
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
        }
    }

    // MARK: - Obsidian

    private var obsidianSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Zapisuj do Obsidiana na żywo", isOn: $liveSync)
                .font(KiwiMangoFont.sans(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            HStack(spacing: 8) {
                Text("Vault")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                    .frame(width: 70, alignment: .leading)
                TextField("~/Kazik/ObsidianSync", text: $vaultPath)
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(11))
                    .padding(8)
                    .background(Color.kiwiMangoComposerBg)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.kiwiMangoBorder.opacity(0.40)))
                Button("…") { pickVault() }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(14, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }

            HStack(spacing: 8) {
                Text("Kategorie")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                    .frame(width: 70, alignment: .leading)
                TextField("projekty, hydraulika, ...", text: $categories)
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(11))
                    .padding(8)
                    .background(Color.kiwiMangoComposerBg)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.kiwiMangoBorder.opacity(0.40)))
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Włącz auto-pamięć długoterminową", isOn: $memoryEnabled)
                .font(KiwiMangoFont.sans(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            Text("kiwiMango sam zapamiętuje ważne fakty z rozmów i przywraca je w nowych czatach.")
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - App

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Uruchamiaj przy logowaniu", isOn: $startAtLogin)
                .font(KiwiMangoFont.sans(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            Toggle("Tryb debug (więcej logów)", isOn: $debugMode)
                .font(KiwiMangoFont.sans(12))
                .foregroundStyle(Color.kiwiMangoTextPrimary)

            HStack {
                Text("Wersja")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                Spacer()
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
            }
        }
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

    private func pickDefaultWorkDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz domyślny katalog roboczy agenta"
        panel.prompt = "Wybierz"
        if !defaultAgentWorkDir.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultAgentWorkDir)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaultAgentWorkDir = url.path
    }
}
