import SwiftUI

// MARK: - RootView

/// Two-column window: sidebar of saved conversations + the chat detail pane.
/// Custom dark "terminal" theme (not native materials) — see DesignSystem.swift.
struct RootView: View {

    @Environment(ChatState.self) private var chatState
    @Environment(AgentManager.self) private var agentManager
    @State private var selection: SidebarSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingNewAgentPopover = false
    @State private var searchText = ""
    @State private var searchResultIDs: Set<Int64> = []
    @FocusState private var searchFocused: Bool

    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var toastMessage: String?
    @State private var bootDone = false

    /// Lab state lives here, not in the views — Arena/Room must survive
    /// navigating away and back (selection switches to a conversation, then
    /// back to `.arena`/`.room`), which would otherwise reset `@State`.
    @State private var arenaState = ArenaState()
    @State private var roomState = RoomState()

    /// Archived agent sessions (Fala 13) — up to 15 most recent, newest first.
    @State private var agentHistory: [AgentSessionRecord] = []

    private let db = DatabaseManager.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                detail
                    .safeAreaInset(edge: .leading, spacing: 0) {
                        if columnVisibility == .detailOnly {
                            collapsedSidebarRail
                        }
                    }
                StatusBarView(selectedModel: chatState.selectedModel)
            }
        }
        .sheet(isPresented: Binding(
            get: { chatState.showingModelManager },
            set: { chatState.showingModelManager = $0 }
        )) {
            ModelManagerView()
        }
        .onChange(of: selection) { _, newValue in
            switch newValue {
            case .conversation(let id):
                Task { await chatState.selectConversation(id) }
            case .agent, .arena, .room, .agentHistory, .prompts, .missionControl, nil:
                break
            }
        }
        .onChange(of: chatState.currentConversationID) { _, newValue in
            // Keep sidebar highlight in sync when a conversation is created
            // lazily from `send()` rather than picked in the list.
            if let id = newValue {
                selection = .conversation(id)
            }
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .hidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestNewAgent)) { _ in
            showingNewAgentPopover = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestNewConversation)) { _ in
            selection = nil
            Task { await chatState.startNewConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestPrompts)) { _ in
            selection = .prompts
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestMissionControl)) { _ in
            selection = .missionControl
        }
        .alert("Zmień nazwę rozmowy", isPresented: renameBinding) {
            TextField("Nazwa", text: $renameText)
            Button("Zapisz") {
                if let target = renameTarget {
                    chatState.renameConversation(target.id, title: renameText)
                }
                renameTarget = nil
            }
            Button("Anuluj", role: .cancel) { renameTarget = nil }
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.toastMessage = nil }
                    }
            }
        }
        .overlay {
            if !bootDone {
                BootSequenceView(onDone: { bootDone = true })
            }
        }
        .task { refreshAgentHistory() }
        .onChange(of: agentManager.sessions.count) { _, _ in refreshAgentHistory() }
    }

    private func refreshAgentHistory() {
        agentHistory = (try? db.fetchAgentSessions(limit: 15)) ?? []
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    // MARK: - Detail routing

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .agent(let id):
            if let session = agentManager.sessions.first(where: { $0.id == id }) {
                AgentDetailView(session: session)
            } else {
                ChatView()
            }
        case .arena:
            ArenaView(arena: arenaState)
        case .room:
            RoomView(room: roomState)
        case .agentHistory(let id):
            if let record = agentHistory.first(where: { $0.id == id }) {
                AgentTranscriptView(record: record)
            } else {
                ChatView()
            }
        case .prompts:
            PromptVaultView { text in
                chatState.draft = text
                selection = nil
            }
        case .missionControl:
            MissionControlView(
                onSelectAgent: { id in selection = .agent(id) },
                onClose: { selection = nil }
            )
        case .conversation, nil:
            ChatView()
        }
    }

    private var filteredConversations: [Conversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return chatState.conversations }
        return chatState.conversations.filter { conversation in
            conversation.title.localizedCaseInsensitiveContains(query)
                || searchResultIDs.contains(conversation.id)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            logoHeader
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 0) {
                    // Hierarchy of intent (F15.2): NOWA ROZMOWA is the one filled
                    // primary action; NOWY AGENT is a secondary outline; ARENA/POKÓJ
                    // share a row as smaller, quieter half-width buttons.
                    PrimarySidebarButton(title: "+ NOWA ROZMOWA") {
                        Task {
                            await chatState.startNewConversation()
                            selection = nil
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    SecondarySidebarButton(title: "+ NOWY AGENT") {
                        showingNewAgentPopover = true
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                    .popover(isPresented: $showingNewAgentPopover, arrowEdge: .trailing) {
                        NewAgentPopover { kind, model, workDir in
                            let session = agentManager.spawn(kind: kind, model: model.name, isCloud: model.isCloud, workDir: workDir)
                            selection = .agent(session.id)
                            showingNewAgentPopover = false
                        }
                    }

                    SecondarySidebarButton(title: "📓 PROMPTY") {
                        selection = .prompts
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)

                    HStack(spacing: 6) {
                        LabSidebarButton(title: "ARENA", isActive: selection == .arena) {
                            selection = .arena
                        }
                        LabSidebarButton(title: "POKÓJ", isActive: selection == .room) {
                            selection = .room
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)

                    // Histories live below the buttons, unlabeled — a thin
                    // divider is enough to tell conversations from agents.
                    searchField
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)

                    LazyVStack(spacing: 0) {
                        ForEach(filteredConversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                isActive: selection == .conversation(conversation.id),
                                onDelete: { chatState.deleteConversation(conversation.id) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = .conversation(conversation.id)
                            }
                            .contextMenu {
                                Button("Zmień nazwę") {
                                    renameText = conversation.title
                                    renameTarget = conversation
                                }
                                Button("Eksportuj do Markdown") {
                                    if let url = chatState.exportConversation(conversation.id) {
                                        withAnimation {
                                            toastMessage = "Zapisano: \(url.lastPathComponent)"
                                        }
                                    }
                                }
                                Button("Wyślij rozmowę do Obsidiana") {
                                    if chatState.sendConversationToObsidian(conversation.id) != nil {
                                        withAnimation {
                                            toastMessage = "Zapisano w Obsidian ✓"
                                        }
                                    }
                                }
                                Button("Duplikuj") {
                                    chatState.duplicateConversation(conversation.id)
                                }
                                Divider()
                                Button("Usuń", role: .destructive) {
                                    chatState.deleteConversation(conversation.id)
                                }
                            }
                        }
                    }

                    if !agentManager.sessions.isEmpty || !agentHistory.isEmpty {
                        Spacer(minLength: 0).frame(height: 16)
                        agentsSection
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        // F15.2: sidebar is its own (lighter) surface again, separated from the
        // chat by a plain graphite hairline — not the old purple neon divider.
        .background(Color.kiwiMangoChrome)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 340)
        .toolbar(removing: .sidebarToggle)
    }

    private var logoHeader: some View {
        HStack(spacing: 8) {
            Text("KM//")
                .font(KiwiMangoFont.mono(20, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.kiwiMangoAccent, Color.kiwiMangoPurple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .neonGlow(Color.kiwiMangoAccent, intensity: 0.4)
                .realBloom(strength: 1.4, radius: 3)
            Text("kiwiMango")
                .font(KiwiMangoFont.mono(11, weight: .medium))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            Spacer()
            Button { toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("Schowaj panel (⌃⌘S)")
        }
    }

    // MARK: - Sidebar toggle

    private func toggleSidebar() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// Wąska listwa widoczna po schowaniu sidebara — jedyna droga powrotu myszą
    /// (poza ⌃⌘S), bo natywny toolbar toggle jest usunięty.
    private var collapsedSidebarRail: some View {
        VStack {
            Button { toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoAccent)
            }
            .buttonStyle(.plain)
            .help("Pokaż panel (⌃⌘S)")
            .padding(.top, 14)
            Spacer()
        }
        .frame(width: 32)
        .frame(maxHeight: .infinity)
        .background(Color.kiwiMangoBackground)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
            TextField("", text: $searchText, prompt: Text("szukaj rozmów…").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66)))
                .textFieldStyle(.plain)
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.kiwiMangoComposerBg)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: searchText) {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                searchResultIDs = []
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            searchResultIDs = (try? db.searchConversationIDs(matching: query)) ?? []
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(spacing: 0) {
            ForEach(agentManager.sessions) { session in
                AgentRow(
                    session: session,
                    isActive: selection == .agent(session.id),
                    onClose: { agentManager.close(session) }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = .agent(session.id)
                }
            }

            if !agentHistory.isEmpty {
                Text("HISTORIA")
                    .font(KiwiMangoFont.mono(9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                ForEach(agentHistory) { record in
                    AgentHistoryRow(
                        record: record,
                        isActive: selection == .agentHistory(record.id),
                        onDelete: {
                            try? db.deleteAgentSession(record.id)
                            refreshAgentHistory()
                            if selection == .agentHistory(record.id) { selection = nil }
                        }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = .agentHistory(record.id)
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar action buttons (F15.2 hierarchy)

/// Shared with `HoverGlow` — its border must ride the exact same corner
/// radius as the pill it wraps. One constant, not two numbers in two files.
let sidebarActionCornerRadius: CGFloat = 3

/// The ONE primary action of the sidebar: filled accent background, dark text.
/// Only "+ NOWA ROZMOWA" uses this — there must be exactly one thing that
/// looks like the obvious next click.
private struct PrimarySidebarButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(KiwiMangoFont.mono(11.5, weight: .bold))
                .foregroundStyle(Color.kiwiMangoAccentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: sidebarActionCornerRadius))
        }
        .buttonStyle(.plain)
        .overlay(HoverGlow(active: hovering, glowColor: .kiwiMangoPurple, cornerRadius: sidebarActionCornerRadius))
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
    }
}

/// Secondary action ("+ NOWY AGENT"): outline only, no fill — one step down
/// from the primary button in visual weight.
private struct SecondarySidebarButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(KiwiMangoFont.mono(11.5, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: sidebarActionCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: sidebarActionCornerRadius)
                        .strokeBorder(Color(hex: "4E5563"), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .overlay(HoverGlow(active: hovering, glowColor: .kiwiMangoAccent, cornerRadius: sidebarActionCornerRadius))
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
    }
}

/// Lab entries (ARENA / POKÓJ): half-width, smaller font, quietest of the four.
private struct LabSidebarButton: View {
    let title: String
    var isActive: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(KiwiMangoFont.mono(10.5, weight: .semibold))
                .foregroundStyle(isActive ? Color.kiwiMangoAccentText : Color.kiwiMangoTextPrimary.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    isActive ? Color.kiwiMangoAccent : Color.white.opacity(0.03),
                    in: RoundedRectangle(cornerRadius: sidebarActionCornerRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: sidebarActionCornerRadius)
                        .strokeBorder(isActive ? Color.clear : Color(hex: "3A3F4C"), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .overlay(HoverGlow(active: hovering, glowColor: isActive ? .kiwiMangoPurple : .kiwiMangoAccent, cornerRadius: sidebarActionCornerRadius))
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
    }
}

// MARK: - ConversationRow

private struct ConversationRow: View {
    let conversation: Conversation
    let isActive: Bool
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? Color.kiwiMangoPurple : Color.clear)
                .frame(width: 2)
                .shadow(color: isActive ? Color.kiwiMangoPurple.opacity(0.6) : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(KiwiMangoFont.sans(12, weight: isActive ? .bold : .medium))
                    .foregroundStyle(
                        isActive
                            ? Color.kiwiMangoTextPrimary
                            : Color.kiwiMangoTextPrimary.opacity(0.8)
                    )
                    .lineLimit(1)
                Text(Self.relativeDate(conversation.updatedAt))
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(
                        isActive
                            ? Color.kiwiMangoPurple
                            : Color.kiwiMangoTextPrimary.opacity(0.66)
                    )
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.kiwiMangoDanger)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 10)
                .help("Usuń rozmowę")
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
    }

    /// Relative wording ("2 godz. temu") within 7 days, plain locale date beyond that.
    private static func relativeDate(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days > 7 {
            return absoluteFormatter.string(from: date)
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: "pl_PL")
        return formatter
    }()
}
