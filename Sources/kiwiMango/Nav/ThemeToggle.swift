import SwiftUI

// MARK: - ThemeToggle (moved from Nav/TopNav.swift 2026-08-05 — the dashboard
// page was deleted so there's nothing left to switch between; only the
// theme toggle survives, top-right of the window.)

struct ThemeToggle: View {
    @State private var theme = ThemeStore.shared
    @State private var isHovering = false

    var body: some View {
        Button {
            theme.toggle()
        } label: {
            Image(systemName: theme.mode == .dark ? "moon" : "sun.max")
                .font(.system(size: 11 + FontScale.bump, weight: .medium))
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
