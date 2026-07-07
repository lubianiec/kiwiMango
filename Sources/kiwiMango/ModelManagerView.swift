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

    private let service = OllamaService()

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            header
            content
        }
        .frame(minWidth: 460, minHeight: 420)
        .background(Color.kiwiMangoSurface)
        .task { await reload() }
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
