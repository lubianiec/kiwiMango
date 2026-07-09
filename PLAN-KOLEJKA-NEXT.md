# kiwiMango — kolejka: F1 + F8 + F9
> Model wykonawczy: Hermes / subagent (szybki, trzyma kontekst).
> Ponytail mode: full — minimum kodu, reuse istniejących wzorców, stdlib/platforma first.

## Zawieszone (nie ruszać bez nowego polecenia)
- reszta F26 kosmetyczna
- F25.2 multi-agent debata
- F25.3 ręczna pamięć projektu
- F25.5 obserwator folderu
- F25.7 marketplace promptów
- F27 całość
- F16/F20/F23 (były zawieszone wcześniej)

---

## F1 — Auto-pamięć długoterminowa (long-term memory)

### Problem
Model zapomina ustalenia po 30 wiadomościach. Paweł nie chce pisać notatek ręcznie.

### Cel
Po każdej zakończonej odpowiedzi asystenta kiwiMango sam wydobywa fakty warte zapamiętania i zapisuje je w SQLite. Przy nowej rozmowie system prompt automatycznie dołącza najbardziej trafne fakty.

### F1.1 — Baza `memoryFact`
- Tabela: `memoryFact(id, content, sourceConversationId, sourceSessionId, scope, createdAt, lastUsedAt, useCount)`
- `scope`: `.global` lub `.project(path)` — globalne lub związane z katalogiem roboczym agenta.
- Wzorzec GRDB id=0 + encode(to:) jak wszystkie tabele w tym projekcie.

### F1.2 — Ekstrakcja faktów
- Po `message.complete` (koniec streamu) uruchom lokalny model z krótkim promptem:
  `Wyciągnij 0-3 konkretne fakty z tej odpowiedzi warte zapamiętania. Format: jeden fakt na linię, zwięźle. Jeśli nic nowego — zwróć pustą odpowiedź.`
- Tylko dla odpowiedzi asystenta w czacie i dla zamkniętych sesji agenta (archiwum).
- Lokalny model = pierwszy nie-cloud z `/api/tags`, żeby było darmowo.
- Efemeryczne — NIE dodawać do historii czatu.

### F1.3 — Retrieval do nowej rozmowy
- Gdy user zaczyna nową rozmowę lub nową sesję agenta z wybranym katalogiem:
  - Global: TOP 5 faktów po `useCount DESC, lastUsedAt DESC`.
  - Project: TOP 5 faktów dla ścieżki roboczej lub jej najbliższego folderu-rodzica.
- Wstrzyknij jako jedną wiadomość systemową na początek historii:
  `Wiesz z poprzednich rozmów: ...`
- Aktualizuj `lastUsedAt` i `useCount`.

### F1.4 — UI zarządzania
- Minimalny widok w Ustawieniach: lista faktów, można usunąć, można edytować.
- Bez kategorii, bez tagów — YAGNI.
- Opcja wyłączenia toggle "Auto-pamięć".

### F1.5 — Checkpoint
- `make build` przechodzi.
- Test: nowa rozmowa → "mam na imię Kazik" → odpowiedź → nowa rozmowa → "jak mam na imię?" → agent pamięta.
- Test agenta: sesja w `~/Kazik/kiwiMango` → ustalenie "używamy Swift 6 tryb v5" → nowy agent w tym samym katalogu → odpowiada z tym faktem.

---

## F8 — macOS Shortcuts + Services

### Problem
kiwiMango żyje tylko w swoim oknie. Paweł chce mieć go pod ręką w każdej aplikacji.

### Cel
1. App Shortcut (`App Intents`) — "Zapytaj kiwimango" z parametrem tekstowym.
2. macOS Services menu — zaznaczony tekst w dowolnej appce → "Wyślij do kiwimango".
3. kiwiMango dostaje tekst, otwiera nową rozmowę, wysyła do aktualnego modelu, wynik ląduje w clipboard lub w oknie.

### F8.1 — App Intents
- Dodaj target app extension `kiwiMangoShortcuts` (embedded, nie osobna apka).
- Jeden `AppIntent`: `AskKiwiMangoIntent(text: String, returnToClipboard: Bool)`.
- Komunikacja: zapisuj request do `UserDefaults` grupy `group.pl.lubianiec.kiwimango` lub do pliku w `~/Library/Application Support/KiwiMango/inbox/`.
- Główna appka odczytuje przy aktywacji.

### F8.2 — Services menu
- Dodaj `ServicesMenu` w Info.plist:
  - `NServicesProvider` / `NSServices` z `message` = `sendToKiwiMango`.
- Handler `NSResponder` w `KiwiMangoAppDelegate` lub `App` implementuje `writeSelectionToPasteboard`.
- Przyjmuje `NSStringPboardType` z tekstem.

### F8.3 — Odbiór w kiwiMango
- W `KiwiMangoAppDelegate.applicationDidBecomeActive` sprawdź `UserDefaults` grupy / plik inbox.
- Jeśli jest request: otwórz główne okno, nowa rozmowa, `chatState.send(text: request.text)`.
- Po zakończonej odpowiedzi:
  - jeśli `returnToClipboard` → kopiuj do NSPasteboard.
  - jeśli nie → po prostu pokaż w oknie.

