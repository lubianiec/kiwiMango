import SwiftUI

// MARK: - HistoryView

/// A modal history browser for both chat conversations and archived agent
/// sessions. Replaces the live sidebar history list with a clean, compact
/// journal-style view.
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ChatState.self) private var chatState
    @Environment(AgentManager.self) private var agentManager

    @State private var entries: [HistoryEntry] = []
    @State private var selectedEntry: HistoryEntry?
    @State private var showingDetail = false

    private let db = DatabaseManager.shared

    enum EntryKind {
        case chat, agent
    }

    struct HistoryEntry: Identifiable, Hashable {
        let id: Int64
        let kind: EntryKind
        let title: String
        let subtitle: String
        let timestamp: Date
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if entries.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(minWidth: 520, minHeight: 420)
            .background(Color.kiwiMangoBackground)
            .navigationTitle("Historia")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                }
            }
        }
        .sheet(isPresented: $showingDetail) {
            if let entry = selectedEntry {
                HistoryDetailSheet(entry: entry)
            }
        }
        .task { loadEntries() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("HISTORIA")
                .font(KiwiMangoFont.mono(10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
            Text("\(entries.count) wpisów · ostatnia aktywność \(lastActivityText)")
                .font(KiwiMangoFont.mono(10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.4))
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var lastActivityText: String {
        guard let last = entries.first?.timestamp else { return "brak" }
        return Self.relativeFormatter.localizedString(for: last, relativeTo: Date())
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    HistoryRow(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEntry = entry
                            showingDetail = true
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
            Text("Brak historii")
                .font(KiwiMangoFont.mono(13, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text("Rozpocznij czat lub agenta, żeby pojawiły się tu wpisy.")
                .font(KiwiMangoFont.mono(11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadEntries() {
        var loaded: [HistoryEntry] = []

        // Chat conversations
        for conversation in chatState.conversations {
            loaded.append(HistoryEntry(
                id: conversation.id,
                kind: .chat,
                title: conversation.title.isEmpty ? "Nowa rozmowa" : conversation.title,
                subtitle: "czat",
                timestamp: conversation.updatedAt
            ))
        }

        // Archived agent sessions
        let sessions = (try? db.fetchAgentSessions(limit: 100)) ?? []
        for session in sessions {
            let agentKind = AgentKind(rawValue: session.kind)?.shortName ?? session.kind
            let shortModel = session.model.split(separator: "/").last.map(String.init) ?? session.model
            let folder = URL(fileURLWithPath: session.workDir).lastPathComponent
            loaded.append(HistoryEntry(
                id: session.id + Int64.max / 2, // avoid collision with conversation ids
                kind: .agent,
                title: "\(agentKind) · \(shortModel)",
                subtitle: folder,
                timestamp: session.endedAt
            ))
        }

        entries = loaded.sorted { $0.timestamp > $1.timestamp }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pl_PL")
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - HistoryRow

private struct HistoryRow: View {
    let entry: HistoryView.HistoryEntry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.kiwiMangoTextPrimary.opacity(isHovered ? 0.6 : 0))
                .frame(width: 2)
                .shadow(color: Color.kiwiMangoTextPrimary.opacity(isHovered ? 0.6 : 0), radius: 3)

            HStack(spacing: 10) {
                kindIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(KiwiMangoFont.mono(12, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(entry.subtitle)
                            .font(KiwiMangoFont.mono(10))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                        Spacer()
                        Text(dateTimeString(entry.timestamp))
                            .font(KiwiMangoFont.mono(10))
                            .foregroundStyle(Color.kiwiMangoTextPrimary)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 9)

            Spacer(minLength: 0)
        }
        .background(
            isHovered
                ? Color.kiwiMangoTextPrimary.opacity(0.08)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovered = $0 }
    }

    private var kindIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.kiwiMangoTextPrimary.opacity(0.12))
                .frame(width: 28, height: 28)
            Image(systemName: entry.kind == .chat ? "bubble.left.fill" : "cpu.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
        }
    }

    private func dateTimeString(_ date: Date) -> String {
        let datePart = Self.dateFormatter.string(from: date)
        let timePart = Self.timeFormatter.string(from: date)
        return "\(datePart) · \(timePart)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        f.locale = Locale(identifier: "pl_PL")
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        f.locale = Locale(identifier: "pl_PL")
        return f
    }()
}

// MARK: - HistoryDetailSheet

private struct HistoryDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: HistoryView.HistoryEntry

    var body: some View {
        NavigationStack {
            Group {
                switch entry.kind {
                case .chat:
                    ChatHistoryDetail(conversationId: entry.id)
                case .agent:
                    AgentHistoryDetail(sessionId: entry.id - Int64.max / 2)
                }
            }
            .background(Color.kiwiMangoBackground)
            .navigationTitle(entry.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 480)
    }
}

private struct ChatHistoryDetail: View {
    let conversationId: Int64
    @State private var messages: [StoredMessage] = []
    private let db = DatabaseManager.shared

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(messages, id: \.id) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == "user" ? "Użytkownik" : "Asystent")
                            .font(KiwiMangoFont.mono(9, weight: .bold))
                            .foregroundStyle(message.role == "user" ? Color.kiwiMangoTextPrimary : Color.kiwiMangoTextPrimary.opacity(0.7))
                        Text(message.content)
                            .font(KiwiMangoFont.mono(12))
                            .foregroundStyle(Color.kiwiMangoTextPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.kiwiMangoPanelDeep.opacity(message.role == "user" ? 0.6 : 0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(16)
        }
        .task {
            messages = (try? db.fetchMessages(conversationId: conversationId)) ?? []
        }
    }
}

private struct AgentHistoryDetail: View {
    let sessionId: Int64
    @State private var record: AgentSessionRecord?
    private let db = DatabaseManager.shared

    var body: some View {
        ScrollView {
            if let record {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("\(AgentKind(rawValue: record.kind)?.shortName ?? record.kind) · \(record.model)")
                            .font(KiwiMangoFont.mono(11))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.7))
                        Spacer()
                        Text(record.endedAt, style: .date)
                            .font(KiwiMangoFont.mono(10))
                            .foregroundStyle(Color.kiwiMangoTextPrimary)
                    }
                    Text(record.transcript)
                        .font(KiwiMangoFont.mono(11))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .textSelection(.enabled)
                }
                .padding(16)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            record = try? db.fetchAgentSession(id: sessionId)
        }
    }
}
