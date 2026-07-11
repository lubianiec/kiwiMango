import SwiftUI

// MARK: - TopNav (PLAN-V2 §7.1)

/// Text nav "DASHBOARD AGENT CHAT" + theme toggle, top-right of the window.
/// No underlines, no backgrounds — active = accent + glow, hover on an
/// inactive item = wider tracking + brighter ink.
struct TopNav: View {
    @Binding var page: Page
    @State private var theme = ThemeStore.shared

    var body: some View {
        HStack(spacing: 14) {
            ThemeToggleButton(theme: theme)

            HStack(spacing: 16) {
                ForEach(Page.allCases, id: \.self) { item in
                    NavItem(title: item.rawValue, isActive: page == item) {
                        page = item
                    }
                }
            }
        }
    }
}

private struct NavItem: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(isActive ? 1.4 : (isHovering ? 2.0 : 1.4))
                .textCase(.uppercase)
                .foregroundStyle(isActive ? Color.accent : Color.ink.opacity(isHovering ? 0.75 : 0.55))
                .shadow(color: isActive ? Color.accent.opacity(0.45) : .clear, radius: isActive ? 6 : 0)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: isHovering)
        .animation(.easeInOut(duration: 0.25), value: isActive)
        .onHover { isHovering = $0 }
    }
}

private struct ThemeToggleButton: View {
    let theme: ThemeStore
    @State private var isHovering = false

    var body: some View {
        Button {
            theme.toggle()
        } label: {
            Image(systemName: theme.mode == .dark ? "moon" : "sun.max")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.ink.opacity(isHovering ? 0.9 : 0.65))
                .frame(width: 26, height: 26)
                .overlay(
                    Circle().strokeBorder(Color.ink.opacity(0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.2), value: theme.mode)
    }
}
