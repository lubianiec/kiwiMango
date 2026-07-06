import AppKit
import Foundation
import Observation
import SwiftTerm

// MARK: - AgentSession

/// One running (or finished) Claude Code TUI session, hosted in a PTY.
/// Deliberately not persisted anywhere — GRDB never sees this. Sessions live
/// only as long as the app process does (see PLAN.md F4 pitfall #3).
@MainActor
final class AgentSession: Identifiable {
    let id = UUID()
    let model: String
    let isCloud: Bool
    let workDir: URL
    let terminal: LocalProcessTerminalView
    let startedAt = Date()
    var status: Status = .running

    /// "namespace/model:tag" → "model:tag" — prefiks namespace
    /// tylko zaśmieca wąski sidebar.
    var shortModel: String { model.split(separator: "/").last.map(String.init) ?? model }

    var title: String { "\(shortModel) · \(workDir.lastPathComponent)" }

    enum Status {
        case running
        case finished
    }

    init(model: String, isCloud: Bool, workDir: URL, terminal: LocalProcessTerminalView) {
        self.model = model
        self.isCloud = isCloud
        self.workDir = workDir
        self.terminal = terminal
    }
}

// MARK: - AgentManager

/// Owns every agent terminal session for the app's lifetime.
/// `@MainActor @Observable` to match `ChatState` — both are UI-facing state
/// containers held by `RootView` (see PLAN.md pitfall #2).
@MainActor
@Observable
final class AgentManager: NSObject {
    private(set) var sessions: [AgentSession] = []

    /// Running-session count, surfaced in the status bar ("Agenci [N]").
    var runningCount: Int { sessions.count { $0.status == .running } }

    /// One delegate object shared by every session; it looks up which
    /// `AgentSession` finished by matching the terminating `TerminalView`.
    /// `@ObservationIgnored` + `lazy` don't mix with `@Observable`'s storage
    /// macro on a plain stored property, so this stays untracked (it's an
    /// implementation detail, not UI state).
    @ObservationIgnored
    private lazy var terminationRelay = TerminationRelay(manager: self)

    @discardableResult
    func spawn(model: String, isCloud: Bool, workDir: URL) -> AgentSession {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.applyKiwiMangoTheme()
        terminal.processDelegate = terminationRelay

        let session = AgentSession(model: model, isCloud: isCloud, workDir: workDir, terminal: terminal)
        sessions.append(session)

        // Login shell (`-l`) re-reads .zshrc/.zprofile so `ollama` (installed via
        // Homebrew or the official pkg) is on PATH even though this process was
        // spawned by the app bundle, not a Terminal window (PLAN.md pitfall #2).
        var env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        env.append("TERM=xterm-256color")

        let escapedDir = workDir.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedModel = model.replacingOccurrences(of: "'", with: "'\\''")
        let command = "cd '\(escapedDir)' && ollama launch claude --model '\(escapedModel)'"

        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", command],
            environment: env,
            currentDirectory: workDir.path
        )

        return session
    }

    func close(_ session: AgentSession) {
        if session.status == .running {
            session.terminal.terminate()
        }
        sessions.removeAll { $0.id == session.id }
    }

    /// Kills every child process. Called on app termination so quitting never
    /// leaves `ollama`/`claude` zombies behind (PLAN.md pitfall #3).
    func killAll() {
        for session in sessions where session.status == .running {
            session.terminal.terminate()
        }
        sessions.removeAll()
    }

    fileprivate func markFinished(_ terminal: TerminalView) {
        guard let session = sessions.first(where: { $0.terminal === terminal }) else { return }
        session.status = .finished
    }
}

// MARK: - TerminationRelay

/// `LocalProcessTerminalViewDelegate` needs an `AnyObject`, non-actor-isolated
/// bridge — `AgentManager`'s own delegate conformance would have to be
/// `nonisolated`, which fights `@MainActor @Observable`. A tiny relay object
/// hops back onto the main actor instead.
private final class TerminationRelay: NSObject, LocalProcessTerminalViewDelegate {
    weak var manager: AgentManager?

    init(manager: AgentManager) {
        self.manager = manager
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [manager] in
            manager?.markFinished(source)
        }
    }
}
