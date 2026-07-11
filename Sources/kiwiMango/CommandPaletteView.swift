import SwiftUI

// MARK: - CommandPaletteView

/// F26.11: ⌘K quick-jump — fuzzy search across conversations, live agent
/// sessions, models, and a handful of app actions. One `TextField` + one
/// keyboard-navigable list, closes on Esc/backdrop tap/selection.
struct CommandPaletteView: View {
    @Environment(ChatState.self) private var chatState
    @Environment(AgentManager.self) private var agentManager
    @Binding var isPresented: Bool
    let onSelectConversation: (Int64) -> Void
    let onSelectAgent: (UUID) -> Void
    let onExported: (String) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool

    private enum Item: Identifiable {
        case conversation(Conversation)
        case agent(AgentSession)
        case model(String)
        case action(id: String, title: String, systemImage: String, perform: () -> Void)

        var id: String {
            switch self {
            case .conversation(let c): return "conv-\(c.id)"
            case .agent(let a): return "agent-\(a.id)"
            case .model(let m): return "model-\(m)"
            case .action(let id, _, _, _): return "action-\(id)"
            }
        }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var actions: [Item] {
        [
            .action(id: "new", title: "Nowa rozmowa", systemImage: "plus.bubble") {
                NotificationCenter.default.post(name: .kiwiMangoRequestNewConversation, object: nil)
            },
            .action(id: "agent", title: "Nowy agent", systemImage: "cpu") {
                NotificationCenter.default.post(name: .kiwiMangoRequestNewAgent, object: nil)
            },
            .action(id: "mission", title: "Centrum Dowodzenia", systemImage: "eye") {
                NotificationCenter.default.post(name: .kiwiMangoRequestMissionControl, object: nil)
            },
            .action(id: "models", title: "Ustawienia modeli", systemImage: "gearshape") {
                chatState.showingModelManager = true
            },
            .action(id: "cron", title: "Moje automaty (cron)", systemImage: "clock") {
                chatState.showingCronManager = true
            },
            .action(id: "export", title: "Eksportuj bieżącą rozmowę do Markdown", systemImage: "square.and.arrow.up") {
                guard let id = chatState.currentConversationID,
                      let url = chatState.exportConversation(id) else { return }
                onExported(url.lastPathComponent)
            }
        ]
    }

    private var filteredConversations: [Item] {
        let source = trimmedQuery.isEmpty
            ? Array(chatState.conversations.prefix(6))
            : chatState.conversations.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
        return source.map { .conversation($0) }
    }

    private var filteredAgents: [Item] {
        let source = trimmedQuery.isEmpty
            ? agentManager.sessions
            : agentManager.sessions.filter { $0.title.localizedCaseInsensitiveContains(trimmedQuery) }
        return source.map { .agent($0) }
    }

    private var filteredModels: [Item] {
        guard !trimmedQuery.isEmpty else { return [] }
        return chatState.availableModels
            .map(\.name)
            .filter { $0.localizedCaseInsensitiveContains(trimmedQuery) }
            .prefix(6)
            .map { .model($0) }
    }

    private var filteredActions: [Item] {
        guard !trimmedQuery.isEmpty else { return actions }
        return actions.filter {
            if case .action(_, let title, _, _) = $0 {
                return title.localizedCaseInsensitiveContains(trimmedQuery)
            }
            return false
        }
    }

    private var sections: [(title: String, items: [Item])] {
        [
            ("ROZMOWY", filteredConversations),
            ("AGENCI", filteredAgents),
            ("MODELE", filteredModels),
            ("AKCJE", filteredActions)
        ].filter { !$0.items.isEmpty }
    }

    private var flatItems: [Item] { sections.flatMap(\.items) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchField
                Rectangle().fill(Color.kiwiMangoBorder.opacity(0.35)).frame(height: 1)
                if flatItems.isEmpty {
                    Text("Brak wyników")
                        .font(KiwiMangoFont.mono(11))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
                        .padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sections, id: \.title) { section in
                                    Text(section.title)
                                        .font(KiwiMangoFont.mono(9, weight: .semibold))
                                        .tracking(1)
                                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
                                        .padding(.horizontal, 14)
                                        .padding(.top, 10)
                                        .padding(.bottom, 4)
                                    ForEach(section.items) { item in
                                        row(for: item, isSelected: flatIndex(of: item) == selectedIndex)
                                            .id(item.id)
                                    }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selectedIndex) { _, newValue in
                            if flatItems.indices.contains(newValue) {
                                withAnimation { proxy.scrollTo(flatItems[newValue].id, anchor: .center) }
                            }
                        }
                    }
                }
            }
            .frame(width: 560)
            .background(Color.kiwiMangoChrome)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.kiwiMangoTextPrimary.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 24)
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) {
            if !flatItems.isEmpty { selectedIndex = min(selectedIndex + 1, flatItems.count - 1) }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if !flatItems.isEmpty { selectedIndex = max(selectedIndex - 1, 0) }
            return .handled
        }
    }

    private func flatIndex(of item: Item) -> Int? {
        flatItems.firstIndex { $0.id == item.id }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            TextField("", text: $query, prompt: Text("rozmowa, agent, model, akcja…").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.mono(13))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .focused($searchFocused)
                .onSubmit { execute(at: selectedIndex) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task { searchFocused = true }
    }

    @ViewBuilder
    private func row(for item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: item))
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.kiwiMangoAccentText : Color.kiwiMangoTextPrimary.opacity(0.6))
                .frame(width: 16)
            Text(label(for: item))
                .font(KiwiMangoFont.mono(12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.kiwiMangoAccentText : Color.kiwiMangoTextPrimary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(isSelected ? Color.kiwiMangoTextPrimary.opacity(0.85) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { perform(item) }
    }

    private func icon(for item: Item) -> String {
        switch item {
        case .conversation: return "bubble.left"
        case .agent: return "cpu"
        case .model: return "cube"
        case .action(_, _, let systemImage, _): return systemImage
        }
    }

    private func label(for item: Item) -> String {
        switch item {
        case .conversation(let c): return c.title
        case .agent(let a): return a.title
        case .model(let m): return m
        case .action(_, let title, _, _): return title
        }
    }

    private func execute(at index: Int) {
        guard flatItems.indices.contains(index) else { return }
        perform(flatItems[index])
    }

    private func perform(_ item: Item) {
        switch item {
        case .conversation(let c):
            onSelectConversation(c.id)
        case .agent(let a):
            onSelectAgent(a.id)
        case .model(let m):
            chatState.selectedModel = m
        case .action(_, _, _, let perform):
            perform()
        }
        close()
    }

    private func close() {
        isPresented = false
    }
}
