import Foundation

// MARK: - HermesGatewayClient
//
// Fala 24: pełny agent Hermes w czacie przez WebSocket gateway
// (`hermes serve`), zastępując F22's headless `hermes chat -q` — ten dawał
// tylko jeden blob tekstu na koniec, bez narzędzi/subagentów/approvali na
// żywo. `HermesChatService` (F22) ZOSTAJE jako plan B, nietknięty.
//
// Fakty zweryfikowane EMPIRYCZNIE w F24.0 (patrz PLAN.md, sekcja FALA 24):
//   - Komenda serwera: `hermes serve --port 0 --skip-build` (port 0 = auto-
//     assign przez OS — unika kolizji z portem 9119 używanym przez ewentualny
//     otwarty Hermes Desktop). Faktyczny port czytany ze stdout, linia
//     `HERMES_BACKEND_READY port=<N>`.
//   - AUTH JEST WYMAGANY nawet na 127.0.0.1: goły WS bez tokena = HTTP 403.
//     Token: env var `HERMES_DASHBOARD_SESSION_TOKEN` ustawiona PRZED startem
//     procesu (inaczej serwer losuje własny, nieznany nam z zewnątrz — nie
//     da się go odczytać z żadnego pliku). WS URL: `?token=<TOKEN>` jako
//     query param (jedyna droga dla WS handshake, nagłówek Authorization
//     niedostępny na upgrade).
//   - Konsekwencja: kiwiMango NIGDY nie dołącza się do cudzego już-działającego
//     serwera (np. Hermes Desktop) — zawsze spawnuje WŁASNY, z własnym
//     tokenem, na osobnym porcie. Terminate przy quicie appki
//     (patrz `HermesGatewayProcessBox` + `App.swift`).
//   - Protokół to pełny JSON-RPC 2.0, NIE płaskie ramki `{"type": ...}`:
//     wywołania klient→serwer: `{"jsonrpc":"2.0","id":N,"method":"...","params":{...}}`,
//     odpowiedzi: `{"jsonrpc":"2.0","id":N,"result":{...}}` lub `{"error":{code,message}}`.
//     Zdarzenia push (bez `id`): `{"jsonrpc":"2.0","method":"event","params":{"type":"...","session_id":"...","payload":{...}}}`.
//   - `session.create` params: `{model, provider, cols, cwd, ...}` — model +
//     provider ustawia się TU, bezpośrednio, per sesja (NIE osobną ramką
//     `model.default` po fakcie — pułapka #3 z F24.0 kontekstu). Odpowiedź
//     ma `result.session_id` (krótkie 8-hex) — TEGO id używać dalej, nie
//     `stored_session_id` (osobny, dłuższy klucz DB).
//   - `prompt.submit` params: `{session_id, text}`. Emituje `message.start` →
//     `thinking.delta`/`reasoning.delta` → `tool.start`/`tool.complete` →
//     `message.delta`×N → `message.complete` (payload: `text`, `usage`, `reasoning`).
//   - `tool.start` payload: `{tool_id, name, context}`. `tool.complete` payload:
//     `{tool_id, name, args:{command,...}, duration_s, result:{output, exit_code, error}}`.
//   - `approval.request` payload (zweryfikowane W ŹRÓDLE, `tools/approval.py`
//     ~linia 2540 — nie wywołane na żywo w F24.0/F24.2: konto testowe ma
//     "smart approval" które auto-czyści flagowane-ale-niegroźne komendy,
//     patrz notatka w PLAN.md): `{command, pattern_key, pattern_keys,
//     description, allow_permanent}`. Odpowiedź: `approval.respond`
//     params `{session_id, choice: "once"|"deny", all: Bool}` — UI daje
//     tylko ZATWIERDŹ (→"once")/ODRZUĆ (→"deny"), bez granularności
//     session/always (matches plan: dwa przyciski).
//   - `clarify.request` payload: `{question, choices}`. Odpowiedź:
//     `clarify.respond` params `{session_id, answer}` (lub `choice`, patrz
//     handler — nie zweryfikowane na żywo, przyjmujemy zgodnie z symetrią
//     do approval.respond).
//   - `image.attach_bytes` istnieje jako osobna metoda — payload w F24.4.
//   - Ignoruj nieznane typy eventów (protokół ma ~150 — pet.*, billing.*,
//     voice.* itd.) — dekoduj TYLKO listę w `Event` poniżej.

