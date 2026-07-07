import SwiftUI
import Charts

// MARK: - KiwiCardView

struct KiwiCardView: View {
    let card: KiwiCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .padding(12)
        .background(Color.kiwiMangoSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = card.icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.kiwiMangoAccent)
            }
            Text(card.title)
                .font(KiwiMangoFont.mono(12, weight: .bold))
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Spacer()
        }
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch card.type {
        case .weather, .stats:
            rowsGrid(rows: card.rows ?? [])
        case .steps:
            stepsView(steps: card.steps ?? [])
        case .compare:
            compareView(leftTitle: card.leftTitle, rightTitle: card.rightTitle, rows: card.rows ?? [])
        }

        if let chart = card.chart {
            chartView(chart)
                .padding(.top, 10)
        }
    }

    private func rowsGrid(rows: [CardRow]) -> some View {
        let columns: [GridItem] = rows.count >= 4
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible())]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    if let icon = row.icon {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kiwiMangoAccent.opacity(0.9))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label)
                            .font(KiwiMangoFont.mono(9))
                            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                        Text(row.value)
                            .font(KiwiMangoFont.mono(15, weight: .semibold))
                            .foregroundStyle(Color.kiwiMangoTextPrimary)
                    }
                }
            }
        }
    }

    private func stepsView(steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)")
                        .font(KiwiMangoFont.mono(10, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccentText)
                        .frame(width: 20, height: 20)
                        .background(Color.kiwiMangoAccent)
                        .clipShape(Circle())
                    Text(step)
                        .font(KiwiMangoFont.sans(12))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
            }
        }
    }

    private func compareView(leftTitle: String?, rightTitle: String?, rows: [CardRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let leftTitle = leftTitle, let rightTitle = rightTitle {
                HStack {
                    Text(leftTitle)
                        .font(KiwiMangoFont.mono(10, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoAccent)
                    Spacer()
                    Text(rightTitle)
                        .font(KiwiMangoFont.mono(10, weight: .bold))
                        .foregroundStyle(Color.kiwiMangoPurple)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.value)
                        .font(KiwiMangoFont.mono(14, weight: .semibold))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                    Spacer()
                    Text(row.label)
                        .font(KiwiMangoFont.mono(10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
                }
            }
        }
    }

    private func chartView(_ chart: CardChart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label = chart.label {
                Text(label)
                    .font(KiwiMangoFont.mono(9))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.6))
            }
            Chart {
                ForEach(Array(chart.points.enumerated()), id: \.offset) { _, point in
                    if chart.kind == "line" {
                        LineMark(
                            x: .value("x", point.x),
                            y: .value("y", point.y)
                        )
                        .foregroundStyle(Color.kiwiMangoAccent)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    } else {
                        BarMark(
                            x: .value("x", point.x),
                            y: .value("y", point.y)
                        )
                        .foregroundStyle(Color.kiwiMangoAccent)
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let text = value.as(String.self) {
                            Text(text)
                                .font(KiwiMangoFont.mono(8))
                                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.5))
                        }
                    }
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 90)
        }
    }
}
