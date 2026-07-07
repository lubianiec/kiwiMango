import Foundation

// MARK: - ClaudeCodeService
//
// Fala 17: chat z modelami Anthropic (Sonnet/Opus/Haiku) przez subskrypcję
// Claude Pro — headless `claude -p ... --output-format stream-json`, NIE przez
// klucz API (zablokowany kontraktowo, wbrew ToS Anthropic dla subskrypcji).
//
// Wire format zweryfikowany EMPIRYCZNIE (2026-07-07):
//   `claude -p "..." --model haiku --output-format stream-json --include-partial-messages --verbose`
// wymaga `--verbose` inaczej CLI odmawia startu. Linie NDJSON, kluczowe typy:
//   {"type":"system","subtype":"init","session_id":"...", ...}          → sesja startuje
//   {"type":"stream_event","event":{"type":"content_block_delta",
//     "delta":{"type":"text_delta","text":"..."}}, "session_id":"..."}  → kawałek tekstu
//   {"type":"result","subtype":"success","result":"...",
//     "total_cost_usd":..., "usage":{...}, "session_id":"..."}          → koniec, finalny tekst
// Inne typy (assistant/user/tool_use/thinking/rate_limit_event/hook_*) są
// ignorowane — CLI emituje je zawsze (hooki z ~/.claude, ewentualne narzędzia),
// parser musi być tolerancyjny, nie zamknięty na jedną ścieżkę.

/// Pure transport layer for headless `claude` CLI (subscription-based, not API key).
/// No UI, no observable state — mirrors `OllamaService`'s shape.
struct ClaudeCodeService: Sendable {

    // MARK: Wire types

    /// One streamed unit — either a text fragment or the final result summary.
    enum Delta: Sendable {
        case content(String)
        case result(ResultInfo)
    }

    struct ResultInfo: Sendable {
        let text: String
        let sessionID: String?
        let costUSD: Double?
        let durationMs: Int?
        let isError: Bool
    }

