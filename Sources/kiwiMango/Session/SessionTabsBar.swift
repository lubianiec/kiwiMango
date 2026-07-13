import SwiftUI

// MARK: - SessionTabsBar (PLAN-V2 §7.3 — Safari-like tabs, shared Agent/Chat)

struct SessionTabsBar: View {
    var sessions: [ConversationSession]
    @Binding var selectedID: ConversationSession.ID?
    var onAdd: () -> Void
    var onClose: (ConversationSession.ID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(sessions) { session in
                TabChip(
                    title: session.title,
                    isActive: session.id == selectedID,
                    onSelect: { selectedID = session.id },
                    onClose: { onClose(session.id) }
                )
            }
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 11 + FontScale.bump, weight: .light))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(TabAddButtonStyle())
        }
    }
}

private struct TabChip: View {
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isActive ? Color.accent : Color.ink.opacity(0.25))
                .frame(width: 5, height: 5)
            Text(String(title.prefix(30)))
                .font(KiwiMangoFont.sans(10))
                .foregroundStyle(isActive ? Color.txt : Color.ink.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
            Text("✕")
                .font(.system(size: 9 + FontScale.bump))
                .foregroundStyle(Color.ink.opacity(0.3))
                .onTapGesture(perform: onClose)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.ink.opacity(isActive ? 0.09 : (isHovering ? 0.08 : 0.045)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.ink.opacity(isActive ? 0.1 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}

private struct TabAddButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovering ? Color.accent : Color.ink.opacity(0.5))
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.ink.opacity(isHovering ? 0 : 0.12), lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 7).fill(isHovering ? Color.accent.opacity(0.08) : .clear))
            )
            .onHover { isHovering = $0 }
    }
}

// MARK: - Empty session state (new tab, no messages yet)

struct EmptySessionView: View {
    var text: String

    var body: some View {
        VStack(spacing: 8) {
            Text("✦").font(.system(size: 22 + FontScale.bump)).opacity(0.5)
            Text(text).font(KiwiMangoFont.sans(11))
        }
        .foregroundStyle(Color.ink.opacity(0.35))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
