import SwiftUI

/// One distinct hue per weekday for the 7-day donut — reused by both the
/// legend dots (`CostsBlock`) and the arc segments (`DonutChart`) so they
/// always agree. Existing palette tokens only, no new colors.
private func weekdayColor(for index: Int) -> Color {
    let palette: [Color] = [.accent, .blue, .teal, .rose, .green, .danger, .coreP]
    return palette[index % palette.count]
}

// MARK: - SectionHead (PLAN-V2 §7.2 — "01 AGENCI ───" header, shared by
// CostsBlock/ProcessSection/AgentsWindow; one definition, reused across the
// target. Moved here from the deleted AgentsSection.swift 2026-07-12 when the
// full agent list left the Dashboard.)

struct SectionHead: View {
    let number: String
    let label: String
    var trailing: AnyView?

    init(_ number: String, _ label: String, @ViewBuilder trailing: () -> some View = { EmptyView() }) {
        self.number = number
        self.label = label
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(number)
                .font(KiwiMangoFont.sans(9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.ink.opacity(0.28))
            Text(label)
                .font(KiwiMangoFont.sans(9, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color.ink.opacity(0.65))
            Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1)
            trailing
        }
        .padding(.vertical, 10)
    }
}

// MARK: - ModelPricing (PLAN-V2 §7.2 pt.4)

enum ModelPricing {
    struct Price { let inputPerMillion: Double; let outputPerMillion: Double }

    private static let table: [(needle: String, price: Price)] = [
        ("kimi", Price(inputPerMillion: 0.6, outputPerMillion: 2.5)),
        ("glm", Price(inputPerMillion: 0.6, outputPerMillion: 2.2)),
        ("minimax", Price(inputPerMillion: 0.3, outputPerMillion: 1.2)),
        ("qwen", Price(inputPerMillion: 0.4, outputPerMillion: 1.2)),
        ("deepseek", Price(inputPerMillion: 0.55, outputPerMillion: 2.19)),
    ]
    private static let fallback = Price(inputPerMillion: 0.5, outputPerMillion: 2.0)

    static func price(for model: String) -> Price {
        let lower = model.lowercased()
        return table.first(where: { lower.contains($0.needle) })?.price ?? fallback
    }
}

// MARK: - CostsBlock ("02 TOKENY", PLAN-V2 §7.2 pt.4)

