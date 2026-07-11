import AppKit
import SwiftUI

// MARK: - DashboardView — jedna strona "Zużycie" (F4 2026-07-11, redesign mono)
//
// Referencja Pawła: dashboard "Ali Sayed" — płaska powierzchnia, zero kart z
// ramkami/tłami, sekcje oddzielone wyłącznie pustą przestrzenią + UPPERCASE
// nagłówkami. Amber (kiwiMangoAccent) jest JEDYNYM wyjątkiem od monochromu:
// słupki wykresu, sparkline'y, badge %, wypełnienia cienkich linii postępu,
// aktywna nawigacja. Reszta = tony bieli/szarości. Zielona kropka statusu
// (Hermes aktywny) zostaje — jedyny inny kolor, na wyraźne życzenie.
//
// Treść identyczna jak przed redesignem (real dane z DashboardStore) — zmienia
// się wyłącznie forma. Żelazna zasada F9: bloom TYLKO na kropce hero.
struct DashboardView: View {
    @State private var store = DashboardStore()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cardsVisible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                DashboardHero(store: store)
                    .cascadeIn(cardsVisible, index: 0, reduceMotion: reduceMotion)

                kpiRow

                // F4 fix: rzędy kart adaptują się do szerokości — ViewThatFits
                // wybiera układ poziomy tylko gdy realnie się mieści (minWidth
                // pilnuje uczciwej decyzji); przy wąskim oknie (min 760 z
                // App.swift → ~470px treści) sekcje spadają pod siebie zamiast
                // ucinać treść na krawędzi.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 40) {
                        chartCard.frame(minWidth: 380)
                        shareCard.frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: 48) {
                        chartCard
                        shareCard
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 40) {
                        tableCard.frame(minWidth: 420)
                        sessionsCard.frame(width: 220)
                        memoryCard.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 48) {
                        tableCard
                        HStack(alignment: .top, spacing: 40) {
                            sessionsCard
                            memoryCard
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.kiwiMangoBackground)
        .task {
            store.start()
            cardsVisible = true
        }
    }

    private var kpiRow: some View {
        // F4 fix: 4 w rzędzie tylko gdy się mieszczą; przy wąskim oknie 2×2.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 40) {
                todayCard.frame(minWidth: 140)
                sevenDayCard.frame(minWidth: 140)
                monthCard.frame(minWidth: 140)
                costCard.frame(minWidth: 140)
            }
            VStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .top, spacing: 40) {
                    todayCard
                    sevenDayCard
                }
                HStack(alignment: .top, spacing: 40) {
                    monthCard
                    costCard
                }
            }
        }
        .cascadeIn(cardsVisible, index: 1, reduceMotion: reduceMotion)
    }

    // MARK: Karty sekcji (wyciągnięte, bo ViewThatFits używa ich w obu wariantach)

    private var chartCard: some View {
        DashboardCard {
            MonthlyStackedChart(
                days: store.last30Days,
                badgePercent: store.monthTrendPercent,
                animate: cardsVisible && !reduceMotion
            )
        }
        .cascadeIn(cardsVisible, index: 2, reduceMotion: reduceMotion)
    }

    private var shareCard: some View {
        DashboardCard(title: "Udział modeli") {
            ModelShareRows(store: store)
        }
        .cascadeIn(cardsVisible, index: 3, reduceMotion: reduceMotion)
    }

    private var tableCard: some View {
        DashboardCard(title: "Per model — 7 dni") {
            ModelTable(store: store)
        }
        .cascadeIn(cardsVisible, index: 4, reduceMotion: reduceMotion)
    }

    private var sessionsCard: some View {
        DashboardCard(title: "Sesje — 7 dni") {
            SessionsSummary(store: store, animate: cardsVisible && !reduceMotion)
        }
        .cascadeIn(cardsVisible, index: 5, reduceMotion: reduceMotion)
    }

    private var memoryCard: some View {
        DashboardCard(title: "Pamięć Hermesa") {
            MemoryAndCron(store: store)
        }
        .cascadeIn(cardsVisible, index: 6, reduceMotion: reduceMotion)
    }

    // MARK: KPI: Dziś

    private var todayCard: some View {
        KpiCard(title: "Dziś") {
            Sparkline(
                values: store.last7Days.map { Double($0.total) },
                color: .kiwiMangoAccent,
                lineWidth: 1.5,
                height: 22,
                animate: cardsVisible && !reduceMotion
            )
            Text(formatTokens(store.todayTokens?.total ?? 0))
                .kpiBigStyle()
                .animation(reduceMotion ? nil : .default, value: store.todayTokens?.total)
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
            Sparkline(
                values: store.last7Days.map { Double($0.total) },
                color: .kiwiMangoAccent,
                lineWidth: 1.5,
                height: 22,
                animate: cardsVisible && !reduceMotion
            )
            Text(formatTokens(store.sevenDayTotal))
                .kpiBigStyle()
                .animation(reduceMotion ? nil : .default, value: store.sevenDayTotal)
            Text("średnio \(formatTokens(store.sevenDayTotal / 7)) / dzień")
                .kpiSubStyle()
        }
    }

    // MARK: KPI: Ten miesiąc

    private var monthCard: some View {
        KpiCard(title: "Ten miesiąc") {
            Sparkline(
                values: store.last30Days.map { Double($0.total) },
                color: .kiwiMangoAccent,
                lineWidth: 1.5,
                height: 22,
                animate: cardsVisible && !reduceMotion
            )
            Text(formatTokens(store.monthTotal))
                .kpiBigStyle()
                .animation(reduceMotion ? nil : .default, value: store.monthTotal)
            Text("total od początku: \(formatTokens(store.allTimeTotal))")
                .kpiSubStyle()
            TrendLabel(percent: store.monthTrendPercent, suffix: "vs poprzedni")
        }
    }

    // MARK: KPI: Koszt

    // ponytail: brak sparkline — Ollama Pro jest flat/mies., seria byłaby
    // zmyśloną linią bez realnej bazy (zakaz z ladder: "nigdy nie zmyślaj danych").
    private var costCard: some View {
        KpiCard(title: "Koszt") {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("$\(Int(DashboardStore.ollamaProMonthlyCost))")
                    .kpiBigStyle()
                Text("/ mc")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
            Text(costSubLabel)
                .kpiSubStyle()
            HStack(spacing: 8) {
                Text("Ollama Pro")
                    .kpiSubStyle()
                Text("FLAT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
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

// MARK: - Wejście kaskadą (F2 — animacje)

private extension View {
    /// Karty Dashboardu wjeżdżają kaskadą: opacity+offset, spring, stagger 40ms
    /// na podstawie `index`. Jeden strzał na starcie widoku, nie na każdą zmianę
    /// danych. Wyłączone całkowicie pod accessibilityReduceMotion.
    func cascadeIn(_ visible: Bool, index: Int, reduceMotion: Bool) -> some View {
        modifier(CascadeIn(visible: visible, index: index, reduceMotion: reduceMotion))
    }
}

private struct CascadeIn: ViewModifier {
    let visible: Bool
    let index: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 8)
                .animation(.spring(response: 0.42, dampingFraction: 0.82).delay(Double(index) * 0.04), value: visible)
        }
    }
}

// MARK: - DashboardCard — bez ramek/tła/cienia (F4: płaska powierzchnia)

struct DashboardCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .kiwiSectionLabel()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        font(.system(size: 22, weight: .light))
            .monospacedDigit()
            .foregroundStyle(color)
            .contentTransition(.numericText())
    }

    func kpiSubStyle() -> some View {
        font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            .lineLimit(1)
    }
}

