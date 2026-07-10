import SwiftUI

// MARK: - RootView

/// Two-column window: top bar navigation + drawer sidebar + detail pane.
/// Three spaces: CHAT, AGENTS, MISSION.
struct RootView: View {

    @Environment(ChatState.self) private var chatState
    @Environment(AgentManager.self) private var agentManager

    // F1: Dashboard = HOME — apka startuje na widoku "Zużycie".
    @State private var selection: SidebarSelection? = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingNewAgentPopover = false
    @State private var searchText = ""
    @State private var searchResultIDs: Set<Int64> = []
    @FocusState private var searchFocused: Bool
    @State private var topSection: TopSection = .dashboard

    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var toastMessage: String?
    @State private var showingCommandPalette = false
    @State private var windowWidth: CGFloat = 900

    @State private var agentHistory: [AgentSessionRecord] = []
    @State private var showingHistory = false

    private let db = DatabaseManager.shared

    enum TopSection: String, Hashable, Identifiable, CaseIterable {
        case chat = "Chat"
        case agent = "Agenci"
        case mission = "Aktywne zadania"
        case dashboard = "Dashboard"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            TopSystemBar()
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebar
            } detail: {
                detail
                    .safeAreaInset(edge: .leading, spacing: 0) {
                        if columnVisibility == .detailOnly {
                            collapsedSidebarRail
                        }
                    }
            }
        }
        .sheet(isPresented: Binding(
            get: { chatState.showingModelManager },
            set: { chatState.showingModelManager = $0 }
        )) {
            ModelManagerView()
        }
        .sheet(isPresented: Binding(
            get: { chatState.showingCronManager },
            set: { chatState.showingCronManager = $0 }
        )) {
            CronManagerView()
        }
        .sheet(isPresented: Binding(
            get: { !UserDefaults.standard.bool(forKey: "kiwiMangoCompletedFirstLaunch") },
            set: { _ in }
        )) {
            FirstLaunchSetupView()
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        windowWidth = newWidth
                    }
            }
        }
        .onChange(of: windowWidth) { _, newWidth in
            if newWidth < 680, columnVisibility != .detailOnly {
                columnVisibility = .detailOnly
            } else if newWidth > 760, columnVisibility != .all {
                columnVisibility = .all
            }
        }
        .onChange(of: selection) { _, newValue in
            switch newValue {
            case .conversation(let id):
                Task { await chatState.selectConversation(id) }
                topSection = .chat
            case .agent, .agentHistory:
                topSection = .agent
            case .missionControl:
                topSection = .mission
            case .dashboard:
                topSection = .dashboard
            case nil:
                break
            }
        }
        .onChange(of: chatState.currentConversationID) { _, newValue in
            if let id = newValue {
                selection = .conversation(id)
                topSection = .chat
            }
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("") { toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .hidden()
            Button("") { showingCommandPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestNewAgent)) { _ in
            showingNewAgentPopover = true
            topSection = .agent
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestNewConversation)) { _ in
            selection = nil
            topSection = .chat
            Task { await chatState.startNewConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kiwiMangoRequestMissionControl)) { _ in
            selection = .missionControl
            topSection = .mission
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
        .overlay {
            if showingCommandPalette {
                CommandPaletteView(
                    isPresented: $showingCommandPalette,
                    onSelectConversation: { id in selection = .conversation(id) },
                    onSelectAgent: { id in selection = .agent(id) },
                    onExported: { filename in
                        withAnimation { toastMessage = "Zapisano: \(filename)" }
                    }
                )
            }
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
        .sheet(isPresented: $showingHistory) {
            HistoryView()
        }
        .task {
            await chatState.loadModels()
            await chatState.refreshClaudeAvailability()
        }
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
        case .agentHistory:
            ChatView()
        case .missionControl:
            MissionControlView(
                onSelectAgent: { id in selection = .agent(id) },
                onClose: { selection = nil }
            )
        case .dashboard:
            DashboardView()
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
            controlPanel
            drawer
        }
        .frame(maxHeight: .infinity)
        // F1: sidebar głębszy niż treść, szew bez linii — różnica tonu robi separację.
        .background(Color.kiwiMangoSidebarDeep)
        .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 380)
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Control panel (left column)

    // ponytail: referencja opisuje pionową listę nawigacji z 2px amber
    // znacznikiem po lewej. Ten sidebar używa kafli (ControlButton) i pigułek
    // (drawerHeader) zamiast listy — aktywny stan już sygnalizuje amber accent
    // + border, więc dokładanie znacznika 2px byłoby drugim wskaźnikiem tej
    // samej rzeczy (zakaz duplikowanych kontrolek, plan pkt. 7).
    private var controlPanel: some View {
        VStack(spacing: 10) {
            Text("Control Panel")
                .kiwiSectionLabel()
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ControlButton(
                    title: "CHAT",
                    icon: "plus.bubble.fill",
                    isAccent: true,
                    isActive: topSection == .chat
                ) {
                    topSection = .chat
                    selection = nil
                    Task { await chatState.startNewConversation() }
                }

                ControlButton(
                    title: "AGENT",
                    icon: "cpu.fill",
                    isAccent: true,
                    isActive: topSection == .agent
                ) {
                    topSection = .agent
                    withAnimation(.easeInOut(duration: 0.22)) {
                        showingNewAgentPopover.toggle()
                    }
                }
                .popover(isPresented: $showingNewAgentPopover) {
                    NewAgentPopover { kind, model, workDir in
                        showingNewAgentPopover = false
                        let session = agentManager.spawn(
                            kind: kind,
                            model: model.name,
                            isCloud: model.isCloud,
                            workDir: workDir
                        )
                        selection = .agent(session.id)
                        topSection = .agent
                    } onClose: {
                        showingNewAgentPopover = false
                    }
                }
            }

            HStack(spacing: 8) {
                ControlButton(
                    title: "HISTORIA",
                    icon: "clock.arrow.circlepath",
                    isActive: showingHistory
                ) {
                    showingHistory = true
                }

                ControlButton(
                    title: "DASH",
                    icon: "chart.bar.xaxis",
                    isActive: topSection == .dashboard
                ) {
                    selection = .dashboard
                    topSection = .dashboard
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Color.kiwiMangoSidebarDeep)
    }

    // MARK: - Drawer

    private var drawer: some View {
        VStack(spacing: 0) {
            drawerHeader
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            switch topSection {
            case .chat:
                chatDrawer
            case .agent:
                agentDrawer
            case .mission:
                missionDrawer
            case .dashboard:
                hudDrawer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kiwiMangoSidebarDeep)
    }

    private var drawerHeader: some View {
        HStack(spacing: 4) {
            ForEach([TopSection.chat, .agent, .mission], id: \.self) { section in
                Button(section.rawValue.uppercased()) {
                    topSection = section
                    switch section {
                    case .chat:
                        if case .conversation = selection {} else { selection = nil }
                    case .agent:
                        if case .agent = selection {} else { selection = nil }
                    case .mission:
                        selection = .missionControl
                    case .dashboard:
                        selection = .dashboard
                    }
                }
                .font(KiwiMangoFont.mono(9, weight: topSection == section ? .bold : .semibold))
                .tracking(0.6)
                .foregroundStyle(topSection == section ? Color.kiwiMangoAccent : Color.kiwiMangoTextPrimary.opacity(0.55))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(topSection == section ? Color.kiwiMangoAssistantBubble.opacity(0.70) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(topSection == section ? Color.kiwiMangoAccent.opacity(0.40) : Color.clear, lineWidth: 1)
                )
                .buttonStyle(.plain)
            }

            Spacer()

            Button { toggleSidebar() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Schowaj panel (⌃⌘S)")
        }
    }

    private var chatDrawer: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredConversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            isActive: selection == .conversation(conversation.id),
                            hasUnread: chatState.hermesUnreadConversationIDs.contains(conversation.id),
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
            }
        }
    }

    private var agentDrawer: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !agentManager.sessions.isEmpty {
                        SectionHeader(title: "NA ŻYWO", count: agentManager.sessions.count)
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
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var missionDrawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Centrum Dowodzenia")
                    .font(KiwiMangoFont.mono(13, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                Text("Podgląd wszystkich żywych agentów, ich modeli, katalogów roboczych i ostatniej aktywności.")
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .lineLimit(nil)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }

    private var hudDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dashboard")
                .font(KiwiMangoFont.mono(13, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text("Podgląd pamięci, sesji, zadań cron i kosztów Hermesa — natywnie, bez WebView.")
                .font(KiwiMangoFont.mono(10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                .lineLimit(nil)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    // MARK: - Sidebar toggle

    private func toggleSidebar() {
        withAnimation {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// Wąska listwa widoczna po schowaniu sidebara.
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
            TextField("", text: $searchText, prompt: Text("szukaj…").foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.66)))
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
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.kiwiMangoBorder.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .kiwiSectionLabel()
            Spacer()
            Text("\(count)")
                .font(KiwiMangoFont.mono(9))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
        }
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - ConversationRow

private struct ConversationRow: View {
    let conversation: Conversation
    let isActive: Bool
    var hasUnread: Bool = false
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? Color.kiwiMangoPurple : Color.clear)
                .frame(width: 3)
                .shadow(color: isActive ? Color.kiwiMangoPurple.opacity(0.6) : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(KiwiMangoFont.sans(12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(
                        isActive
                            ? Color.kiwiMangoTextPrimary
                            : Color.kiwiMangoTextPrimary.opacity(0.85)
                    )
                    .lineLimit(1)
                Text(relativeDate(conversation.updatedAt))
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(
                        isActive
                            ? Color.kiwiMangoPurple
                            : Color.kiwiMangoTextPrimary.opacity(0.55)
                    )
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            if hasUnread, !isHovered {
                Circle()
                    .fill(Color.kiwiMangoPurple)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, 12)
                    .help("Hermes dokończył coś w tle")
            }

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
                ? AnyShapeStyle(Color.kiwiMangoAssistantBubble.opacity(0.55))
                : AnyShapeStyle(isHovered ? Color.white.opacity(0.04) : Color.clear)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
    }

    private func relativeDate(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days > 7 {
            return Self.absoluteFormatter.string(from: date)
        }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
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

// MARK: - ControlButton

/// Warm-dark sidebar control: rounded tile with icon + label.
/// Active state uses the assistant-bubble brown with amber text/icon.
private struct ControlButton: View {
    let title: String
    let icon: String
    var isAccent: Bool = false
    var isActive: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isActive ? Color.kiwiMangoAssistantBubble.opacity(0.75) : Color.kiwiMangoComposerBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    isActive ? Color.kiwiMangoAccent.opacity(0.45) : Color.kiwiMangoBorder.opacity(hovering ? 0.55 : 0.30),
                                    lineWidth: 1
                                )
                        )

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(foregroundColor)
                }
                .frame(height: 44)
                .shadow(color: Color.black.opacity(hovering ? 0.15 : 0), radius: 5, x: 0, y: 2)

                Text(title)
                    .font(KiwiMangoFont.mono(8, weight: isActive ? .bold : .medium))
                    .tracking(0.6)
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
    }

    private var foregroundColor: Color {
        if isActive { return Color.kiwiMangoAccent }
        if isAccent { return Color.kiwiMangoAccent }
        return hovering ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.72)
    }
}