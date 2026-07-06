import SwiftUI

// MARK: - Live shaders (Fala 9)

/// `swift build` (what the Makefile drives) doesn't reliably compile `.metal`
/// into SwiftPM's own `default.metallib` the way Xcode does — verified
/// empirically (see PLAN.md F9.0). `MetalCompilerPlugin` compiles our shaders
/// into `debug.metallib` instead, which `ShaderLibrary.bundle(.module)` can't
/// find (it only ever looks for `default.metallib`) — load it by URL instead.
let kiwiShaders: ShaderLibrary = {
    guard let url = Bundle.module.url(forResource: "debug", withExtension: "metallib") else {
        fatalError("[KiwiMango] debug.metallib not found in Bundle.module — check MetalCompilerPlugin output")
    }
    return ShaderLibrary(url: url)
}()

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
    /// Neon Noir, now alive (F9.1): instead of a static gradient, a Metal shader
    /// glow in the same top-left spot that breathes faster while a model streams
    /// and settles to a calm static frame at idle. Nakładać na NAJBARDZIEJ
    /// zewnętrzny kontener widoku; wewnętrzne tła muszą być .clear, żeby
    /// prześwitywało.
    func kiwiMangoNoirBackground() -> some View {
        background(BreathingBackdrop())
    }
}

/// Drives `breathingGlow` — a `TimelineView` that only ticks (30fps cap) while
/// a reply is streaming AND the window is active; idle renders one static
/// frame and costs nothing (PLAN.md F9 iron rule #1).
private struct BreathingBackdrop: View {
    @Environment(ChatState.self) private var chatState
    @Environment(\.scenePhase) private var scenePhase
    @State private var intensity: CGFloat = 0.35

    private var isPaused: Bool {
        !chatState.isStreaming || scenePhase != .active
    }

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: isPaused)) { timeline in
                // Faster model → faster pulse, capped so it never turns into a strobe.
                let speed = 1.2 + min(chatState.liveTokRate / 40.0, 2.0)
                let t = timeline.date.timeIntervalSinceReferenceDate * speed
                Rectangle()
                    .fill(Color(hex: "09090B"))
                    .colorEffect(kiwiShaders.breathingGlow(.float2(proxy.size), .float(t), .float(intensity)))
            }
        }
        .ignoresSafeArea()
        .onChange(of: chatState.isStreaming) { _, isStreaming in
            withAnimation(.easeInOut(duration: 0.8)) {
                intensity = isStreaming ? 1.0 : 0.35
            }
        }
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
