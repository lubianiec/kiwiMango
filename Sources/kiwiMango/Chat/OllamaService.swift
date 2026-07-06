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
        temperature: Double? = nil
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
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(
                            model: model, messages: messages, stream: true, think: think,
                            options: temperature.map { ChatOptions(temperature: $0) }
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
    }

    private struct ChatOptions: Encodable {
        let temperature: Double
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

    private struct ErrorBody: Decodable {
        let error: String
    }
}