/// "▲ 18% vs wczoraj" / "▼ 6% vs poprzedni" — nic, gdy brak danych porównawczych
/// (żadnych zmyślonych 0%). Mono: kierunek niesie strzałka, nie kolor.
private struct TrendLabel: View {
    let percent: Int?
    let suffix: String

    var body: some View {
        if let percent {
            Text("\(percent >= 0 ? "▲" : "▼") \(abs(percent))% \(suffix)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }
}

// MARK: - 1. Hero header — "HERMES / Witaj, Paweł!" + tokeny 7 dni

private struct DashboardHero: View {
    let store: DashboardStore

    private var isAlive: Bool { store.gatewayState?.isAlive ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HERMES")
                        .kiwiSectionLabel()
                    Text("Witaj, Paweł!")
                        .font(.system(size: 27, weight: .light))
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                }
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("TOKENY 7 DNI")
                        .kiwiSectionLabel()
                    Text(formatTokens(store.sevenDayTotal))
                        .font(.system(size: 26, weight: .light))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(Color.kiwiMangoTextPrimary)
                }
            }

            HStack(spacing: 8) {
                // Żelazna zasada F9: bloom TYLKO na tej jednej kropce hero,
                // nigdzie indziej na całej stronie. Zielona kropka statusu
                // zostaje — jedyny inny kolor poza amberem, na życzenie.
                Circle()
                    .fill(isAlive ? Color(hex: "7FB77E") : Color.kiwiMangoTextPrimary.opacity(0.25))
                    .frame(width: 7, height: 7)
                    .realBloom(strength: 1.0, radius: 3)
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }

    private var statusLine: String {
        var parts: [String] = [isAlive ? "Hermes aktywny" : "Hermes offline"]
        if let model = store.configSummary?.activeModel { parts.append(model) }
        parts.append(accountLabel)
        parts.append("\(store.sessionsToday) sesji dziś")
        parts.append(refreshLabel)
        return parts.joined(separator: "  ·  ")
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.unitsStyle = .short
        return formatter
    }()
}

// MARK: - 2. Wykres 30 dni — włosowate słupki

private struct MonthlyStackedChart: View {
    let days: [HermesStateReader.DayTokens]
    var badgePercent: Int?
    var animate: Bool = false

