import Foundation
import GRDB

/// Read-only reader for Hermes' own session-history database (`~/.hermes/state.db`) —
/// a ~156 MB SQLite/WAL file the `hermes` CLI writes to continuously while it runs.
///
/// Opened with `Configuration.readonly = true`, which sets the `SQLITE_OPEN_READONLY`
/// flag — the same effect as URI `mode=ro`. Deliberately **not** `immutable=1`: that
/// flag tells SQLite the file will never change and lets it cache a stale snapshot,
/// which would show a frozen view of a database Hermes is actively appending to via
/// WAL (verified against the live db — see the query comparison below).
///
/// Schema (verified 2026-07-10 via `sqlite3 ~/.hermes/state.db .tables` against the
/// live db): only `sessions` and `messages` exist, plus FTS/index bookkeeping tables
/// (`messages_fts*`, `gateway_routing`, `compression_locks`, `state_meta`). There is
/// **no** `corrections`, `patterns`, `sudo`, or `agents` table. Only the two token
/// aggregate queries survive here — the session-list/replay readers were removed with
/// the old 17-section Dashboard (2026-07-10, strona "Zużycie").
///
/// Cost columns (`estimated_cost_usd`, `actual_cost_usd`, `cost_status`, ...) are
/// intentionally never selected: Ollama sessions always report
/// `estimated_cost_usd = 0` / `cost_status = "unknown"` (see PLAN-DASHBOARD.md
/// PUŁAPKA #5) — showing a dollar figure built from that would be a lie. Tokens are
/// the only trustworthy "ile" measure.
///
/// Query shapes mirror `hermes insights` (`~/.hermes/hermes-agent/agent/insights.py`):
/// cutoff = `now - days*86400`, filtered on `sessions.started_at`, tokens summed as
/// `input + output + cache_read + cache_write` (reasoning_tokens excluded, matching
/// upstream). Verified against `hermes insights --days 7` on the live db — see
/// HermesStateReaderTests-equivalent check in the task report; both agree on
/// sessions=106, input=174,739,559, output=1,015,824, total=175,755,383.
enum HermesStateReader {

    // MARK: - Models

    struct DayTokens: Identifiable, Sendable {
        var id: String { day }
        /// `yyyy-MM-dd`, local calendar day of `started_at` — matches `hermes insights`'
        /// `datetime.fromtimestamp(...).strftime("%Y-%m-%d")` grouping.
        let day: String
        /// Fala 3 (PLAN-DASHBOARD.md, hero's "Sesje dziś"): session count for the day,
        /// added to the existing per-day token query rather than a second query.
        let sessionCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    }

