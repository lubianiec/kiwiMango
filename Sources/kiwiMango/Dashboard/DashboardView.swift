import AppKit
import SwiftUI

// MARK: - DashboardView — jedna strona "Zużycie" (2026-07-10)
//
// Zastępuje 17-sekcyjny dashboard (enum DashboardSection + segmentBar + parity
// panele). Układ 1:1 z zaakceptowanego mockupu
// (~/Downloads/kiwi-dashboard-zuzycie-mockup.html):
//   1. pasek statusu (chrome): kropka hero + Hermes/Telegram | MODEL | KONTO |
//      SESJE DZIŚ | "odświeżono X temu"
//   2. rząd 4 kart KPI: Dziś / 7 dni / Ten miesiąc / Koszt
//   3. wykres 30 dni (2/3) + donut udziału modeli i Hermes vs kiwi czat (1/3)
//   4. tabela per model / Sesje 7 dni / Pamięć + Cron
// Żelazna zasada F9: bloom TYLKO na kropce hero, żadnych shaderów nigdzie
// indziej. Wykresy: czysty Canvas/Path, zero frameworków.
struct DashboardView: View {
    @State private var store = DashboardStore()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                UsageStatusBar(store: store)
                kpiRow
                HStack(alignment: .top, spacing: 14) {
                    DashboardCard(title: "Tokeny — ostatnie 30 dni") {
                        MonthlyStackedChart(days: store.last30Days)
                    }
                    DashboardCard {
                        ModelShareDonut(store: store)
                    }
                    .frame(width: 330)
                }
                HStack(alignment: .top, spacing: 14) {
                    DashboardCard(title: "Per model — 7 dni") {
                        ModelTable(store: store)
                    }
                    DashboardCard(title: "Sesje — 7 dni") {
                        SessionsSummary(store: store)
                    }
                    .frame(width: 265)
                    DashboardCard(title: "Pamięć Hermesa") {
                        MemoryAndCron(store: store)
                    }
                    .frame(width: 285)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kiwiMangoBackground)
        .task { store.start() }
    }

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 14) {
            todayCard
            sevenDayCard
            monthCard
            costCard
        }
    }

    // MARK: KPI: Dziś

    private var todayCard: some View {
        KpiCard(title: "Dziś") {
            Text(formatTokens(store.todayTokens?.total ?? 0))
                .kpiBigStyle(color: .kiwiMangoAccent)
            Text(todaySub)
                .kpiSubStyle()
            TrendLabel(percent: store.todayTrendPercent, suffix: "vs wczoraj")
        }
    }

    private var todaySub: String {
        guard let today = store.todayTokens else { return "brak danych" }
        return "↑ \(formatTokens(today.inputTokens)) wej. · ↓ \(formatTokens(today.outputTokens)) wyj."
    }

    // MARK: KPI: 7 dni

    private var sevenDayCard: some View {
        KpiCard(title: "7 dni") {
            Text(formatTokens(store.sevenDayTotal))
                .kpiBigStyle()
            Text("średnio \(formatTokens(store.sevenDayTotal / 7)) / dzień")
                .kpiSubStyle()
            Sparkline(
                values: store.last7Days.map { Double($0.total) },
                color: .kiwiMangoAccent.opacity(0.8),
                lineWidth: 1.5,
                height: 24
            )
        }
    }

    // MARK: KPI: Ten miesiąc

    private var monthCard: some View {
        KpiCard(title: "Ten miesiąc") {
            Text(formatTokens(store.monthTotal))
                .kpiBigStyle()
            Text("total od początku: \(formatTokens(store.allTimeTotal))")
                .kpiSubStyle()
            TrendLabel(percent: store.monthTrendPercent, suffix: "vs poprzedni")
        }
    }

    // MARK: KPI: Koszt

    private var costCard: some View {
        KpiCard(title: "Koszt") {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("$\(Int(DashboardStore.ollamaProMonthlyCost))")
                    .kpiBigStyle()
                Text("/ mc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
            Text(costSubLabel)
                .kpiSubStyle()
            HStack(spacing: 8) {
                Text("Ollama Pro")
                    .kpiSubStyle()
                Text("FLAT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.kiwiMangoAccent.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.kiwiMangoAccent)
            }
        }
    }

    private var costSubLabel: String {
        guard let cost = store.effectiveCostPerMillionTokens else {
            return "brak tokenów w tym miesiącu"
        }
        return "\(String(format: "%.2f", cost)) $ / 1M tok. w tym mies."
    }
}

// MARK: - Kolory serii wykresów (tylko strona "Zużycie", z mockupu)

private extension Color {
    static let chartAmberDim = Color(hex: "C77B3A")
    static let chartSand = Color(hex: "D9C8A9")
    static let chartMoss = Color(hex: "8FA98B")
    static let trendUp = Color(hex: "7FB77E")
    static let trendDown = Color(hex: "C97B6E")
}

// MARK: - DashboardCard (bez zmian — wspólna rama karty)

struct DashboardCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kiwiMangoSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.kiwiMangoBorder.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct KpiCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        DashboardCard(title: title) {
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
}

private extension Text {
    func kpiBigStyle(color: Color = .kiwiMangoTextPrimary) -> some View {
        font(.system(size: 26, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    func kpiSubStyle() -> some View {
        font(.system(size: 11.5))
            .monospacedDigit()
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            .lineLimit(1)
    }
}

/// "▲ 18% vs wczoraj" / "▼ 6% vs poprzedni" — nic, gdy brak danych porównawczych
/// (żadnych zmyślonych 0%).
private struct TrendLabel: View {
    let percent: Int?
    let suffix: String

    var body: some View {
        if let percent {
            Text("\(percent >= 0 ? "▲" : "▼") \(abs(percent))% \(suffix)")
                .font(.system(size: 11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(percent >= 0 ? Color.trendUp : Color.trendDown)
        }
    }
}

// MARK: - 1. Pasek statusu

private struct UsageStatusBar: View {
    let store: DashboardStore

    private var isAlive: Bool { store.gatewayState?.isAlive ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            statusBlock
            separator
            keyValue("MODEL", store.configSummary?.activeModel ?? "—")
            separator
            keyValue("KONTO", accountLabel)
            separator
            keyValue("SESJE DZIŚ", "\(store.sessionsToday)")
            Spacer(minLength: 0)
            Text(refreshLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.kiwiMangoChrome, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.kiwiMangoBorder.opacity(0.55), lineWidth: 1)
        )
    }

    private var statusBlock: some View {
        HStack(spacing: 11) {
            // Żelazna zasada F9: bloom TYLKO na tej jednej kropce hero,
            // nigdzie indziej na całej stronie.
            Circle()
                .fill(isAlive ? Color.trendUp : Color.kiwiMangoTextPrimary.opacity(0.25))
                .frame(width: 10, height: 10)
                .realBloom(strength: 1.0, radius: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(isAlive ? "Hermes aktywny" : "Hermes offline")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
        }
    }

    private var subtitle: String {
        guard let gatewayState = store.gatewayState else {
            return "brak ~/.hermes/gateway_state.json"
        }
        if let telegram = gatewayState.state.platforms["telegram"]?.state {
            return "Telegram: \(telegram)"
        }
        return gatewayState.state.state
    }

    private var accountLabel: String {
        if let account = store.ollamaAccount {
            return "\(account.name) · \(account.plan.uppercased())"
        }
        return store.ollamaChecked ? "offline" : "…"
    }

    private var refreshLabel: String {
        guard let date = store.lastStateRefresh else { return "odświeżanie…" }
        return "odświeżono \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.kiwiMangoBorder)
            .frame(width: 1, height: 28)
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key)
                .font(.system(size: 10))
                .tracking(0.6)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.unitsStyle = .short
        return formatter
    }()
}

// MARK: - 3a. Wykres 30 dni (słupki stack wejście/wyjście)

private struct MonthlyStackedChart: View {
    let days: [HermesStateReader.DayTokens]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Spacer()
                legendItem("wejście", color: .kiwiMangoAccent)
                legendItem("wyjście", color: Color.chartSand.opacity(0.6))
            }
            if days.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .frame(height: 190)
            } else {
                chartCanvas
                    .frame(height: 190)
                HStack {
                    Text(firstDayLabel)
                    Spacer()
                    Text("dziś")
                }
                .font(.system(size: 10))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
            }
        }
    }

    private var chartCanvas: some View {
        Canvas { context, size in
            let maxTotal = max(days.map(\.total).max() ?? 1, 1)
            let labelWidth: CGFloat = 34
            let plotX = labelWidth
            let plotWidth = size.width - labelWidth

            // Siatka pozioma (bardzo subtelna) + etykiety osi skalowane do danych.
            for step in 1...4 {
                let fraction = CGFloat(step) / 4
                let y = size.height * (1 - fraction)
                var line = Path()
                line.move(to: CGPoint(x: plotX, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Color.kiwiMangoTextPrimary.opacity(0.07)), lineWidth: 1)

                let label = Text(formatTokens(Int(Double(maxTotal) * Double(fraction))))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
                context.draw(context.resolve(label), at: CGPoint(x: 2, y: y), anchor: .leading)
            }

            let slot = plotWidth / CGFloat(days.count)
            let barWidth = min(slot * 0.62, 16)
            for (index, day) in days.enumerated() {
                // ponytail: "wejście" = total - output (input + cache read/write
                // zlane w jeden segment), żeby słupki sumowały się do tych samych
                // totali co kafle KPI.
                let output = day.outputTokens
                let input = day.total - output
                let inputHeight = size.height * CGFloat(input) / CGFloat(maxTotal)
                let outputHeight = size.height * CGFloat(output) / CGFloat(maxTotal)
                let x = plotX + slot * CGFloat(index) + (slot - barWidth) / 2
                let isToday = index == days.count - 1

                let outputRect = CGRect(
                    x: x, y: size.height - inputHeight - outputHeight,
                    width: barWidth, height: outputHeight
                )
                context.fill(
                    Path(roundedRect: outputRect, cornerRadius: 2),
                    with: .color(Color.chartSand.opacity(isToday ? 0.75 : 0.45))
                )
                let inputRect = CGRect(
                    x: x, y: size.height - inputHeight,
                    width: barWidth, height: max(inputHeight, 1)
                )
                context.fill(
                    Path(roundedRect: inputRect, cornerRadius: 2),
                    with: .color(Color.kiwiMangoAccent.opacity(isToday ? 1 : 0.72))
                )
            }
        }
    }

    private var firstDayLabel: String {
        guard let first = days.first,
              let date = Self.dayParser.date(from: first.day) else { return "" }
        return Self.axisFormatter.string(from: date)
    }

    private func legendItem(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "d MMM"
        return formatter
    }()
}

// MARK: - 3b. Donut udziału modeli + Hermes vs kiwiMango czat

private struct ModelShareDonut: View {
    let store: DashboardStore

    private static let segmentColors: [Color] = [
        .kiwiMangoAccent, .chartAmberDim, Color.chartSand.opacity(0.7), Color.chartMoss.opacity(0.7),
    ]

    /// Max 4 segmenty — reszta modeli zostaje na szarym torze tła.
    private var topModels: [HermesStateReader.ModelTokens] { Array(store.modelTokens7d.prefix(4)) }
    private var total: Int { max(store.sevenDayTotal, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("UDZIAŁ MODELI — 7 DNI")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))

            if topModels.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                HStack(spacing: 18) {
                    donut
                    legend
                }
            }

            Divider().padding(.top, 4)
            hermesVsKiwi
        }
    }

    private var donut: some View {
        ZStack {
            // Tylko pierścień jest obrócony o -90° (start od godziny 12) —
            // tekst środka zostaje prosto, poza obróconą grupą.
            ZStack {
                Circle()
                    .stroke(Color.kiwiMangoTextPrimary.opacity(0.06), lineWidth: 15)
                ForEach(Array(topModels.enumerated()), id: \.element.model) { index, model in
                    let start = fractionBefore(index)
                    Circle()
                        .trim(from: start, to: start + fraction(model))
                        .stroke(Self.segmentColors[index], style: StrokeStyle(lineWidth: 15, lineCap: .butt))
                }
            }
            .rotationEffect(.degrees(-90))

            VStack(spacing: 1) {
                Text(formatTokens(store.sevenDayTotal))
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                Text("7 DNI")
                    .font(.system(size: 8.5))
                    .tracking(0.6)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
        }
        .frame(width: 110, height: 110)
        .padding(2)
    }

    private func fraction(_ model: HermesStateReader.ModelTokens) -> CGFloat {
        CGFloat(model.total) / CGFloat(total)
    }

    private func fractionBefore(_ index: Int) -> CGFloat {
        topModels.prefix(index).reduce(0) { $0 + fraction($1) }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(topModels.enumerated()), id: \.element.model) { index, model in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Self.segmentColors[index])
                        .frame(width: 8, height: 8)
                    Text(model.model)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(Int((fraction(model) * 100).rounded()))%")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                }
            }
        }
    }

    // MARK: Hermes vs kiwiMango czat

    private var kiwiChatTotal: Int { store.kiwiTokenUsage7d.reduce(0) { $0 + $1.total } }
    private var hermesPercent: Int {
        let combined = store.sevenDayTotal + kiwiChatTotal
        guard combined > 0 else { return 0 }
        return Int((Double(store.sevenDayTotal) / Double(combined) * 100).rounded())
    }

    private var hermesVsKiwi: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HERMES VS KIWIMANGO CZAT")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))

            HStack(spacing: 24) {
                statBlock(formatTokens(store.sevenDayTotal), "HERMES", valueColor: .kiwiMangoAccent)
                statBlock(formatTokens(kiwiChatTotal), "KIWI CZAT")
            }

            if store.sevenDayTotal + kiwiChatTotal > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.kiwiMangoAccent)
                            .frame(width: proxy.size.width * CGFloat(hermesPercent) / 100)
                        Rectangle()
                            .fill(Color.chartSand.opacity(0.55))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)

                Text("\(hermesPercent)% zużycia idzie przez Hermesa")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                Text("brak tokenów w tym okresie")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
        }
    }

    private func statBlock(_ value: String, _ label: String, valueColor: Color = .kiwiMangoTextPrimary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(valueColor)
            Text(label)
                .font(.system(size: 9.5))
                .tracking(0.5)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }
}