    // F2: słupki rosną od zera przy wejściu — skala Y na całym Canvas
    // (prostsza droga z planu zamiast animatableData per-słupek).
    @State private var growth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tokeny — ostatnie 30 dni")
                    .kiwiSectionLabel()
                Spacer()
                if let badgePercent {
                    Text("\(badgePercent >= 0 ? "▲" : "▼") \(abs(badgePercent))%")
                        .font(.system(size: 10.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.kiwiMangoAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.kiwiMangoAccent.opacity(0.12), in: Capsule())
                }
            }

            if days.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .frame(height: 180)
            } else {
                chartCanvas
                    .frame(height: 180)
                    .scaleEffect(y: growth, anchor: .bottom)
                    .onAppear {
                        guard animate else { growth = 1; return }
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(0.1)) {
                            growth = 1
                        }
                    }
                HStack {
                    Text(firstDayLabel)
                    Spacer()
                    Text("DZIŚ")
                }
                .font(.system(size: 8, weight: .medium))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.3))
            }
        }
    }

    private var chartCanvas: some View {
        Canvas { context, size in
            let maxTotal = max(days.map(\.total).max() ?? 1, 1)
            let slot = size.width / CGFloat(days.count)
            // Referencja: słupki włosowate 2-3px, duże odstępy, bez siatki/osi.
            let barWidth = min(slot * 0.35, 2.5)

            for (index, day) in days.enumerated() {
                // ponytail: "wejście" = total - output (input + cache
                // read/write zlane w jeden segment), żeby słupki sumowały się
                // do tych samych totali co kafle KPI.
                let output = day.outputTokens
                let input = day.total - output
                let inputHeight = size.height * CGFloat(input) / CGFloat(maxTotal)
                let outputHeight = size.height * CGFloat(output) / CGFloat(maxTotal)
                let x = slot * CGFloat(index) + (slot - barWidth) / 2
                let isToday = index == days.count - 1

                let outputRect = CGRect(
                    x: x, y: size.height - inputHeight - outputHeight,
                    width: barWidth, height: outputHeight
                )
                context.fill(
                    Path(roundedRect: outputRect, cornerRadius: 1),
                    with: .color(Color.kiwiMangoTextPrimary.opacity(isToday ? 0.30 : 0.16))
                )
                let inputRect = CGRect(
                    x: x, y: size.height - inputHeight,
                    width: barWidth, height: max(inputHeight, 1)
                )
                context.fill(
                    Path(roundedRect: inputRect, cornerRadius: 1),
                    with: .color(Color.kiwiMangoAccent.opacity(isToday ? 1 : 0.65))
                )
            }
        }
    }

    private var firstDayLabel: String {
        guard let first = days.first,
              let date = Self.dayParser.date(from: first.day) else { return "" }
        return Self.axisFormatter.string(from: date)
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

// MARK: - 3. Udział modeli (cienkie linie postępu) + Hermes vs kiwiMango czat

private struct ModelShareRows: View {
    let store: DashboardStore

    /// Max 4 modele — reszta zostaje poza listą (donut usunięty, F4).
    private var topModels: [HermesStateReader.ModelTokens] { Array(store.modelTokens7d.prefix(4)) }
    private var total: Int { max(store.sevenDayTotal, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if topModels.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(topModels.enumerated()), id: \.element.model) { index, model in
                        row(model, isLeader: index == 0)
                    }
                }
            }

            hermesVsKiwi
        }
    }

    private func fraction(_ model: HermesStateReader.ModelTokens) -> CGFloat {
        CGFloat(model.total) / CGFloat(total)
    }

    private func row(_ model: HermesStateReader.ModelTokens, isLeader: Bool) -> some View {
        HStack(spacing: 10) {
            Text(model.model.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.65))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.kiwiMangoTextPrimary.opacity(0.15))
                    Capsule()
                        .fill(Color.kiwiMangoAccent.opacity(isLeader ? 1 : 0.6))
                        .frame(width: proxy.size.width * fraction(model))
                }
            }
            .frame(height: 2)

            Text("\(Int((fraction(model) * 100).rounded()))%")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                .frame(width: 28, alignment: .trailing)
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
                .kiwiSectionLabel()

            HStack(spacing: 24) {
                statBlock(formatTokens(store.sevenDayTotal), "HERMES")
                statBlock(formatTokens(kiwiChatTotal), "KIWI CZAT")
            }

            if store.sevenDayTotal + kiwiChatTotal > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.kiwiMangoAccent)
                            .frame(width: proxy.size.width * CGFloat(hermesPercent) / 100)
                        Rectangle()
                            .fill(Color.kiwiMangoTextPrimary.opacity(0.15))
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 2)

                Text("\(hermesPercent)% zużycia idzie przez Hermesa")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                Text("brak tokenów w tym okresie")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            }
        }
    }

    private func statBlock(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .light))
                .monospacedDigit()
                .foregroundStyle(Color.kiwiMangoTextPrimary)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        }
    }
}

