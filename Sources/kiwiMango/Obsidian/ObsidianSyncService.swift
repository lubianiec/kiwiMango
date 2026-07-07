import Foundation

// MARK: - ObsidianSyncService (Fala 12)

/// Writes live notes for chats and agent sessions into Paweł's Obsidian vault.
/// Every note gets a TL;DR (or a placeholder waiting on one) — a raw transcript
/// dump with nothing else is "cmentarz notatek" per Paweł's vault protocol.
///
/// File writes happen off the main actor (`Task.detached`); the small amount of
/// DB access used here (`DatabaseManager`) is safe from any thread — GRDB's
/// `DatabaseQueue` serializes its own writes/reads internally.
enum ObsidianSyncService {

    // MARK: Settings (mirrors the `@AppStorage` keys used in `SettingsView`)

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "obsidianLiveSync") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "obsidianLiveSync") }
    }

    static var vaultPath: String {
        UserDefaults.standard.string(forKey: "obsidianVaultPath")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Kazik/ObsidianSync").path
    }

    static var categories: [String] {
        let raw = UserDefaults.standard.string(forKey: "obsidianCategories")
            ?? "projekty, hydraulika, obrazy, muzyka, kod, inne"
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static var vaultURL: URL { URL(fileURLWithPath: vaultPath) }
    private static var chatsFolder: URL { vaultURL.appendingPathComponent("AI/Czaty", isDirectory: true) }
    private static var agentsFolder: URL { vaultURL.appendingPathComponent("AI/Agenci", isDirectory: true) }

    /// Vault may not exist any more (new Mac, moved folder, …) — toggle disables
    /// itself rather than crashing or spamming errors on every message.
    private static func requireVault() -> Bool {
        guard FileManager.default.fileExists(atPath: vaultPath) else {
            isEnabled = false
            return false
        }
        return true
    }

    // MARK: - Chats (F12.2)

    /// Called after every completed (non-cancelled, non-error) assistant reply.
    /// Rewrites the whole note from scratch — simpler and more robust than
    /// appending, and cheap at chat-note sizes.
    static func syncConversation(conversationId: Int64, title: String, model: String) {
        guard isEnabled, requireVault() else { return }
        Task.detached(priority: .background) {
            do {
                let messages = try DatabaseManager.shared.fetchMessages(conversationId: conversationId)
                // Skip welcome-message noise — only real back-and-forth gets a note.
                guard messages.count >= 4 else { return }

                try? FileManager.default.createDirectory(at: chatsFolder, withIntermediateDirectories: true)

                var meta = try DatabaseManager.shared.fetchConversationObsidianMeta(conversationId)
                let fileURL: URL
                if let existing = meta.file {
                    fileURL = chatsFolder.appendingPathComponent(existing)
                } else {
                    let name = "\(slug(from: title)) \(shortID())"
                    fileURL = uniqueURL(in: chatsFolder, base: name)
                    try DatabaseManager.shared.setConversationObsidianFile(conversationId, file: fileURL.lastPathComponent)
                    meta.file = fileURL.lastPathComponent
                }

                // One-time classification, first time the note is written for real.
                if meta.category == nil, let localModel = await pickLocalModel() {
                    let sample = messages.prefix(4).map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                    if let category = await classify(text: sample, using: localModel) {
                        try? DatabaseManager.shared.setConversationCategory(conversationId, category: category)
                        meta.category = category
                    }
                }

                let existingTLDR = extractTLDR(fromFileAt: fileURL)
                let markdown = chatMarkdown(
                    title: title, model: model, category: meta.category ?? "inne",
                    messages: messages, tldr: existingTLDR
                )
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("[ObsidianSyncService] chat sync failed: \(error)")
            }
        }
    }

    /// F12.4: triggered when leaving a conversation (switch/close) — fills in
    /// the TL;DR section if it's still the placeholder. Never overwrites a
    /// TL;DR that's already there (might be hand-edited by Paweł).
    static func generateTLDRIfNeeded(conversationId: Int64, title: String, model: String) {
        guard isEnabled, requireVault() else { return }
        Task.detached(priority: .background) {
            do {
                let messages = try DatabaseManager.shared.fetchMessages(conversationId: conversationId)
                guard messages.count >= 4 else { return }
                let meta = try DatabaseManager.shared.fetchConversationObsidianMeta(conversationId)
                guard let fileName = meta.file else { return }
                let fileURL = chatsFolder.appendingPathComponent(fileName)
                guard let existing = extractTLDR(fromFileAt: fileURL), isPlaceholder(existing) else { return }
                guard let localModel = await pickLocalModel() else { return }

                let transcript = messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
                guard let tldr = await summarize(text: transcript, using: localModel) else { return }

                let markdown = chatMarkdown(
                    title: title, model: model, category: meta.category ?? "inne",
                    messages: messages, tldr: tldr
                )
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("[ObsidianSyncService] TL;DR generation failed: \(error)")
            }
        }
    }

    private static func chatMarkdown(
        title: String, model: String, category: String, messages: [StoredMessage], tldr: String?
    ) -> String {
        let iso = ISO8601DateFormatter().string(from: Date())
        var markdown = """
        ---
        typ: czat
        data: \(iso)
        model: \(model)
        tagi: [ai/czat, \(category)]
        ---
        # \(title)

        ## TL;DR
        \(tldr ?? placeholderTLDR)

        ## Transkrypt

        """
        for message in messages {
            let speaker = message.role == "user" ? "Paweł" : "kiwiMango (\(model))"
            let content = message.content.isEmpty ? "_[załączony obraz]_" : message.content
            markdown += "**\(speaker):** \(content)\n\n"
        }
        return markdown
    }

    // MARK: - Agent sessions (F12.3)

    /// One-shot: written once at session end (`markFinished`/`close`/`killAll`),
    /// never rewritten — unlike chat notes there's no "later turn" to react to.
    static func syncAgentSession(
        kind: String, model: String, isCloud: Bool, workDir: String,
        startedAt: Date, endedAt: Date, transcript: String
    ) {
        guard isEnabled, requireVault() else { return }
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: agentsFolder, withIntermediateDirectories: true)

            let folderName = URL(fileURLWithPath: workDir).lastPathComponent
            let category = categoryForFolder(folderName)
            let name = "\(kind) \(folderName) \(shortID())"
            let fileURL = uniqueURL(in: agentsFolder, base: name)

            var tldr = placeholderTLDR
            // Last 80 lines only — the full transcript can be thousands of lines,
            // too much for a local model to summarize usefully (F12.4 pt. 3).
            let tailLines = transcript.split(separator: "\n", omittingEmptySubsequences: false).suffix(80)
            if let localModel = await pickLocalModel(),
               let summary = await summarize(text: tailLines.joined(separator: "\n"), using: localModel) {
                tldr = summary
            }

            let minutes = max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))
            let iso = ISO8601DateFormatter().string(from: endedAt)
            let markdown = """
            ---
            typ: agent
            agent: \(kind.uppercased())
            model: \(model)
            katalog: \(workDir)
            czas: \(minutes) min
            data: \(iso)
            tagi: [ai/agent, \(category)]
            ---
            # \(kind.uppercased()) · \(folderName)

            ## TL;DR
            \(tldr)

            ## Transkrypt terminala

            ```
            \(transcript)
            ```
            """
            do {
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                print("[ObsidianSyncService] agent session sync failed: \(error)")
            }
        }
    }

    private static func categoryForFolder(_ folder: String) -> String {
        let known = ["kiwiMango": "kod", "FotoSpis": "kod", "PromptAlmanach2": "kod"]
        return known[folder] ?? (categories.contains("kod") ? "kod" : "inne")
    }

    // MARK: - Local model helpers

    /// Picks a non-cloud model for classification/TL;DR — zero API cost, and
    /// these are low-stakes background tasks that don't need a frontier model.
    /// Returns nil (skip, try again next trigger) if Ollama is offline or only
    /// cloud models are installed — a cheap `/api/tags` call, safe off the
    /// main actor since this runs detached from any particular chat session.
    private static func pickLocalModel() async -> String? {
        guard let models = try? await OllamaService().listModelsDetailed() else { return nil }
        return models.first { !$0.isCloud }?.name
    }

    private static func classify(text: String, using model: String) async -> String? {
        let prompt = """
        Przypisz rozmowie JEDNĄ kategorię z listy: \(categories.joined(separator: ", ")). \
        Odpowiedz samym słowem.

        \(text.prefix(2000))
        """
        guard let reply = await runLocalPrompt(prompt, model: model) else { return nil }
        let word = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .components(separatedBy: .whitespacesAndNewlines).first ?? ""
        return categories.contains(word) ? word : "inne"
    }

    private static func summarize(text: String, using model: String) async -> String? {
        let prompt = """
        Podsumuj poniższą rozmowę/sesję w 2-3 punktach po polsku. Jeśli padły zadania do zrobienia, \
        dodaj sekcję "ACTION ITEMS" z checkboxami markdown. Zwięźle, bez wstępu.

        \(text.prefix(4000))
        """
        return await runLocalPrompt(prompt, model: model)
    }

    private static func runLocalPrompt(_ prompt: String, model: String) async -> String? {
        let service = OllamaService()
        var result = ""
        do {
            for try await delta in service.streamChat(
                model: model,
                messages: [OllamaService.ChatPayloadMessage(role: "user", content: prompt)],
                think: false
            ) {
                if case .content(let text) = delta { result += text }
            }
        } catch {
            return nil
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - File helpers

    private static let placeholderTLDR = "_(uzupełniane przez F12.4)_"

    private static func isPlaceholder(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == placeholderTLDR
    }

    /// Pulls the current `## TL;DR` section out of an existing note (so a
    /// rewrite doesn't clobber a TL;DR that was already generated — or one
    /// Paweł hand-edited).
    private static func extractTLDR(fromFileAt url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard let range = content.range(of: "## TL;DR\n") else { return nil }
        let afterHeading = content[range.upperBound...]
        let section = afterHeading.components(separatedBy: "\n## ").first ?? String(afterHeading)
        return section.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ASCII-only, hyphenated slug — same convention as `ChatState.slug(from:)`.
    private static func slug(from title: String) -> String {
        let folded = title.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "pl_PL"))
        let dashed = String(folded.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        var collapsed = dashed
        while collapsed.contains("--") { collapsed = collapsed.replacingOccurrences(of: "--", with: "-") }
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 6-char id suffix — guarantees a stable, unique filename even if the
    /// conversation gets renamed later (F12.1 pt. 3).
    private static func shortID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
    }

    private static func uniqueURL(in dir: URL, base: String) -> URL {
        var url = dir.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base)-\(counter).md")
            counter += 1
        }
        return url
    }
}
