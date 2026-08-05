import Foundation

// MARK: - OllamaAccountClient

/// Read-only client for the local Ollama account/model state, feeding the Dashboard's
/// hero status and "ILE/ZA ILE" panels.
///
/// Distinct from `Chat/OllamaService` (the chat transport): this only ever does three
/// cheap read endpoints with a short timeout and **never throws** — every call returns
/// `nil`/`[]` on any failure (offline daemon, bad JSON, timeout) so the dashboard can
/// render "offline" instead of crashing or surfacing an error to the UI.
struct OllamaAccountClient: Sendable {

    /// ponytail: reuses `OllamaService`'s host resolution (same `UserDefaults
    /// "ollamaHost"` key + `http://localhost:11434` default) by delegating to it
    /// instead of re-reading UserDefaults here — one source of truth for the host.
    private let service = OllamaService()

    // MARK: Public types

    /// `POST /api/me` response (name/email/plan) — the fields the dashboard needs.
    /// The live response also carries `id`/`avatarurl`; ignored, not decoded.
    struct Account: Sendable {
        let name: String
        let email: String
        let plan: String
    }

    /// One entry from `/api/tags`. `remoteModel` is the upstream name ollama.com uses
    /// for a cloud model (e.g. local name `"kimi-k2.7-code:cloud"` → remote model
    /// `"kimi-k2.7-code"`). Verified live: not every `:cloud`-suffixed name is
    /// consistent (e.g. `"gemma4:31b-cloud"`), so token-usage lookups elsewhere must
    /// match on both `name` and `remoteModel` — see `matches(_:)` and PLAN-DASHBOARD.md
    /// pitfall #9.
    struct ModelEntry: Sendable {
        let name: String
        let remoteModel: String?
        /// True iff `/api/tags` reported a `remote_host` for this entry — the
        /// reliable cloud signal (same rule as `OllamaService.ModelInfo.isCloud`).
        let isCloud: Bool

        /// True if `key` names this model, whether the caller has the local
        /// `:cloud`-suffixed name or the bare remote model name.
        func matches(_ key: String) -> Bool {
            key == name || key == remoteModel
        }
    }

    /// One entry from `/api/ps` — a model currently loaded in memory/VRAM.
    struct LoadedModel: Sendable {
        let name: String
    }

    // MARK: Public API

    /// `POST /api/me` (GET returns 405 — verified live). `nil` on any failure,
    /// including Ollama being offline.
    func account() async -> Account? {
        guard let data = await fetch("/api/me", method: "POST") else { return nil }
        return try? JSONDecoder().decode(AccountResponse.self, from: data).account
    }

    /// `GET /api/tags`. Empty array on any failure — same graceful-degradation
    /// contract as `account()`.
    func models() async -> [ModelEntry] {
        guard let data = await fetch("/api/tags", method: "GET"),
              let tags = try? JSONDecoder().decode(TagsResponse.self, from: data)
        else { return [] }
        return tags.models.map {
            ModelEntry(name: $0.name, remoteModel: $0.remoteModel, isCloud: $0.remoteHost != nil)
        }
    }

    /// `GET /api/ps`. Empty array on any failure.
    func loadedModels() async -> [LoadedModel] {
        guard let data = await fetch("/api/ps", method: "GET"),
              let ps = try? JSONDecoder().decode(PsResponse.self, from: data)
        else { return [] }
        return ps.models.map { LoadedModel(name: $0.name) }
    }

    // MARK: - Transport

    /// 3 s timeout (PLAN-DASHBOARD.md pitfall #2) — swallows every error into `nil`
    /// so callers never need a `do/catch` for "Ollama isn't running".
    private func fetch(_ path: String, method: String) async -> Data? {
        guard let url = URL(string: service.host + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    // MARK: - Wire format

    private struct AccountResponse: Decodable {
        let name: String
        let email: String
        let plan: String

        var account: Account { Account(name: name, email: email, plan: plan) }
    }

    private struct TagsResponse: Decodable {
        struct Entry: Decodable {
            let name: String
            let remoteModel: String?
            let remoteHost: String?

            enum CodingKeys: String, CodingKey {
                case name
                case remoteModel = "remote_model"
                case remoteHost = "remote_host"
            }
        }
        let models: [Entry]
    }

    private struct PsResponse: Decodable {
        struct Entry: Decodable {
            let name: String
        }
        let models: [Entry]
    }
}