// MARK: - 4a. Tabela per model (7 dni)

private struct ModelTable: View {
    let store: DashboardStore

    private var leaderTotal: Int { max(store.modelTokens7d.first?.total ?? 1, 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                Text("WEJŚCIE").frame(width: 62, alignment: .trailing)
                Text("WYJŚCIE").frame(width: 62, alignment: .trailing)
                Text("TREND").frame(width: 58, alignment: .trailing)
                Spacer().frame(width: 78)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            .padding(.bottom, 8)

            Divider()

            if store.modelTokens7d.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .padding(.vertical, 10)
            } else {
                ForEach(store.modelTokens7d) { model in
                    HStack {
                        Text(model.model)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                        Text(formatTokens(model.inputTokens)).frame(width: 62, alignment: .trailing)
                        Text(formatTokens(model.outputTokens)).frame(width: 62, alignment: .trailing)
                        trendCell(model.model).frame(width: 58, alignment: .trailing)
                        modelBar(model).frame(width: 70).padding(.leading, 8)
                    }
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func trendCell(_ model: String) -> some View {
        if let percent = store.modelTrendPercent(model) {
            Text("\(percent >= 0 ? "▲" : "▼") \(abs(percent))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(percent >= 0 ? Color.trendUp : Color.trendDown)
        } else {
            Text("—")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
        }
    }

    /// Mini pasek poziomy względem lidera tabeli.
    private func modelBar(_ model: HermesStateReader.ModelTokens) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.kiwiMangoTextPrimary.opacity(0.08))
                Capsule()
                    .fill(Color.kiwiMangoAccent)
                    .frame(width: proxy.size.width * CGFloat(model.total) / CGFloat(leaderTotal))
            }
        }
        .frame(height: 5)
    }
}

