import SwiftUI

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
                .font(KiwiMangoFont.sans(8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.ink.opacity(0.28))
            Text(label)
                .font(KiwiMangoFont.sans(8.5, weight: .semibold))
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
//
// ponytail: static approximate $/1M in-out table, no Settings UI yet (plan
// explicitly scopes the editable dictionary out of this wave — "poza
// zakresem tej fali"). Matched by substring against whatever model name
// HermesStateReader reports (e.g. "kimi-k2.7-code:cloud"). All entries are
// "≈" — comparable public API pricing for these model families, not billed
// figures (kiwiMango pays a flat Ollama Pro subscription, not per-token).
enum ModelPricing {
    struct Price { let inputPerMillion: Double; let outputPerMillion: Double }

    private static let table: [(needle: String, price: Price)] = [
        ("kimi", Price(inputPerMillion: 0.6, outputPerMillion: 2.5)),
        ("glm", Price(inputPerMillion: 0.6, outputPerMillion: 2.2)),
        ("minimax", Price(inputPerMillion: 0.3, outputPerMillion: 1.2)),
        ("qwen", Price(inputPerMillion: 0.4, outputPerMillion: 1.2)),
        ("deepseek", Price(inputPerMillion: 0.55, outputPerMillion: 2.19)),
    ]
    /// Generic fallback for unlisted models — also "≈", flagged the same way in the UI.
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
            HStack(alignment: .top, spacing: 26) {
                sevenDayBars
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
            Text(label).font(KiwiMangoFont.sans(8.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
            Text(value)
                .font(KiwiMangoFont.sans(17, weight: .light))
                .contentTransition(.numericText())
                .animation(.default, value: value)
                .foregroundStyle(Color.txt)
            Text(sub).font(KiwiMangoFont.sans(9.5)).foregroundStyle(Color.ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendText(_ percent: Int?) -> String {
        guard let percent else { return "—" }
        return percent >= 0 ? "▲ \(percent)%" : "▼ \(-percent)%"
    }

    // MARK: 7-day bars

    private var sevenDayBars: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ostatnie 7 dni").font(KiwiMangoFont.sans(8.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
            let days = store.last7Days
            HStack(alignment: .bottom, spacing: 4) {
                if days.isEmpty {
                    Text("brak danych").font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.45))
                } else {
                    let maxTotal = max(days.map(\.total).max() ?? 1, 1)
                    ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                        let isLast = index == days.count - 1
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.accent.opacity(isLast ? 1 : 0.65))
                            .frame(width: 5, height: max(2, CGFloat(day.total) / CGFloat(maxTotal) * 56))
                    }
                }
            }
            .frame(height: 56, alignment: .bottom)
            HStack {
                Text(days.first.map(Self.weekdayAbbrev) ?? "")
                Spacer()
                Text(days.isEmpty ? "" : "Dziś")
            }
            .font(KiwiMangoFont.sans(7.5, weight: .semibold)).tracking(0.6).textCase(.uppercase)
            .foregroundStyle(Color.ink.opacity(0.3))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func weekdayAbbrev(_ day: HermesStateReader.DayTokens) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let date = formatter.date(from: day.day) else { return "" }
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "pl_PL")
        weekday.dateFormat = "EEE"
        return weekday.string(from: date).capitalized
    }

    // MARK: Costs column

    private var costsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("Koszty").font(KiwiMangoFont.sans(8.5, weight: .semibold)).tracking(1.2)
                    .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
                Text("· kurs NBP dziś").font(KiwiMangoFont.sans(8.5)).foregroundStyle(Color.ink.opacity(0.3))
            }
            if let usdRate = nbp.usdRate, let eurRate = nbp.eurRate, apiValueUSD > 0 {
                costRow("Zapłacone (flat)", value: "\(Int(DashboardStore.ollamaProMonthlyCost * usdRate)) zł", sub: "/mc")
                costRow("Wartość wg cen API", value: "\(Int(apiValueUSD * usdRate)) zł", sub: "≈ \(Int(apiValueUSD * usdRate / eurRate)) €")
                let savingsPercent = Int((1 - (DashboardStore.ollamaProMonthlyCost / (apiValueUSD))).rounded() * 100)
                Rectangle().fill(Color.green).frame(height: 2).opacity(0.9)
                costRow("Oszczędność", value: "−\(max(0, savingsPercent))%", sub: nil, valueColor: .green)
            } else {
                // pułapka #14: offline/no cache/no usage yet → no invented rate.
                Text("brak kursu NBP lub danych o zużyciu").font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func costRow(_ label: String, value: String, sub: String?, valueColor: Color = .txt) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(label).font(KiwiMangoFont.sans(9.5)).foregroundStyle(Color.ink.opacity(0.55))
            Spacer()
            HStack(spacing: 4) {
                Text(value).font(KiwiMangoFont.sans(14, weight: .light)).foregroundStyle(valueColor)
                if let sub {
                    Text(sub).font(KiwiMangoFont.sans(9.5)).foregroundStyle(Color.ink.opacity(0.55))
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
        VStack(alignment: .leading, spacing: 7) {
            Text("Udział modeli — 7 dni").font(KiwiMangoFont.sans(8.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))
                .padding(.top, 18)
            let models = Array(store.modelTokens7d.prefix(4))
            let total = max(models.reduce(0) { $0 + $1.total }, 1)
            if models.isEmpty {
                Text("brak danych").font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.45))
            } else {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    let percent = Double(model.total) / Double(total) * 100
                    HStack(spacing: 10) {
                        Text(model.model.uppercased())
                            .font(KiwiMangoFont.sans(8.5, weight: .medium)).tracking(0.4)
                            .foregroundStyle(Color.ink.opacity(0.65))
                            .frame(width: 100, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.ink.opacity(0.15))
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.accent.opacity(index == 0 ? 1 : 0.6))
                                        .frame(width: geo.size.width * percent / 100)
                                }
                        }
                        .frame(height: 2)
                        Text("\(Int(percent))%")
                            .font(KiwiMangoFont.mono(9.5))
                            .foregroundStyle(Color.ink.opacity(0.55))
                            .frame(width: 28, alignment: .trailing)
                    }
                }
            }
        }
    }
}
