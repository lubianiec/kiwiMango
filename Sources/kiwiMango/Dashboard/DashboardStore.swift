import Foundation
import Observation

// MARK: - DashboardStore (strona "Zużycie", 2026-07-10)
//
// Owns every piece of state the single-page "Zużycie" dashboard reads. Three
// refresh rhythms:
//   - file-backed state (gateway/cron/memory/config) → `HermesFilesWatcher`,
//     debounced ~1s on its own queue.
//   - Ollama account → polled every 60s.
//   - `state.db` (tokens) → polled every 30s, plus once immediately on `start()`.
// Every reader here already degrades to nil/[]/offline on its own — this store
// just holds the latest snapshot.
@MainActor
@Observable
final class DashboardStore {

    // MARK: Files (watcher-driven)

    private(set) var gatewayState: (state: HermesFilesReader.GatewayState, isAlive: Bool)?
    private(set) var cronJobs: [HermesFilesReader.CronJob] = []
    private(set) var memoryFile: HermesFilesReader.MemoryFile?
    private(set) var userFile: HermesFilesReader.MemoryFile?
    private(set) var configSummary: HermesFilesReader.ConfigSummary?

    // MARK: Ollama account (60s)

    private(set) var ollamaAccount: OllamaAccountClient.Account?
    private(set) var ollamaChecked = false

    // MARK: state.db (30s / on-enter)
    //
    // ponytail: one 62-day daily query covers everything day-based on the page
    // (today tile + trend vs wczoraj, 7-day tile + sparkline, 30-day chart,
    // this month + previous month for the trend) — sliced in Swift below.
    private(set) var dailyTokens: [HermesStateReader.DayTokens] = []
    private(set) var modelTokens7d: [HermesStateReader.ModelTokens] = []
    /// Previous 7-day window (days 8–14 ago) — per-model trend in the table.
    private(set) var modelTokensPrev7d: [HermesStateReader.ModelTokens] = []
    /// ponytail: "od początku" approximated with a 10-year window, which in
    /// practice covers everything actually in `state.db`.
    private(set) var allTimeTotal = 0
    /// kiwiMango's own chat usage (GRDB `token_usage`, Fala 2).
    private(set) var kiwiTokenUsage7d: [DatabaseManager.TokenUsageTotal] = []
    /// "odświeżono X temu" in the status bar.
    private(set) var lastStateRefresh: Date?