/// Pure transport + protocol layer. No UI state — `ChatState` (F24.2) owns
/// the observable side, mirroring how `ClaudeCodeService`/`HermesChatService`
/// are pure transports too.
actor HermesGatewayClient {

    // MARK: Errors

    enum ClientError: LocalizedError {
        case binaryNotFound
        case spawnFailed(String)
        case connectFailed(String)
        case rpcError(code: Int, message: String)
        case sessionMissing
        case disconnected

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                "Nie znaleziono binarki `hermes` na PATH."
            case .spawnFailed(let message):
                "Nie udało się uruchomić serwera Hermes: \(message)"
            case .connectFailed(let message):
                "Nie udało się połączyć z Hermes Gateway: \(message)"
            case .rpcError(_, let message):
                message.isEmpty ? "Hermes zgłosił błąd." : "Hermes: \(message)"
            case .sessionMissing:
                "Brak aktywnej sesji Hermes."
            case .disconnected:
                "Połączenie z Hermes Gateway zerwane."
            }
        }
    }

    // MARK: Events (Sendable, pre-decoded — see header comment for wire shapes)

    enum Event: Sendable {
        case ready
        case messageStart(sessionID: String)
        case messageDelta(sessionID: String, text: String)
        case thinkingDelta(sessionID: String, text: String)
        case toolStart(sessionID: String, toolID: String, name: String, context: String)
        case toolComplete(sessionID: String, toolID: String, name: String, output: String, exitCode: Int?, errorText: String?)
        case subagentStart(sessionID: String, id: String, description: String?)
        case subagentText(sessionID: String, id: String, text: String)
        case subagentComplete(sessionID: String, id: String)
        case approvalRequest(sessionID: String, command: String?, description: String?)
        case clarifyRequest(sessionID: String, question: String, choices: [String])
        case messageComplete(sessionID: String, text: String, reasoning: String?)
        case sessionTitle(sessionID: String, title: String)
        case turnError(sessionID: String?, message: String)
    }

    // MARK: State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var token: String = ""
    private var port: Int = 0
    private var nextRequestID = 1
    private var pendingCalls: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var eventContinuation: AsyncStream<Event>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private(set) var isConnected = false

    /// One shared instance for the app's lifetime — kiwiMango only ever runs
    /// one Hermes gateway chat surface at a time (mirrors `AgentManager`'s
    /// single-owner-of-processes philosophy).
    static let shared = HermesGatewayClient()

    /// Live event stream for the UI (`ChatState`) to consume. Multiple
    /// `for await` loops would only see events after they start listening —
    /// callers must start consuming before/immediately after `connect()`.
    private var _events: AsyncStream<Event>?

    func events() -> AsyncStream<Event> {
        if let existing = _events { return existing }
        let stream = AsyncStream<Event> { continuation in
            self.eventContinuation = continuation
        }
        _events = stream
        return stream
    }

    // MARK: - Binary discovery (mirrors ClaudeCodeService.resolvedBinaryPath)

    private static let knownHermesPaths: [String] = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return [
            "\(home)/.local/bin/hermes",
            "/opt/homebrew/bin/hermes",
            "/usr/local/bin/hermes",
        ]
    }()

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

    // MARK: - Connect (spawn own server + WS handshake)

    /// Spawns a dedicated `hermes serve` process (own token, own auto-assigned
    /// port — see header for why we never attach to a foreign server) and
    /// opens the authenticated WebSocket. No-op if already connected.
    func connectIfNeeded() async throws {
        if isConnected, webSocketTask != nil { return }

        guard let hermesPath = Self.resolvedBinaryPath() else {
            throw ClientError.binaryNotFound
        }

        let generatedToken = "kiwimango-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        token = generatedToken

        let resolvedPort = try await Self.spawnServer(hermesPath: hermesPath, token: generatedToken)
        port = resolvedPort

        guard let url = URL(string: "ws://127.0.0.1:\(resolvedPort)/api/ws?token=\(generatedToken)") else {
            throw ClientError.connectFailed("zły URL")
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        urlSession = session
        webSocketTask = task
        task.resume()
        isConnected = true

        startReceiveLoop(on: task)
    }

    /// Starts the process and blocks (off the actor) until it prints
    /// `HERMES_BACKEND_READY port=<N>` on stdout, or fails/times out.
    private static func spawnServer(hermesPath: String, token: String) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: hermesPath)
            process.arguments = ["serve", "--port", "0", "--skip-build"]
            var env = ProcessInfo.processInfo.environment
            env["HERMES_DASHBOARD_SESSION_TOKEN"] = token
            process.environment = env

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            let box = SpawnResultBox()

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                guard let chunk = String(data: data, encoding: .utf8) else { return }
                guard let portValue = box.appendAndExtractPort(chunk) else { return }
                HermesGatewayProcessBox.shared.set(process)
                if box.markResumed() {
                    continuation.resume(returning: portValue)
                }
            }

            process.terminationHandler = { proc in
                stdout.fileHandleForReading.readabilityHandler = nil
                if box.markResumed() {
                    continuation.resume(throwing: ClientError.spawnFailed("proces zakończył się (kod \(proc.terminationStatus)) zanim serwer wystartował"))
                }
            }

            do {
                try process.run()
            } catch {
                if box.markResumed() {
                    continuation.resume(throwing: ClientError.spawnFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            while true {
                guard let self else { return }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleIncoming(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleIncoming(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    await self.handleDisconnect(error)
                    return
                }
                if Task.isCancelled { return }
            }
        }
    }

    private func handleDisconnect(_ error: Error) {
        isConnected = false
        webSocketTask = nil
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: ClientError.disconnected)
        }
        pendingCalls.removeAll()
        eventContinuation?.yield(.turnError(sessionID: nil, message: "Połączenie z Hermes Gateway zerwane."))
    }

    private func handleIncoming(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let method = object["method"] as? String, method == "event" {
            guard let params = object["params"] as? [String: Any] else { return }
            if let event = Self.decodeEvent(params) {
                eventContinuation?.yield(event)
            }
            return
        }

        guard let id = object["id"] as? Int else { return }
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }

        if let result = object["result"] as? [String: Any] {
            continuation.resume(returning: result)
        } else if let errorObj = object["error"] as? [String: Any] {
            let code = errorObj["code"] as? Int ?? -1
            let message = errorObj["message"] as? String ?? ""
            continuation.resume(throwing: ClientError.rpcError(code: code, message: message))
        } else {
            continuation.resume(returning: [:])
        }
    }

    /// Decodes the ~15 event types kiwiMango's UI actually uses. Anything
    /// else (pet.*, billing.*, voice.*, …) returns `nil` and is dropped —
    /// deliberate per pułapka #6 (F24.0 kontekst).
    private static func decodeEvent(_ params: [String: Any]) -> Event? {
        guard let type = params["type"] as? String else { return nil }
        let sessionID = params["session_id"] as? String ?? ""
        let payload = params["payload"] as? [String: Any] ?? [:]

        switch type {
        case "gateway.ready":
            return .ready
        case "message.start":
            return .messageStart(sessionID: sessionID)
        case "message.delta":
            guard let text = payload["text"] as? String else { return nil }
            return .messageDelta(sessionID: sessionID, text: text)
        case "thinking.delta", "reasoning.delta":
            guard let text = payload["text"] as? String else { return nil }
            return .thinkingDelta(sessionID: sessionID, text: text)
        case "tool.start":
            let toolID = payload["tool_id"] as? String ?? ""
            let name = payload["name"] as? String ?? ""
            let context = payload["context"] as? String ?? ""
            return .toolStart(sessionID: sessionID, toolID: toolID, name: name, context: context)
        case "tool.complete":
            let toolID = payload["tool_id"] as? String ?? ""
            let name = payload["name"] as? String ?? ""
            let result = payload["result"] as? [String: Any] ?? [:]
            let output = result["output"] as? String ?? ""
            let exitCode = result["exit_code"] as? Int
            let errorText = result["error"] as? String
            return .toolComplete(sessionID: sessionID, toolID: toolID, name: name, output: output, exitCode: exitCode, errorText: errorText)
        case "subagent.start":
            let id = payload["id"] as? String ?? payload["subagent_id"] as? String ?? ""
            let description = payload["description"] as? String
            return .subagentStart(sessionID: sessionID, id: id, description: description)
        case "subagent.text":
            let id = payload["id"] as? String ?? payload["subagent_id"] as? String ?? ""
            let text = payload["text"] as? String ?? ""
            return .subagentText(sessionID: sessionID, id: id, text: text)
        case "subagent.complete":
            let id = payload["id"] as? String ?? payload["subagent_id"] as? String ?? ""
            return .subagentComplete(sessionID: sessionID, id: id)
        case "approval.request":
            let command = payload["command"] as? String
            let description = payload["description"] as? String
            return .approvalRequest(sessionID: sessionID, command: command, description: description)
        case "clarify.request":
            let question = payload["question"] as? String ?? ""
            let choices = payload["choices"] as? [String] ?? []
            return .clarifyRequest(sessionID: sessionID, question: question, choices: choices)
        case "message.complete":
            let text = payload["text"] as? String ?? ""
            let reasoning = payload["reasoning"] as? String
            return .messageComplete(sessionID: sessionID, text: text, reasoning: reasoning)
        case "session.title":
            let title = payload["title"] as? String ?? ""
            return .sessionTitle(sessionID: sessionID, title: title)
        case "error":
            let message = payload["message"] as? String ?? "nieznany błąd"
            return .turnError(sessionID: sessionID.isEmpty ? nil : sessionID, message: message)
        default:
            return nil
        }
    }

    // MARK: - RPC calls

    private func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard isConnected, let task = webSocketTask else { throw ClientError.disconnected }

        let id = nextRequestID
        nextRequestID += 1

        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else { throw ClientError.connectFailed("nie udało się zakodować żądania") }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[id] = continuation
            Task {
                do {
                    try await task.send(.string(text))
                } catch {
                    self.pendingCalls.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        }
    }

    /// Creates a session, returning the short 8-hex `session_id` to use in
    /// every subsequent call for this conversation.
    func createSession(model: String, provider: String, cwd: String?) async throws -> String {
        var params: [String: Any] = ["model": model, "provider": provider, "cols": 80]
        if let cwd { params["cwd"] = cwd }
        let result = try await call("session.create", params: params)
        guard let sessionID = result["session_id"] as? String else {
            throw ClientError.sessionMissing
        }
        return sessionID
    }

    /// Resumes a previously created session by its gateway `session_id`.
    /// Falls back to a fresh `createSession` if the resume fails (e.g. the
    /// server restarted and the in-memory session is gone) — resuming a
    /// dead id must never hard-fail a turn.
    func resumeOrCreateSession(existingSessionID: String?, model: String, provider: String, cwd: String?) async throws -> String {
        if let existingSessionID {
            do {
                let result = try await call("session.resume", params: ["session_id": existingSessionID])
                if let sessionID = result["session_id"] as? String {
                    return sessionID
                }
            } catch {
                // Fall through to a fresh session — see doc comment.
            }
        }
        return try await createSession(model: model, provider: provider, cwd: cwd)
    }

    func submitPrompt(sessionID: String, text: String) async throws {
        _ = try await call("prompt.submit", params: ["session_id": sessionID, "text": text])
    }

    /// `image.attach_bytes` — must be called BEFORE `submitPrompt` for the
    /// same turn (F24.4). `base64Data` is the raw image bytes, base64-encoded.
    func attachImageBytes(sessionID: String, base64Data: String, mimeType: String) async throws {
        _ = try await call("image.attach_bytes", params: [
            "session_id": sessionID,
            "data": base64Data,
            "mime_type": mimeType,
        ])
    }

    /// UI only offers ZATWIERDŹ/ODRZUĆ (no session/always granularity —
    /// matches the two-button plan). `approve` → server's "once" choice.
    func respondApproval(sessionID: String, approve: Bool) async throws {
        _ = try await call("approval.respond", params: [
            "session_id": sessionID,
            "choice": approve ? "once" : "deny",
            "all": false,
        ])
    }

    func respondClarify(sessionID: String, answer: String) async throws {
        _ = try await call("clarify.respond", params: ["session_id": sessionID, "answer": answer])
    }

    func interrupt(sessionID: String) async throws {
        _ = try await call("session.interrupt", params: ["session_id": sessionID])
    }

    // MARK: - Teardown

    /// Closes the socket and kills our spawned server. Called on app quit
    /// (via `HermesGatewayProcessBox`, synchronously) — this async path is
    /// for an explicit in-app "disconnect", not currently exposed in UI but
    /// kept for the reconnect-with-backoff flow (F24.1 test hook).
    func disconnect() {
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        urlSession?.invalidateAndCancel()
        urlSession = nil
        HermesGatewayProcessBox.shared.terminate()
    }
}