// MARK: - 4b. Sesje — 7 dni

private struct SessionsSummary: View {
    let store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 22) {
                statBlock("\(store.sessionsToday)", "DZIŚ")
                statBlock("\(store.sessions7d)", "7 DNI")
                statBlock(store.tokensPerSession.map { formatTokens($0) } ?? "—", "TOK. / SESJA")
            }

            if store.last7Days.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                sessionBars
            }
        }
    }

    private var sessionBars: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let days = store.last7Days
                let maxCount = max(days.map(\.sessionCount).max() ?? 1, 1)
                let slot = size.width / CGFloat(days.count)
                let barWidth = min(slot * 0.6, 18)
                for (index, day) in days.enumerated() {
                    let height = max(size.height * CGFloat(day.sessionCount) / CGFloat(maxCount), 2)
                    let x = slot * CGFloat(index) + (slot - barWidth) / 2
                    let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                    let isToday = index == days.count - 1
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 3),
                        with: .color(Color.kiwiMangoAccent.opacity(isToday ? 1 : 0.55))
                    )
                }
            }
            .frame(height: 60)

            HStack(spacing: 0) {
                ForEach(store.last7Days) { day in
                    Text(weekdayLabel(day.day))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.35))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func statBlock(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9.5))
                .tracking(0.5)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }

    private func weekdayLabel(_ day: String) -> String {
        guard let date = Self.dayParser.date(from: day) else { return "" }
        return Self.weekdayFormatter.string(from: date)
    }

    private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

