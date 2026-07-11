import AppKit
import SwiftUI
import SwiftTerm

// MARK: - TerminalHostView

/// Hosts an existing `LocalProcessTerminalView` (SwiftTerm) inside SwiftUI.
///
/// Deliberately does NOT create the terminal itself — `AgentManager` owns and
/// caches one `LocalProcessTerminalView` per `AgentSession` for its whole
/// lifetime (see pitfall #1 in PLAN.md F4). This view only mounts whichever
/// instance it's handed into a plain container `NSView`, swapping the subview
/// when the selected session changes and leaving it alone otherwise — so
/// switching to the chat tab and back does not recreate the process or lose
/// scrollback.
struct TerminalHostView: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizesSubviews = true
        mount(terminal, in: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminal.superview !== container {
            mount(terminal, in: container)
        }
    }

    private func mount(_ terminal: LocalProcessTerminalView, in container: NSView) {
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(terminal)
        DispatchQueue.main.async {
            container.window?.makeFirstResponder(terminal)
        }
    }
}

// MARK: - Terminal styling

extension LocalProcessTerminalView {
    /// Applies the Pinterest palette to a freshly created terminal:
    /// background #14213D, text #E5E5E5, cursor orange #FCA311, mono 12.
    /// ANSI palette is left untouched — the agent TUI supplies its own colors.
    func applyKiwiMangoTheme() {
        nativeBackgroundColor = NSColor(hex: "272729")
        nativeForegroundColor = NSColor(hex: "F2F2F7")
        caretColor = NSColor(hex: "F2994A")
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var hexValue = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexValue = hexValue.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexValue).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
