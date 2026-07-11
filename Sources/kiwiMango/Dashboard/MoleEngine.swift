import AppKit
import Foundation

// MARK: - MoleEngine (PLAN-V2 §7.5 / §11 pułapka 9)
//
// Mole is GUI-only: every operation below is a direct Swift/Process call, not
// a wrapper around the `mo` (tw93/mole) TUI binary — that binary is
// interactive and would need fragile pty+output parsing for zero benefit.
// // ponytail: sizes computed via FileManager enumerator (stdlib), not by
// shelling out to `du` and parsing text — same number, no process overhead.
//
// All destructive paths go through `FileManager.trashItem` (recoverable, same
// pattern ProcessSection.swift already uses for cache clearing) — never
// `removeItem`/`rm -rf`, and never touch a path under `/var` or otherwise
// requiring root. The one deliberate exception is emptying the already-is-the-
// Trash folder (~/.Trash) itself, which is inherently a permanent op — gated
// by the same confirm alert as everything else in MoleView.
@MainActor
@Observable
final class MoleEngine {

    // MARK: - Clean

    struct CleanCategory: Identifiable {
        enum Kind: String, CaseIterable { case appCaches, logs, trash, installers, derivedData }
        let kind: Kind
        let title: String
        let subtitle: String
        var sizeBytes: UInt64?
        var isSelected: Bool

        var id: Kind { kind }
    }

    private(set) var cleanCategories: [CleanCategory] = [
        .init(kind: .appCaches, title: "Cache aplikacji", subtitle: "~/Library/Caches", sizeBytes: nil, isSelected: true),
        .init(kind: .logs, title: "Logi systemowe", subtitle: "~/Library/Logs", sizeBytes: nil, isSelected: true),
        .init(kind: .trash, title: "Kosz", subtitle: "~/.Trash", sizeBytes: nil, isSelected: true),
        .init(kind: .installers, title: "Pobrane instalatory", subtitle: "~/Downloads — .dmg, .pkg", sizeBytes: nil, isSelected: false),
        .init(kind: .derivedData, title: "Cache Xcode / SPM", subtitle: "DerivedData", sizeBytes: nil, isSelected: false),
    ]

    private(set) var isLoadingCleanSizes = false
    private(set) var isCleaning = false
    private(set) var cleanProgress: Double = 0
    private(set) var lastCleanResultText: String?

    var cleanSelectedTotalBytes: UInt64 {
        cleanCategories.filter(\.isSelected).reduce(0) { $0 + ($1.sizeBytes ?? 0) }
    }

    func toggleClean(_ kind: CleanCategory.Kind) {
        guard let i = cleanCategories.firstIndex(where: { $0.kind == kind }) else { return }
        cleanCategories[i].isSelected.toggle()
    }

    /// Real, non-blocking size scan (pułapka #9 — never block main with `du`-equivalent work).
    func loadCleanSizes() async {
        guard !isLoadingCleanSizes else { return }
        isLoadingCleanSizes = true
        defer { isLoadingCleanSizes = false }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let targets: [(CleanCategory.Kind, URL)] = [
            (.appCaches, home.appendingPathComponent("Library/Caches")),
            (.logs, home.appendingPathComponent("Library/Logs")),
            (.trash, home.appendingPathComponent(".Trash")),
            (.installers, home.appendingPathComponent("Downloads")),
            (.derivedData, home.appendingPathComponent("Library/Developer/Xcode/DerivedData")),
        ]

        for (kind, url) in targets {
            let size: UInt64
            switch kind {
            case .installers:
                size = await Self.sizeOfInstallers(in: url)
            default:
                size = await Task.detached(priority: .utility) { Self.directorySize(url) }.value
            }
            if let i = cleanCategories.firstIndex(where: { $0.kind == kind }) {
                cleanCategories[i].sizeBytes = size
            }
        }
    }

