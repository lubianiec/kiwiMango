import Foundation

// MARK: - OllamaService

/// Pure transport layer for the local Ollama HTTP API. No UI, no observable state.
///
/// - Host: `UserDefaults "ollamaHost"`, default `http://localhost:11434`.
/// - Streaming: `POST /api/chat` with `stream: true` → NDJSON, one JSON object per line.
/// - Models:    `GET /api/tags` → names + capabilities.
struct OllamaService: Sendable {

    // MARK: Config

    /// Base URL string, e.g. `http://localhost:11434`.
    let host: String

    init(host: String? = nil) {
        self.host = host
            ?? UserDefaults.standard.string(forKey: "ollamaHost")
            ?? "http://localhost:11434"
    }

    /// Host without scheme, for human-readable error messages ("localhost:11434").
    var displayHost: String {
        host
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    // MARK: Public wire types

    /// One message in the `/api/chat` payload. `images` = base64-encoded JPEG/PNG bytes.
    struct ChatPayloadMessage: Encodable, Sendable {
        let role: String
        let content: String
        var images: [String]?

        init(role: String, content: String, images: [String]? = nil) {
            self.role = role
            self.content = content
            self.images = images
        }
    }

    /// Model entry from `/api/tags`.
    struct ModelInfo: Sendable {
        let name: String
        let capabilities: [String]
        /// Size on disk in bytes, as reported by Ollama.
        let size: Int64
        /// Proxied through the local `ollama serve` to ollama.com (an Ollama Pro
        /// account) rather than run on-device — true iff `/api/tags` reported a
        /// `remote_host` for this entry. Verified against live output: this is the
        /// reliable signal, NOT the `:cloud` name suffix (e.g. "gemma4:31b-cloud"
        /// is cloud but the suffix is "-cloud", not ":cloud").
        let isCloud: Bool

        /// Thinking-capable models need `"think": false`, otherwise the answer
        /// streams into a `thinking` field and the UI looks hung.
        var supportsThinking: Bool { capabilities.contains("thinking") }
    }

    /// Generation stats reported on the final chunk (`done: true`) of a chat stream.
    struct ChatStats: Sendable {
        let evalCount: Int
        let evalDurationNs: Int64
        let promptEvalCount: Int

        var tokensPerSecond: Double {
            guard evalDurationNs > 0 else { return 0 }
            return Double(evalCount) / (Double(evalDurationNs) / 1_000_000_000)
        }
    }

    /// One unit of a streamed chat response — either an answer fragment or, on the
    /// final chunk, the generation stats. Kept separate from plain `String` deltas
    /// so the UI can distinguish "more text" from "stream finished, here are the numbers".
    enum ChatDelta: Sendable {
        case content(String)
        case stats(ChatStats)
    }

    enum OllamaError: LocalizedError {
        case badURL(String)
        case http(Int, String)
        case server(String)

        var errorDescription: String? {
            switch self {
            case .badURL(let host):
                "Nieprawidłowy adres hosta Ollama: \(host)"
            case .http(let code, let body):
                body.isEmpty ? "Ollama zwróciła HTTP \(code)." : "Ollama HTTP \(code): \(body)"
            case .server(let message):
                message
            }
        }
    }

    // MARK: - Chat (streaming)

    /// `POST /api/chat` with `stream: true`. Yields `message.content` deltas as they
    /// arrive; finishes on `done: true`. Cancelling the consuming task cancels the request.
    ///
    /// - Parameter think: pass `false` for thinking-capable models so tokens arrive in
    ///   `content` immediately; pass `nil` to omit the field entirely.
    func streamChat(
        model: String,
        messages: [ChatPayloadMessage],
        think: Bool? = nil,
        temperature: Double? = nil,
        isLocal: Bool = false
    ) -> AsyncThrowingStream<ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: try endpoint("/api/chat"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    // The streaming body has no overall deadline; this is only the max
                    // idle gap between chunks — generous, so a cold model load does not
                    // trip it. A dead localhost still fails instantly (conn. refused).
                    request.timeoutInterval = 300
                    // F21.1/F21.2: local models only — cloud models manage their own
                    // lifetime/context, sending these would be meaningless noise.
                    // keep_alive: 30m keeps the model resident so a message after an
                    // idle gap doesn't pay a cold-load penalty (~tens of seconds).
                    // num_ctx: 8192 avoids Ollama's smaller default context silently
                    // truncating and "dumbing down" long local conversations — 8192
                    // fits a Gemma e4b's KV cache comfortably in 16GB RAM; do not
                    // raise this without checking RAM headroom first.
                    let options: ChatOptions? = (temperature != nil || isLocal)
                        ? ChatOptions(temperature: temperature, numCtx: isLocal ? 8192 : nil)
                        : nil
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(
                            model: model, messages: messages, stream: true, think: think,
                            options: options, keepAlive: isLocal ? "30m" : nil
                        )
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw OllamaError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let chunk = try? JSONDecoder()
                            .decode(ChatChunk.self, from: Data(line.utf8)) else { continue }

                        if let error = chunk.error {
                            throw OllamaError.server(error)
                        }
                        // `message.thinking` deltas are intentionally dropped — only the
                        // actual answer is surfaced.
                        if let content = chunk.message?.content, !content.isEmpty {
                            continuation.yield(.content(content))
                        }
                        if chunk.done == true {
                            if let evalCount = chunk.evalCount,
                               let evalDuration = chunk.evalDuration {
                                continuation.yield(.stats(ChatStats(
                                    evalCount: evalCount,
                                    evalDurationNs: evalDuration,
                                    promptEvalCount: chunk.promptEvalCount ?? 0
                                )))
                            }
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pull (Fala 10)

    /// One line of `/api/pull`'s NDJSON progress stream.
    struct PullProgress: Sendable {
        let status: String
        let completed: Int64
        let total: Int64
    }

    /// `POST /api/pull` — works for both `ollama.com` registry names and
    /// `hf.co/{author}/{repo}:{quant}` HuggingFace references; same endpoint,
    /// same NDJSON shape either way. Cancelling the consuming task cancels the
    /// request — Ollama resumes a half-finished blob on the next pull attempt.
    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: try endpoint("/api/pull"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.timeoutInterval = 600
                    request.httpBody = try JSONEncoder().encode(PullRequest(model: model, stream: true))

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw OllamaError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
                    }

                    for try await line in bytes.lines {
                        guard !line.isEmpty else { continue }
                        guard let chunk = try? JSONDecoder().decode(PullChunk.self, from: Data(line.utf8)) else { continue }
                        if let error = chunk.error {
                            throw OllamaError.server(error)
                        }
                        continuation.yield(PullProgress(
                            status: chunk.status ?? "",
                            completed: chunk.completed ?? 0,
                            total: chunk.total ?? 0
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Web search (Fala 14)

    struct WebSearchResult: Decodable, Sendable {
        let title: String
        let url: String
        let content: String
    }

    struct WebFetchResult: Decodable, Sendable {
        let title: String?
        let content: String
    }

    /// Thrown when the user has web search toggled on but hasn't pasted a key
    /// yet — a distinct case so callers can show the Polish guidance message
    /// instead of a generic network error.
    struct MissingWebSearchKeyError: LocalizedError {
        var errorDescription: String? {
            "Brak klucza — ModelManager → WEB SEARCH"
        }
    }

    private var webSearchKey: String? {
        let key = UserDefaults.standard.string(forKey: "ollamaWebSearchKey") ?? ""
        return key.isEmpty ? nil : key
    }

    /// `POST https://ollama.com/api/web_search` — deliberately hits ollama.com
    /// directly, never the local `host`, both because the key must never reach
    /// `localhost` and because the local server (0.31.1) doesn't proxy this
    /// endpoint (verified: 404).
    func webSearch(query: String, maxResults: Int = 4) async throws -> [WebSearchResult] {
        guard let key = webSearchKey else { throw MissingWebSearchKeyError() }
        var request = URLRequest(url: URL(string: "https://ollama.com/api/web_search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(WebSearchRequest(query: query, maxResults: maxResults))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
        }
        let decoded = try JSONDecoder().decode(WebSearchResponse.self, from: data)
        // Trim each result's content in the client (F14.1 pitfall c) — keeps the
        // injected context block bounded regardless of what the API returns.
        return decoded.results.prefix(maxResults).map {
            WebSearchResult(title: $0.title, url: $0.url, content: String($0.content.prefix(2000)))
        }
    }

    /// `POST https://ollama.com/api/web_fetch` — fetch+summarize a single URL.
    func webFetch(url: String) async throws -> WebFetchResult {
        guard let key = webSearchKey else { throw MissingWebSearchKeyError() }
        var request = URLRequest(url: URL(string: "https://ollama.com/api/web_fetch")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONEncoder().encode(WebFetchRequest(url: url))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
        }
        let decoded = try JSONDecoder().decode(WebFetchResponse.self, from: data)
        return WebFetchResult(title: decoded.title, content: String(decoded.content.prefix(2000)))
    }

    // MARK: - Models

    /// `GET /api/tags` → model names (contract API).
    func listModels() async throws -> [String] {
        try await listModelsDetailed().map(\.name)
    }

    /// `GET /api/tags` → names + capabilities (used to decide `think: false`).
    func listModelsDetailed() async throws -> [ModelInfo] {
        var request = URLRequest(url: try endpoint("/api/tags"))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
        }
        let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
        return tags.models.map {
            ModelInfo(
                name: $0.name,
                capabilities: $0.capabilities ?? [],
                size: $0.size ?? 0,
                isCloud: $0.remoteHost != nil
            )
        }
    }

    /// Connectivity check for the status bar — GETs `/api/tags` and discards the
    /// body, timing only the round trip. Real measurement, not a fabricated number.
    func ping() async -> (online: Bool, latencyMs: Int) {
        let start = Date()
        do {
            var request = URLRequest(url: try endpoint("/api/tags"))
            request.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let online = (response as? HTTPURLResponse)?.statusCode == 200
            return (online, elapsedMs)
        } catch {
            return (false, Int(Date().timeIntervalSince(start) * 1000))
        }
    }

    /// `DELETE /api/delete` — permanently removes a model's blobs from disk.
    /// Verified against Ollama 0.31.1: the server accepts `{"model": name}`.
    func deleteModel(name: String) async throws {
        var request = URLRequest(url: try endpoint("/api/delete"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(DeleteRequest(model: name))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(code, Self.decodeErrorBody(body) ?? body)
        }
    }

    /// `POST /api/show` → context window size for `model`. The context length
    /// key is namespaced by architecture (`kimi-k2.context_length`,
    /// `qwen3.context_length`, ...), so read `general.architecture` first,
    /// then look up the matching key.
    // ponytail: JSONSerialization instead of Decodable — the context_length
    // key name varies per model family, which Codable can't express without
    // more boilerplate than this dict lookup.
    func contextLength(for model: String) async throws -> Int {
        var request = URLRequest(url: try endpoint("/api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(["model": model])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelInfo = json["model_info"] as? [String: Any],
              let arch = modelInfo["general.architecture"] as? String,
              let contextLength = modelInfo["\(arch).context_length"] as? Int
        else { throw OllamaError.server("context_length not found") }
        return contextLength
    }

    // MARK: - Helpers

    /// Raw image bytes (JPEG/PNG) → base64 string for the `images` field.
    static func base64(from imageData: Data) -> String {
        imageData.base64EncodedString()
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: host + path) else { throw OllamaError.badURL(host) }
        return url
    }

    private static func decodeErrorBody(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
        else { return nil }
        return parsed.error
    }

    // MARK: - Private wire format

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatPayloadMessage]
        let stream: Bool
        let think: Bool?   // synthesized Encodable omits the key when nil
        let options: ChatOptions?
        let keepAlive: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, think, options
            case keepAlive = "keep_alive"
        }
    }

    private struct ChatOptions: Encodable {
        let temperature: Double?
        let numCtx: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
        }
    }

    private struct ChatChunk: Decodable {
        struct Message: Decodable {
            let content: String?
            let thinking: String?
        }
        let message: Message?
        let done: Bool?
        let error: String?
        let evalCount: Int?
        let evalDuration: Int64?
        let promptEvalCount: Int?

        enum CodingKeys: String, CodingKey {
            case message, done, error
            case evalCount = "eval_count"
            case evalDuration = "eval_duration"
            case promptEvalCount = "prompt_eval_count"
        }
    }

    private struct TagsResponse: Decodable {
        struct Entry: Decodable {
            let name: String
            let capabilities: [String]?
            let size: Int64?
            /// Present only for models proxied to ollama.com — the reliable signal
            /// for `isCloud`. The `:cloud` name suffix is just a convention some
            /// tags follow (e.g. "gemma4:31b-cloud" doesn't) — verified against
            /// `/api/tags`, not safe to rely on alone.
            let remoteHost: String?

            enum CodingKeys: String, CodingKey {
                case name, capabilities, size
                case remoteHost = "remote_host"
            }
        }
        let models: [Entry]
    }

    private struct DeleteRequest: Encodable {
        let model: String
    }

    private struct PullRequest: Encodable {
        let model: String
        let stream: Bool
    }

    private struct PullChunk: Decodable {
        let status: String?
        let completed: Int64?
        let total: Int64?
        let error: String?
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    private struct WebSearchRequest: Encodable {
        let query: String
        let maxResults: Int

        enum CodingKeys: String, CodingKey {
            case query
            case maxResults = "max_results"
        }
    }

    private struct WebSearchResponse: Decodable {
        let results: [WebSearchResult]
    }

    private struct WebFetchRequest: Encodable {
        let url: String
    }

    private struct WebFetchResponse: Decodable {
        let title: String?
        let content: String
    }
}
