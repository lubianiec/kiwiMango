import Foundation
import Observation

// MARK: - HermesHUDManager

/// Spawns and tracks the local hermes-hudui server so kiwiMango can show the
/// Hermes dashboard without leaving the app. Lazy install: if the CLI is missing,
/// the UI clones the upstream repo, creates a venv, installs Python deps and
/// builds the frontend, then starts the server. ponytail: reuse the existing
/// `~/.hermes-hudui` checkout rather than inventing a new package manager.
@MainActor
@Observable
final class HermesHUDManager {
    enum State: Equatable {
        case idle
        case checking
        case missing
        case installing(String)
        case starting
        case ready(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var logLines: [String] = []

    private var process: Process?
    private var installProcess: Process?
    private var pollTask: Task<Void, Never>?

    /// Fixed companion directory for the hermes-hudui checkout + venv.
    private let huduiHome = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".hermes-hudui")

    /// The binary inside the venv; this is the only executable we trust.
    private var hermesHUDUIPath: String? {
        let path = huduiHome.appendingPathComponent("venv/bin/hermes-hudui").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Tries to find a Python 3.11+ interpreter to drive pip installs.
    private var pythonPath: String? {
        let candidates = [
            "/opt/homebrew/bin/python3.14",
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/python3.11").path,
            "/usr/bin/python3",
        ]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            if versionOK(path) { return path }
        }
        return nil
    }

    private func versionOK(_ path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return false }
            let parts = text.split(separator: " ").last?.split(separator: ".") ?? []
            guard let major = parts.first.flatMap({ Int($0) }), let minor = parts.dropFirst().first.flatMap({ Int($0) }) else { return false }
            return major > 3 || (major == 3 && minor >= 11)
        } catch {
            return false
        }
    }

    /// True if the companion checkout already exists and looks complete.
    private var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: huduiHome.path) else { return false }
        let binary = huduiHome.appendingPathComponent("venv/bin/hermes-hudui").path
        let staticIndex = huduiHome.appendingPathComponent("backend/static/index.html").path
        return fm.isExecutableFile(atPath: binary) && fm.fileExists(atPath: staticIndex)
    }

    func check() {
        state = .checking
        if isInstalled {
            startServer()
        } else {
            state = .missing
        }
    }

    func install() {
        guard let python = pythonPath else {
            state = .failed("Nie znaleziono Pythona 3.11+. Zainstaluj Python via Homebrew.")
            return
        }
        state = .installing(python)
        logLines = []

        let fm = FileManager.default
        if fm.fileExists(atPath: huduiHome.path) {
            try? fm.removeItem(at: huduiHome)
        }
        try? fm.createDirectory(at: huduiHome, withIntermediateDirectories: true)

        // Single zsh login-shell invocation does clone + venv + pip + frontend build.
        // This avoids chaining multiple Process tasks and handles PATH/activation correctly.
        let script = """
        set -e
        cd "\(huduiHome.path)"
        echo "→ Klonuję hermes-hudui..."
        git clone https://github.com/joeynyc/hermes-hudui.git . --quiet
        echo "→ Tworzę środowisko Python..."
        "\(python)" -m venv venv
        source venv/bin/activate
        echo "→ Instaluję zależności..."
        pip install -e . -q
        echo "→ Buduję frontend..."
        cd frontend
        npm install --silent
        npm run build
        cd ..
        mkdir -p backend/static/assets
        cp frontend/dist/index.html backend/static/
        cp frontend/dist/assets/* backend/static/assets/
        echo "✔ Gotowe."
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", script]
        task.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        task.standardOutput = out
        task.standardError = out
        installProcess = task

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.logLines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
        }

        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.isInstalled {
                    self.startServer()
                } else {
                    self.state = .failed("Instalacja się nie powiodła. Sprawdź logi.")
                }
            }
        }

        do {
            try task.run()
        } catch {
            state = .failed("Błąd uruchomienia instalatora: \(error.localizedDescription)")
        }
    }

    func startServer() {
        guard let binary = hermesHUDUIPath else {
            state = .missing
            return
        }
        state = .starting
        stopServer()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["--port", "3001", "--host", "127.0.0.1"]
        task.environment = ProcessInfo.processInfo.environment

        let out = Pipe()
        task.standardOutput = out
        task.standardError = out
        process = task

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.logLines.append(contentsOf: text.split(separator: "\n").map(String.init))
            }
        }

        do {
            try task.run()
            pollUntilReady()
        } catch {
            state = .failed("Nie udało się uruchomić serwera: \(error.localizedDescription)")
        }
    }

    func stopServer() {
        pollTask?.cancel()
        pollTask = nil
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }

    private func pollUntilReady() {
        pollTask = Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if await self.isServerReady() {
                    self.state = .ready(URL(string: "http://127.0.0.1:3001")!)
                    return
                }
            }
            self?.state = .failed("Serwer nie odpowiada na porcie 3001.")
        }
    }

    private func isServerReady() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:3001/") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