    enum ClaudeCodeError: LocalizedError {
        case binaryNotFound
        case notLoggedIn
        case processFailed(String)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                "Nie znaleziono binarki `claude` na PATH."
            case .notLoggedIn:
                "Nie jesteś zalogowany do Claude Code. Uruchom `claude` w terminalu i wykonaj /login."
            case .processFailed(let message):
                message.isEmpty ? "Proces `claude` zakończył się błędem." : message
            case .rateLimited:
                "Wyczerpano limit Claude Pro (okno 5h). Spróbuj ponownie później albo przełącz się na model Ollama."
            }
        }
    }

    // MARK: - Availability detection (F17.0 gate, cached by caller)

    /// PATH-detection pattern mirrors `AgentManager`: a login shell (`-l`)
    /// re-reads .zshrc/.zprofile so `claude` (installed via npm/Homebrew) is
    /// found even though this process wasn't spawned from a Terminal window.
    static func detectBinaryPath() async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "which claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if proc.terminationStatus == 0, let path, !path.isEmpty {
                    continuation.resume(returning: path)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Fast login check: `claude -p "ping" --model haiku` should return quickly
    /// and non-empty. Only called once at startup after `detectBinaryPath`
    /// succeeds — a real network round-trip, so keep it to a tiny prompt.
    static func checkLoggedIn() async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-l", "-c",
                "claude -p 'Odpowiedz jednym słowem: ok' --model haiku",
            ]
            process.environment = Self.sanitizedEnvironment()
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
                return
            }
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: proc.terminationStatus == 0 && !text.isEmpty)
            }
        }
    }

    /// Strips inherited `ANTHROPIC_*` env vars that would break subscription
    /// auth (they redirect the CLI at the API-key path, which is blocked for
    /// Claude Pro subscriptions and against ToS). Verified empirically —
    /// these vars must be ACTIVELY removed, not just left unset by us.
    static func sanitizedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        env.removeValue(forKey: "CLAUDECODE")
        env["TERM"] = "xterm-256color"
        return env
    }

    // MARK: - Streaming

    /// Model alias → `--model` flag value.
    enum ClaudeModel: String, Sendable {
        case sonnet
        case opus
        case haiku
    }

    /// Streams a single prompt through `claude -p`, optionally resuming a
    /// prior session (`--resume <id>`) for conversation continuity.
    ///
    /// Prompt is passed as a `Process.arguments` element — NOT interpolated
    /// into a shell string — so no escaping is needed and command injection
    /// via pasted user text is impossible by construction. The outer `zsh -l`
    /// wrapper is only used to resolve PATH; the prompt itself never touches
    /// the shell's string interpolation.
    func streamMessage(
        prompt: String,
        model: ClaudeModel,
        resumeSessionID: String? = nil
    ) -> AsyncThrowingStream<Delta, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")

            // Locate `claude` once via login shell, then invoke it directly
            // with an argument array (not a second shell layer) so the
            // prompt never passes through shell string parsing at all.
            var claudeArgs = [
                "-p", prompt,
                "--model", model.rawValue,
                "--output-format", "stream-json",
                "--include-partial-messages",
                "--verbose",
            ]
            if let resumeSessionID {
                claudeArgs += ["--resume", resumeSessionID]
            }

            // We still need a login shell to resolve PATH for `claude` itself
            // (AgentManager pattern), but the prompt/model/session-id are
            // passed as a literal argv array to the child `claude` process via
            // `env -- claude <args...>`, executed FROM the login shell's
            // resolved PATH — so `-l -c` only ever sees the fixed string
            // "exec claude \"$@\"" and never re-parses user content.
            process.arguments = ["-l", "-c", "exec claude \"$@\"", "--", ] + claudeArgs
            process.environment = Self.sanitizedEnvironment()

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let buffer = LineBuffer()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in buffer.append(data) {
                    Self.handleLine(line, continuation: continuation)
                }
            }

            var stderrText = ""
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrText += String(data: data, encoding: .utf8) ?? ""
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                // Flush any trailing partial line without a final newline.
                if let last = buffer.flush() {
                    Self.handleLine(last, continuation: continuation)
                }
                if proc.terminationStatus != 0 {
                    let trimmed = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased().contains("rate limit") || trimmed.lowercased().contains("usage limit") {
                        continuation.finish(throwing: ClaudeCodeError.rateLimited)
                    } else if trimmed.lowercased().contains("not logged in")
                        || trimmed.lowercased().contains("please run") {
                        continuation.finish(throwing: ClaudeCodeError.notLoggedIn)
                    } else {
                        continuation.finish(throwing: ClaudeCodeError.processFailed(trimmed))
                    }
                } else {
                    continuation.finish()
                }
            }

            continuation.onTermination = { @Sendable _ in
                // Zero zombie processes on cancel/quit — same hygiene as
                // AgentManager.killAll: terminate, don't just drop the handle.
                if process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.finish(throwing: ClaudeCodeError.binaryNotFound)
            }
        }
    }

    /// Parses one NDJSON line and yields the relevant `Delta`, if any.
    /// Unknown/irrelevant `type` values (assistant, user, tool_use, thinking,
    /// rate_limit_event, hook_*, ...) are silently ignored — verified
    /// empirically that a bare `claude -p` invocation still emits these even
    /// with no tools/hooks configured on the caller's account, so the parser
    /// must tolerate them rather than assume a minimal fixed shape.
    private static func handleLine(_ line: String, continuation: AsyncThrowingStream<Delta, Error>.Continuation) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let type = object["type"] as? String else { return }

        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return }
            continuation.yield(.content(text))

        case "result":
            let text = object["result"] as? String ?? ""
            let sessionID = object["session_id"] as? String
            let cost = object["total_cost_usd"] as? Double
            let duration = object["duration_ms"] as? Int
            let isError = object["is_error"] as? Bool ?? (object["subtype"] as? String != "success")
            // Log cost/limits to console (F17.1 requirement) — no UI surface yet.
            if let cost {
                print(String(format: "[ClaudeCodeService] koszt: $%.4f, czas: %dms", cost, duration ?? 0))
            }
            continuation.yield(.result(ResultInfo(
                text: text, sessionID: sessionID, costUSD: cost, durationMs: duration, isError: isError
            )))

        default:
            break
        }
    }
}

// MARK: - LineBuffer

/// Accumulates raw stdout bytes and splits on `\n`, carrying any partial
/// trailing line forward to the next chunk. `Process.readabilityHandler`
/// delivers arbitrary byte chunks, not line-aligned NDJSON records.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let range = pending.range(of: Data([0x0A])) {
            let lineData = pending.subdata(in: pending.startIndex..<range.lowerBound)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            pending.removeSubrange(pending.startIndex..<range.upperBound)
        }
        return lines
    }

    /// Returns any leftover partial line once the process has terminated.
    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty, let line = String(data: pending, encoding: .utf8) else { return nil }
        pending.removeAll()
        return line.isEmpty ? nil : line
    }
}