// MARK: - 4a. Tabela per model (7 dni) — cienkie wiersze

private struct ModelTable: View {
    let store: DashboardStore

    private var leaderTotal: Int { max(store.modelTokens7d.first?.total ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                Text("WEJŚCIE").frame(width: 58, alignment: .trailing)
                Text("WYJŚCIE").frame(width: 58, alignment: .trailing)
                Text("TREND").frame(width: 52, alignment: .trailing)
                Spacer().frame(width: 78)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            // F4 fix: bez lineLimit "MODEL" łamał się pionowo (M/O/D/E/L) przy
            // ściśniętej kolumnie — jedna linia + truncation zamiast zawijania.
            .lineLimit(1)
            .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))

            if store.modelTokens7d.isEmpty {
                Text("brak danych")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                VStack(spacing: 14) {
                    ForEach(store.modelTokens7d) { model in
                        HStack {
                            Text(model.model)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                            Text(formatTokens(model.inputTokens)).frame(width: 58, alignment: .trailing)
                            Text(formatTokens(model.outputTokens)).frame(width: 58, alignment: .trailing)
                            trendCell(model.model).frame(width: 52, alignment: .trailing)
                            modelBar(model).frame(width: 70).padding(.leading, 8)
                        }
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.85))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trendCell(_ model: String) -> some View {
        if let percent = store.modelTrendPercent(model) {
            Text("\(percent >= 0 ? "▲" : "▼") \(abs(percent))%")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
        } else {
            Text("—")
                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.3))
        }
    }

    /// Cienka linia postępu (2px) względem lidera tabeli.
    private func modelBar(_ model: HermesStateReader.ModelTokens) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.kiwiMangoTextPrimary.opacity(0.15))
                Capsule()
                    .fill(Color.kiwiMangoAccent)
                    .frame(width: proxy.size.width * CGFloat(model.total) / CGFloat(leaderTotal))
            }
        }
        .frame(height: 2)
    }
}

// MARK: - 4b. Sesje — 7 dni

private struct SessionsSummary: View {
    let store: DashboardStore
    var animate: Bool = false

    @State private var growth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                let barWidth = min(slot * 0.3, 3)
                for (index, day) in days.enumerated() {
                    let height = max(size.height * CGFloat(day.sessionCount) / CGFloat(maxCount), 2)
                    let x = slot * CGFloat(index) + (slot - barWidth) / 2
                    let rect = CGRect(x: x, y: size.height - height, width: barWidth, height: height)
                    let isToday = index == days.count - 1
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1),
                        with: .color(Color.kiwiMangoAccent.opacity(isToday ? 1 : 0.5))
                    )
                }
            }
            .frame(height: 56)
            .scaleEffect(y: growth, anchor: .bottom)
            .onAppear {
                guard animate else { growth = 1; return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(0.1)) {
                    growth = 1
                }
            }

            HStack(spacing: 0) {
                ForEach(store.last7Days) { day in
                    Text(weekdayLabel(day.day))
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.3))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func statBlock(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .light))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium))
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
        VStack(alignment: .leading, spacing: 18) {
            memoryRow(label: "MEMORY.md", file: store.memoryFile)
            memoryRow(label: "USER.md", file: store.userFile)

            Text("CRON")
                .kiwiSectionLabel()

            if store.cronJobs.isEmpty {
                Text("brak zadań")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
            } else {
                VStack(spacing: 10) {
                    ForEach(store.cronJobs) { job in
                        HStack {
                            Text(job.name)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(cronStatus(job))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(cronOK(job) ? 0.85 : 0.45))
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
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(file.map { "\($0.charCount) / \($0.limit) zn." } ?? "brak pliku")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kiwiMangoTextPrimary.opacity(0.55))
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.kiwiMangoTextPrimary.opacity(0.15))
                    Capsule()
                        .fill(Color.kiwiMangoTextPrimary.opacity(0.55))
                        .frame(width: proxy.size.width * CGFloat((file?.fillPercent ?? 0) / 100))
                }
            }
            .frame(height: 2)
        }
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "pl_PL")
        formatter.unitsStyle = .short
        return formatter
    }()
}
