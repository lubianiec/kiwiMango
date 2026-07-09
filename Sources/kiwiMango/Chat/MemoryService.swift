import Foundation

// MARK: - MemoryService (F1)

/// Extracts concise, reusable facts from assistant replies using the same
/// local model pipeline as the chat. No new dependencies; small single file.
struct MemoryService {

    /// Extract facts worth remembering from an assistant message.
    /// - Parameter conversationId: used to back-link the fact to its origin.
    /// - Returns: one `MemoryFact` per extracted line; empty on failure.
    static func extractFacts(
        from assistantText: String,
        model: String,
        conversationId: Int64,
        scope: String = "global"
    ) async -> [MemoryFact] {
        guard UserDefaults.standard.bool(forKey: "kiwiMangoMemoryEnabled") else { return [] }
        guard !assistantText.isEmpty,
              !assistantText.hasPrefix("⚠️"),
              !assistantText.hasPrefix("⏹") else { return [] }

        // Limit input so extraction is fast even for long replies.
        let trimmed = String(assistantText.prefix(4000))

        let prompt = """
        Wydobądź z poniższej odpowiedzi asystenta WYŁĄCZNIE konkretne fakty, które warto zapamiętać na przyszłość (preferencje użytkownika, stałe ustawienia, wazne decyzje, kluczowe informacje o projekcie, hasła awaryjne, kody). Ignoruj: powitania, pytania, wyjaśnienia ogólne, cytaty z rozmowy, tymczasowe błędy.

        Zwróć wynik jako listę punktowaną, każdy fakt w osobnej linii, bez wstępu i bez podsumowania. Jeśli nie ma wartych zapamiętania faktów — zwróć pustą odpowiedź.

        Odpowiedź asystenta:
        \(trimmed)
        """

        let service = OllamaService()
        var reply = ""
        do {
            for try await delta in service.streamChat(
                model: model,
                messages: [OllamaService.ChatPayloadMessage(role: "user", content: prompt)],
                think: nil
            ) {
                if case .content(let text) = delta { reply += text }
            }
        } catch {
            print("[KiwiMango] Memory extraction failed: \(error)")
            return []
        }

        return parseFacts(reply, conversationId: conversationId, scope: scope)
    }

    /// Parses a bullet/exploded list into fact records.
    private static func parseFacts(_ raw: String, conversationId: Int64, scope: String) -> [MemoryFact] {
        raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                // Strip leading bullets / dashes / numbers.
                var cleaned = line
                for prefix in ["- ", "* ", "• ", "– ", "— "] {
                    if cleaned.hasPrefix(prefix) { cleaned.removeFirst(prefix.count); break }
                }
                if let match = cleaned.range(of: #"^\d+\.\s*"#, options: .regularExpression) {
                    cleaned.removeSubrange(match)
                }
                return cleaned.trimmingCharacters(in: .whitespaces)
            }
            .filter { $0.count >= 10 && !$0.lowercased().hasPrefix("nie ma") }
            .prefix(5)
            .map { MemoryFact(
                pendingContent: $0,
                scope: scope,
                sourceConversationId: conversationId
            ) }
    }
}