    struct ModelTokens: Identifiable, Sendable {
        var id: String { model }
        let model: String
        let sessionCount: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens }
    }

    // MARK: - Connection

    private static let path = (NSHomeDirectory() as NSString).appendingPathComponent(".hermes/state.db")

    /// Lazily opened once; `nil` when `~/.hermes/state.db` doesn't exist (Hermes never
    /// ran) — every public method below degrades to `[]` in that case rather than
    /// throwing, so callers can render an "offline / no data" state with zero crashes.
    private static let dbQueue: DatabaseQueue? = {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var config = Configuration()
        config.readonly = true
        return try? DatabaseQueue(path: path, configuration: config)
    }()

    // MARK: - Token totals ("ile")

    /// Per-day token sums for the last `days` days (oldest first).
    static func dailyTokenTotals(days: Int = 7) async throws -> [DayTokens] {
        guard let dbQueue else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        date(started_at, 'unixepoch', 'localtime') AS day,
                        COUNT(*) AS sessions,
                        SUM(input_tokens) AS input_tokens,
                        SUM(output_tokens) AS output_tokens,
                        SUM(cache_read_tokens) AS cache_read_tokens,
                        SUM(cache_write_tokens) AS cache_write_tokens
                    FROM sessions
                    WHERE started_at >= ?
                    GROUP BY day
                    ORDER BY day ASC
                    """,
                arguments: [cutoff]
            ).map { row in
                DayTokens(
                    day: row["day"],
                    sessionCount: row["sessions"] ?? 0,
                    inputTokens: row["input_tokens"] ?? 0,
                    outputTokens: row["output_tokens"] ?? 0,
                    cacheReadTokens: row["cache_read_tokens"] ?? 0,
                    cacheWriteTokens: row["cache_write_tokens"] ?? 0
                )
            }
        }
    }

    /// Per-model token sums for the last `days` days, highest total first.
    /// `offsetDays` shifts the whole window back in time — e.g. `days: 7,
    /// offsetDays: 7` = the *previous* 7 days, used for the per-model trend
    /// column ("Zużycie" page).
    static func modelTokenTotals(days: Int = 7, offsetDays: Int = 0) async throws -> [ModelTokens] {
        guard let dbQueue else { return [] }
        let upper = Date().addingTimeInterval(-Double(offsetDays) * 86400).timeIntervalSince1970
        let cutoff = upper - Double(days) * 86400
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        COALESCE(model, 'unknown') AS model,
                        COUNT(*) AS sessions,
                        SUM(input_tokens) AS input_tokens,
                        SUM(output_tokens) AS output_tokens,
                        SUM(cache_read_tokens) AS cache_read_tokens,
                        SUM(cache_write_tokens) AS cache_write_tokens
                    FROM sessions
                    WHERE started_at >= ? AND started_at < ?
                    GROUP BY model
                    ORDER BY (SUM(input_tokens) + SUM(output_tokens) + SUM(cache_read_tokens) + SUM(cache_write_tokens)) DESC
                    """,
                arguments: [cutoff, upper]
            ).map { row in
                ModelTokens(
                    model: row["model"],
                    sessionCount: row["sessions"] ?? 0,
                    inputTokens: row["input_tokens"] ?? 0,
                    outputTokens: row["output_tokens"] ?? 0,
                    cacheReadTokens: row["cache_read_tokens"] ?? 0,
                    cacheWriteTokens: row["cache_write_tokens"] ?? 0
                )
            }
        }
    }

    // MARK: - Recent sessions ("01 AGENCI", PLAN-V2 §7.2 pt.3 / pułapka #15)
    //
    // The gateway (`HermesGatewayClient`) has no RPC that lists other agents'
    // sessions — it only creates/resumes/drives kiwiMango's OWN chat session.
    // Verified against every method in Chat/HermesGatewayClient.swift: no
    // `session.list`. So the AGENCI section reads `state.db` directly instead
    // — the same table `dailyTokenTotals`/`modelTokenTotals` already read,
    // just at per-session grain instead of aggregated.

    struct RecentSession: Identifiable, Sendable {
        let id: String
        let title: String?
        let model: String?
        let startedAt: Date
        let endedAt: Date?
        let inputTokens: Int
        let outputTokens: Int
        let toolCallCount: Int
    }

    /// Sessions started in the last `minutes` minutes, or still open
    /// (`ended_at IS NULL`) regardless of age — newest first.
    static func recentSessions(minutes: Int = 15) async throws -> [RecentSession] {
        guard let dbQueue else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60).timeIntervalSince1970
        return try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, title, model, started_at, ended_at, input_tokens, output_tokens, tool_call_count
                    FROM sessions
                    WHERE started_at >= ? OR ended_at IS NULL
                    ORDER BY started_at DESC
                    LIMIT 20
                    """,
                arguments: [cutoff]
            ).map { row in
                let startedAt: Double = row["started_at"] ?? 0
                let endedAt: Double? = row["ended_at"]
                return RecentSession(
                    id: row["id"] ?? "",
                    title: row["title"],
                    model: row["model"],
                    startedAt: Date(timeIntervalSince1970: startedAt),
                    endedAt: endedAt.map { Date(timeIntervalSince1970: $0) },
                    inputTokens: row["input_tokens"] ?? 0,
                    outputTokens: row["output_tokens"] ?? 0,
                    toolCallCount: row["tool_call_count"] ?? 0
                )
            }
        }
    }

}
