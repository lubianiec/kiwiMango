<div align="center">

# 🥝 kiwiMango 🥭

**Czaty z lokalnym AI i agenci Claude Code — w jednym natywnym oknie macOS.**

`Swift 6` · `SwiftUI` · `GRDB (SQLite)` · `SwiftTerm` · `macOS 26`

*Deep Cyberpunk / Neon Noir terminal UI — neonowa limonka i fiolet na prawie-czerni.*

</div>

---

## Czym jest kiwiMango

Natywny klient [Ollama](https://ollama.com) dla macOS — bez Electrona, bez przeglądarki, bez chmury pośrednika. Rozmowy z modelami lokalnymi i cloud, a obok nich pełnoprawne sesje **Claude Code** działające na modelach Ollama — we wbudowanym terminalu, wiele równolegle.

## Funkcje

### 💬 Czat
- Streaming odpowiedzi z pulsującym kursorem, statystyki **tok/s**
- Markdown + bloki kodu z przyciskiem „kopiuj"
- Załączanie obrazów do modeli vision (drag & drop, auto-konwersja HEIC→JPEG)
- Kopiuj / regeneruj odpowiedź, fork rozmowy, zmiana nazwy
- Historia w SQLite (GRDB) — wszystko na dysku, nic nie wycieka

### 🤖 Agenci
- Sesje **Claude Code** (`ollama launch claude`) we wbudowanym emulatorze terminala (SwiftTerm)
- Wybór dowolnego modelu z Ollamy — lokalnego lub cloud — i katalogu roboczego
- Wiele agentów równolegle; przełączanie czat ↔ agent nie ubija sesji
- Czyste zamykanie — zero procesów-zombie po wyjściu z appki

### ⚡ Narzędzia
- **Persony** — profile model + system prompt + temperatura
- **Dyktowanie** po polsku (SFSpeechRecognizer, wszystko lokalnie)
- **Biblioteka promptów** pod `/` w composerze
- Eksport rozmowy do Markdown lub prosto do vaulta **Obsidian**
- Wyszukiwarka rozmów (tytuły + treść)
- Modele lokalne i **cloud** (konto ollama.com) w jednym pickerze
- Status bar z realnym pingiem, latencją i licznikiem agentów

## Skróty klawiszowe

| Skrót | Akcja |
|-------|-------|
| `⌘N` | Nowa rozmowa |
| `⌘T` | Nowy agent |
| `⌘F` | Szukaj rozmów |
| `⌃⌘S` | Schowaj/pokaż panel boczny |
| `⇧⏎` | Nowa linia w composerze |
| `/` | Biblioteka promptów |

## Wymagania

- macOS 26+
- [Ollama](https://ollama.com/download) z co najmniej jednym modelem (`ollama pull <model>`)
- Xcode Command Line Tools (Swift 6)
- Do agentów: `ollama launch claude` (Claude Code przez Ollamę)

## Szybki start

```bash
git clone https://github.com/lubianiec/kiwiMango.git
cd kiwiMango
make run        # build + uruchomienie
make install    # instalacja do /Applications
make dmg        # obraz dystrybucyjny
```

## Struktura

```
Sources/kiwiMango/
├── App.swift               # @main, sceny, skróty globalne
├── RootView.swift          # NavigationSplitView: sidebar + detail
├── DesignSystem.swift      # paleta Neon Noir, neonGlow, kształty
├── Chat/                   # czat: widoki, stan, transport HTTP
├── Agents/                 # sesje Claude Code: AgentManager, SwiftTerm host
└── Database/               # GRDB: migracje, Conversation, StoredMessage
```

## Stack

| Warstwa | Technologia |
|---------|-------------|
| UI | SwiftUI (custom terminal theme, zero Electrona) |
| Baza | [GRDB 7](https://github.com/groue/GRDB.swift) + SQLite |
| Terminal | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (PTY) |
| AI | Ollama HTTP API (`/api/chat`, NDJSON streaming) |
| Build | Swift Package Manager + Makefile |

---

<div align="center">

*Zbudowane w duecie człowiek + Claude. 🥝🥭*

</div>