    /// Recycles the contents of every selected category. Progress is coarse
    /// (one tick per category) — good enough for a 3pt bar, no need for
    /// byte-level progress plumbing.
    func runClean() async {
        guard !isCleaning else { return }
        isCleaning = true
        cleanProgress = 0
        lastCleanResultText = nil
        defer { isCleaning = false }

        let selected = cleanCategories.filter(\.isSelected)
        guard !selected.isEmpty else { return }
        var recoveredBytes: UInt64 = 0
        let home = FileManager.default.homeDirectoryForCurrentUser

        for (index, category) in selected.enumerated() {
            recoveredBytes += category.sizeBytes ?? 0
            switch category.kind {
            case .appCaches:
                await Self.recycleContents(of: home.appendingPathComponent("Library/Caches"))
            case .logs:
                await Self.recycleContents(of: home.appendingPathComponent("Library/Logs"))
            case .installers:
                await Self.recycleInstallers(in: home.appendingPathComponent("Downloads"))
            case .derivedData:
                await Self.recycleContents(of: home.appendingPathComponent("Library/Developer/Xcode/DerivedData"))
            case .trash:
                // ponytail: the one deliberate exception — this IS the Trash,
                // so "clean" means permanently empty it, not re-trash it.
                await Self.emptyTrash(home.appendingPathComponent(".Trash"))
            }
            cleanProgress = Double(index + 1) / Double(selected.count)
        }

        UserDefaults.standard.set(Date(), forKey: "lastCleanDate")
        UserDefaults.standard.set(recoveredBytes, forKey: "lastCleanBytes")
        lastCleanResultText = "✓ Odzyskano \(formatGB(recoveredBytes))"
        await loadCleanSizes()
    }

