import SwiftUI

// MARK: - SettingsView

/// App preferences: Ollama host + default chat model.
struct SettingsView: View {

    @Environment(ChatState.self) private var chatState

    @AppStorage("ollamaHost") private var ollamaHost: String = "http://localhost:11434"
    @AppStorage("obsidianLiveSync") private var obsidianLiveSync: Bool = true
    @AppStorage("obsidianVaultPath") private var obsidianVaultPath: String = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent("Kazik/ObsidianSync").path
    @AppStorage("obsidianCategories") private var obsidianCategories: String =
        "projekty, hydraulika, obrazy, muzyka, kod, inne"

    var body: some View {
        Form {
            Section("Połączenie") {
                LabeledContent("Host Ollama") {
                    TextField("http://localhost:11434", text: $ollamaHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                }
            }

            Section("Model czatu") {
                @Bindable var cs = chatState
                if chatState.availableModels.isEmpty {
                    Text("Brak połączenia z Ollama — używany zapisany model.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Domyślny model", selection: $cs.selectedModel) {
                        ForEach(chatState.availableModels, id: \.name) { model in
                            Text(model.isCloud ? "☁️ \(model.name)" : model.name).tag(model.name)
                        }
                    }
                }
            }

            Section("Obsidian (Fala 12)") {
                Toggle("Zapisuj do Obsidiana na żywo", isOn: $obsidianLiveSync)
                LabeledContent("Vault") {
                    HStack {
                        TextField("~/Kazik/ObsidianSync", text: $obsidianVaultPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Wybierz…") { pickVault() }
                    }
                }
                LabeledContent("Kategorie") {
                    TextField("projekty, hydraulika, obrazy, ...", text: $obsidianCategories)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Snippety") {
                SnippetSettingsSection()
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { await chatState.loadModels() }
    }

    private func pickVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz folder vaulta Obsidian"
        panel.prompt = "Wybierz"
        if !obsidianVaultPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: obsidianVaultPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        obsidianVaultPath = url.path
    }
}

// MARK: - SnippetSettingsSection

/// Simple CRUD list for prompt snippets (`/trigger` → content in the composer).
private struct SnippetSettingsSection: View {
    @Environment(ChatState.self) private var chatState

    @State private var newTrigger = ""
    @State private var newContent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(chatState.snippets) { snippet in
                HStack {
                    Text("/\(snippet.trigger)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 90, alignment: .leading)
                    Text(snippet.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        chatState.deleteSnippet(snippet.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                TextField("trigger", text: $newTrigger)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                TextField("treść snippetu", text: $newContent)
                    .textFieldStyle(.roundedBorder)
                Button("Dodaj", action: addSnippet)
                    .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newContent.isEmpty)
            }
        }
    }

    private func addSnippet() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        chatState.saveSnippet(Snippet(id: 0, trigger: trigger, content: newContent, position: 0))
        newTrigger = ""
        newContent = ""
    }
}
