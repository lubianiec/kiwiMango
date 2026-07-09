# kiwiMango — kolejka wykonanych fal

Zawieszone / nieistotne na razie usunięte (backup w `~/Downloads/PLAN-KOLEJKA-NEXT-backup-2026-07-09.md`).

## Wykonane ✅

### F9 — Rozbudowane okno ustawień
- Sidebar z kategoriami: Ogólne, Czat, Ollama, Hermes, Agenci, Obsidian, Zaawansowane.
- Panel Hermes: edycja `~/.hermes/config.yaml` z walidacją YAML (Yams).
- Zamieniono systemowe `SettingsView` na pełne okno `SettingsWindow`.
- Commit: `ad0b5d4`.

### F1 — Auto-pamięć długoterminowa
- Tabela `memoryFact` w GRDB: `id, content, sourceConversationId, sourceSessionId, scope, createdAt, lastUsedAt, useCount`.
- Ekstrakcja faktów z każdej zakończonej odpowiedzi lokalnego modelu w tle.
- Retrieval TOP 5 global faktów wstrzykiwanych do nowej rozmowy jako system prompt.
- Toggle włącz/wyłącz w ustawieniach (panel Czat).
- Commit: `f24b119`.

## Zawieszone ⏸️

- F8 — macOS Shortcuts + Services (zawieszone 2026-07-09, backup planu zawiera opis).

---
> Ponytail full: przewietrzony plan. Dodajemy dalej tylko gdy faktycznie potrzebne.
