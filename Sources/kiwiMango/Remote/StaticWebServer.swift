import Foundation
import Network

// MARK: - StaticWebServer
//
// Serves the built Vite web app (`web/dist/`, shipped at
// `Contents/Resources/WebUI/` in the .app bundle) on
// `RemoteWebUIConfig.staticServerPort`, and transparently relays `/api/ws`
// requests to the real Hermes gateway (`RemoteWebUIConfig.gatewayPort`) as a
// raw byte pipe — see class doc below for why that's the ponytail-correct
// shortcut vs. a real WS-aware proxy.
//
// Wired into `App.swift`'s `KiwiMangoAppDelegate` — started in
// applicationDidFinishLaunching, stopped in applicationShouldTerminate
// (mirrors `HermesGatewayProcessBox` lifecycle elsewhere).

/// `NWListener`-based HTTP server (Network.framework — no new dependency,
/// ponytail rung 3). One-shot, HTTP/1.0-style responses: read the request,
/// write the response, close. No keep-alive, no chunked transfer, no real
/// HTTP parser — this only ever serves a single static page to a phone
/// browser, so the ceiling is intentionally low.
final class StaticWebServer: @unchecked Sendable {
    static let shared = StaticWebServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "kiwiMango.StaticWebServer")

    // ponytail: kept alive for the server's whole lifetime (not tied to a
    // SwiftUI view's onAppear/onDisappear like the native Dashboard's own
    // instances) so CPU/network deltas and NBP's 24h cache have something to
    // diff against between polls. Same classes the native UI already uses —
    // just a second long-lived instance for the web surface.
    @MainActor private var hardwareMonitor: HardwareMonitor?
    @MainActor private var nbpClient: NBPClient?

    private init() {}

    @MainActor
    private func ensureHardwareMonitor() -> HardwareMonitor {
        if let hardwareMonitor { return hardwareMonitor }
        let monitor = HardwareMonitor()
        monitor.start()
        hardwareMonitor = monitor
        return monitor
    }

    @MainActor
    private func ensureNBPClient() -> NBPClient {
        if let nbpClient { return nbpClient }
        let client = NBPClient()
        nbpClient = client
        return client
    }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(RemoteWebUIConfig.staticServerPort))
        )
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHeader(connection, buffered: Data())
    }

    /// Reads until the end of the HTTP header block (`\r\n\r\n`) — enough to
    /// see the request line and decide whether this is a WS-upgrade bound for
    /// the gateway or a plain page load. No full HTTP parsing needed.
    private func readHeader(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffered
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.route(connection, headerAndBeyond: buf, headerEnd: range.upperBound)
                return
            }
            if isComplete || error != nil || data == nil {
                connection.cancel()
                return
            }
            self.readHeader(connection, buffered: buf)
        }
    }

    private func route(_ connection: NWConnection, headerAndBeyond buf: Data, headerEnd: Data.Index) {
        let headerData = buf[buf.startIndex..<headerEnd]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        if path.hasPrefix("/api/ws") {
            relayToGateway(connection, alreadyRead: buf)
        } else if path.hasPrefix("/api/status") {
            serveStatus(connection)
        } else {
            serveFile(connection, path: path)
        }
    }

    // MARK: - /api/status (web Dashboard tile — reuses existing readers, no new parsing)

    /// ponytail: no shared HTTP client/timeout helper exists yet for a bare
    /// GET-with-timeout — `ServiceStatus.ping` in DashboardView.swift does the
    /// same thing but is `private` to that type, so this is a 4-line
    /// duplicate rather than a new shared utility for one caller.
    private static func pingAlive(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Full "Zużycie" dashboard payload for the web UI — reuses the exact same
    /// readers/derivations the native `DashboardStore`/`CostsBlock`/
    /// `HardwareMonitor`/`ProcessSection` views already call. See class docs
    /// above for why hardware/NBP state is kept in two long-lived ivars
    /// rather than re-created per request.
    private func serveStatus(_ connection: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            let gateway = HermesFilesReader.gatewayState()
            let config = HermesFilesReader.configSummary()
            let ollamaAlive = await Self.pingAlive("http://localhost:11434/api/version")

            async let dailyTask = (try? HermesStateReader.dailyTokenTotals(days: 62)) ?? []
            async let modelTask = (try? HermesStateReader.modelTokenTotals(days: 7)) ?? []
            async let allTimeTask = (try? HermesStateReader.modelTokenTotals(days: 3650)) ?? []
            // ponytail: activeAgents = "still open" sessions, not the native
            // AgentsMonitor's stricter 60s-since-last-token-change rule — that
            // rule needs cross-poll state (lastChangeAt/history dicts) which
            // only makes sense for a live-polling SwiftUI view, not a
            // stateless HTTP handler. Close enough for a status number.
            async let sessionsTask = (try? HermesStateReader.recentSessions(minutes: 15)) ?? []

            let daily = await dailyTask
            let modelTokens7d = await modelTask
            let allTimeTotal = await allTimeTask.reduce(0) { $0 + $1.total }
            let activeAgents = await sessionsTask.filter { $0.endedAt == nil }.count

            let tokens = Self.tokenStats(daily: daily, monthTotal7dModels: modelTokens7d, allTimeTotal: allTimeTotal)
            let last7 = Array(daily.suffix(7)).map { ["day": $0.day, "total": $0.total] as [String: Any] }
            let modelShare = modelTokens7d.prefix(4).map { ["model": $0.model, "total": $0.total] as [String: Any] }

            let (usdRate, eurRate) = await self.nbpRates()
            let costs = Self.costStats(modelTokens7d: modelTokens7d, usdRate: usdRate, eurRate: eurRate)

            let hardware = await self.hardwareSnapshot()
            let processes = await self.processSnapshot()

            let body: [String: Any] = [
                "gatewayAlive": gateway?.isAlive ?? false,
                "activeModel": config?.activeModel as Any? ?? NSNull(),
                "ollamaAlive": ollamaAlive,
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                "activeAgents": activeAgents,
                "tokens": tokens,
                "last7Days": last7,
                "modelShare7d": modelShare,
                "costs": costs,
                "hardware": hardware,
                "processes": processes,
            ]
            let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
            self.send(connection, status: "200 OK", contentType: "application/json", body: data)
        }
    }

    /// Mirrors `DashboardStore`'s today/7d/month/all-time derivations exactly
    /// (including "nil when there's no prior window" — no invented 0%/trend).
    private static func tokenStats(
        daily: [HermesStateReader.DayTokens], monthTotal7dModels: [HermesStateReader.ModelTokens], allTimeTotal: Int
    ) -> [String: Any] {
        let dayFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = .current
            return f
        }()
        let todayKey = dayFormatter.string(from: Date())
        let yesterdayKey = dayFormatter.string(from: Date().addingTimeInterval(-86400))
        let monthPrefix = String(todayKey.prefix(7))
        let previousMonthPrefix = Calendar.current.date(byAdding: .month, value: -1, to: Date())
            .map { String(dayFormatter.string(from: $0).prefix(7)) }

        let today = daily.first { $0.day == todayKey }
        let yesterday = daily.first { $0.day == yesterdayKey }
        let todayTrendPercent: Int? = {
            guard let today, let yesterday, yesterday.total > 0 else { return nil }
            return Int((Double(today.total - yesterday.total) / Double(yesterday.total) * 100).rounded())
        }()

        let last7 = Array(daily.suffix(7))
        let sevenDayTotal = last7.reduce(0) { $0 + $1.total }
        let monthTotal = daily.filter { $0.day.hasPrefix(monthPrefix) }.reduce(0) { $0 + $1.total }
        let monthTrendPercent: Int? = {
            guard let prefix = previousMonthPrefix else { return nil }
            let previous = daily.filter { $0.day.hasPrefix(prefix) }.reduce(0) { $0 + $1.total }
            guard previous > 0, monthTotal > 0 else { return nil }
            return Int((Double(monthTotal - previous) / Double(previous) * 100).rounded())
        }()

        return [
            "today": today.map { $0.total } as Any? ?? NSNull(),
            "todayTrendPercent": todayTrendPercent as Any? ?? NSNull(),
            "sevenDay": sevenDayTotal,
            "month": monthTotal,
            "monthTrendPercent": monthTrendPercent as Any? ?? NSNull(),
            "allTime": allTimeTotal,
        ]
    }

    /// Mirrors `CostsBlock.costsColumn`'s exact formula (same buggy-or-not
    /// numbers as the native app — not this wave's job to "fix" them).
    private static func costStats(
        modelTokens7d: [HermesStateReader.ModelTokens], usdRate: Double?, eurRate: Double?
    ) -> [String: Any] {
        let apiValueUSD = modelTokens7d.reduce(0.0) { sum, model in
            let price = ModelPricing.price(for: model.model)
            return sum
                + Double(model.inputTokens) / 1_000_000 * price.inputPerMillion
                + Double(model.outputTokens) / 1_000_000 * price.outputPerMillion
        }
        guard let usdRate, let eurRate, apiValueUSD > 0 else {
            return ["nbpUsdRate": NSNull(), "nbpEurRate": NSNull(), "paidZl": NSNull(), "apiValueZl": NSNull(), "apiValueEur": NSNull(), "savingsPercent": NSNull()]
        }
        // ponytail: same literal as DashboardStore.ollamaProMonthlyCost — that
        // property is @MainActor-isolated (part of an @Observable class), not
        // worth a MainActor hop just to read a constant that never changes.
        let ollamaProMonthlyCost = 20.0
        let paidZl = Int(ollamaProMonthlyCost * usdRate)
        let apiValueZl = Int(apiValueUSD * usdRate)
        let apiValueEur = Int(apiValueUSD * usdRate / eurRate)
        let savingsPercent = Int((1 - (ollamaProMonthlyCost / apiValueUSD)).rounded() * 100)
        return [
            "nbpUsdRate": usdRate, "nbpEurRate": eurRate,
            "paidZl": paidZl, "apiValueZl": apiValueZl, "apiValueEur": apiValueEur,
            "savingsPercent": max(0, savingsPercent),
        ]
    }

    private func nbpRates() async -> (usd: Double?, eur: Double?) {
        let client = await MainActor.run { self.ensureNBPClient() }
        await client.refreshIfNeeded()
        return await MainActor.run { (client.usdRate, client.eurRate) }
    }

    /// ponytail: no sparkline history in v1 — `HardwareMonitor.cpuHistory`
    /// etc. exist but wiring 60-sample arrays through JSON for a value the
    /// mockup treats as decorative wasn't worth it this wave. Add by exposing
    /// `monitor.cpuHistory` (already public-ish `private(set)`) the same way.
    private func hardwareSnapshot() async -> [String: Any] {
        await MainActor.run {
            let m = self.ensureHardwareMonitor()
            let ramUsed: Double? = {
                guard let app = m.ramAppBytes, let wired = m.ramWiredBytes, let compressed = m.ramCompressedBytes else { return nil }
                return Double(app + wired + compressed) / 1e9
            }()
            return [
                "cpuPercent": m.cpuPercent as Any? ?? NSNull(),
                "gpuPercent": m.gpuDevicePercent as Any? ?? NSNull(),
                "ramUsedGB": ramUsed as Any? ?? NSNull(),
                "ramTotalGB": Double(m.ramTotalBytes) / 1e9,
                "ssdAvailableGB": m.ssdAvailableBytes.map { Double($0) / 1e9 } as Any? ?? NSNull(),
                "ssdTotalGB": m.ssdTotalBytes.map { Double($0) / 1e9 } as Any? ?? NSNull(),
                "netDownMBs": m.netDownBytesPerSec.map { $0 / 1_000_000 } as Any? ?? NSNull(),
                "netUpMBs": m.netUpBytesPerSec.map { $0 / 1_000_000 } as Any? ?? NSNull(),
            ]
        }
    }

    /// ponytail: name-only, no app icon (`NSRunningApplication.icon` → PNG →
    /// base64 is real work for a "which process is eating CPU" glance the
    /// mockup itself renders tiny) — omitted, add by base64-encoding
    /// `icon.tiffRepresentation` if ever wanted.
    private func processSnapshot() async -> [[String: Any]] {
        await MainActor.run {
            let m = self.ensureHardwareMonitor()
            return m.topProcesses.map {
                ["name": $0.name, "pid": Int($0.id), "cpuPercent": $0.cpuPercent, "ramMB": Double($0.ramBytes) / 1_048_576]
            }
        }
    }

    // MARK: - Static files (Vite build output)

    /// `Contents/Resources/WebUI/` — NOT an SPM resource bundle (Vite emits
    /// many files with hashed names, unlike the old single `index.html`
    /// resource), so this reaches into the app bundle directly.
    private var webUIDir: URL {
        Bundle.main.resourceURL!.appendingPathComponent("WebUI", isDirectory: true)
    }

    private func serveFile(_ connection: NWConnection, path: String) {
        let cleanPath = path.components(separatedBy: "?").first ?? path
        guard !cleanPath.contains("..") else {
            send(connection, status: "400 Bad Request", contentType: "text/plain", body: Data("bad path".utf8))
            return
        }
        let relative = cleanPath == "/" ? "index.html" : String(cleanPath.dropFirst())
        var fileURL = webUIDir.appendingPathComponent(relative)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // SPA fallback — harmless even without client-side routing today.
            fileURL = webUIDir.appendingPathComponent("index.html")
        }
        guard var data = try? Data(contentsOf: fileURL) else {
            send(connection, status: "500 Internal Server Error", contentType: "text/plain", body: Data("WebUI missing from bundle".utf8))
            return
        }
        if fileURL.lastPathComponent == "index.html" {
            let token = HermesGatewayClient.loadOrCreatePersistedToken()
            if let html = String(data: data, encoding: .utf8) {
                data = Data(html.replacingOccurrences(of: "%%GATEWAY_TOKEN_VALUE%%", with: token).utf8)
            }
        }
        send(connection, status: "200 OK", contentType: contentType(for: fileURL.pathExtension), body: data)
    }

    private func contentType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "woff2": return "font/woff2"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    private func send(_ connection: NWConnection, status: String, contentType: String, body: Data) {
        let response = "HTTP/1.0 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - WebSocket relay
    //
    // A WS upgrade + all subsequent frames ride one continuous TCP stream, so
    // relaying raw bytes both directions is sufficient — no WS framing needs
    // to be understood here (ponytail: real WS-aware reverse proxy would be
    // the "correct" upgrade path if this ever needs to inspect/modify frames).

    private func relayToGateway(_ connection: NWConnection, alreadyRead: Data) {
        let gateway = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(RemoteWebUIConfig.gatewayPort)), using: .tcp
        )
        gateway.start(queue: queue)
        gateway.send(content: alreadyRead, completion: .contentProcessed { _ in })
        pump(from: connection, to: gateway)
        pump(from: gateway, to: connection)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                destination.cancel()
                source.cancel()
                return
            }
            self.pump(from: source, to: destination)
        }
    }
}
