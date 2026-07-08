import Foundation

// MARK: - HermesChatService
//
// Fala 22 (F22.1): chat z Hermes Agent (Ollama cloud/local) w normalnym oknie
// czatu, wzorem `ClaudeCodeService` (Fala 17), ale headless bez streamingu —
// `hermes chat` zwraca jeden blob na końcu procesu, nie NDJSON.
//
// Fakty zweryfikowane empirycznie w F22.0 (patrz PLAN.md, sekcja FALA 22):
//   - Nowa sesja: pierwsze wywołanie BEZ `--continue`/`--resume` — Hermes sam
//     tworzy sesję, `session_id` widoczny w stdout. Kolejne tury: `--resume <id>`
//     (NIE `--continue <nazwa>` — to wymaga już istniejącej nazwy/tytułu).
//   - Komenda bazowa: `hermes chat -q "<tekst>" -Q --provider ollama-launch
//     --accept-hooks` (+ `--resume <id>` gdy kontynuacja, + `-m <model>` gdy
//     user wybrał konkretny, + `--image <ścieżka>` dla załącznika).
//   - `--provider ollama-launch` jest OBOWIĄZKOWY zawsze — bez tego Hermes
//     Desktop / `ollama launch` może przepisać `~/.hermes/config.yaml` na
//     `provider: anthropic` (płatne API zamiast Ollama) — realny incydent
//     2026-07-08 (13,9M tokenów przez zły provider).
//   - Format stdout: brak prawdziwych kolorów ANSI. Jest ramka Unicode
//     `┌─ Reasoning ──┐` (redrawowana przez `\r`, ignorować całość), potem
//     zawsze linia `session_id: <id>`, a PO NIEJ czysta finalna odpowiedź do
//     końca stdout. Reguła parsowania: regex `session_id:\s*(\S+)` — znajdź
//     OSTATNIE wystąpienie, wyciągnij id, odpowiedź = wszystko po tej linii
//     (trim). Nie trzeba osobno stripować ANSI/`\r`/box.
//   - Błędy: exit code 1, czytelny jednolinijkowy komunikat na stdout, brak
//     zawieszenia. Binarka: `~/.local/bin/hermes` (realny plik:
//     `~/.hermes/hermes-agent/venv/bin/hermes`).
//   - Timing: proste zapytanie ~3s (narzut startu venv), tury z narzędziami
//     mogą trwać MINUTY → min. 5 minut timeout.

/// Pure transport layer for headless `hermes chat` CLI. No UI, no observable
/// state — mirrors `ClaudeCodeService`'s shape, but request/response instead
/// of streaming (Hermes emits one blob at process end, not NDJSON deltas).
struct HermesChatService: Sendable {

    // MARK: Wire types

    /// Cleaned-up result of one `hermes chat` turn.
    struct HermesResponse: Sendable {
        /// Finalna odpowiedź, już bez ramki Reasoning i stopki `session_id:`.
        let text: String
        /// Session id do przekazania jako `--resume` w kolejnej turze tej
        /// samej rozmowy. Zawsze obecny gdy proces zakończył się sukcesem.
        let sessionID: String
    }

