import SwiftUI

// MARK: - PromptVaultView (Fala 11)

/// Private prompt collection: image prompts, personas, drafts — anything
/// Paweł wants to remember. NOT the `/` composer snippets (F2.6, `Snippet`
/// table) — different feature, kept deliberately separate (see PLAN.md F11
/// pitfall a). Anti-"armagedon" measures per Paweł's requirement: mandatory
/// category, chips with counts, search, sort by most-recently-used.
struct PromptVaultView: View {
    let onSendToChat: (String) -> Void

    @Environment(ChatState.self) private var chatState
    @State private var prompts: [SavedPrompt] = []
    @State private var searchText = ""
    @State private var activeCategory: String?
    @State private var selectedID: Int64?
    @State private var editingPrompt: SavedPrompt?
    @State private var showingForm = false
    @State private var pendingDelete: SavedPrompt?
    @State private var toastMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            searchAndChips
            Divider().overlay(Color.white.opacity(0.1))
            HStack(spacing: 0) {
                list
                    .frame(width: 260)
                Divider().overlay(Color.white.opacity(0.1))
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.kiwiMangoSurface)
        .task { reload() }
        .sheet(isPresented: $showingForm) {
            PromptFormView(prompt: editingPrompt, defaultCategory: activeCategory) { saved in
                do {
                    let stored = try DatabaseManager.shared.saveSavedPrompt(saved)
                    reload()
                    selectedID = stored.id
                } catch {
                    print("[KiwiMango] Failed to save prompt: \(error)")
                }
            }
        }
        .confirmationDialog(
            "Usunąć „\(pendingDelete?.title ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Usuń", role: .destructive) {
                if let id = pendingDelete?.id {
                    try? DatabaseManager.shared.deleteSavedPrompt(id)
                    if selectedID == id { selectedID = nil }
                    reload()
                }
                pendingDelete = nil
            }
            Button("Anuluj", role: .cancel) { pendingDelete = nil }
        }
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
                        try? await Task.sleep(for: .seconds(2))
                        self.toastMessage = nil
                    }
            }
        }
    }

    private func reload() {
        prompts = (try? DatabaseManager.shared.fetchSavedPrompts()) ?? []
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack {
            Text("PROMPTY")
                .font(KiwiMangoFont.mono(13, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Spacer()
            Button {
                editingPrompt = nil
                showingForm = true
            } label: {
                Text("+ NOWY")
                    .font(KiwiMangoFont.mono(10.5, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoAccentText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(Color.kiwiMangoChrome)
    }

    // MARK: - Search + category chips

    private var categoryCounts: [(category: String, count: Int)] {
        var counts: [String: Int] = [:]
        for prompt in prompts { counts[prompt.category, default: 0] += 1 }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private var searchAndChips: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                TextField("", text: $searchText, prompt: Text("szukaj promptów…").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4)))
                    .textFieldStyle(.plain)
                    .font(KiwiMangoFont.mono(11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.kiwiMangoComposerBg)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(title: "WSZYSTKIE \(prompts.count)", isActive: activeCategory == nil) {
                        activeCategory = nil
                    }
                    ForEach(categoryCounts, id: \.category) { entry in
                        chip(title: "\(entry.category) \(entry.count)", isActive: activeCategory == entry.category) {
                            activeCategory = entry.category
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func chip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(KiwiMangoFont.mono(10, weight: .semibold))
                .foregroundStyle(isActive ? Color.kiwiMangoAccentText : Color.kiwiMangoTextPrimary.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isActive ? Color.kiwiMangoAccent : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .neonBorder(isActive ? Color.kiwiMangoAccent : Color.white.opacity(0.16), cornerRadius: 4, active: isActive)
    }

    // MARK: - List (left column)

    private var filteredPrompts: [SavedPrompt] {
        var result = prompts
        if let activeCategory {
            result = result.filter { $0.category == activeCategory }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(query) || $0.content.localizedCaseInsensitiveContains(query)
            }
        }
        return result
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredPrompts) { prompt in
                    promptRow(prompt)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = prompt.id }
                        .background(selectedID == prompt.id ? Color.white.opacity(0.05) : Color.clear)
                }
            }
        }
    }

    private func promptRow(_ prompt: SavedPrompt) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(prompt.title)
                    .font(KiwiMangoFont.mono(11.5, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(prompt.category)
                    .font(KiwiMangoFont.mono(8.5, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoPurple)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.kiwiMangoPurple.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
            Text(prompt.content.split(separator: "\n").first.map(String.init) ?? "")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Detail (right column)

    private var selectedPrompt: SavedPrompt? {
        filteredPrompts.first { $0.id == selectedID } ?? prompts.first { $0.id == selectedID }
    }

    @ViewBuilder
    private var detail: some View {
        if let prompt = selectedPrompt {
            VStack(alignment: .leading, spacing: 12) {
                Text(prompt.title)
                    .font(KiwiMangoFont.mono(15, weight: .bold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)

                ScrollView {
                    Text(prompt.content)
                        .font(KiwiMangoFont.mono(12))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button("[KOPIUJ]") { copy(prompt) }
                        .buttonStyle(.plain)
                        .font(KiwiMangoFont.mono(11, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccentText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 4))

                    Button("[→ DO CZATU]") { sendToChat(prompt) }
                        .buttonStyle(.plain)
                        .font(KiwiMangoFont.mono(11, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoPurple)

                    Button("[EDYTUJ]") {
                        editingPrompt = prompt
                        showingForm = true
                    }
                    .buttonStyle(.plain)
                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))

                    Button("[USUŃ]") { pendingDelete = prompt }
                        .buttonStyle(.plain)
                        .font(KiwiMangoFont.mono(11, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "Wybierz prompt z listy",
                systemImage: "text.book.closed"
            )
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func copy(_ prompt: SavedPrompt) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt.content, forType: .string)
        try? DatabaseManager.shared.touchSavedPromptUsage(prompt.id)
        reload()
        toastMessage = "Skopiowano ✓"
    }

    private func sendToChat(_ prompt: SavedPrompt) {
        try? DatabaseManager.shared.touchSavedPromptUsage(prompt.id)
        reload()
        onSendToChat(prompt.content)
    }
}

// MARK: - PromptFormView

private struct PromptFormView: View {
    let prompt: SavedPrompt?
    let defaultCategory: String?
    let onSave: (SavedPrompt) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var content: String
    @State private var category: String
    @State private var newCategory: String = ""

    init(prompt: SavedPrompt?, defaultCategory: String?, onSave: @escaping (SavedPrompt) -> Void) {
        self.prompt = prompt
        self.defaultCategory = defaultCategory
        self.onSave = onSave
        _title = State(initialValue: prompt?.title ?? "")
        _content = State(initialValue: prompt?.content ?? "")
        _category = State(initialValue: prompt?.category ?? defaultCategory ?? "INNE")
    }

    var body: some View {
        Form {
            Section("Tytuł") {
                TextField("np. Prompt SD — portret", text: $title)
            }
            Section("Kategoria") {
                TextField("np. OBRAZY", text: $category)
                    .onChange(of: category) { _, newValue in
                        category = newValue.uppercased()
                    }
            }
            Section("Treść") {
                TextEditor(text: $content)
                    .frame(minHeight: 220)
                    .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(20)
        .frame(width: 460, height: 480)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }
                Button("Zapisz") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || category.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }

    private func save() {
        let now = Date()
        let saved = SavedPrompt(
            id: prompt?.id ?? 0,
            title: title.trimmingCharacters(in: .whitespaces),
            content: content,
            category: category.trimmingCharacters(in: .whitespaces).uppercased(),
            createdAt: prompt?.createdAt ?? now,
            lastUsedAt: prompt?.lastUsedAt ?? now
        )
        onSave(saved)
        dismiss()
    }
}
