import SwiftUI

// MARK: - ModelManagerView

/// Lists locally installed Ollama models with their size on disk and lets the
/// user permanently delete them. Opened as a `.sheet` from `RootView`'s sidebar.
struct ModelManagerView: View {

    @Environment(ChatState.self) private var chatState
    @Environment(\.dismiss) private var dismiss

    @State private var models: [OllamaService.ModelInfo] = []
    @State private var isLoading = false
    @State private var loadError: String?

    @State private var pendingDelete: OllamaService.ModelInfo?
    @State private var isDeleting = false
    @State private var deleteError: String?
    @State private var successMessage: String?

    // MARK: F10.1 — pull
    @State private var pullText = ""
    @State private var pullTask: Task<Void, Never>?
    @State private var pullStatus = ""
    @State private var pullCompleted: Int64 = 0
    @State private var pullTotal: Int64 = 0
    @State private var pullError: String?
    @State private var pendingLargePull: String?
    @State private var warnedLargePull = false

    // MARK: F10.2 — GGUF import
    @State private var importLog: [String] = []
    @State private var isImporting = false
    @State private var showingImportNamePrompt = false
    @State private var importFileURL: URL?
    @State private var importName = ""

    // MARK: F14.0 — web search key
    @AppStorage("ollamaWebSearchKey") private var webSearchKey = ""
    @State private var isTestingWebSearch = false
    @State private var webSearchTestResult: Bool?
    @State private var webSearchTestError: String?

