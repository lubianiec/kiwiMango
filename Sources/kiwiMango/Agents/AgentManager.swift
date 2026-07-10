import AppKit
import Foundation
import Observation
import SwiftTerm

// MARK: - AgentKind

/// Which coding agent to run in the PTY. All of them ship as `ollama launch`
/// integrations, so the spawn command differs only by the integration name —
/// `--model` is a launcher-level flag, identical for every kind.
enum AgentKind: String, CaseIterable, Identifiable {
    case claude
    case hermes
    case codex
    /// Fala 17: bare `claude` interactive TUI via Claude Pro subscription —
    /// NOT an `ollama launch` integration, spawned differently in `spawn()`.
    case claudePro

    var id: String { rawValue }

    /// Argument for `ollama launch <integration>`. Not used by `.claudePro`.
    var integration: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "CLAUDE CODE"
        case .hermes: "HERMES"
        case .codex: "CODEX"
        case .claudePro: "CLAUDE PRO"
        }
    }

    /// Short label for the narrow sidebar row.
    var shortName: String {
        switch self {
        case .claude: "CLAUDE"
        case .hermes: "HERMES"
        case .codex: "CODEX"
        case .claudePro: "PRO"
        }
    }
}

// MARK: - AgentSession

/// One running (or finished) Claude Code TUI session, hosted in a PTY.
/// Deliberately not persisted anywhere — GRDB never sees this. Sessions live
/// only as long as the app process does (see PLAN.md F4 pitfall #3).
@MainActor
final class AgentSession: Identifiable {
    let id = UUID()
    let kind: AgentKind
    let model: String
    let isCloud: Bool
    let workDir: URL
    let terminal: LocalProcessTerminalView
    let startedAt = Date()
    var status: Status = .running

    /// Guards against saving the same session to `agentSession` twice (Fala 13) —
    /// `archive(_:)` can be reached from `markFinished`, `close`, or `killAll`.
    var archived = false

    /// "namespace/model:tag" → "model:tag" — prefiks namespace
    /// tylko zaśmieca wąski sidebar.
    var shortModel: String { model.split(separator: "/").last.map(String.init) ?? model }

    var title: String { "\(kind.shortName) · \(workDir.lastPathComponent)" }

    enum Status {
        case running
        case finished
    }

    init(kind: AgentKind, model: String, isCloud: Bool, workDir: URL, terminal: LocalProcessTerminalView) {
        self.kind = kind
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
    func spawn(kind: AgentKind, model: String, isCloud: Bool, workDir: URL) -> AgentSession {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.applyKiwiMangoTheme()
        terminal.processDelegate = terminationRelay
        // Default scrollback is only 500 lines (SwiftTerm TerminalOptions) — bump
        // it once up front so `dumpTranscript` has up to 2000 lines to work with.
        terminal.getTerminal().changeScrollback(2000)

        let session = AgentSession(kind: kind, model: model, isCloud: isCloud, workDir: workDir, terminal: terminal)
        sessions.append(session)

        // Login shell (`-l`) re-reads .zshrc/.zprofile so `ollama` (installed via
        // Homebrew or the official pkg) is on PATH even though this process was
        // spawned by the app bundle, not a Terminal window (PLAN.md pitfall #2).
        var env = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        env.append("TERM=xterm-256color")

        let escapedDir = workDir.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedModel = model.replacingOccurrences(of: "'", with: "'\\''")

        let command: String
        if kind == .claudePro {
            // Claude Pro subscription — bare `claude` TUI, NOT `ollama launch`.
            // Must never inherit API-key/base-URL env vars, or the CLI silently
            // switches from subscription auth to (broken/ToS-violating) API auth.
            let strippedKeys = [
                "ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDECODE",
            ]
            env.removeAll { entry in
                strippedKeys.contains { entry.hasPrefix("\($0)=") }
            }
            command = "cd '\(escapedDir)' && claude --model '\(escapedModel)'"
        } else {
            command = "cd '\(escapedDir)' && ollama launch \(kind.integration) --model '\(escapedModel)'"
        }

        terminal.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", command],
            environment: env,
            currentDirectory: workDir.path
        )

        return session
    }

    func close(_ session: AgentSession) {
        // Dump BEFORE terminate — the buffer is still alive; terminate() tears
        // down the process and can leave the view in a state that's too late
        // to read reliably.
        archive(session)
        if session.status == .running {
            session.terminal.terminate()
        }
        sessions.removeAll { $0.id == session.id }
    }

    /// Kills every child process. Called on app termination so quitting never
    /// leaves `ollama`/`claude` zombies behind (PLAN.md pitfall #3) — also a
    /// best-effort synchronous archive of every still-live session (F13.2).
    func killAll() {
        for session in sessions where session.status == .running {
            archive(session)
            session.terminal.terminate()
        }
        sessions.removeAll()
    }

    fileprivate func markFinished(_ terminal: TerminalView) {
        guard let session = sessions.first(where: { $0.terminal === terminal }) else { return }
        session.status = .finished
        // The process died on its own (not via `close`) — archive right away,
        // don't wait for the user to dismiss the row.
        archive(session)
    }

    /// One private point of entry to `agentSession` — called from `markFinished`,
    /// `close`, and `killAll`. Guards against double-saving the same session
    /// and skips test-run noise (<60s, no real content).
    private func archive(_ session: AgentSession) {
        guard !session.archived else { return }
        let transcript = Self.dumpTranscript(of: session)
        let duration = Date().timeIntervalSince(session.startedAt)
        guard duration >= 60, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.archived = true
            return
        }
        session.archived = true
        let endedAt = Date()
        do {
            try DatabaseManager.shared.saveAgentSession(
                kind: session.kind.rawValue,
                model: session.model,
                isCloud: session.isCloud,
                workDir: session.workDir.path,
                startedAt: session.startedAt,
                endedAt: endedAt,
                transcript: transcript
            )
        } catch {
            print("[AgentManager] failed to archive session \(session.id): \(error)")
        }
        // Fala 12 (F12.3): same transcript, same "≥60s and non-empty" bar
        // already applied above — no need to re-check it here.
        ObsidianSyncService.syncAgentSession(
            kind: session.kind.rawValue,
            model: session.model,
            isCloud: session.isCloud,
            workDir: session.workDir.path,
            startedAt: session.startedAt,
            endedAt: endedAt,
            transcript: transcript
        )
    }

    /// Reads the terminal's transcript and reduces it to a readable summary:
    /// first 20 non-empty lines (what the user asked / initial context) plus
    /// last 30 non-empty lines (final result). No alt-buffer TUI garbage,
    /// no 2000-line raw dump. ponytail: PTY doesn't give us structured turns,
    /// so we store the most useful raw window instead.
    static func dumpTranscript(of session: AgentSession) -> String {
        let terminal = session.terminal.getTerminal()
        let normal = String(data: terminal.getBufferAsData(kind: .normal), encoding: .utf8) ?? ""
        let altText = String(data: terminal.getBufferAsData(kind: .alt), encoding: .utf8) ?? ""
        let text = normal + "\n" + altText

        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var summary = ""
        if let first = lines.first {
            summary += "▸ start: \(first)\n"
        }
        if lines.count > 20 {
            summary += "\n[... \(lines.count - 50 > 0 ? lines.count - 50 : 0) linii pominiętych ...]\n\n"
            let tail = Array(lines.suffix(30))
            summary += tail.joined(separator: "\n")
        } else {
            summary += lines.dropFirst().joined(separator: "\n")
        }
        return summary
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