### F8.4 — Dodanie do Info.plist / Makefile
- Klucze App Groups, Services, App Intents entitlements.
- Makefile musi podpisać embedded extension tym samym certyfikatem co główna appka.

### F8.5 — Checkpoint
- `make build` + `make install`.
- Test: zaznacz tekst w Safari → Services → "Wyślij do kiwimango" → otwiera się kiwiMango, nowa rozmowa, leci odpowiedź.
- Test Shortcuts: utwórz shortcut "Zapytaj kiwimango" → wpisz tekst → odpowiedź w clipboard.

---

## F9 — Rozbudowane okno ustawień aplikacji i Hermesa

### Problem
Obecne ustawienia to mały `Form` w systemowej karcie. Hermes ma swój config w `~/.hermes/config.yaml` — nie dotykany z appki. Brakuje jednego miejsca z logiką: kiwiMango + Hermes w tym samym stylu.

### Cel
Nowe, osobne okno ustawień (`SettingsWindow`) otwierane z menu albo ⌘,. Lewy sidebar z kategoriami, prawa strona z formularzami. Stylistyka: taka sama kolorystyka, fonty, karty, kiwi-card vibe co cała apka.

### F9.1 — Struktura okna
- `SettingsWindow.swift` — własne `Window` / `WindowGroup` w `App.swift`, tytuł "Ustawienia".
- Lewy sidebar (180 px): sekcje z ikonami SF Symbols.
- Prawy obszar: formularze grupowane w sekcje, jak obecny `SettingsView`, ale rozbudowane.
- Kategorie:
  1. **Ogólne** — język, startup, notyfikacje, skróty klawiszowe.
  2. **Czat** — domyślny model, persona, temperatura, max historii, auto-pamięć (F1).
  3. **Ollama** — host, timeout, lokalne modele, cloud modele, fallback order.
  4. **Hermes** — provider, default model, reasoning effort, approvals mode, toolsets.
  5. **Agenci** — domyślny agent (Claude Code / OpenCode / Codex), workdir, telemetry ON/OFF.
  6. **Obsidian** — vault, kategorie, live sync, template notatki.
  7. **Zaawansowane** — logi, debug, reset pamięci, eksport/import.

### F9.2 — Hermes config UI
- Odczyt/zapis `~/.hermes/config.yaml` przez `Yams` (YAML parser) — dodaj zależność do `Package.swift`.
- Pola edytowalne:
  - Provider (ollama-launch / ollama / inny)
  - Default model picker
  - Reasoning effort (low / medium / high)
  - Approvals mode (off / smart / always)
  - Browser provider / enabled
  - Wybrane toolsets checklista
  - Terminal cwd
- Po zapisie: walić w `hermes config reload`? Nie — Hermes CLI wymaga restartu sesji. Wystarczy zapisać plik i pokazać info: "Zrestartuj Hermesa, żeby zmiany zaczęły działać."
- Przycisk "Otwórz config.yaml w edytorze" dla edge case'ów.

### F9.3 — Migracja istniejących `@AppStorage`
- Wszystkie dotychczasowe klucze `@AppStorage` przenieść do jednej `AppSettings` klasy (Observable) z `@AppStorage` properties.
- `SettingsView` stanie się cienkim wrapperem lub zostanie zastąpiony przez nowe okno.
- Zachować nazwy kluczy, żeby nie stracić danych użytkownika.

### F9.4 — Styl
- Tło: `DesignSystem.background`.
- Karty ustawień w `KiwiCardView` tam, gdzie pasuje (np. model info, agent status).
- Toggle, pickery, textfield z `.roundedBorder` + nasze kolory akcentu.
- Sekcje z małymi nagłówkami, dividerami, paddingiem 20.
- Sidebar z wyróżnieniem aktywnej kategorii (tło `.selection`).

### F9.5 — Checkpoint
- `make build` przechodzi.
- Test: ⌘, otwiera nowe okno ustawień, przełączanie kategorii działa.
- Test Hermes: zmiana reasoning effort na "medium", zapis pliku, plik YAML ma poprawną wartość.
- Test migracji: stary `ollamaHost` i `obsidianVaultPath` pozostają bez zmian po aktualizacji.

---

## Kolejność wykonania
1. F9 — najpierw okno ustawień, bo F1 potrzebuje tam swojej sekcji Auto-pamięć.
2. F1 — auto-pamięć (SQLite + ekstrakcja + retrieval).
3. F8 — macOS Shortcuts + Services (najwięcej entitlements i podpisu).

## Definition of done
- F9: nowe okno ustawień, Hermes edytowalny, stylistyka spójna.
- F1: pamięć działa bez ręcznego zarządzania.
- F8: Services działa z każdej aplikacji, Shortcuts działa z Siri/Automator.
- Build czysty, instalacja w `/Applications`, Paweł przetestował na żywo.