struct CostsBlock: View {
    let store: DashboardStore
    @State private var nbp = NBPClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("02", "Tokeny")
            kpiRow
            HStack(alignment: .top, spacing: 22) {
                sevenDayDonut
                Rectangle().fill(Color.ink.opacity(0.07)).frame(width: 1)
                costsColumn
            }
            .padding(.top, 16)
            modelShare
        }
        .task { await nbp.refreshIfNeeded() }
    }

    // MARK: KPI row

    private var kpiRow: some View {
        HStack(spacing: 12) {
            kpi("Dziś", value: store.todayTokens.map { formatCompactTokens($0.total) } ?? "—",
                sub: trendText(store.todayTrendPercent))
            kpi("7 dni", value: formatCompactTokens(store.sevenDayTotal),
                sub: "\(formatCompactTokens(store.sevenDayTotal / 7))/d")
            kpi("Miesiąc", value: formatCompactTokens(store.monthTotal),
                sub: trendText(store.monthTrendPercent))
            kpi("Od początku", value: formatCompactTokens(store.allTimeTotal), sub: "total")
        }
    }

    private func kpi(_ label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(KiwiMangoFont.sans(9.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
            Text(value)
                .font(KiwiMangoFont.sans(18, weight: .light))
                .contentTransition(.numericText())
                .animation(.default, value: value)
                .foregroundStyle(Color.txt)
            Text(sub).font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendText(_ percent: Int?) -> String {
        guard let percent else { return "—" }
        return percent >= 0 ? "▲ \(percent)%" : "▼ \(-percent)%"
    }

    // MARK: 7-day donut chart (replacing the bar chart)

    private var sevenDayDonut: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Ostatnie 7 dni").font(KiwiMangoFont.sans(9.5, weight: .semibold)).tracking(1.2)
                    .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
                Text("· wejście / wyjście").font(KiwiMangoFont.sans(9)).foregroundStyle(Color.ink.opacity(0.3))
            }

            let days = store.last7Days
            if days.isEmpty {
                Text("brak danych").font(KiwiMangoFont.sans(11)).foregroundStyle(Color.ink.opacity(0.45))
            } else {
                HStack(spacing: 16) {
                    DonutChart(days: days)
                        .frame(width: 110, height: 110)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(days.enumerated()).suffix(4), id: \.offset) { index, day in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(weekdayColor(for: index))
                                    .frame(width: 6, height: 6)
                                Text(Self.weekdayAbbrevShort(day))
                                    .font(KiwiMangoFont.sans(9.5, weight: .medium))
                                    .foregroundStyle(Color.ink.opacity(0.65))
                                    .frame(width: 24, alignment: .leading)
                                Text(formatCompactTokens(day.total))
                                    .font(KiwiMangoFont.mono(10))
                                    .foregroundStyle(Color.txt)
                                Spacer()
                            }
                        }
                    }
                    .frame(width: 110)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func weekdayAbbrevShort(_ day: HermesStateReader.DayTokens) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let date = formatter.date(from: day.day) else { return "" }
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "pl_PL")
        weekday.dateFormat = "EEEEE"
        return weekday.string(from: date).uppercased()
    }

    // MARK: Costs column

    private var costsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("Koszty").font(KiwiMangoFont.sans(9.5, weight: .semibold)).tracking(1.2)
                    .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
                Text("· kurs NBP dziś").font(KiwiMangoFont.sans(9)).foregroundStyle(Color.ink.opacity(0.3))
            }
            if let usdRate = nbp.usdRate, let eurRate = nbp.eurRate, apiValueUSD > 0 {
                costRow("Zapłacone (flat)", value: "\(Int(DashboardStore.ollamaProMonthlyCost * usdRate)) zł", sub: "/mc")
                costRow("Wartość wg cen API", value: "\(Int(apiValueUSD * usdRate)) zł", sub: "≈ \(Int(apiValueUSD * usdRate / eurRate)) €")
                let savingsPercent = Int((1 - (DashboardStore.ollamaProMonthlyCost / (apiValueUSD))).rounded() * 100)
                Rectangle().fill(Color.green).frame(height: 2).opacity(0.9)
                costRow("Oszczędność", value: "−\(max(0, savingsPercent))%", sub: nil, valueColor: .green)
            } else {
                Text("brak kursu NBP lub danych o zużyciu").font(KiwiMangoFont.sans(11)).foregroundStyle(Color.ink.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func costRow(_ label: String, value: String, sub: String?, valueColor: Color = .txt) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(label).font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.55))
            Spacer()
            HStack(spacing: 4) {
                Text(value).font(KiwiMangoFont.sans(15, weight: .light)).foregroundStyle(valueColor)
                if let sub {
                    Text(sub).font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.55))
                }
            }
        }
    }

    private var apiValueUSD: Double {
        store.modelTokens7d.reduce(0) { sum, model in
            let price = ModelPricing.price(for: model.model)
            return sum
                + Double(model.inputTokens) / 1_000_000 * price.inputPerMillion
                + Double(model.outputTokens) / 1_000_000 * price.outputPerMillion
        }
    }

    // MARK: Model share

    private var modelShare: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Udział modeli — 7 dni").font(KiwiMangoFont.sans(9.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
                .padding(.top, 18)
            let models = Array(store.modelTokens7d.prefix(4))
            let total = max(models.reduce(0) { $0 + $1.total }, 1)
            if models.isEmpty {
                Text("brak danych").font(KiwiMangoFont.sans(11)).foregroundStyle(Color.ink.opacity(0.45))
            } else {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        let percent = Double(model.total) / Double(total) * 100
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .stroke(Color.ink.opacity(0.12), lineWidth: 4)
                                Circle()
                                    .trim(from: 0, to: percent / 100)
                                    .stroke(modelColor(for: index), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.easeOut, value: percent)
                                Text("\(Int(percent))%")
                                    .font(KiwiMangoFont.mono(11, weight: .semibold))
                                    .foregroundStyle(Color.txt)
                            }
                            .frame(width: 52, height: 52)

                            Text(model.model.uppercased())
                                .font(KiwiMangoFont.sans(9.5, weight: .medium))
                                .tracking(0.3)
                                .foregroundStyle(Color.ink.opacity(0.65))
                                .lineLimit(1)
                            Text(formatCompactTokens(model.total))
                                .font(KiwiMangoFont.mono(10))
                                .foregroundStyle(Color.ink.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func modelColor(for index: Int) -> Color {
        switch index {
        case 0: Color.accent
        case 1: Color.blue
        case 2: Color.teal
        default: Color.rose
        }
    }
}

// MARK: - Donut chart

private struct DonutChart: View {
    let days: [HermesStateReader.DayTokens]

    private var total: Double {
        max(Double(days.reduce(0) { $0 + $1.total }), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.ink.opacity(0.08))
            Circle()
                .stroke(Color.ink.opacity(0.12), lineWidth: 10)

            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 - 5
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var startAngle = -Double.pi / 2

                for (index, day) in days.enumerated() {
                    let sweep = Double(day.total) / total * 2 * .pi
                    let endAngle = startAngle + sweep
                    let path = Path { path in
                        path.addArc(center: center, radius: radius, startAngle: .radians(startAngle), endAngle: .radians(endAngle), clockwise: false)
                    }
                    context.stroke(path, with: .color(weekdayColor(for: index)), lineWidth: 10)
                    startAngle = endAngle
                }
            }

            VStack(spacing: 0) {
                Text(formatCompactTokens(Int(total)))
                    .font(KiwiMangoFont.mono(14, weight: .semibold))
                    .foregroundStyle(Color.txt)
                Text("7 dni")
                    .font(KiwiMangoFont.sans(8.5, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(Color.ink.opacity(0.4))
            }
        }
    }
}
