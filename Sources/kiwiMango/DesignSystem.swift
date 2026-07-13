import SwiftUI

// MARK: - Color(hex:)

extension Color {
    /// Builds a Color from a hex string like "#c6ff3d" or "c6ff3d".
    init(hex: String) {
        var hexValue = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexValue = hexValue.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexValue).scanHexInt64(&rgb)

        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255

        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Theme (PLAN-V2 §2)

enum Theme: String, CaseIterable {
    case dark, light
}

/// Single source of truth for the active theme. Read from anywhere (view body,
/// Canvas draw closure, etc.) via `Color.ink`/`Color.bg`/... below — each of
/// those computed vars reads `ThemeStore.shared.mode`, and since `ThemeStore`
/// is `@Observable`, SwiftUI's body-access tracking picks up the dependency
/// even through the indirection, so views repaint on toggle without needing
/// `@Environment` plumbing everywhere.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var mode: Theme {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "theme") }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "theme") ?? ""
        mode = Theme(rawValue: raw) ?? .dark
    }

    func toggle() {
        mode = (mode == .dark) ? .light : .dark
    }
}

// MARK: - Palette tokens (PLAN-V2 §2 — the only source of color in the app)

extension Color {
    private static var isDark: Bool { ThemeStore.shared.mode == .dark }

    static var ink: Color { isDark ? Color(hex: "F2F2F7") : Color(hex: "2E2E34") }
    static var bg: Color { isDark ? Color(hex: "2C2C2E") : Color(hex: "D7D7DB") }
    static var chrome: Color { isDark ? Color(hex: "29292B") : Color(hex: "CDCDD2") }
    static var panel: Color { isDark ? Color(hex: "232325") : Color(hex: "CBCBD0") }
    static var panel2: Color { isDark ? Color(hex: "272729") : Color(hex: "D0D0D4") }
    static var popbg: Color { isDark ? Color(hex: "38383B") : Color(hex: "E1E1E5") }
    static var compbg: Color { isDark ? Color(hex: "323235") : Color(hex: "DDDDE1") }
    static var bubble: Color { isDark ? Color(hex: "3A3A3D") : Color(hex: "C5C5CB") }
    static var txt: Color { isDark ? Color(hex: "F2F2F7") : Color(hex: "2E2E34") }
    static var accent: Color { isDark ? Color(hex: "F2994A") : Color(hex: "C97620") }
    static var green: Color { isDark ? Color(hex: "7FB77E") : Color(hex: "4F8B4E") }
    static var blue: Color { isDark ? Color(hex: "7EA6C9") : Color(hex: "4E7BA0") }
    static var teal: Color { isDark ? Color(hex: "6FBFB0") : Color(hex: "3F8D7F") }
    static var rose: Color { isDark ? Color(hex: "C98A9E") : Color(hex: "A55E77") }
    static var danger: Color { isDark ? Color(hex: "FF6A5C") : Color(hex: "C74836") }

    /// P-core bars in the CPU hardware panel — one fixed hex, not themed (PLAN-V2 §2/§7.4).
    static let coreP = Color(hex: "8B7EC9")
    /// Inline code color — one fixed hex, not themed (PLAN-V2 §2/§7.4).
    static let code = Color(hex: "FCA311")

    // MARK: - Terminal / syntax palette
    static var syntaxKeyword: Color { isDark ? Color(hex: "FF7B72") : Color(hex: "D73A49") }
    static var syntaxString: Color { isDark ? Color(hex: "A5D6FF") : Color(hex: "032162") }
    static var syntaxComment: Color { isDark ? Color(hex: "8B949E") : Color(hex: "6A737D") }
    static var syntaxNumber: Color { code }

    // MARK: - v1 aliases (kept so Chat/SyntaxHighlighter.swift and Chat/MarkdownText.swift
    // keep compiling untouched this wave; ponytail: rename call sites when those files
    // are next touched instead of doing it as a drive-by here).
    static var kiwiMangoTextPrimary: Color { txt }
    static var kiwiMangoSyntaxKeyword: Color { syntaxKeyword }
    static var kiwiMangoSyntaxString: Color { syntaxString }
    static var kiwiMangoSyntaxComment: Color { syntaxComment }
    static var kiwiMangoSyntaxNumber: Color { syntaxNumber }
    static var kiwiMangoPanelDeep: Color { panel2 }
}

// MARK: - Section label

