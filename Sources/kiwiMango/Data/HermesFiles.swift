import Darwin
import Foundation

// MARK: - HermesFilesReader (Fala 1c)
//
// Read-only snapshot of everything under `~/.hermes/` that ISN'T `state.db`
// (that's `HermesStateReader`, Fala 1). Every function here is best-effort:
// `~/.hermes` may not exist at all (Hermes never installed/run on this Mac),
// individual files can be mid-write, and `~/.hermes/profiles/` doesn't exist
// on Paweł's machine today. Nothing here throws to the caller — missing or
// unparsable input just means nil/[]/an "offline" reading, never a crash.

enum HermesFilesReader {

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes", isDirectory: true)
    }

    // MARK: - Gateway state (gateway_state.json)

    struct GatewayState: Decodable {
        let pid: Int
        let state: String
        let platforms: [String: Platform]
        let updatedAt: String

        struct Platform: Decodable {
            let state: String
        }

        enum CodingKeys: String, CodingKey {
            case pid, platforms
            case state = "gateway_state"
            case updatedAt = "updated_at"
        }
    }

    /// Pułapka z planu: gateway w trybie messaging (Telegram) NIE nasłuchuje na
    /// TCP, więc "czy gateway żyje" nigdy nie sprawdzamy przez próbę połączenia
    /// — tylko plik + `kill(pid, 0)` (Darwin: sygnał 0 = sam check istnienia
    /// procesu, nic mu nie wysyła). Zwraca nil gdy plik nie istnieje/jest
    /// nie do sparsowania (gateway nigdy nie startował albo trwa zapis).
    static func gatewayState() -> (state: GatewayState, isAlive: Bool)? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("gateway_state.json")),
              let state = try? JSONDecoder().decode(GatewayState.self, from: data)
        else { return nil }
        let isAlive = kill(pid_t(state.pid), 0) == 0
        return (state, isAlive)
    }

    // MARK: - Cron jobs (cron/jobs.json)

    struct CronJob: Decodable, Identifiable {
        let id: String
        let name: String
        let scheduleDisplay: String
        let nextRunAt: String?
        let lastRunAt: String?
        let lastStatus: String?
        let enabled: Bool

        enum CodingKeys: String, CodingKey {
            case id, name, enabled
            case scheduleDisplay = "schedule_display"
            case nextRunAt = "next_run_at"
            case lastRunAt = "last_run_at"
            case lastStatus = "last_status"
        }
    }

    static func cronJobs() -> [CronJob] {
        struct Wrapper: Decodable { let jobs: [CronJob] }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("cron/jobs.json")),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data)
        else { return [] }
        return wrapper.jobs
    }

    // MARK: - Memory (memories/MEMORY.md, memories/USER.md)

    struct MemoryFile {
        let text: String
        let charCount: Int
        let limit: Int
        var fillPercent: Double { limit > 0 ? min(100, Double(charCount) / Double(limit) * 100) : 0 }
    }

    // Limity z rekonesansu w planie: MEMORY.md 2200 znaków, USER.md 1375 —
    // ściany narzucane przez Hermesa, nie coś co odczytujemy z pliku.
    static func memoryFile() -> MemoryFile? { readMemory("memories/MEMORY.md", limit: 2200) }
    static func userFile() -> MemoryFile? { readMemory("memories/USER.md", limit: 1375) }

    private static func readMemory(_ relativePath: String, limit: Int) -> MemoryFile? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
        else { return nil }
        return MemoryFile(text: text, charCount: text.count, limit: limit)
    }

    // MARK: - config.yaml (active model + enabled plugins — line-scan, NOT a YAML parser)
    //
    // ponytail: only 2 scalars are needed out of a config file with a dozen
    // unrelated sections — a full YAML parse (Yams is already a dependency,
    // see `parseFrontmatter` below) would be the "correct" tool but is
    // overkill for "read one `default:` line and one flat list under
    // `enabled:`". Line-scan sufit: breaks if Paweł restructures config.yaml
    // to nest `model.default` under something else, or if `enabled:` stops
    // being the plugins list's exact trimmed line — cheap to notice (empty
    // result) and cheap to fix later with Yams if that ever happens.
    struct ConfigSummary {
        let activeModel: String?
        let enabledPlugins: [String]
    }

    static func configSummary() -> ConfigSummary? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("config.yaml"), encoding: .utf8)
        else { return nil }
        let lines = text.components(separatedBy: .newlines)

        let activeModel = lines
            .first { $0.range(of: #"^\s*default:\s*\S"#, options: .regularExpression) != nil }
            .map { $0.replacingOccurrences(of: #"^\s*default:\s*"#, with: "", options: .regularExpression) }

        var plugins: [String] = []
        if let enabledIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "enabled:" }) {
            for line in lines[(enabledIndex + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- ") else { break }
                plugins.append(String(trimmed.dropFirst(2)))
            }
        }
        return ConfigSummary(activeModel: activeModel, enabledPlugins: plugins)
    }

    // providerStatuses/activeModelMetadata/skills/profiles/plugins/healthChecks
    // removed with the 17-section Dashboard (2026-07-10, strona "Zużycie") — the
    // page only reads gateway/cron/memory/config above.
}

// MARK: - HermesFilesWatcher (Fala 1c)
//
// DispatchSource file-level watcher for the 3 "live" `~/.hermes` files
// (gateway_state.json, cron/jobs.json, memories/MEMORY.md). No existing
// FSEvents/DispatchSource pattern in the codebase to reuse (checked
// ObsidianSyncService and friends — file-writing only, nothing watches).
final class HermesFilesWatcher {

    private let queue = DispatchQueue(label: "com.kiwimango.hermesFilesWatcher", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var debounceWorkItem: DispatchWorkItem?
    private let onChange: () -> Void

    /// `onChange` fires on the main actor, at most once per ~1s even if all
    /// 3 files change in the same burst (a cron run commonly touches
    /// gateway_state + jobs.json back to back).
    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = { Task { @MainActor in onChange() } }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes")
        let watchedPaths = [
            root.appendingPathComponent("gateway_state.json").path,
            root.appendingPathComponent("cron/jobs.json").path,
            root.appendingPathComponent("memories/MEMORY.md").path
        ]
        queue.async { [weak self] in
            watchedPaths.forEach { self?.watch(path: $0) }
        }
    }

    /// ponytail: a file that doesn't exist yet when the watcher starts is
    /// simply never watched (covers Paweł's real setup — all 3 exist).
    /// Picking up a file created later would need a directory-level watch;
    /// not worth it for 3 known, already-present paths.
    private func watch(path: String) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.scheduleDebounced()
            // Atomic "write to temp, rename over target" (how JSON/Markdown
            // config files are typically saved) replaces the inode our fd
            // points at — a rename/delete event means THIS fd is now stale,
            // so cancel it and reopen the path fresh to keep watching.
            let flags = source.data
            if flags.contains(.rename) || flags.contains(.delete) {
                source.cancel()
                self.queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.watch(path: path)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources.append(source)
    }

    private func scheduleDebounced() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        debounceWorkItem = item
        queue.asyncAfter(deadline: .now() + 1.0, execute: item)
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}

// MARK: - Demo check (ponytail: one runnable check for non-trivial logic)
//
// Not a test framework — exercises every reader against whatever's really on
// disk right now and returns a printable summary. Call from anywhere (e.g.
// temporarily from `KiwiMangoApp.init()`) to sanity-check this file after a
// change; no assertions baked in since the "correct" answer depends on
// Paweł's actual `~/.hermes` state at call time.
enum HermesFilesDemoCheck {
    @MainActor
    static func run() -> String {
        var lines: [String] = []

        if let (state, alive) = HermesFilesReader.gatewayState() {
            lines.append("gateway: pid=\(state.pid) state=\(state.state) alive=\(alive) telegram=\(state.platforms["telegram"]?.state ?? "—")")
        } else {
            lines.append("gateway: brak/nieczytelny gateway_state.json")
        }

        let jobs = HermesFilesReader.cronJobs()
        lines.append("cron: \(jobs.count) job(ów)" + (jobs.first.map { " — pierwszy: \($0.name) [\($0.scheduleDisplay)] next=\($0.nextRunAt ?? "—")" } ?? ""))

        if let memory = HermesFilesReader.memoryFile() {
            lines.append("MEMORY.md: \(memory.charCount)/\(memory.limit) znaków (\(String(format: "%.0f", memory.fillPercent))%)")
        } else {
            lines.append("MEMORY.md: brak")
        }
        if let user = HermesFilesReader.userFile() {
            lines.append("USER.md: \(user.charCount)/\(user.limit) znaków (\(String(format: "%.0f", user.fillPercent))%)")
        } else {
            lines.append("USER.md: brak")
        }

        if let config = HermesFilesReader.configSummary() {
            lines.append("config.yaml: model=\(config.activeModel ?? "—") plugins=\(config.enabledPlugins)")
        } else {
            lines.append("config.yaml: brak/nieczytelny")
        }

        // Exercise the watcher too — opens real fds for the 3 live files and
        // tears them down cleanly; a crash here would mean the O_EVTONLY/
        // DispatchSource setup above is broken against the real paths.
        var watcherFired = false
        let watcher = HermesFilesWatcher { watcherFired = true }
        _ = watcher // silence "never used" — held just long enough to prove init doesn't crash
        lines.append("watcher: initialized ok (fired=\(watcherFired), immediate — expected false)")

        return lines.joined(separator: "\n")
    }
}
