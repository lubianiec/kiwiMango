import SwiftUI

// MARK: - ThinkingBlockView (PLAN-V2 §7.3)

/// Collapsed = pill "✦ tok myślenia · N s ▾" in violet mono (terminal-stream
/// restyle, kiwimango-warsztat-terminal.html "Anatomia rozróżnienia"). Expanded
/// = panel2 block with a 2pt violet left edge, italic text. Toggling drives
/// the caller's autoscroll pause (see `ConversationView`) — this view only
/// renders + reports taps.
struct ThinkingBlockView: View {
    @Bindable var model: ThinkingBlockModel
    var onToggle: () -> Void

    // ponytail: local constant, not a DesignSystem.swift addition — this
    // task's file scope is Session/*.swift only, and violet is used nowhere
    // else yet. Promote to `Color.coreP` in DesignSystem.swift if a second
    // call site shows up.
    private var violet: Color { Color(hex: "8B7EC9") }

    /// Tylda z przodu — to szacunek z tekstu, nie odczyt z modelu, i ma tak
    /// wyglądać. Brak liczby (stara sesja / brak tekstu) → brak członu.
    private var tokensSuffix: String {
        guard let tokens = model.tokens, tokens > 0 else { return "" }
        return " · ~\(TokenEstimate.formatStep(tokens)) tok"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.isExpanded.toggle()
                onToggle()
            } label: {
                header
            }
            .buttonStyle(.plain)

            if model.isExpanded {
                Text(model.text)
                    .font(KiwiMangoFont.sans(11.5))
                    .italic()
                    .foregroundStyle(Color.ink.opacity(0.55))
                    .padding(10)
                    .frame(maxWidth: 340, alignment: .leading)
                    .background(Color.panel2)
                    .overlay(Rectangle().fill(violet.opacity(0.4)).frame(width: 2), alignment: .leading)
                    .clipShape(RoundedCorners(radii: [0, 6, 6, 0]))
            }
        }
        .padding(.top, 4)
        .padding(.trailing, 20)
        .padding(.bottom, 8)
        // Ta sama oś 14 pt co wiadomości i wiersze narzędzi — rynna usunięta
        // razem z wcięciem, nic już nie skacze w poziomie w obrębie tury.
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HoverBorderCapsule(activeColor: violet, isActive: model.isExpanded) {
            HStack(spacing: 7) {
                Text("✦")
                Text("tok myślenia · \(String(format: "%.1f", model.seconds)) s\(tokensSuffix)")
                Text("▾")
                    .font(.system(size: 7 + FontScale.bump))
                    .rotationEffect(.degrees(model.isExpanded ? 180 : 0))
            }
            .font(KiwiMangoFont.mono(10.5))
            .foregroundStyle(violet)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }
}

/// Rounded-corner pill with hover border that brightens to `activeColor` —
/// shared shell for ThinkingBlock's header and ToolCall's capsule.
struct HoverBorderCapsule<Content: View>: View {
    var activeColor: Color
    var isActive: Bool
    @ViewBuilder var content: Content

    @State private var isHovering = false

    var body: some View {
        content
            .background(Capsule().fill(Color.clear))
            .overlay(
                Capsule().strokeBorder(
                    isActive || isHovering ? activeColor.opacity(0.4) : Color.ink.opacity(0.1),
                    lineWidth: 1
                )
            )
            .clipShape(Capsule())
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.2), value: isHovering)
    }
}

/// Per-corner rounded rect — SwiftUI has no built-in "round only these corners"
/// shape pre-macOS 26, and this is one line cheaper than importing a shape lib.
struct RoundedCorners: Shape {
    var radii: [CGFloat] // [topLeft, topRight, bottomRight, bottomLeft]

    func path(in rect: CGRect) -> Path {
        Path { path in
            let tl = radii[0], tr = radii[1], br = radii[2], bl = radii[3]
            path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
        }
    }
}
