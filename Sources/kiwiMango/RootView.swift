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
    // ponytail: druga flaga zamiast dzielenia jednej między dwa przyciski
    // (header "+" i duży pusty-stan) — dwa .popover na tym samym Bool
    // konfliktowałyby o punkt zaczepienia w SwiftUI.
    @State private var showingNewAgentPopoverFromEmptyState = false
    @State private var searchText = ""
    @State private var searchResultIDs: Set<Int64> = []
    @FocusState private var searchFocused: Bool
    @State private var topSection: TopSection = .dashboard

    @State private var renameTarget: Conversation?
    @State private var renameText = ""
    @State private var toastMessage: String?
    @State private var showingCommandPalette = false

    @Namespace private var navMarkerNS
    @State private var agentHistory: [AgentSessionRecord] = []
    @State private var showingHistory = false
    @State private var showingSettings = false

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
        // F4 fix: auto-chowanie sidebara po szerokości okna USUNIĘTE — GeometryReader
        // mierzył widok już po zwinięciu kolumny i pętla zostawiała sidebar widoczny
        // tylko w wąskim zakresie szerokości. Sidebar jest stały; chowa go wyłącznie
        // ręczny toggle (⌃⌘S / przycisk).
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .task {
            await chatState.loadModels()
            await chatState.refreshClaudeAvailability()
        }
    }

    private func refreshAgentHistory() {
        agentHistory = (try? db.fetchAgentSessions(limit: 15)) ?? []
    }

    /// Shared spawn path — header "+" and the empty-state button both call
    /// this after closing their own popover flag.
    private func spawnAgent(kind: AgentKind, model: OllamaService.ModelInfo, workDir: URL) {
        let session = agentManager.spawn(
            kind: kind,
            model: model.name,
            isCloud: model.isCloud,
            workDir: workDir
        )
        selection = .agent(session.id)
        topSection = .agent
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
            settingsFooter
        }
        .frame(maxHeight: .infinity)
        // F1: sidebar głębszy niż treść, szew bez linii — różnica tonu robi separację.
        .background(Color.kiwiMangoSidebarDeep)
        // F4: sztywna szerokość ~230px jak w referencji — koniec z rozjazdem
        // szerokości kolumny przy resize okna.
        .navigationSplitViewColumnWidth(230)
        .toolbar(removing: .sidebarToggle)
    }

    // MARK: - Control panel (left column)

    // F4 (referencja "Ali Sayed"): pionowa lista nawigacji zamiast kafli —
    // avatar+nazwa na górze, potem NavRow na pozycję, aktywna = jaśniejsza
    // biel + 2px amber znacznik po lewej (jedyny wskaźnik aktywności).
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.kiwiMangoComposerBg)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text("P")
                            .font(KiwiMangoFont.mono(12, weight: .semibold))
                            .foregroundStyle(Color.kiwiMangoTextPrimary)
                    )
                Text("Paweł")
                    .font(KiwiMangoFont.mono(13))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
            }
            .padding(.bottom, 28)

            // Zakładki drawera (CHAT/AGENCI/AKTYWNE ZADANIA) scalone z menu —
            // dublowały topSection (pułapka 7). Chat/Agenci tylko przełączają
            // sekcję; nowa rozmowa i nowy Hermes = "+" w nagłówku drawera.
            NavRow(title: "Chat", icon: "bubble.left.fill", isActive: topSection == .chat, markerNamespace: navMarkerNS) {
                topSection = .chat
                if case .conversation = selection {} else { selection = nil }
            }

            NavRow(title: "Agenci", icon: "cpu.fill", isActive: topSection == .agent, markerNamespace: navMarkerNS) {
                topSection = .agent
                if case .agent = selection {} else { selection = nil }
            }

            NavRow(title: "Zadania", icon: "list.bullet.rectangle.fill", isActive: topSection == .mission, markerNamespace: navMarkerNS) {
                selection = .missionControl
                topSection = .mission
            }

            NavRow(title: "Historia", icon: "clock.arrow.circlepath", isActive: showingHistory) {
                showingHistory = true
            }

            NavRow(title: "Dashboard", icon: "chart.bar.xaxis", isActive: topSection == .dashboard, markerNamespace: navMarkerNS) {
                selection = .dashboard
                topSection = .dashboard
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kiwiMangoSidebarDeep)
        // Napędza przesuwanie się amber znacznika między pozycjami.
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: topSection)
    }

    // MARK: - Settings footer

    /// "Na dole Ustawienia" z referencji — jedyna pozycja przypięta do dołu
    /// całego sidebara (poza scrollowalnym drawerem). SettingsView już
    /// istniała w projekcie, nigdzie niepodpięta — tylko dopięcie prezentacji.
    private var settingsFooter: some View {
        NavRow(title: "Ustawienia", icon: "gearshape.fill", isActive: showingSettings) {
            showingSettings = true
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
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

    // Rząd zakładek zastąpiony nagłówkiem sekcji w stylu referencji:
    // UPPERCASE 9px / 40% bieli + kontekstowe "+" (nowa rozmowa / nowy
    // Hermes) + toggle panelu. Sekcję przełącza menu główne wyżej.
    private var drawerHeader: some View {
        HStack(spacing: 10) {
            Text(drawerTitle)
                .font(KiwiMangoFont.mono(9, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.40))

            Spacer()

            switch topSection {
            case .chat:
                DrawerIconButton(icon: "plus", help: "Nowa rozmowa") {
                    selection = nil
                    Task { await chatState.startNewConversation() }
                }
            case .agent:
                DrawerIconButton(icon: "plus", help: "Nowy Hermes") {
                    showingNewAgentPopover = true
                }
                .popover(isPresented: $showingNewAgentPopover) {
                    NewAgentPopover { kind, model, workDir in
                        showingNewAgentPopover = false
                        spawnAgent(kind: kind, model: model, workDir: workDir)
                    } onClose: {
                        showingNewAgentPopover = false
                    }
                }
            case .mission, .dashboard:
                EmptyView()
            }

            DrawerIconButton(icon: "sidebar.left", help: "Schowaj panel (⌃⌘S)") {
                toggleSidebar()
            }
        }
    }

    private var drawerTitle: String {
        switch topSection {
        case .chat: "ROZMOWY"
        case .agent: "AGENCI"
        case .mission: "ZADANIA"
        case .dashboard: "DASHBOARD"
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
            if agentManager.sessions.isEmpty {
                emptyAgentState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
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
                    .padding(.horizontal, 14)
                }
            }
        }
    }

    // Odkrywalność (zadanie Pawła): "+" w nagłówku drawera samo w sobie jest
    // za mało widoczne — pusty stan agentów dostaje duży, wyraźny przycisk.
    private var emptyAgentState: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            Image(systemName: "cpu.fill")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.3))
            Text("Brak agentów")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
            Button {
                showingNewAgentPopoverFromEmptyState = true
            } label: {
                Text("+  Nowy Hermes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoAccentText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Color.kiwiMangoAccent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingNewAgentPopoverFromEmptyState) {
                NewAgentPopover { kind, model, workDir in
                    showingNewAgentPopoverFromEmptyState = false
                    spawnAgent(kind: kind, model: model, workDir: workDir)
                } onClose: {
                    showingNewAgentPopoverFromEmptyState = false
                }
            }
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var missionDrawer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Centrum Dowodzenia")
                    .font(KiwiMangoFont.mono(13, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoTextPrimary)
                Text("Podgląd wszystkich żywych agentów, ich modeli, katalogów roboczych i ostatniej aktywności.")
                    .font(KiwiMangoFont.mono(10.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                    .lineLimit(nil)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }

    // F4: referencja nie ma tekstów-opisów w sidebarze — sekcja Dashboard
    // zostawia drawer pusty (sierota "…natywnie, bez WebView" usunięta).
    private var hudDrawer: some View {
        Spacer()
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
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
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
                            ? Color.kiwiMangoTextPrimary
                            : Color.kiwiMangoTextPrimary.opacity(0.65)
                    )
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 8)

            Spacer(minLength: 0)

            if hasUnread, !isHovered {
                Circle()
                    .fill(Color.kiwiMangoTextPrimary)
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

// MARK: - NavRow

/// Pionowa pozycja nawigacji ze stylu referencji: ikona 15px + UPPERCASE
/// label 11.5px, wiersz 40px. Hover = jaśniejsze tło + tekst (~150ms),
/// aktywna = pełna biel + amber znacznik, który przesuwa się między
/// pozycjami sekcji przez matchedGeometryEffect (namespace z RootView).
private struct NavRow: View {
    let title: String
    let icon: String
    var isActive: Bool = false
    /// Wiersze sekcji (Chat/Agenci/Zadania/Dashboard) dostają wspólny
    /// namespace → znacznik płynnie jeździ; wiersze-sheety (Historia,
    /// Ustawienia) bez namespace → statyczny znacznik, zero konfliktu ID.
    var markerNamespace: Namespace.ID? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                marker
                    .frame(width: 2, height: 16)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 20)
                    .offset(x: hovering && !isActive ? 1.5 : 0)
                Text(title.uppercased())
                    .font(KiwiMangoFont.mono(11.5, weight: .semibold))
                    .tracking(1.5)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 8)
            .foregroundStyle(
                isActive
                    ? Color.kiwiMangoTextPrimary
                    : Color.kiwiMangoTextPrimary.opacity(hovering ? 0.85 : 0.55)
            )
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(hovering && !isActive ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(NavRowPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    @ViewBuilder
    private var marker: some View {
        if isActive, let ns = markerNamespace {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.kiwiMangoAccent)
                .matchedGeometryEffect(id: "navMarker", in: ns)
        } else if isActive {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.kiwiMangoAccent)
        } else {
            Color.clear
        }
    }
}

/// Mała ikonka akcji w nagłówku drawera — hover rozjaśnia jak w NavRow.
private struct DrawerIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(hovering ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(NavRowPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

/// Krótki spring/scale feedback na klik.
private struct NavRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}