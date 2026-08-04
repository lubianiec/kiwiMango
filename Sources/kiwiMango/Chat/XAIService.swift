import Foundation

// MARK: - XAIService
//
// Pure transport layer for the xAI (Grok) chat completions API, mirroring
// OllamaService's shape so ChatSessionController can treat it as a third
// backend. No protocol abstraction (ponytail: only two backends existed
// before this, a third is still a switch, not a hierarchy).
struct XAIService: Sendable {

    enum XAIError: LocalizedError {
        case http(Int, String)
        case proxyUnreachable

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                body.isEmpty ? "xAI zwróciła HTTP \(code)." : "xAI HTTP \(code): \(body)"
            case .proxyUnreachable:
                "Grok wymaga proxy Hermesa — uruchom w terminalu: hermes proxy start --provider xai"
            }
        }
    }

    // ponytail: hardcoded, no /v1/models discovery in v1.
    static let models = ["grok-4.5"]

    // Auth = SuperGrok OAuth, held by the local `hermes proxy` process, not this
    // app — the Bearer value is a placeholder the proxy swaps for the real
    // token. No UserDefaults key, no MissingKeyError.
    private static let baseURL = "http://127.0.0.1:8645/v1"

    /// `POST http://127.0.0.1:8645/v1/chat/completions` with `stream: true` → SSE.
    /// Yields text deltas as they arrive; yields stats once, from the final
    /// chunk that carries `usage` (its `choices` is empty — must not be
    /// treated as end of stream).
    func streamChat(
        model: String,
        messages: [OllamaService.ChatPayloadMessage]
    ) -> AsyncThrowingStream<OllamaService.ChatDelta, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "\(Self.baseURL)/chat/completions")!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer kiwimango", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 300
                    request.httpBody = try JSONEncoder().encode(ChatRequest(
                        model: model,
                        messages: messages.map { WireMessage(role: $0.role, content: $0.content) },
                        stream: true,
                        streamOptions: StreamOptions(includeUsage: true)
                    ))

                    let start = Date()
                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    } catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut].contains(error.code) {
                        throw XAIError.proxyUnreachable
                    }

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines {
                            body += line
                            if body.count > 500 { break }
                        }
                        throw XAIError.http(http.statusCode, Self.decodeErrorBody(body) ?? body)
                    }

                    for try await line in bytes.lines {
                        guard let delta = Self.parseSSELine(line) else { continue }
                        switch delta {
                        case .done:
                            continuation.finish()
                            return
                        case .chunk(let chunk):
                            if let content = chunk.choices?.first?.delta.content, !content.isEmpty {
                                continuation.yield(.content(content))
                            }
                            if let usage = chunk.usage {
                                continuation.yield(.stats(OllamaService.ChatStats(
                                    evalCount: usage.completionTokens,
                                    evalDurationNs: Int64(Date().timeIntervalSince(start) * 1_000_000_000),
                                    promptEvalCount: usage.promptTokens
                                )))
                            }
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

    // MARK: - SSE parsing (pułapka 1: prefix "data: ", terminator "[DONE]", empty lines)

    enum SSEEvent {
        case chunk(StreamChunk)
        case done
    }

    /// Exposed at package-internal level for the self-check below.
    static func parseSSELine(_ line: String) -> SSEEvent? {
        guard line.hasPrefix("data: ") else { return nil }
        let payload = String(line.dropFirst(6))
        if payload == "[DONE]" { return .done }
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8)) else { return nil }
        return .chunk(chunk)
    }

    private static func decodeErrorBody(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
        else { return nil }
        return parsed.error?.message ?? parsed.message
    }

    // MARK: - Wire format

    private struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct StreamOptions: Encodable {
        let includeUsage: Bool
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let streamOptions: StreamOptions
        enum CodingKeys: String, CodingKey {
            case model, messages, stream
            case streamOptions = "stream_options"
        }
    }

    struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }
            let delta: Delta
        }
        struct Usage: Decodable {
            let completionTokens: Int
            let promptTokens: Int
            enum CodingKeys: String, CodingKey {
                case completionTokens = "completion_tokens"
                case promptTokens = "prompt_tokens"
            }
        }
        let choices: [Choice]?
        let usage: Usage?
    }

    private struct ErrorBody: Decodable {
        struct Nested: Decodable { let message: String? }
        let error: Nested?
        let message: String?
    }
}