// MARK: - 4c. Pamięć Hermesa + mini lista Cron

private struct MemoryAndCron: View {
    let store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            memoryRow(label: "MEMORY.md", file: store.memoryFile)
            memoryRow(label: "USER.md", file: store.userFile)

            Divider().padding(.top, 2)

            Text("CRON")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))

            if store.cronJobs.isEmpty {
                Text("brak zadań")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                VStack(spacing: 7) {
                    ForEach(store.cronJobs) { job in
                        HStack {
                            Text(job.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(cronStatus(job))
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(cronOK(job) ? Color.trendUp : Color.kiwiMangoTextPrimary.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private func cronOK(_ job: HermesFilesReader.CronJob) -> Bool {
        job.enabled && ["OK", "SUCCESS", "COMPLETED"].contains(job.lastStatus?.uppercased() ?? "")
    }

    private func cronStatus(_ job: HermesFilesReader.CronJob) -> String {
        guard job.enabled else { return "WYŁĄCZONE" }
        let status = job.lastStatus?.uppercased() ?? "—"
        guard let iso = job.nextRunAt, let date = Self.isoParser.date(from: iso) else { return status }
        return "\(status) · \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func memoryRow(label: String, file: HermesFilesReader.MemoryFile?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(file.map { "\($0.charCount) / \($0.limit) zn." } ?? "brak pliku")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.kiwiMangoTextPrimary.opacity(0.08))
                    Capsule()
                        .fill(fillColor(file))
                        .frame(width: proxy.size.width * CGFloat((file?.fillPercent ?? 0) / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private func fillColor(_ file: HermesFilesReader.MemoryFile?) -> Color {
        guard let file else { return Color.kiwiMangoTextPrimary.opacity(0.3) }
        return file.fillPercent > 90 ? .trendDown : .kiwiMangoAccent
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.unitsStyle = .short
        return formatter
    }()
}