    private let ollamaClient = OllamaAccountClient()
    private var watcher: HermesFilesWatcher?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Idempotent — safe to call from `.onAppear`/`.task` every time the section is
    /// shown; the running refresh loop and watcher are left in place.
    func start() {
        refreshFiles()
        guard refreshTask == nil else { return }
        watcher = HermesFilesWatcher { [weak self] in self?.refreshFiles() }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var tick = 0
            while !Task.isCancelled {
                await self.refreshStateDB()
                if tick % 2 == 0 { await self.refreshOllamaAccount() }
                tick += 1
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Refreshers

    func refreshFiles() {
        gatewayState = HermesFilesReader.gatewayState()
        cronJobs = HermesFilesReader.cronJobs()
        memoryFile = HermesFilesReader.memoryFile()
        userFile = HermesFilesReader.userFile()
        configSummary = HermesFilesReader.configSummary()
    }

    func refreshOllamaAccount() async {
        ollamaAccount = await ollamaClient.account()
        ollamaChecked = true
    }

    func refreshStateDB() async {
        async let daily = (try? HermesStateReader.dailyTokenTotals(days: 62)) ?? []
        async let byModel = (try? HermesStateReader.modelTokenTotals(days: 7)) ?? []
        async let byModelPrev = (try? HermesStateReader.modelTokenTotals(days: 7, offsetDays: 7)) ?? []
        async let allTime = (try? HermesStateReader.modelTokenTotals(days: 3650)) ?? []
        dailyTokens = await daily
        modelTokens7d = await byModel
        modelTokensPrev7d = await byModelPrev
        allTimeTotal = await allTime.reduce(0) { $0 + $1.total }
        kiwiTokenUsage7d = (try? DatabaseManager.shared.fetchTokenUsageTotals(days: 7)) ?? []
        lastStateRefresh = Date()
    }

    // MARK: - Derived ("ILE")

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    private var todayKey: String { Self.dayFormatter.string(from: Date()) }
    private var yesterdayKey: String {
        Self.dayFormatter.string(from: Date().addingTimeInterval(-86400))
    }

    var todayTokens: HermesStateReader.DayTokens? { dailyTokens.first { $0.day == todayKey } }
    var sessionsToday: Int { todayTokens?.sessionCount ?? 0 }

    /// nil when there's no yesterday row — no invented 0%.
    var todayTrendPercent: Int? {
        guard let today = todayTokens,
              let yesterday = dailyTokens.first(where: { $0.day == yesterdayKey }),
              yesterday.total > 0
        else { return nil }
        return Int((Double(today.total - yesterday.total) / Double(yesterday.total) * 100).rounded())
    }

    /// ponytail: the underlying query only returns days with activity (no
    /// zero-filling for silent days), so "last 7/30 days" is really "last 7/30
    /// days *with activity*" — fine for Paweł's daily usage pattern.
    var last7Days: [HermesStateReader.DayTokens] { Array(dailyTokens.suffix(7)) }
    var sevenDayTotal: Int { last7Days.reduce(0) { $0 + $1.total } }
    var last30Days: [HermesStateReader.DayTokens] { Array(dailyTokens.suffix(30)) }

    var sessions7d: Int { last7Days.reduce(0) { $0 + $1.sessionCount } }
    var tokensPerSession: Int? {
        guard sessions7d > 0 else { return nil }
        return sevenDayTotal / sessions7d
    }

    private var monthPrefix: String { String(todayKey.prefix(7)) }
    private var previousMonthPrefix: String? {
        guard let date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return nil }
        return String(Self.dayFormatter.string(from: date).prefix(7))
    }

    /// This calendar month's total — filters the 62-day window by `yyyy-MM` prefix.
    var monthTotal: Int {
        dailyTokens.filter { $0.day.hasPrefix(monthPrefix) }.reduce(0) { $0 + $1.total }
    }

    /// nil when the previous month has no data in the window — no invented trend.
    /// (62 days always spans the whole previous calendar month: ≤31 days of it
    /// plus ≤31 days of the current one.)
    var monthTrendPercent: Int? {
        guard let prefix = previousMonthPrefix else { return nil }
        let previous = dailyTokens.filter { $0.day.hasPrefix(prefix) }.reduce(0) { $0 + $1.total }
        guard previous > 0, monthTotal > 0 else { return nil }
        return Int((Double(monthTotal - previous) / Double(previous) * 100).rounded())
    }

    /// Per-model 7-day trend vs the previous 7 days; nil when the model has no
    /// previous-window data (new model → no fake 0%).
    func modelTrendPercent(_ model: String) -> Int? {
        guard let previous = modelTokensPrev7d.first(where: { $0.model == model }),
              previous.total > 0,
              let current = modelTokens7d.first(where: { $0.model == model })
        else { return nil }
        return Int((Double(current.total - previous.total) / Double(previous.total) * 100).rounded())
    }

    // MARK: - Derived ("ZA ILE")
    //
    // Ollama Pro only — no Claude Pro line without a real settings toggle
    // confirming it (no "koszt z sufitu").
    static let ollamaProMonthlyCost = 20.0

    /// `nil` until there's at least one token this month (avoids a divide-by-zero
    /// "$0.00/1M" that looks like real data).
    var effectiveCostPerMillionTokens: Double? {
        guard monthTotal > 0 else { return nil }
        return Self.ollamaProMonthlyCost / (Double(monthTotal) / 1_000_000)
    }
}