/// The recurring "CONTROL PANEL" / "MODEL" / "SESJE DZIŚ" look: tiny uppercase
/// caps, wide tracking, muted. One modifier so every section/eyebrow label
/// across the app matches exactly.
struct KiwiSectionLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(KiwiMangoFont.mono(10.5, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Color.txt.opacity(0.55))
    }
}

extension View {
    func kiwiSectionLabel() -> some View {
        modifier(KiwiSectionLabelStyle())
    }
}

// MARK: - Font scale (global readability bump)

enum FontScale {
    /// Global font-size bump for readability (PLAN-V2 polish).
    static let bump: CGFloat = 2
}

// MARK: - Fonts

enum KiwiMangoFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size + FontScale.bump, weight: weight, design: .monospaced)
    }

    /// SF Pro (system default) — body font per PLAN-V2 §1. Kept as a separate
    /// name (rather than inlining `.system`) so call sites read intent.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size + FontScale.bump, weight: weight)
    }
}

// MARK: - Warm dark effects

extension View {
    /// Soft glow behind small elements (status dots, active nav item).
    func neonGlow(_ color: Color, intensity: CGFloat = 1) -> some View {
        self
            .shadow(color: color.opacity(0.35 * intensity), radius: 4, x: 0, y: 2)
    }
}

/// Subtle border matching the theme. Active variant uses full accent color.
struct NeonBorder: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat = 4
    var lineWidth: CGFloat = 1
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(color.opacity(active ? 0.8 : 0.35), lineWidth: lineWidth)
            )
            .shadow(color: color.opacity(active ? 0.25 : 0.10), radius: active ? 8 : 3, x: 0, y: 1)
    }
}

extension View {
    func neonBorder(_ color: Color, cornerRadius: CGFloat = 4, lineWidth: CGFloat = 1, active: Bool = false) -> some View {
        modifier(NeonBorder(color: color, cornerRadius: cornerRadius, lineWidth: lineWidth, active: active))
    }
}

// MARK: - Hover glow

/// Hover feedback for interactive elements: border brightens to accent + soft shadow.
struct HoverGlow: View {
    let active: Bool
    let glowColor: Color
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(glowColor.opacity(0.85), lineWidth: 1)
            .shadow(color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2)
            .opacity(active ? 1 : 0)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.15), value: active)
    }
}

// MARK: - Compact number formatting (PLAN-V2 §7.2 — "48,2M" / "142k" style)

/// Polish-locale compact token/count formatter shared by AgentsSection,
/// CostsBlock — matches the reference mockup's `48,2M` / `142k` look.
func formatCompactTokens(_ n: Int) -> String {
    let value = Double(abs(n))
    let sign = n < 0 ? "-" : ""
    switch value {
    case 1_000_000...:
        return sign + String(format: "%.1fM", value / 1_000_000).replacingOccurrences(of: ".", with: ",")
    case 1_000...:
        return sign + String(format: "%.0fk", value / 1_000)
    default:
        return "\(n)"
    }
}

// MARK: - Chat bubble shapes (reused by ConversationView, fala 2/3)

/// Generalized chamfered-corner panel shape — pick which corners get cut and by how much.
struct CutCornerShape: Shape {
    struct Corners: OptionSet {
        let rawValue: Int
        static let topLeft = Corners(rawValue: 1 << 0)
        static let topRight = Corners(rawValue: 1 << 1)
        static let bottomRight = Corners(rawValue: 1 << 2)
        static let bottomLeft = Corners(rawValue: 1 << 3)
    }

    var corners: Corners
    var size: CGFloat = 10

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tl = corners.contains(.topLeft) ? size : 0
        let tr = corners.contains(.topRight) ? size : 0
        let br = corners.contains(.bottomRight) ? size : 0
        let bl = corners.contains(.bottomLeft) ? size : 0

        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 { path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + tr)) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 { path.addLine(to: CGPoint(x: rect.maxX - br, y: rect.maxY)) }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 { path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bl)) }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 { path.addLine(to: CGPoint(x: rect.minX + tl, y: rect.minY)) }
        path.closeSubpath()
        return path
    }
}

/// User bubble: tail notch cut into the bottom-right corner.
struct UserBubbleShape: Shape {
    var tail: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + tail, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - tail))
        path.closeSubpath()
        return path
    }
}

/// Assistant bubble: tail notch cut into the top-left corner.
struct AssistantBubbleShape: Shape {
    var tail: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tail, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tail))
        path.closeSubpath()
        return path
    }
}
