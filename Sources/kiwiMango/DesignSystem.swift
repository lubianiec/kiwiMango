import SwiftUI

// MARK: - Live shaders (Fala 9)

/// `.bundle(.module)`, not `.default` — the SPM executable target packaged by
/// the Makefile doesn't put `default.metallib` in `Bundle.main`, only in the
/// generated `kiwiMango_kiwiMango.bundle` resource bundle (see PLAN.md F9.0).
let kiwiShaders = ShaderLibrary.bundle(.module)

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

// MARK: - KiwiMango palette (v2 — deep cyberpunk terminal)

extension Color {
    /// Page-level background outside the app chrome (#09090B, zinc-950).
    static let kiwiMangoBackground = Color(hex: "09090B")
    /// Title bars, sidebar background (#0E0E11).
    static let kiwiMangoChrome = Color(hex: "0E0E11")
    /// Main content surface (#101014).
    static let kiwiMangoSurface = Color(hex: "101014")
    /// Composer background (#0A0A0D).
    static let kiwiMangoComposerBg = Color(hex: "0A0A0D")
    /// Neon lime accent (#39FF14) — active states, terminal text, primary borders.
    static let kiwiMangoAccent = Color(hex: "39FF14")
    /// Text drawn on top of the accent color (#141416).
    static let kiwiMangoAccentText = Color(hex: "141416")
    /// Neon violet (#BF00FF) — decorations, secondary borders, sidebar highlights.
    static let kiwiMangoPurple = Color(hex: "BF00FF")
    /// Primary text, faint green-white tint (#E8FFE0).
    static let kiwiMangoTextPrimary = Color(hex: "E8FFE0")
    /// Destructive/coral accent (#ff6a5c).
    static let kiwiMangoDanger = Color(hex: "ff6a5c")
}

// MARK: - Fonts

enum KiwiMangoFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Redirected to monospaced — the v2 terminal look uses mono everywhere,
    /// including message content. Kept as a separate name (rather than replacing
    /// every `.sans` call site) so a future non-mono body font is a one-line change.
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Noir backdrop

extension View {
    /// Neon Noir: zamiast płaskiej czerni radialny gradient — chłodna fioletowa
    /// poświata od lewego górnego rogu, gasnąca w zinc-950. Nakładać na
    /// NAJBARDZIEJ zewnętrzny kontener widoku; wewnętrzne tła muszą być .clear,
    /// żeby gradient prześwitywał.
    func kiwiMangoNoirBackground() -> some View {
        background(
            RadialGradient(
                colors: [Color(hex: "161122"), Color(hex: "09090B")],
                center: UnitPoint(x: 0.25, y: 0.0),
                startRadius: 0,
                endRadius: 1000
            )
        )
    }
}

// MARK: - Neon effects

extension View {
    /// Layered glow behind a view — 3 shadow passes at decreasing opacity/increasing
    /// radius. Cheap (`.shadow`), but don't stack on many rows in a `LazyVStack` at
    /// once; prefer toggling via `.opacity` on hover rather than adding/removing it.
    func neonGlow(_ color: Color, intensity: CGFloat = 1) -> some View {
        self
            .shadow(color: color.opacity(0.9 * intensity), radius: 2)
            .shadow(color: color.opacity(0.5 * intensity), radius: 6)
            .shadow(color: color.opacity(0.25 * intensity), radius: 14)
    }
}

/// 1px border + matching glow, with an `.active` variant for focus/hover states.
struct NeonBorder: ViewModifier {
    var color: Color
    var cornerRadius: CGFloat = 4
    var lineWidth: CGFloat = 1
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(color.opacity(active ? 0.95 : 0.55), lineWidth: lineWidth)
            )
            .shadow(color: color.opacity(active ? 0.7 : 0.3), radius: active ? 12 : 4)
    }
}

extension View {
    func neonBorder(_ color: Color, cornerRadius: CGFloat = 4, lineWidth: CGFloat = 1, active: Bool = false) -> some View {
        modifier(NeonBorder(color: color, cornerRadius: cornerRadius, lineWidth: lineWidth, active: active))
    }
}

/// Generalized chamfered-corner panel shape — pick which corners get cut and by
/// how much. `UserBubbleShape`/`AssistantBubbleShape` predate this and stay as-is
/// (single fixed corner each); this is for new panels that need it configurable.
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

// MARK: - Chat bubble shapes

/// User bubble: tail notch cut into the bottom-right corner.
/// Mirrors the mockup's `polygon(0 0,100% 0,100% 100%,14px 100%,0 calc(100% - 14px))`.
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
/// Mirrors the mockup's `polygon(14px 0,100% 0,100% 100%,0 100%,0 14px)`.
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
