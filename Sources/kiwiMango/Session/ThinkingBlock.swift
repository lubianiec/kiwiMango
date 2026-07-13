import SwiftUI

// MARK: - ThinkingBlockView (PLAN-V2 §7.3)

/// Collapsed = pill "✦ Tok myślenia · N s ▼". Expanded = panel2 block with a
/// 2pt accent left edge, italic text. Toggling drives the caller's autoscroll
/// pause (see `ConversationView`) — this view only renders + reports taps.
struct ThinkingBlockView: View {
    @Bindable var model: ThinkingBlockModel
    var onToggle: () -> Void

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
                    .font(KiwiMangoFont.sans(10.5))
                    .italic()
                    .foregroundStyle(Color.ink.opacity(0.55))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.panel2)
                    .overlay(Rectangle().fill(Color.accent.opacity(0.35)).frame(width: 2), alignment: .leading)
                    .clipShape(RoundedCorners(radii: [0, 8, 8, 0]))
            }
        }
        .frame(maxWidth: 340, alignment: .leading)
    }

    private var header: some View {
        HoverBorderCapsule(activeColor: .accent, isActive: model.isExpanded) {
            HStack(spacing: 7) {
                Text("✦")
                Text("Tok myślenia · \(String(format: "%.1f", model.seconds)) s")
                Text("▼")
                    .font(.system(size: 7 + FontScale.bump))
                    .rotationEffect(.degrees(model.isExpanded ? 180 : 0))
            }
            .font(KiwiMangoFont.sans(9.5))
            .foregroundStyle(model.isExpanded ? Color.accent : Color.ink.opacity(0.45))
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