// MARK: - SpawnResultBox

/// Lock-owned mutable state for `spawnServer`'s readability/termination
/// handlers, which Swift 6 concurrency checking treats as running on
/// arbitrary (possibly concurrent) queues — a plain captured `var` would be
/// a data race. `@unchecked Sendable` is safe here because every access to
/// `buffer`/`resumed` goes through the lock.
private final class SpawnResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var resumed = false

    /// Appends a stdout chunk and returns the parsed port if the
    /// `HERMES_BACKEND_READY port=<N>` line has now appeared and we haven't
    /// already resolved. Does NOT mark resumed — caller does that after
    /// successfully calling `continuation.resume`.
    func appendAndExtractPort(_ chunk: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return nil }
        buffer += chunk
        guard let range = buffer.range(of: #"HERMES_BACKEND_READY port=(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let portString = buffer[range]
            .replacingOccurrences(of: "HERMES_BACKEND_READY port=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(portString)
    }

    /// Returns `true` (and flips the flag) only the first time it's called —
    /// guards against the readability handler and termination handler both
    /// trying to resume the same continuation.
    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}

// MARK: - HermesGatewayProcessBox

/// Holds the spawned `hermes serve` `Process` outside the actor so
/// `KiwiMangoAppDelegate.applicationShouldTerminate` (synchronous, no
/// `await`) can terminate it at quit — same hygiene as `AgentManager.killAll`
/// (PLAN.md F4 pitfall #3): no zombie processes left behind.
final class HermesGatewayProcessBox: @unchecked Sendable {
    static let shared = HermesGatewayProcessBox()
    private let lock = NSLock()
    private var process: Process?

    private init() {}

    func set(_ process: Process?) {
        lock.lock()
        defer { lock.unlock() }
        self.process = process
    }

    func terminate() {
        lock.lock()
        let current = process
        process = nil
        lock.unlock()
        if let current, current.isRunning {
            current.terminate()
        }
    }
}