    private let service = OllamaService()

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            header
            pullSection
            content
            webSearchSection
        }
        .frame(minWidth: 460, minHeight: 480)
        .background(Color.kiwiMangoSurface)
        .task { await reload() }
        .alert("Nazwa modelu", isPresented: $showingImportNamePrompt) {
            TextField("nazwa", text: $importName)
            Button("Importuj") {
                if let url = importFileURL {
                    runGGUFImport(fileURL: url, name: importName)
                }
            }
            Button("Anuluj", role: .cancel) { importFileURL = nil }
        } message: {
            Text("Małe litery, cyfry, myślniki.")
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Usuń trwale", role: .destructive) {
                if let model = pendingDelete {
                    Task { await performDelete(model) }
                }
            }
            Button("Anuluj", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let model = pendingDelete {
                Text("""
                Model „\(model.name)” (\(Self.formattedSize(model.size))) zostanie trwale \
                usunięty z dysku. To nieodwracalne — żeby go znów użyć, trzeba będzie \
                pobrać go ponownie (`ollama pull \(model.name)`).
                """)
            }
        }
        .alert("Błąd usuwania", isPresented: deleteErrorBinding) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .overlay(alignment: .bottom) {
            if let successMessage {
                Text(successMessage)
                    .font(.callout)
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.kiwiMangoChrome, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.successMessage = nil }
                    }
            }
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            HStack(spacing: 6) {
                Rectangle()
                    .fill(Color.kiwiMangoAccent)
                    .frame(width: 7, height: 7)
                Text("kiwiMango — modele")
                    .font(KiwiMangoFont.mono(10.5, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                    .textCase(.lowercase)
            }
            Spacer()
            Button("Odśwież") {
                Task { await reload() }
            }
            .buttonStyle(.plain)
            .font(KiwiMangoFont.mono(10.5))
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
            .disabled(isLoading)

            Button("Zamknij") { dismiss() }
                .buttonStyle(.plain)
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.kiwiMangoChrome)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MODELE_OLLAMA")
                .font(KiwiMangoFont.mono(14, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text("łącznie \(Self.formattedSize(totalSize)) na dysku")
                .font(KiwiMangoFont.mono(11.5))
                .foregroundStyle(Color.kiwiMangoAccent.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var totalSize: Int64 {
        models.filter { !$0.isCloud }.reduce(0) { $0 + $1.size }
    }

    // MARK: - F14.0 — Web search key

    private var webSearchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.white.opacity(0.1))

            Text("WEB SEARCH")
                .font(KiwiMangoFont.mono(10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .padding(.top, 10)

            Text("Klucz z ollama.com/settings/keys — daje modelom dostęp do świeżego internetu.")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))

            HStack(spacing: 8) {
                SecureField("", text: $webSearchKey, prompt: Text("klucz API").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.kiwiMangoComposerBg)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))

                Button("[TESTUJ]") { testWebSearch() }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccent)
                    .disabled(webSearchKey.trimmingCharacters(in: .whitespaces).isEmpty || isTestingWebSearch)

                if isTestingWebSearch {
                    ProgressView().controlSize(.small).tint(Color.kiwiMangoAccent)
                } else if let result = webSearchTestResult {
                    Text(result ? "✓" : "✗")
                        .font(KiwiMangoFont.mono(14, weight: .bold))
                        .foregroundStyle(result ? Color.kiwiMangoAccent : Color.kiwiMangoDanger)
                }
            }

            if let webSearchTestError {
                Text(webSearchTestError)
                    .font(KiwiMangoFont.mono(10))
                    .foregroundStyle(Color.kiwiMangoDanger)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func testWebSearch() {
        isTestingWebSearch = true
        webSearchTestResult = nil
        webSearchTestError = nil
        Task {
            do {
                _ = try await service.webSearch(query: "test", maxResults: 1)
                webSearchTestResult = true
            } catch {
                webSearchTestResult = false
                webSearchTestError = error.localizedDescription
            }
            isTestingWebSearch = false
        }
    }

    // MARK: - F10.1/F10.2 — Pull + import section

    private var pullSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POBIERZ MODEL")
                .font(KiwiMangoFont.mono(10, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))

            HStack(spacing: 8) {
                TextField("", text: $pullText, prompt: Text("hf.co/TheBloke/model:Q4_K_M albo nazwa z ollama.com").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.kiwiMangoComposerBg)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
                    .disabled(pullTask != nil)

                if pullTask != nil {
                    Button("[✕]") { cancelPull() }
                        .buttonStyle(.plain)
                        .font(KiwiMangoFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoDanger)
                } else {
                    Button("[POBIERZ]") { startPull(pullText) }
                        .buttonStyle(.plain)
                        .font(KiwiMangoFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccent)
                        .disabled(pullText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button("[IMPORT .GGUF]") { pickGGUFFile() }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(11, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoPurple)
                    .disabled(pullTask != nil || isImporting)
            }

            if pullTask != nil {
                pullProgressView
            }
            if let pullError {
                Text(pullError)
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.kiwiMangoDanger)
            }
            if isImporting || !importLog.isEmpty {
                importLogView
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .alert("Model może nie zmieścić się w 16 GB RAM", isPresented: largePullConfirmBinding) {
            Button("Pobierz mimo to") { pendingLargePull = nil }
            Button("Anuluj", role: .cancel) {
                pendingLargePull = nil
                cancelPull()
            }
        } message: {
            Text("Rozmiar tego modelu przekracza ~6 GB — pobrać mimo to?")
        }
    }

    private var largePullConfirmBinding: Binding<Bool> {
        Binding(get: { pendingLargePull != nil }, set: { if !$0 { pendingLargePull = nil } })
    }

    private var pullProgressView: some View {
        let fraction = pullTotal > 0 ? Double(pullCompleted) / Double(pullTotal) : 0
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.kiwiMangoAccent)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
            .neonBorder(Color.kiwiMangoAccent, cornerRadius: 3)

            HStack {
                Text(pullStatus)
                Spacer()
                if pullTotal > 0 {
                    Text("\(Self.formattedSize(pullCompleted)) / \(Self.formattedSize(pullTotal)) — \(Int(fraction * 100))%")
                }
            }
            .font(KiwiMangoFont.mono(10))
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
        }
    }

    private var importLogView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(importLog.suffix(6).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(KiwiMangoFont.mono(9.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - F10.1 actions

    private func startPull(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        pullError = nil
        pullStatus = "startuję…"
        pullCompleted = 0
        pullTotal = 0
        // :cloud manifests are metadata-only — no disk-size warning needed.
        warnedLargePull = name.hasSuffix(":cloud")
        pullTask = Task {
            do {
                for try await progress in service.pull(model: name) {
                    pullStatus = progress.status
                    pullCompleted = progress.completed
                    pullTotal = progress.total
                    // F10.1 pitfall (a): warn as soon as the manifest tells us the
                    // real size — Ollama reports `total` on the first "downloading"
                    // line, well before most bytes move, so this still lands early.
                    if !warnedLargePull, progress.total > 6_000_000_000 {
                        warnedLargePull = true
                        pendingLargePull = name
                    }
                }
                pullText = ""
                await reload()
                withAnimation { successMessage = "Model gotowy ✓" }
            } catch is CancellationError {
                // Cancelled by the user — Ollama resumes the partial blob on the next pull.
            } catch {
                pullError = error.localizedDescription
            }
            pullTask = nil
        }
    }

    private func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
    }

    // MARK: - F10.2 actions

    private func pickGGUFFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.init(filenameExtension: "gguf")].compactMap { $0 }
        panel.message = "Wybierz plik .gguf do zaimportowania"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFileURL = url
        importName = url.deletingPathExtension().lastPathComponent.lowercased()
        showingImportNamePrompt = true
    }

    private func runGGUFImport(fileURL: URL, name: String) {
        let validName = name.lowercased().filter { $0.isLowercase || $0.isNumber || $0 == "-" }
        guard !validName.isEmpty else {
            importLog.append("✗ Nazwa modelu: tylko małe litery/cyfry/myślniki")
            return
        }
        isImporting = true
        importLog = ["startuję import „\(validName)”…"]

        Task.detached {
            let modelfile = "FROM \(fileURL.path)\n"
            let modelfileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("kiwiMango-Modelfile-\(UUID().uuidString)")
            do {
                try modelfile.write(to: modelfileURL, atomically: true, encoding: .utf8)
            } catch {
                await MainActor.run {
                    importLog.append("✗ Nie udało się zapisać Modelfile: \(error.localizedDescription)")
                    isImporting = false
                }
                return
            }

            let escapedName = validName.replacingOccurrences(of: "'", with: "'\\''")
            let escapedModelfile = modelfileURL.path.replacingOccurrences(of: "'", with: "'\\''")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "ollama create '\(escapedName)' -f '\(escapedModelfile)'"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    importLog.append("✗ Nie udało się uruchomić ollama create: \(error.localizedDescription)")
                    isImporting = false
                }
                return
            }

            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let text = String(data: data, encoding: .utf8) {
                    let lines = text.split(separator: "\n").map(String.init)
                    await MainActor.run { importLog.append(contentsOf: lines) }
                }
            }
            process.waitUntilExit()
            try? FileManager.default.removeItem(at: modelfileURL)

            await MainActor.run {
                isImporting = false
                if process.terminationStatus == 0 {
                    importLog.append("✓ Model „\(validName)” gotowy")
                    Task { await reload() }
                    withAnimation { successMessage = "Model gotowy ✓" }
                } else {
                    importLog.append("✗ ollama create zakończyło się kodem \(process.terminationStatus)")
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && models.isEmpty {
            ProgressView("Wczytywanie modeli…")
                .tint(Color.kiwiMangoAccent)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError, models.isEmpty {
            ContentUnavailableView(
                "Nie udało się wczytać modeli",
                systemImage: "exclamationmark.triangle",
                description: Text(loadError)
            )
            .foregroundStyle(Color.kiwiMangoTextPrimary)
        } else if models.isEmpty {
            ContentUnavailableView(
                "Brak pobranych modeli",
                systemImage: "shippingbox"
            )
            .foregroundStyle(Color.kiwiMangoTextPrimary)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    if !localOnlyModels.isEmpty {
                        sectionHeader("💻 LOKALNE")
                        Divider().overlay(Color.white.opacity(0.1))
                        ForEach(localOnlyModels, id: \.name) { model in
                            modelRow(model)
                            Divider().overlay(Color.white.opacity(0.1))
                        }
                    }
                    if !cloudOnlyModels.isEmpty {
                        sectionHeader("☁️ CLOUD")
                        Divider().overlay(Color.white.opacity(0.1))
                        ForEach(cloudOnlyModels, id: \.name) { model in
                            modelRow(model)
                            Divider().overlay(Color.white.opacity(0.1))
                        }
                    }
                }
            }
        }
    }

    private var localOnlyModels: [OllamaService.ModelInfo] { models.filter { !$0.isCloud } }
    private var cloudOnlyModels: [OllamaService.ModelInfo] { models.filter(\.isCloud) }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(KiwiMangoFont.mono(9.5, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private func modelRow(_ model: OllamaService.ModelInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name)
                    .font(KiwiMangoFont.sans(13, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                Text(model.isCloud ? "przez konto ollama.com" : Self.formattedSize(model.size))
                    .font(KiwiMangoFont.mono(11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.69))
            }
            Spacer()
            if !model.isCloud {
                Button {
                    pendingDelete = model
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kiwiMangoDanger)
                        .frame(width: 26, height: 26)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isDeleting)
                .help("Usuń model z dysku")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Bindings

    private var confirmationTitle: String {
        pendingDelete.map { "Usunąć „\($0.name)”?" } ?? ""
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    // MARK: - Actions

    private func reload() async {
        isLoading = true
        loadError = nil
        do {
            models = try await service.listModelsDetailed()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func performDelete(_ model: OllamaService.ModelInfo) async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await service.deleteModel(name: model.name)
            pendingDelete = nil

            // Don't leave the UI pointing at a model that no longer exists on disk.
            if chatState.selectedModel == model.name {
                chatState.selectedModel = models.first(where: { $0.name != model.name })?.name ?? ""
            }

            await reload()
            withAnimation { successMessage = "Usunięto „\(model.name)”" }
        } catch {
            pendingDelete = nil
            deleteError = error.localizedDescription
        }
    }

    // MARK: - Formatting

    private static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter.string(fromByteCount: bytes)
    }
}
