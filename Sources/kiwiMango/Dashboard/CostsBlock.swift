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

    // MARK: Period (Claude Design mockup, 2026-08-05 — KPI kafle są
    // klikalne, klik pokazuje "udział modeli" dla tego okresu pod spodem.
    // Nested in CostsBlock rather than file scope — no reason for any other
    // view to reference it.

    enum Period: Equatable {
        case today, week, month, allTime

        /// Label used in "UDZIAŁ MODELI — <label>".
        var label: String {
            switch self {
            case .today: "DZIŚ"
            case .week: "7 DNI"
            case .month: "MIESIĄC"
            case .allTime: "OD POCZĄTKU"
            }
        }
    }

    let store: DashboardStore
    @State private var nbp = NBPClient()
    @State private var selectedPeriod: Period?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHead("02", "Tokeny")
            kpiRow
            modelSharePanel
            HStack(alignment: .top, spacing: 22) {
                sevenDayColumn
                Rectangle().fill(Color.ink.opacity(0.07)).frame(width: 1)
                costsColumn
            }
            .padding(.top, 16)
        }
        .task { await nbp.refreshIfNeeded() }
    }

    // MARK: KPI row — clickable, selects the period shown in modelSharePanel.

    private var kpiRow: some View {
        HStack(spacing: 12) {
            kpi(.today, "Dziś", value: store.todayTokens.map { formatCompactTokens($0.total) } ?? "—", sub: "")
            kpi(.week, "7 dni", value: formatCompactTokens(store.sevenDayTotal),
                sub: "\(formatCompactTokens(store.sevenDayTotal / 7))/d")
            kpi(.month, "Miesiąc", value: formatCompactTokens(store.monthTotal), sub: "")
            kpi(.allTime, "Od początku", value: formatCompactTokens(store.allTimeTotal), sub: "total")
        }
    }

    private func kpi(_ period: Period, _ label: String, value: String, sub: String) -> some View {
        let isSelected = selectedPeriod == period
        return VStack(alignment: .leading, spacing: 2) {
            Text(label).font(KiwiMangoFont.sans(9.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(isSelected ? Color.accent : Color.ink.opacity(0.45))
            Text(value)
                .font(KiwiMangoFont.sans(18, weight: .light))
                .contentTransition(.numericText())
                .animation(.default, value: value)
                .foregroundStyle(Color.txt)
            Text(sub).font(KiwiMangoFont.sans(10)).foregroundStyle(Color.ink.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPeriod = (selectedPeriod == period) ? nil : period
        }
    }

    // MARK: Model share panel — replaces the old always-visible "Udział
    // modeli" block under the 7-day chart.
    //
    // ponytail: mockup daje temu panelowi sztywne 92pt, bo w mockupie zawsze
    // były 3 modele. Na realnych danych bywa 4 + „inne" — wiersze wychodziły
    // poza ramkę i NACHODZIŁY na wykres 7 dni i kolumnę kosztów (Paweł złapał
    // to od razu). Wysokość naturalna + animacja: rzędy poniżej przesuwają
    // się przy rozwijaniu, ale nic się nie nakłada.

    private var modelSharePanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.ink.opacity(0.08)).frame(height: 1)
            if let period = selectedPeriod {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Udział modeli — \(period.label)")
                        .font(KiwiMangoFont.sans(9, weight: .semibold))
                        .tracking(1.1)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.ink.opacity(0.45))

                    let slices = modelSlices(for: models(for: period))
                    if slices.isEmpty {
                        Text("brak danych").font(KiwiMangoFont.sans(11)).foregroundStyle(Color.ink.opacity(0.45))
                    } else {
                        ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                            modelRow(slice)
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selectedPeriod)
    }

    private func modelRow(_ slice: ModelSlice) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(slice.color).frame(width: 7, height: 7)
            Text(slice.name)
                .font(KiwiMangoFont.sans(10, weight: .medium))
                .foregroundStyle(Color.ink.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 62, alignment: .leading)
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4).fill(Color.ink.opacity(0.12))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(slice.color)
                            .frame(width: geo.size.width * max(slice.percent, 0) / 100)
                    }
            }
            .frame(height: 7)
            Text("\(Int(slice.percent))%")
                .font(KiwiMangoFont.mono(10.5, weight: .semibold))
                .foregroundStyle(Color.txt)
                .frame(width: 30, alignment: .trailing)
            Text(formatCompactTokens(slice.tokens))
                .font(KiwiMangoFont.mono(9))
                .foregroundStyle(Color.ink.opacity(0.45))
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func models(for period: Period) -> [HermesStateReader.ModelTokens] {
        switch period {
        case .today: store.modelTokensToday
        case .week: store.modelTokens7d
        case .month: store.modelTokensMonth
        case .allTime: store.modelTokensAllTime
        }
    }

    // MARK: 7-day bar chart — one left column ("skąd wzięły się tokeny z 7
    // dni"). Model share used to live here too (segmented bar + legend);
    // moved up into `modelSharePanel`, driven by the KPI row selection
    // instead of always showing the 7-day window only.

    private var sevenDayColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wykres 7 dni").font(KiwiMangoFont.sans(9.5, weight: .semibold)).tracking(1.2)
                .textCase(.uppercase).foregroundStyle(Color.ink.opacity(0.45))

            let days = store.last7Days
            if days.isEmpty {
                Text("brak danych").font(KiwiMangoFont.sans(11)).foregroundStyle(Color.ink.opacity(0.45))
            } else {
                // ponytail: 84 = 48pt słupka + etykieta wartości nad + skrót
                // dnia pod + odstępy. Było 130 (wysokość z czasów skali
                // liniowej) — nadmiar spychał wiersz kosztów poza dolną
                // krawędź okna; przy 76 z kolei ginęły nazwy dni.
                WeekBarChart(days: days)
                    .frame(height: 84)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                let paidZl = DashboardStore.ollamaProMonthlyCost * usdRate
                let apiZl = apiValueUSD * usdRate
                // Uczciwy wzór z mockupu: gdy abonament kosztuje więcej niż
                // użycie wg cen API, oszczędność wychodzi ujemna — pokazujemy
                // to zamiast zamiatać pod dywan przez `max(0, ...)`.
                let savingsPct = Int(((apiZl - paidZl) / apiZl * 100).rounded())
                let resultColor: Color = savingsPct >= 0 ? .green : .danger
                let sign = savingsPct >= 0 ? "+" : "\u{2212}"

                costRow("Zapłacone", value: "\(Int(paidZl)) zł", sub: "/mc")
                costRow("Wg cen API", value: "\(Int(apiZl)) zł", sub: "≈ \(Int(apiZl / eurRate)) €")
                Rectangle().fill(resultColor.opacity(0.85)).frame(height: 2)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                costRow("Oszczędność", value: "\(sign)\(abs(savingsPct))%", sub: nil, valueColor: resultColor)
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
                Text(value).font(KiwiMangoFont.sans(17, weight: .light)).foregroundStyle(valueColor)
                if let sub {
                    Text(sub).font(KiwiMangoFont.sans(10.5)).foregroundStyle(Color.ink.opacity(0.55))
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

    // MARK: Model slices — shared by `modelSharePanel` for whichever period
    // is selected. Top 4 models by tokens; the rest fold into a grey "inne".

    private struct ModelSlice: Identifiable {
        var id: String { name }
        let name: String
        let tokens: Int
        let percent: Double
        let color: Color
    }

    private func modelSlices(for models: [HermesStateReader.ModelTokens]) -> [ModelSlice] {
        let ranked = models.sorted { $0.total > $1.total }
        let total = max(ranked.reduce(0) { $0 + $1.total }, 1)
        let shown = Array(ranked.prefix(4))
        let otherTotal = ranked.dropFirst(4).reduce(0) { $0 + $1.total }
        var slices = shown.enumerated().map { index, model in
            ModelSlice(name: Self.shortModelName(model.model), tokens: model.total,
                       percent: Double(model.total) / Double(total) * 100, color: modelColor(for: index))
        }
        if otherTotal > 0 {
            slices.append(ModelSlice(name: "inne", tokens: otherTotal,
                                      percent: Double(otherTotal) / Double(total) * 100, color: Color.ink.opacity(0.3)))
        }
        return slices
    }

    /// "glm-5.2:cloud" → "glm-5.2" — the `:cloud` suffix is an Ollama routing
    /// detail, not content worth the label width in a 4-row list.
    private static func shortModelName(_ model: String) -> String {
        model.replacingOccurrences(of: ":cloud", with: "")
    }

    private func modelColor(for index: Int) -> Color {
        switch index {
        case 0: Color.accent
        case 1: Color.blue
        case 2: Color.teal
        case 3: Color.rose
        default: Color.green
        }
    }
}

// MARK: - Week bar chart (pn–nd) — log scale + per-weekday-position color, so
// one outlier day (e.g. 26M tokens) doesn't flatten the rest of the week to
// zero (Claude Design mockup, 2026-08-05).

private struct WeekBarChart: View {
    let days: [HermesStateReader.DayTokens]

    private static let barColors: [Color] = [.accent, .blue, .teal, .rose, .green, .danger, .coreP]
    private static let maxBarHeight: Double = 48

    private var maxValue: Int { max(days.map(\.total).max() ?? 1, 1) }
    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.string(from: Date())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let isToday = day.day == todayKey
                let barHeight = max(4, log10(Double(day.total) + 1) / log10(Double(maxValue) + 1) * Self.maxBarHeight)
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    Text(day.total > 0 ? formatCompactTokens(day.total) : "")
                        .font(KiwiMangoFont.mono(8))
                        .foregroundStyle(Color.ink.opacity(0.45))
                        .fixedSize()
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.barColors[index % Self.barColors.count])
                        .frame(maxWidth: 20)
                        .frame(height: barHeight)
                        .clipShape(.rect(topLeadingRadius: 3, topTrailingRadius: 3))
                        .animation(.easeOut, value: day.total)
                    Text(Self.weekdayAbbrev(day))
                        .font(KiwiMangoFont.sans(8.5, weight: isToday ? .heavy : .regular))
                        .foregroundStyle(isToday ? Color.txt : Color.ink.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private static func weekdayAbbrev(_ day: HermesStateReader.DayTokens) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        guard let date = formatter.date(from: day.day) else { return "" }
        let names = ["nd", "pn", "wt", "śr", "cz", "pt", "sb"] // Calendar weekday: 1=Sunday
        let weekday = Calendar.current.component(.weekday, from: date)
        return names[weekday - 1]
    }
}