    enum ServiceError: LocalizedError {
        case binaryNotFound
        case processFailed(String)
        case timedOut
        case unparsableOutput(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                "Hermes nie jest zainstalowany. Zainstaluj: `ollama launch hermes` (pierwsze uruchomienie zainstaluje binarkę) albo sprawdź `~/.local/bin/hermes`."
            case .processFailed(let message):
                if message.lowercased().contains("anthropic") || message.contains("400") {
                    // F22.4: wymuszony --provider ollama-launch powinien temu zapobiec —
                    // jeśli mimo to wystąpi, pokazujemy surowy komunikat obok, żeby dało
                    // się zdiagnozować (defensywnie, patrz pułapka 2 w PLAN.md).
                    "⚠️ Hermes ma ustawionego płatnego providera (Anthropic) zamiast Ollama — sprawdź `~/.hermes/config.yaml` (`provider: ollama-launch`) albo uruchom `hermes model` żeby to naprawić.\n\nSzczegóły: \(message)"
                } else {
                    message.isEmpty ? "Proces `hermes` zakończył się błędem." : "Hermes zwrócił błąd: \(message)"
                }
            case .timedOut:
                "Hermes nie odpowiedział w ciągu 5 minut — przerwano."
            case .unparsableOutput(let raw):
                "Nie udało się rozpoznać odpowiedzi Hermesa (brak `session_id:` w outpucie): \(raw)"
            }
        }
    }

    // MARK: - Binary detection (F17 pattern, adapted for `hermes`)

    /// Tries to locate the `hermes` binary. First asks a login shell so
    /// .zshrc/.zprofile PATH is respected, then falls back to a short list of
    /// known absolute paths — needed because an app launched from the Dock
    /// does not always inherit the user's shell PATH.
    static func detectBinaryPath() async -> String? {
        let shellPath = await detectBinaryPathViaLoginShell()
        if let shellPath, FileManager.default.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        return knownHermesPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static let knownHermesPaths: [String] = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            "\(home)/.local/bin/hermes",
            "\(home)/.hermes/hermes-agent/venv/bin/hermes",
        ]
    }()

    private static func detectBinaryPathViaLoginShell() async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "which hermes"]
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

    /// Synchronous resolver used by `send` (which builds the process
    /// off the calling thread inside a continuation, mirrors ClaudeCodeService).
    private static func resolvedBinaryPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "which hermes"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0, let path, !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // fall through to known paths
        }
        return knownHermesPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Minimum timeout before `Process.terminate()` is called on a stuck
    /// turn — tool-using turns can legitimately take minutes (F22 pułapka 5).
    static let timeout: TimeInterval = 300

    /// Parses the picker's `"hermes:llama3.2"` id into the underlying Ollama
    /// model name, or `nil` if `id` doesn't have the `hermes:` prefix.
    /// Mirrors `ClaudeCodeService.parseModelID`.
    static func parseModelID(_ id: String) -> String? {
        guard id.hasPrefix("hermes:") else { return nil }
        let name = String(id.dropFirst("hermes:".count))
        return name.isEmpty ? nil : name
    }

    // MARK: - Request/response

    /// Sends one message through `hermes chat`, optionally resuming a prior
    /// session (`--resume <id>`) for conversation continuity.
    ///
    /// `message` is passed as a `Process.arguments` element — NOT interpolated
    /// into a shell string — so no escaping is needed and command injection
    /// via pasted user text is impossible by construction. The outer `zsh -l`
    /// wrapper (binary resolution only) never sees the message text.
    ///
    /// Fala 22 (F22.2): wrapped in `withTaskCancellationHandler` so the STOP
    /// button (which calls `Task.cancel()` on the caller's `streamTask`) reaches
    /// the underlying `Process` — plain `withCheckedThrowingContinuation` never
    /// observes cancellation on its own, and without this the CLI would keep
    /// running in the background for up to 5 minutes after STOP.
    func send(
        message: String,
        sessionID: String? = nil,
        model: String? = nil,
        imagePath: String? = nil
    ) async throws -> HermesResponse {
        guard let hermesPath = Self.resolvedBinaryPath() else {
            throw ServiceError.binaryNotFound
        }

        var arguments = [
            "chat",
            "-q", message,
            "-Q",
            "--provider", "ollama-launch",
            "--accept-hooks",
        ]
        if let sessionID, !sessionID.isEmpty {
            arguments += ["--resume", sessionID]
        }
        if let model, !model.isEmpty {
            arguments += ["-m", model]
        }
        if let imagePath, !imagePath.isEmpty {
            arguments += ["--image", imagePath]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hermesPath)
        process.arguments = arguments

        // Set once (from `onCancel`) so the termination handler can tell a
        // user-requested STOP apart from a genuine process failure.
        let wasCancelled = LockedFlag()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                // Guards against double-resume of the continuation: process
                // termination and the timeout watchdog race each other.
                let resumed = LockedFlag()

                let timeoutWorkItem = DispatchWorkItem {
                    guard resumed.trySet() else { return }
                    if process.isRunning {
                        process.terminate()
                    }
                    continuation.resume(throwing: ServiceError.timedOut)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timeoutWorkItem)

                process.terminationHandler = { proc in
                    timeoutWorkItem.cancel()
                    guard resumed.trySet() else { return }

                    if wasCancelled.isSet {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let out = String(data: outData, encoding: .utf8) ?? ""
                    let err = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if proc.terminationStatus != 0 {
                        let combined = [out.trimmingCharacters(in: .whitespacesAndNewlines), err]
                            .filter { !$0.isEmpty }
                            .joined(separator: "\n")
                        continuation.resume(throwing: ServiceError.processFailed(combined))
                        return
                    }

                    switch Self.parseResponse(out) {
                    case .success(let response):
                        continuation.resume(returning: response)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                do {
                    try process.run()
                } catch {
                    timeoutWorkItem.cancel()
                    if resumed.trySet() {
                        continuation.resume(throwing: ServiceError.binaryNotFound)
                    }
                }
            }
        }, onCancel: {
            wasCancelled.trySet()
            if process.isRunning {
                process.terminate()
            }
        })
    }

    /// Parses raw stdout: finds the LAST `session_id: <id>` occurrence and
    /// treats everything after that line as the final answer. Everything
    /// before it (Reasoning box redrawn via `\r`, optional "Resumed session"
    /// header) is discarded wholesale — verified empirically in F22.0, no
    /// separate ANSI/`\r` stripping needed.
    private static func parseResponse(_ raw: String) -> Result<HermesResponse, ServiceError> {
        let pattern = #"session_id:\s*(\S+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return .failure(.unparsableOutput(raw))
        }
        let nsRange = NSRange(raw.startIndex..., in: raw)
        let matches = regex.matches(in: raw, options: [], range: nsRange)
        guard let lastMatch = matches.last,
              let idRange = Range(lastMatch.range(at: 1), in: raw),
              let fullLineRange = Range(lastMatch.range(at: 0), in: raw)
        else {
            return .failure(.unparsableOutput(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        let sessionID = String(raw[idRange])
        let answer = String(raw[fullLineRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sessionID.isEmpty else {
            return .failure(.unparsableOutput(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(HermesResponse(text: answer, sessionID: sessionID))
    }
}

// MARK: - LockedFlag

/// Ensures a continuation is resumed exactly once when two async paths
/// (process termination vs. timeout watchdog) race to complete it.
private final class LockedFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// Returns `true` the first time it's called (caller may proceed to
    /// resume the continuation), `false` on every subsequent call.
    @discardableResult
    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }

    /// Read-only check, used by the termination handler to tell a
    /// user-requested cancel apart from a genuine process failure without
    /// consuming the one-shot semantics of `trySet()`.
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