    nonisolated private static func sizeOfInstallers(in downloads: URL) async -> UInt64 {
        await Task.detached(priority: .utility) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
            return items.filter { ["dmg", "pkg"].contains($0.pathExtension.lowercased()) }
                .reduce(UInt64(0)) { $0 + directorySize($1) }
        }.value
    }

    nonisolated private static func recycleInstallers(in downloads: URL) async {
        await Task.detached(priority: .utility) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) else { return }
            for item in items where ["dmg", "pkg"].contains(item.pathExtension.lowercased()) {
                try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
            }
        }.value
    }

    /// Trashes every item *inside* a folder, leaving the folder itself in
    /// place (Caches/Logs/DerivedData must still exist as empty dirs so the
    /// next app launch doesn't have to recreate the parent).
    nonisolated private static func recycleContents(of folder: URL) async {
        await Task.detached(priority: .utility) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
            for item in items {
                try? FileManager.default.trashItem(at: item, resultingItemURL: nil)
            }
        }.value
    }

    nonisolated private static func emptyTrash(_ trash: URL) async {
        await Task.detached(priority: .utility) {
            guard let items = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return }
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }.value
    }

    // MARK: - Uninstall

    struct InstalledApp: Identifiable {
        let id: String // bundle identifier, falls back to path
        let name: String
        let url: URL
        let bundleID: String?
        var sizeBytes: UInt64?
        var companionBytes: UInt64?
    }

    private(set) var installedApps: [InstalledApp] = []
    private(set) var isLoadingApps = false

    func loadApps() async {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        defer { isLoadingApps = false }

        let apps = await Task.detached(priority: .utility) { () -> [InstalledApp] in
            guard let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Applications"), includingPropertiesForKeys: nil) else { return [] }
            return items
                .filter { $0.pathExtension == "app" }
                .compactMap { url -> InstalledApp? in
                    let bundle = Bundle(url: url)
                    let bundleID = bundle?.bundleIdentifier
                    // Skip Apple's own apps — plan §7.5 "bez systemowych".
                    if let bundleID, bundleID.hasPrefix("com.apple.") { return nil }
                    let name = bundle?.infoDictionary?["CFBundleName"] as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    return InstalledApp(id: bundleID ?? url.path, name: name, url: url, bundleID: bundleID)
                }
        }.value

        installedApps = apps
        for i in installedApps.indices {
            let app = installedApps[i]
            installedApps[i].sizeBytes = await Task.detached(priority: .utility) { Self.directorySize(app.url) }.value
            installedApps[i].companionBytes = await Task.detached(priority: .utility) { Self.companionSize(for: app.bundleID) }.value
        }
    }

    nonisolated private static func companionPaths(for bundleID: String?) -> [URL] {
        guard let bundleID else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            home.appendingPathComponent("Library/Caches/\(bundleID)"),
            home.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
            home.appendingPathComponent("Library/Application Support/\(bundleID)"),
        ]
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        if let files = try? FileManager.default.contentsOfDirectory(at: launchAgents, includingPropertiesForKeys: nil) {
            paths += files.filter { $0.lastPathComponent.hasPrefix(bundleID) }
        }
        return paths.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated private static func companionSize(for bundleID: String?) -> UInt64 {
        companionPaths(for: bundleID).reduce(0) { $0 + directorySize($1) }
    }

    /// Recycles the app bundle + every companion file. Confirm alert lives in
    /// MoleView, right before this is called.
    func uninstall(_ app: InstalledApp) async {
        try? FileManager.default.trashItem(at: app.url, resultingItemURL: nil)
        for path in Self.companionPaths(for: app.bundleID) {
            try? FileManager.default.trashItem(at: path, resultingItemURL: nil)
        }
        await loadApps()
    }

    // MARK: - Optimize

    struct OptimizeAction: Identifiable {
        let id: String
        let title: String
        let subtitle: String
    }

    /// `purge` was dropped from newer macOS releases — hide the button rather
    /// than fail silently when it's missing (§7.5).
    let optimizeActions: [OptimizeAction] = {
        var actions = [
            OptimizeAction(id: "spotlight", title: "Przebuduj bazę Spotlight", subtitle: "mdutil — indeks wyszukiwania"),
            OptimizeAction(id: "dns", title: "Wyczyść DNS cache", subtitle: "dscacheutil + killall mDNSResponder"),
            OptimizeAction(id: "audio", title: "Restart usług audio", subtitle: "coreaudiod przy trzaskach dźwięku"),
        ]
        if ["/usr/sbin/purge", "/usr/bin/purge"].contains(where: FileManager.default.fileExists) {
            actions.append(OptimizeAction(id: "purge", title: "Purge nieaktywnej pamięci", subtitle: "odzysk RAM"))
        }
        return actions
    }()

    private(set) var optimizeRunning: Set<String> = []
    private(set) var optimizeResults: [String: String] = [:]

    func runOptimize(_ id: String) async {
        optimizeRunning.insert(id)
        optimizeResults[id] = nil
        defer { optimizeRunning.remove(id) }

        // nil = success, non-nil = failure message shown inline.
        let failure: String?
        switch id {
        case "spotlight": failure = await Self.run("/usr/bin/mdutil", ["-E", "/"])
        case "dns": failure = await Self.runShell("dscacheutil -flushcache; killall -HUP mDNSResponder")
        case "audio": failure = await Self.runShell("killall coreaudiod")
        case "purge": failure = await Self.run("/usr/sbin/purge", [])
        default: failure = "Nieznana akcja"
        }

        optimizeResults[id] = failure ?? "✓ gotowe"
    }

    /// Returns nil on success, or a human-readable failure message.
    nonisolated private static func run(_ executablePath: String, _ arguments: [String]) async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 { return nil }
                let errorText = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if errorText.lowercased().contains("permission") || errorText.lowercased().contains("operation not permitted") {
                    return "Wymaga uprawnień roota — pomijamy"
                }
                return "Nie udało się (\(process.terminationStatus))"
            } catch {
                return "Nie udało się uruchomić"
            }
        }.value
    }

    /// killall/dscacheutil need a shell for the `;` sequencing — no other
    /// stdlib shortcut for "run two commands in order" without one.
    nonisolated private static func runShell(_ command: String) async -> String? {
        await run("/bin/zsh", ["-c", command])
    }

    // MARK: - Analyze

    struct AnalyzeEntry: Identifiable {
        let url: URL
        var sizeBytes: UInt64?
        var isDirectory: Bool
        var id: String { url.path }
        var name: String { url.lastPathComponent }
    }

    private(set) var analyzeCurrentDir: URL = FileManager.default.homeDirectoryForCurrentUser
    private(set) var analyzeBreadcrumb: [URL] = [FileManager.default.homeDirectoryForCurrentUser]
    private(set) var analyzeEntries: [AnalyzeEntry] = []
    private(set) var isLoadingAnalyze = false
    private var analyzeSizeCache: [URL: UInt64] = [:]

    func analyzeNavigate(to url: URL) {
        analyzeCurrentDir = url
        if let existingIndex = analyzeBreadcrumb.firstIndex(of: url) {
            analyzeBreadcrumb = Array(analyzeBreadcrumb[...existingIndex])
        } else {
            analyzeBreadcrumb.append(url)
        }
    }

    func loadAnalyzeCurrentDir() async {
        isLoadingAnalyze = true
        defer { isLoadingAnalyze = false }
        let dir = analyzeCurrentDir

        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var entries = items.map { url -> AnalyzeEntry in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return AnalyzeEntry(url: url, sizeBytes: analyzeSizeCache[url], isDirectory: isDir)
        }
        analyzeEntries = entries.sorted { ($0.sizeBytes ?? .max) > ($1.sizeBytes ?? .max) }

        for i in entries.indices where entries[i].sizeBytes == nil {
            let url = entries[i].url
            let size = await Task.detached(priority: .utility) { Self.directorySize(url) }.value
            analyzeSizeCache[url] = size
            entries[i].sizeBytes = size
            analyzeEntries = entries.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        }
    }

    func revealInFinder(_ entry: AnalyzeEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func trashAnalyzeEntry(_ entry: AnalyzeEntry) async {
        try? FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        analyzeSizeCache[entry.url] = nil
        await loadAnalyzeCurrentDir()
    }

    // MARK: - Status

    struct StatusInfo {
        var smartStatus: String?
        var pressureText: String
        var throttleText: String
        var launchAgentsCount: Int?
        var lastCleanText: String?
    }

    func loadStatus(ramPressureLevel: Int32?) async -> StatusInfo {
        async let smart = Self.readSMARTStatus()
        async let throttle = Self.readThrottleStatus()
        let launchAgentsCount = Self.countLaunchAgents()

        let lastCleanText: String? = {
            guard let date = UserDefaults.standard.object(forKey: "lastCleanDate") as? Date else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let bytes = UserDefaults.standard.object(forKey: "lastCleanBytes") as? UInt64
            let sizeText = bytes.map { " · odzyskano \(formatGB($0))" } ?? ""
            return "\(formatter.string(from: date))\(sizeText)"
        }()

        return StatusInfo(
            smartStatus: await smart,
            pressureText: Self.pressureText(ramPressureLevel),
            throttleText: await throttle,
            launchAgentsCount: launchAgentsCount,
            lastCleanText: lastCleanText
        )
    }

    private static func pressureText(_ level: Int32?) -> String {
        switch level {
        case .some(0): return "normalne"
        case .some(1): return "podwyższone"
        case .some(let l) where l > 1: return "krytyczne"
        case .some: return "normalne"
        case .none: return "brak danych"
        }
    }

    nonisolated private static func readSMARTStatus() async -> String? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            process.arguments = ["info", "-plist", "/"]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return plist["SMARTStatus"] as? String
        }.value
    }

    nonisolated private static func readThrottleStatus() async -> String {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "therm"]
            let pipe = Pipe()
            process.standardOutput = pipe
            guard (try? process.run()) != nil else { return "brak danych" }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // ponytail: heuristic text match — pmset's key set differs across
            // macOS versions, but "0" speed/schedule limits always mean "no throttle".
            let isThrottled = output.contains("CPU_Speed_Limit") && !output.contains("CPU_Speed_Limit\t\t= 100")
            return isThrottled ? "throttling aktywny" : "brak throttlingu"
        }.value
    }

    nonisolated private static func countLaunchAgents() -> Int? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userAgents = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/LaunchAgents").path))?.count ?? 0
        let systemAgents = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchAgents"))?.count ?? 0
        return userAgents + systemAgents
    }

    // MARK: - Shared helpers

    nonisolated static func directorySize(_ url: URL) -> UInt64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        guard isDir.boolValue else {
            return UInt64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

func formatGB(_ bytes: UInt64) -> String {
    plNumber(Double(bytes) / 1e9, 1) + " GB"
}
