import SwiftUI

// MARK: - Token formatting (Fala 3, PLAN-DASHBOARD.md)
//
// Moved from `Agents/MissionControlView.swift` (was `private`) — identical
// "1.2M" / "3.4k" / "812" formatting, now shared with DashboardView's tiles/tables.
func formatTokens(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
    return "\(count)"
}

// MARK: - MetricItem (Fala 3, PLAN-DASHBOARD.md)
//
// Moved from `Agents/MissionControlView.swift` (`private`, kept there since F18.2) —
// pure move, `private` dropped so MissionControlView's metrics bar and
// `DashboardView`'s tiles share one implementation instead of two copies. Defaults
// reproduce MissionControlView's original look exactly (same fonts/colors/opacity);
// callers that want a different palette — Dashboard's native semantic colors instead
// of the chat's neon theme — pass overrides instead of forking the view.
struct MetricItem: View {
    let label: String
    let value: String
    var labelColor: Color = Color.kiwiMangoTextPrimary.opacity(0.55)
    var valueColor: Color = Color.kiwiMangoTextPrimary
    var font: Font = KiwiMangoFont.mono(11, weight: .semibold)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(KiwiMangoFont.mono(8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(labelColor)
            Text(value)
                .font(font)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
    }
}

// MARK: - TokenBar (Fala 3, PLAN-DASHBOARD.md)
//
// Moved from the near-identical private `tokenBar(_:)` methods on
// `AgentMissionCard`/`HermesMissionCard` in MissionControlView.swift. Those two
// differed only in which colored segments they draw (2 vs 3) and what the caption
// text says — this takes both as parameters instead of guessing a fixed shape. The
// visual (proportional-width segments in a fixed-height bar, mono caption below) is
// byte-for-byte what both call sites drew before the move.
struct TokenBar: View {
    struct Segment {
        let value: Int
        let color: Color
    }

    let segments: [Segment]
    let caption: String
    var captionColor: Color = Color.kiwiMangoTextPrimary.opacity(0.65)
    var height: CGFloat = 5

    private var total: CGFloat { CGFloat(max(segments.reduce(0) { $0 + $1.value }, 1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: proxy.size.width * CGFloat(segment.value) / total)
                    }
                }
            }
            .frame(height: height)

            Text(caption)
                .font(KiwiMangoFont.mono(9.5))
                .foregroundStyle(captionColor)
        }
    }
}

// MARK: - Sparkline (Fala 3, PLAN-DASHBOARD.md)
//
// Moved from `AgentMissionCard.sparkline(_:)` — same Canvas drawing (normalize to
// the value range, one stroked polyline, no fill/points/axes), now parameterized on
// color so Dashboard can draw it in the system accent instead of the chat's neon
// orange without a second copy of the math.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Color.kiwiMangoTextPrimary.opacity(0.7)
    var lineWidth: CGFloat = 1
    var height: CGFloat = 18
    var animate: Bool = false

    // F2 (mono redesign): "rysowanie się" linii przy wejściu. Canvas nie ma
    // .trim jak Shape, więc najlazysza droga to maskowanie szerokością zamiast
    // przepisywania na Path/Shape — animate=false (domyślne, wszystkie stare
    // call site'y) trzyma progress=1 od startu, więc zero zmiany zachowania.
    @State private var progress: CGFloat

    init(values: [Double], color: Color = Color.kiwiMangoTextPrimary.opacity(0.7), lineWidth: CGFloat = 1, height: CGFloat = 18, animate: Bool = false) {
        self.values = values
        self.color = color
        self.lineWidth = lineWidth
        self.height = height
        self.animate = animate
        _progress = State(initialValue: animate ? 0 : 1)
    }

    var body: some View {
        if values.count > 1 {
            Canvas { context, size in
                let maxValue = values.max() ?? 1
                let minValue = min(values.min() ?? 0, maxValue - 0.001)
                let range = max(maxValue - minValue, 0.001)

                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let normalized = (value - minValue) / range
                    let y = size.height - CGFloat(normalized) * size.height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(color), lineWidth: lineWidth)
            }
            .frame(height: height)
            .mask(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle().frame(width: proxy.size.width * progress)
                }
            }
            .onAppear {
                guard animate else { return }
                withAnimation(.easeOut(duration: 0.6)) { progress = 1 }
            }
        }
    }
}
