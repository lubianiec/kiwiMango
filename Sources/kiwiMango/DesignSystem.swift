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

// MARK: - KiwiMango palette (v3 — warm dark, unified)
// Based on Paweł's reference screenshot: deep charcoal surfaces, warm orange
// accents, brown assistant bubbles, grey user bubbles, round send button.

extension Color {
    /// Window-level background (deep charcoal, almost black).
    static let kiwiMangoBackground = Color(hex: "141414")
    /// Top bar and elevated chrome (slightly lighter than background).
    static let kiwiMangoChrome = Color(hex: "1C1C1E")
    /// Sidebar / drawer surface.
    static let kiwiMangoSurface = Color(hex: "1A1A1D")
    /// Composer and input fields.
    static let kiwiMangoComposerBg = Color(hex: "1F1F23")
    /// Primary accent / buttons / send — warm orange.
    static let kiwiMangoAccent = Color(hex: "F2994A")
    /// Text drawn on top of the accent color.
    static let kiwiMangoAccentText = Color(hex: "FFFFFF")
    /// Secondary warm highlight for active rows / amber details.
    static let kiwiMangoPurple = Color(hex: "F5A623")
    /// Primary text (soft white).
    static let kiwiMangoTextPrimary = Color(hex: "F2F2F7")
    /// Destructive/coral accent.
    static let kiwiMangoDanger = Color(hex: "FF6A5C")
    /// Deep recessed panel for popovers / modals.
    static let kiwiMangoPanelDeep = Color(hex: "161618")
    /// Warm amber for numeric literals in syntax highlighter.
    static let kiwiMangoSyntaxNumber = Color(hex: "FCA311")

    // MARK: - Chat bubble colors (F3 redesign mono: monochrom, kolor tylko w Dashboardzie)
    /// User message bubble background — lighter graphite tone (hover tone from tokens).
    static let kiwiMangoUserBubble = Color(hex: "232326")
    /// Assistant message bubble background — same tone as a Dashboard card, mono.
    static let kiwiMangoAssistantBubble = Color(hex: "1A1A1D")
    /// Assistant bubble text color.
    static let kiwiMangoAssistantText = Color(hex: "F2F2F7")
    /// Subtle border used on inactive inputs / cards.
    static let kiwiMangoBorder = Color(hex: "3F3F46")
    /// Sidebar surface — deeper than window/card background (redesign mono F1).
    /// No divider line at the seam; the tone jump alone reads as separation.
    static let kiwiMangoSidebarDeep = Color(hex: "101012")
}

// MARK: - Section label (redesign mono F1)

/// The recurring "CONTROL PANEL" / "MODEL" / "SESJE DZIŚ" look from the mono
/// reference: tiny uppercase caps, wide tracking, muted. One modifier so every
/// section/eyebrow label across the app matches exactly.
struct KiwiSectionLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(KiwiMangoFont.mono(10.5, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.45))
    }
}

extension View {
    func kiwiSectionLabel() -> some View {
        modifier(KiwiSectionLabelStyle())
    }
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
    @State private var intensity: CGFloat = 0.45

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
                    .fill(Color.kiwiMangoBackground)
                    .colorEffect(kiwiShaders.breathingGlow(.float2(proxy.size), .float(t), .float(intensity)))
            }
        }
        .ignoresSafeArea()
        .onChange(of: chatState.isStreaming) { _, isStreaming in
            withAnimation(.easeInOut(duration: 0.8)) {
                intensity = isStreaming ? 1.2 : 0.45
            }
        }
    }
}

// MARK: - Real bloom (F9.2)

extension View {
    /// A real sampled bloom, not a shadow trick — use ONLY on small, non-scrolling
    /// elements (logo, status dots, composer prefix). `layerEffect` re-samples a
    /// blurred version of the layer every frame it's asked to; on a `LazyVStack`
    /// row that means bloom-on-scroll jank, so never put this in the transcript.
    func realBloom(strength: CGFloat = 1.2, radius: CGFloat = 3) -> some View {
        layerEffect(
            kiwiShaders.neonBloom(.float(strength), .float(radius)),
            maxSampleOffset: CGSize(width: radius * 2, height: radius * 2)
        )
    }
}

// MARK: - Materialize-in (F9.3)

/// One-shot "teleport" for a freshly appended chat bubble — a horizontal wave
/// distortion that settles over 0.35s. `isActive` must be `false` for loaded
/// history / scroll-recycled rows (see `ChatState.lastAnimatedMessageID`);
/// when inactive this renders as a plain, undistorted, fully-opaque view.
private struct MaterializeIn: ViewModifier {
    let isActive: Bool
    var onFinished: () -> Void = {}

    @State private var progress: CGFloat = 0
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { size = proxy.size }
                }
            )
            .distortionEffect(
                kiwiShaders.materialize(.float2(size), .float(progress)),
                maxSampleOffset: CGSize(width: 40, height: 0)
            )
            .opacity(0.15 + 0.85 * progress)
            .onAppear {
                guard isActive else {
                    progress = 1
                    return
                }
                withAnimation(.easeOut(duration: 0.35)) { progress = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onFinished() }
            }
    }
}

extension View {
    func materializeIn(isActive: Bool, onFinished: @escaping () -> Void = {}) -> some View {
        modifier(MaterializeIn(isActive: isActive, onFinished: onFinished))
    }
}

// MARK: - Warm dark effects

extension View {
    /// Soft, warm shadow behind small elements (send button, active dots). Keeps the
    /// same call sites as the old neonGlow but matches the screenshot's subtle depth.
    func neonGlow(_ color: Color, intensity: CGFloat = 1) -> some View {
        self
            .shadow(color: color.opacity(0.35 * intensity), radius: 4, x: 0, y: 2)
    }
}

/// Subtle border matching the warm dark theme. Active variant uses full accent color.
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

/// Hover feedback for sidebar action buttons: border brightens to accent + soft shadow.
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
