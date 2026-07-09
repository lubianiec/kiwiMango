# PLAN — kiwiMango iOS Pilot

> Dokładny plan wykonawczy. Przygotowany przez Hermesa (2026-07-09) do realizacji przez Fable 5 (architektura) + Claude Code / Kimi (kod).
> **Zasada:** zero kodu w tym pliku — tylko architektura, pliki, interfejsy, kolejność, testy i pułapki.
> **Wykonuj sekwencyjnie**, fala po fali. Po każdej fali: `make build` (macOS) i build iOS targetu muszą przechodzić.
> **Nie rozpychać zakresu.** iOS Pilot ma robić DOKŁADNIE jedną rzecz: być natywnym oknem czatu do kiwiMango na Macu.

---

## 0. Kontekst i cele

### 0.1 Co już istnieje (nie wymyślamy na nowo)

- **kiwiMango macOS**: Swift 6 (tryb `.v5`), SwiftUI, SPM, GRDB (SQLite), macOS 26
- **Hermes Gateway**: `HermesGatewayClient.swift` — WebSocket JSON-RPC 2.0 do własnego serwera `hermes serve` (auto-port, token w query). Obsługuje `session.create`, `prompt.submit`, streaming `message.delta/thinking/tool/subagent/approval/clarify/complete`.
- **Baza czatu**: `DatabaseManager.swift` — `Conversation` + `StoredMessage` w SQLite (`~/Library/Application Support/KiwiMango/kiwiMango.sqlite`).
- **Design system**: `DesignSystem.swift` — paleta Graphite & Lime (`#171512`, `#c6ff3d`, `#232326`, itp.), czcionki mono/sans, dymki ze ściętymi rogami.
- **Obsidian sync**: `ObsidianSyncService.swift` — zapisuje czaty do `AI/Czaty/` na żywo.
- **Fala 16 (Remote) była zawieszona** — jej diagnoza (serwer HTTP + QR + mobilny web-czat) zostaje wykorzystana, ale forma zmienia się na **natywną apkę iOS zamiast web-appki**.

### 0.2 Cel produktowy

iPhone 17 Pro staje się **pilotem / młodszym bratem** kiwiMango:

- piszę na telefonie → widzę na Macu w czasie rzeczywistym
- ta sama historia czatu (jedna baza SQLite na Macu)
- ten sam wygląd (Graphite & Lime, minimalistyczny czat)
- parowanie przez kod QR (Zero-Config Setup)
- asynchroniczne zadania agenta: wysyłam z telefonu, Hermes robi na Macu, dostaję powiadomienie / widzę wynik po otwarciu apki
- foto-załączniki z aparatu telefonu → do modelu przez Maca

### 0.3 Cele NIE wchodzące w zakres (anty-scope-creep)

- NIE tworzymy kolejnego „ChatGPT na iOS" — brak osobnej bazy, osobnych modeli, osobnej logiki
- NIE uruchamiamy Ollamy ani Hermesa na iPhonie — telefon jest tylko terminalem
- NIE przenosimy agenty/terminalu/agentów na iOS — na start tylko czat tekstowy
- NIE budujemy własnego serwera chmurowego — wszystko przez lokalną sieć / Tailscale
- NIE zmieniamy wyglądu kiwiMango macOS, chyba że wymaga tego współdzielony komponent

### 0.4 Role modeli

- **Fable 5**: ten plan + ewentualne uzupełnienia architektoniczne. NIE pisze kodu.
- **Claude Code / Sonnet / Kimi**: implementacja w Xcode pod dyktando planu.
- **Paweł**: testuje na żywej wersji, zatwierdza, decyduje czy iść dalej.

---

## 1. Architektura wysokiego poziomu

```
┌─────────────────────────────┐         ┌─────────────────────────────────────┐
│     iPhone 17 Pro (iOS)       │         │           MacBook M4 (macOS)        │
│  kiwiMango Pilot.app          │         │      kiwiMango.app (rozbudowana)    │
│  ───────────────────────      │         │  ─────────────────────────────────  │
│  SwiftUI Chat View            │◄───────►│  KiwiMangoServerService            │
│  PilotConnectionManager         │ WebSocket│  ├─ HTTP API (QR config, health)   │
│  PilotSessionStore              │  + HTTP  │  ├─ WebSocket server (/pilot/ws)   │
│  HapticsManager               │         │  └─ bridge do ChatState / DB       │
│  CameraAttachmentService      │         │       │                             │
│  PushNotificationManager      │         │       ▼                             │
└─────────────────────────────┘         │  HermesGatewayClient (już jest)     │
                                          │  DatabaseManager (GRDB) — wspólna   │
                                          │  ObsidianSyncService                │
                                          └─────────────────────────────────────┘
```

### 1.1 Kluczowe zasady architektoniczne

1. **Single source of truth**: historia i ustawienia żyją TYLKO na Macu. iPhone trzyma tylko cache + lokalne preferencje (np. ostatnio używany model, motyw, token auth).
2. **Zero-Config Setup**: kod QR zawiera `server_url` + `auth_token`. iPhone po zeskanowaniu zapisuje token w Keychain i łączy się automatycznie.
3. **WebSocket jako główny kanał**: wszystkie real-time eventy (nowe wiadomości, delta, status agenta) idą przez WS. HTTP używany tylko do inicjalnego handshake, health-check i uploadu załączników.
4. **Graceful Reconnect**: iOS zabija WS po zablokowaniu ekranu. Aplikacja po wybudzeniu odtwarza połączenie i żąda brakujących wiadomości (sync od `last_known_message_id`).
5. **Asynchroniczność**: zadanie wysłane z telefonu nie wymaga otwartej apki. Serwer na Macu kontynuuje pracę, a iPhone dostaje powiadomienie / odpytuje status po reconnect.
6. **Bezpieczeństwo**: token w Keychain, HTTPS opcjonalnie (Tailscale daje HTTPS przez domenę), komunikacja po lokalnej sieci lub tunelu.

### 1.2 Protokół między iOS a Macu

#### HTTP endpoints (serwer w kiwiMango macOS)

| Endpoint | Metoda | Opis |
|----------|--------|------|
| `/api/pilot/config` | GET | Zwraca nazwę serwera, wersję, czy wymagany jest token (dla discovery) |
| `/api/pilot/qr` | GET | Generuje kod QR z JSON: `{server_url, auth_token, server_name}` |
| `/api/pilot/health` | GET | 200 gdy serwer i połączenie z Hermes/Ollama OK |
| `/api/pilot/attachments` | POST | Upload zdjęcia/załącznika z iPhone; zwraca `attachment_id` używany w `prompt.submit` |
| `/api/pilot/messages?since_id=N&limit=50` | GET | Pobiera historię wiadomości z bazy (dla reconnect / pull-to-refresh) |

#### WebSocket events (`/api/pilot/ws?token=...`)

Zdarzenia push z Macu do iOS:

```json
{"type":"message.delta","conversation_id":123,"message_id":"...","delta":"tekst"}
{"type":"message.complete","conversation_id":123,"message_id":"...","final_text":"...","usage":{}}
{"type":"tool.start","conversation_id":123,"tool_id":"...","name":"...","description_pl":"..."}
{"type":"tool.complete","conversation_id":123,"tool_id":"...","result":"..."}
{"type":"thinking.delta","conversation_id":123,"session_id":"...","delta":"..."}
{"type":"subagent.count","conversation_id":123,"count":2}
{"type":"approval.request","conversation_id":123,"request_id":"...","command":"...","description":"..."}
{"type":"notification","title":"Hermes gotowy","body":"Zadanie zakończone"}
{"type":"error","message":"..."}
```

Komendy z iOS do Macu:

```json
{"type":"prompt.submit","conversation_id":123,"text":"...","model":"...","attachment_ids":[]}
{"type":"approval.respond","request_id":"...","choice":"once|deny"}
{"type":"conversation.create","title":"..."}
{"type":"conversation.select","conversation_id":123}
{"type":"ping"}
```

---

## 2. FALE WYKONAWCZE

### FALA 0 — Przygotowanie projektu iOS

**Cel:** nowy target / nowy pakiet SwiftPM z aplikacją iOS, podpięty pod istniejący repo kiwiMango, bez łamania buildu macOS.

**Pliki:**
- `Package.swift` — dodanie nowego produktu `.executable` / `.application` dla iOS (lub nowy katalog `kiwiMangoPilot/` z własnym `Package.swift`)
- `kiwiMangoPilot/` — katalog źródeł iOS
- `kiwiMangoPilot/Sources/PilotApp.swift` — `@main`
- `kiwiMangoPilot/Sources/PilotAppState.swift` — główny `@MainActor @Observable` stan apki
- `Makefile` — nowe komendy: `make pilot-build`, `make pilot-run`, `make pilot-install`

**Decyzja do podjęcia przez Paweła / agenta:**

a) **Opcja A (zalecana): osobny podpakiet SPM**
- `kiwiMangoPilot/Package.swift` zależny od wspólnego pakietu `kiwiMangoKit`
- Wspólne modele (kolory, typy wiadomości, protokół) wydzielone do `Sources/kiwiMangoKit/`
- iOS i macOS dzielą tylko to, co naprawdę wspólne: design tokens, modele wiadomości, parsowanie kiwi-card

b) **Opcja B (szybsza): nowy target w istniejącym Package.swift**
- dodajemy `.executableTarget(name: "kiwiMangoPilot", platform: .iOS(...))`
- ryzyko: zacznie mieszać zależności macOS-only (SwiftTerm, AppKit) z iOS
- wybieramy tylko jeśli agent potwierdzi, że zależności są odseparowane

**Rekomendacja planu: Opcja A.** Agent wykonawczy musi najpierw wydzielić `kiwiMangoKit` z obecnych `Sources/kiwiMango/` — tylko to, co bezpiecznie współdzielić:
- `DesignSystem.swift` (kolory, fonty, modyfikatory UI — bez AppKit)
- `ChatModels.swift` — część modeli uniwersalnych (`ChatMessage`, `SenderKind`, `Role`)
- `MarkdownText.swift` + `SyntaxHighlighter.swift` — parser Markdown (wieloplatformowy)
- `KiwiCard` / `KiwiCardView` — karty podsumowujące

**Krok 0.1 — wydzielenie wspólnego pakietu `kiwiMangoKit`**
1. Utwórz `Sources/kiwiMangoKit/DesignSystem.swift` — przenieś wszystkie kolory, fonty, kształty dymków, które nie używają `AppKit`/`NSColor`.
2. Utwórz `Sources/kiwiMangoKit/ChatModels.swift` — uproszczone modele uniwersalne. macOS używa rozbudowanych wersji z `gatewayThinking`, `gatewayToolLines` itp., więc zrób **protokół / bazowe structy**, z których dziedziczą obie platformy (Swift nie ma dziedziczenia structów — użyj composition lub duplikuj minimalny core).
3. Utwórz `Sources/kiwiMangoKit/MarkdownText.swift` i `SyntaxHighlighter.swift` — wersje bez AppKit (użyj `SwiftUI.Text` / `Image` zamiast `NSImage`).
4. Zaktualizuj `Package.swift` macOS, żeby zależał od `kiwiMangoKit`.
5. `make build` macOS musi przejść bez zmian w UI.

**Test F0:**
- `make build` macOS przechodzi
- nowy pusty target iOS kompiluje się: `make pilot-build`
- pusty ekran iOS startuje w symulatorze / na iPhonie

**Pułapka F0:**
- Nie wydzielaj do `kiwiMangoKit` plików używających `AppKit`, `NSImage`, `NSTask`, `Process` — to zepsuje build iOS.
- Nie refaktoryzuj całego kiwiMango macOS „na zapas”. Przenosisz tylko to, co iOS naprawdę potrzebuje.

---

### FALA 1 — Serwer HTTP + WebSocket w kiwiMango macOS

**Cel:** kiwiMango na Macu wystawia API, do którego może się podłączyć iPhone.

**Pliki:**
- `Sources/kiwiMango/Pilot/PilotServerService.swift` — serwer HTTP + WS, uruchamiany przy starcie apki, zatrzymywany przy quicie
- `Sources/kiwiMango/Pilot/PilotSession.swift` — jedno podłączenie iOS (identyfikacja po tokenie, subskrypcja zdarzeń)
- `Sources/kiwiMango/Pilot/PilotMessage.swift` — wspólne structy protokołu (command/event)
- `Sources/kiwiMango/Pilot/PilotQRCode.swift` — generowanie QR z konfiguracją
- `Sources/kiwiMango/Pilot/PilotAttachmentHandler.swift` — odbiór załączników z iOS
- `Sources/kiwiMango/App.swift` — uruchomienie / zatrzymanie serwera przy lifecycle apki

**Implementacja:**

#### F1.1 — Wybór biblioteki serwera

Nie piszemy własnego HTTP/WS od zera. Dopuszczalne opcje:
- **Vapor** (najbardziej znana, ale ciężka — dużo zależności)
- **Hummingbird** (lżejszy, nowoczesny, dobrze działa z Swift Concurrency)
- **Swifter** (mały, wbudowany HTTP server w czystym Swift)
- **NIOWebSocketServer** (ręcznie, ale elastycznie)

**Rekomendacja: Hummingbird + HummingbirdWebSocket.**
- Jest w SPM, ma Concurrency-first API, lekki.
- Obsługuje zarówno HTTP routes jak i WebSocket upgrade w jednym serwerze.
- Alternatywa: jeśli Hummingbird nie zbuduje się na macOS 26 beta → fallback na **Swifter** (mniej zależności, prostszy kod).

Agent musi dodać do `Package.swift` macOS:
```swift
.package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
.package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
.target(dependencies: [.product(name: "Hummingbird", package: "hummingbird"), .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")])
```

#### F1.2 — Routing HTTP

```swift
struct PilotRouter {
    static func build(storage: PilotStorage) -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.get("api/pilot/config") { _, ctx in ... }
        router.get("api/pilot/qr") { ... }
        router.get("api/pilot/health") { ... }
        router.get("api/pilot/messages") { ... }
        router.post("api/pilot/attachments") { ... body ... }
        return router
    }
}
```

`/api/pilot/qr` generuje QR jako PNG (lub SVG) z JSON:
```json
{
  "server_url": "http://192.168.1.X:11719",
  "auth_token": "km-xxxxxxxx",
  "server_name": "Kazik-M4"
}
```

**Uwaga:** port serwera musi być **stały lub zapisywany w UserDefaults** — inaczej iPhone straci połączenie po restarcie kiwiMango. Rekomendacja: domyślny port `11719` (łatwy do zapamiętania, wolny), z możliwością zmiany w ustawieniach.

#### F1.3 — WebSocket `/api/pilot/ws`

- Upgrade tylko gdy `token` w query zgadza się z zapisanym w `PilotServerService.authToken`.
- Każde połączenie = osobna `PilotSession` (actor), subskrybuje `ChatState` events / `HermesGatewayClient.events()` / `DatabaseManager` changes.
- Proxy eventów: serwer tłumaczy wewnętrzne eventy kiwiMango (np. `ChatState.messages` changes, `HermesGatewayClient.Event`) na protokół `PilotEvent` dla iOS.
- Obsługa komend przychodzących: `prompt.submit`, `approval.respond`, `conversation.create`, `conversation.select`.

#### F1.4 — Bezpieczeństwo i token

- Token generowany raz przy pierwszym uruchomieniu serwera i zapisywany w Keychain (macOS `SecItemAdd`).
- Jeśli użytkownik chce zerować parowanie: przycisk w ustawieniach „Zresetuj połączenie z iPhonem" → nowy token.
- QR zawiera plaintext token — to lokalna sieć, więc ryzyko akceptowalne. Opcjonalnie: token ważny 24h dla pierwszego parowania (młodsza wersja), potem zapisany na stałe.

#### F1.5 — Integracja z lifecycle

W `KiwiMangoApp`:
```swift
@main
struct KiwiMangoApp: App {
    @StateObject private var pilotServer = PilotServerService.shared

    var body: some Scene {
        WindowGroup { ... }
            .onAppear { Task { try? await pilotServer.start() } }
            .onDisappear { pilotServer.stop() } // lub w AppDelegate / NSApplication delegate
    }
}
```

**Test F1:**
- kiwiMango macOS uruchamia się, serwer startuje na porcie 11719
- `curl http://localhost:11719/api/pilot/health` zwraca 200
- `/api/pilot/qr` zwraca obraz QR, który można zeskanować testowym skanerem i odczytać JSON
- WebSocket bez tokena zwraca 403
- WebSocket z poprawnym tokenem łączy się i odbiera `{"type":"connected"}`

**Pułapka F1:**
- Port może być zajęty (zwłaszcza po crashu). Serwer musi obsługiwać `bind error` i próbować portu zapasowego (11720, 11721) lub pokazać błąd w UI.
- iOS zabija WS — serwer musi być gotowy na nagłe rozłączenia bez crasha i czyścić `PilotSession`.

---

### FALA 2 — Parowanie i konfiguracja iOS

**Cel:** iPhone potrafi zeskanować QR, zapisać konfigurację i połączyć się z Macem.

**Pliki:**
- `kiwiMangoPilot/Sources/Onboarding/QRScannerView.swift` — widok skanera (CodeScannerView lub własny `AVCaptureMetadataOutput`)
- `kiwiMangoPilot/Sources/Onboarding/PairingViewModel.swift` — logika parowania
- `kiwiMangoPilot/Sources/Services/PilotConfiguration.swift` — model zapisanej konfiguracji (`serverURL`, `authToken`, `serverName`)
- `kiwiMangoPilot/Sources/Services/PilotKeychain.swift` — Keychain wrapper
- `kiwiMangoPilot/Sources/Services/PilotConnectionManager.swift` — zarządzanie WS + HTTP
- `kiwiMangoPilot/Sources/Info.plist` — uprawnienie do aparatu

**Implementacja:**

#### F2.1 — Model konfiguracji

```swift
struct PilotConfiguration: Codable, Sendable {
    let serverURL: URL
    let authToken: String
    let serverName: String
    let pairedAt: Date
}
```

#### F2.2 — Keychain

- Token zapisany w Keychain z `kSecClassGenericPassword`, account = `kiwiMangoPilot.server.<serverName>`.
- Konfiguracja zapisywana w `UserDefaults` (nie wrażliwa), token w Keychain.
- Przy usunięciu apki konfiguracja znika z UserDefaults, token z Keychain.

#### F2.3 — QR Scanner

- Użyj `AVCaptureDevice` + `AVCaptureMetadataOutput` (bardziej kontrola) lub gotowej biblioteki CodeScanner (szybciej).
- Skaner pokazuje overlay z ramką QR, limonkowy znacznik, przycisk „Wpisz ręcznie".
- Po zeskanowaniu: walidacja URL, ping `/api/pilot/health`, jeśli OK → zapisz konfigurację, przejdź do czatu.
- Jeśli ping nie przechodzi (np. inna sieć) → pokazuje błąd „Nie można połączyć się z Maciem. Upewnij się, że jesteś w tej samej sieci.

#### F2.4 — Ręczne połączenie (fallback)

Widok „Wpisz ręcznie":
- pole URL (`http://...:11719`)
- przycisk „Połącz"
- przy pierwszym połączeniu serwer zwraca nowy token? Czy użytkownik wpisuje token sam? — **decyzja:** przy ręcznym wpisywaniu użytkownik musi odczytać token z kiwiMango macOS (np. z okna ustawień). Nie upraszczajmy do zero-knowledge.

#### F2.5 — ConnectionManager

```swift
@MainActor
@Observable
final class PilotConnectionManager {
    enum State { case disconnected, connecting, connected, reconnecting, error(String) }
    var state: State = .disconnected
    var lastError: String?

    func connect(configuration: PilotConfiguration) async
    func disconnect()
    func send(_ command: PilotCommand) async throws
    func reconnectWithBackoff()
}
```

**Test F2:**
- zeskanowanie QR zapisuje konfigurację i łączy się z Macem
- zamknięcie iOS apki, otwarcie ponownie → automatyczne połączenie z zapisaną konfiguracją
- zmiana sieci Wi-Fi → pokazuje błąd połączenia
- przycisk „Rozłącz" czyści konfigurację i wraca do skanera

**Pułapka F2:**
- iOS wymaga `NSCameraUsageDescription` w Info.plist — bez tego apka crashuje przy otwarciu skanera.
- URL z QR może zawierać `http://` i lokalny IP. iOS blokuje plaintext HTTP w produkcyjnych appkach, ALE w developmentie / ad-hoc jest dozwolony. Dla TestFlight/App Store trzeba dodać `NSAllowsArbitraryLoads` lub używać Tailscale HTTPS. W pierwszej wersji akceptujemy HTTP + ad-hoc dystrybucja.

---

### FALA 3 — UI czatu na iOS

**Cel:** iPhone wyświetla czat w szacie Graphite & Lime, z tą samą semantyką co kiwiMango macOS.

**Pliki:**
- `kiwiMangoPilot/Sources/Chat/PilotChatView.swift` — główny widok czatu
- `kiwiMangoPilot/Sources/Chat/PilotMessageBubble.swift` — dymek user/asystent
- `kiwiMangoPilot/Sources/Chat/PilotComposerView.swift` — pole tekstowe + przyciski
- `kiwiMangoPilot/Sources/Chat/PilotChatState.swift` — stan wiadomości, draftu, streamingu
- `kiwiMangoPilot/Sources/Chat/PilotToolStatusView.swift` — wskaźnik „Hermes myśli / używa narzędzia / subagenci"
- `kiwiMangoPilot/Sources/Design/PilotDesignSystem.swift` — iOS-specific overrides (np. safe area, dynamic type)

**Implementacja:**

#### F3.1 — Kolory i typografia

- Użyj `kiwiMangoKit.DesignSystem` — kolory identyczne.
- Dostosuj rozmiary pod iOS: mniejsze paddingi, większe dymki (dotyk), czcionka minimum `body` z uwzględnieniem Dynamic Type.

#### F3.2 — ChatView

- Góra: tytuł rozmowy + nazwa aktywnego modelu (mono, małe).
- Środek: `ScrollView` + `LazyVStack` z wiadomościami. Przy nowej wiadomości auto-scroll do dołu.
- Dół: composer (jak iMessage: rounded, kolor tła `kiwiMangoComposerBg`, limonkowy przycisk send).
- Pull-to-refresh: pobiera historię od `last_known_message_id` (obsługuje reconnect).

#### F3.3 — Dymki

- User: prawa strona, tło `kiwiMangoSurface`, tekst primary, zaokrąglone rogi (nie ścięte jak na Macu — na iOS lepiej wyglądają zaokrąglone).
- Asystent: lewa strona, tekst `kiwiMangoTextPrimary`, tło przezroczyste, obrys `kiwiMangoAccent.opacity(0.25)`, mała ikona/model nad dymkiem.
- Markdown: reużywamy `kiwiMangoKit.MarkdownText`.
- Bloki kodu: tło ciemne, przycisk kopiuj, horizontal scroll.
- kiwi-card: reużywamy `kiwiMangoKit.KiwiCardView` (zmniejszony dla iOS).

#### F3.4 — Status agenta (tool/subagent/thinking)

- Podczas streamingu pokazujemy: „Hermes myśli…" (collapsible), „Używa narzędzia: …" (po polsku przez `ToolHumanizer`), „Subagenci pracują: N".
- Po zakończeniu turna sekcja „myśli" zwija się automatycznie (jak na Macu).

#### F3.5 — Approval / Clarify

- Gdy przyjdzie `approval.request`: wstrzymujemy composer, pokazujemy modal/panel z komendą + przyciskami „ZATWIERDŹ" / „ODRZUĆ".
- Gdy `clarify.request`: pokazujemy pytanie + lista odpowiedzi do wyboru.
- Wysyłamy odpowiedź przez WS.

**Test F3:**
- apka wygląda jak młodszy brat kiwiMango — ciemne tło, limonkowe akcenty, mono czcionki
- wiadomości user/asystent renderują się poprawnie
- markdown, kody, kiwi-card działają
- composer wysyła wiadomość przez WS

**Pułapka F3:**
- iOS keyboard zabiera sporo miejsca — composer musi używać `.safeAreaInset(edge: .bottom)` lub `KeyboardAvoidingView`, inaczej pole zniknie pod klawiaturą.
- `LazyVStack` z dużą historią może mieć problemy z auto-scroll — użyć `ScrollViewReader` + `withAnimation`.

---

### FALA 4 — Synchronizacja historii + Graceful Reconnect

**Cel:** iPhone widzi tę samą historię co Mac, a po reconnectie nie gubi się.

**Pliki:**
- `kiwiMangoPilot/Sources/Services/PilotSyncEngine.swift` — logika synchronizacji
- `kiwiMangoPilot/Sources/Services/PilotMessageStore.swift` — lokalny cache wiadomości (opcjonalnie SQLite, ale na start UserDefaults/JSON wystarczy)
- `Sources/kiwiMango/Pilot/PilotHistoryAPI.swift` — endpointy do pobierania historii
- `Sources/kiwiMango/Database/DatabaseManager+Pilot.swift` — metody: `messagesSince(id:limit:)`, `latestMessageID(for:)`

**Implementacja:**

#### F4.1 — Protokół synchronizacji

Każda wiadomość ma identyfikator liniowy (`message_id` = `conversation_id`-`rowid` z SQLite).

Połączenie WS:
1. Po `connected` iOS wysyła `{"type":"sync.request","last_known_message_id":"...","conversation_id":123}`.
2. Mac odpowiada `{"type":"sync.response","messages":[...]}` z brakującymi wiadomościami.
3. iOS merguje do lokalnego stanu, unikając duplikatów.

#### F4.2 — Graceful Reconnect

- iOS: `PilotConnectionManager` ma `reconnectTask`. Po rozłączeniu czeka 1s, 2s, 4s, 8s, max 30s.
- Po reconnect wysyła `sync.request` z `last_known_message_id`.
- Jeśli użytkownik wysłał wiadomość w trakcie rozłączenia: trzymamy ją w kolejce lokalnej i wysyłamy ponownie po reconnect.
- Jeśli odpowiedź się skończyła podczas rozłączenia: powiadomienie push / badge na ikonie apki.

#### F4.3 — Live streaming na iOS

- Mac wysyła `message.delta` co nowy fragment — iOS appends do ostatniej wiadomości asystenta.
- `message.complete` finalizuje wiadomość, zapisuje ją w lokalnym cache.
- `tool.start` / `tool.complete` aktualizuje status.

#### F4.4 — Wybór rozmowy na iOS

- Widok listy rozmów (jak sidebar na Macu): tytuł + czas ostatniej wiadomości + fragment treści.
- Klik → `conversation.select` do Maca + sync historii.
- Przycisk nowa rozmowa → `conversation.create`.

**Test F4:**
- otwarcie apki pobiera pełną historię aktywnej rozmowy
- wysłanie wiadomości z iPhone pojawia się na Macu w czasie rzeczywistym
- zablokowanie iPhone na 30s, odblokowanie → reconnect, sync, brak brakujących wiadomości
- wysłanie wiadomości podczas offline → wisi w kolejce, wysyła się po reconnect

**Pułapka F4 (krytyczna):**
- iOS zabija WS bardzo szybko. Nie polegamy na WS dla trwałej pracy. Hermes na Macu kontynuuje pracę niezależnie od iPhone. iPhone tylko odbiera powiadomienia / syncuje wynik.
- Przy szybkim reconnect można dostać duplikaty eventów. Każdy `message.delta` powinien mieć `sequence_number`, a iOS merguje po `message_id + sequence`.

---

### FALA 5 — Załączniki, haptyka, powiadomienia

**Cel:** iPhone jako pełne narzędzie wejściowe: zdjęcia, wibracje, powiadomienia.

**Pliki:**
- `kiwiMangoPilot/Sources/Chat/PilotAttachmentPicker.swift` — wybór zdjęcia/aparatu
- `kiwiMangoPilot/Sources/Services/PilotAttachmentUploader.swift` — upload do Maca
- `kiwiMangoPilot/Sources/Services/PilotHaptics.swift` — haptyka
- `kiwiMangoPilot/Sources/Services/PilotNotifications.swift` — lokalne powiadomienia
- `kiwiMangoPilot/Sources/Widgets/PilotWidget.swift` — widget ekranu głównego (opcjonalnie, iOS 17+)

**Implementacja:**

#### F5.1 — Foto załączniki

- Przycisk aparatu w composerze: wybór „Zrób zdjęcie" / "Wybierz z galerii".
- Zdjęcie kompresowane do JPEG (max 1920px szerokości, quality 0.85) przed wysyłką.
- Upload przez `/api/pilot/attachments` (multipart/form-data).
- Mac zapisuje w `~/Library/Application Support/KiwiMango/Attachments/` i zwraca `attachment_id`.
- W `prompt.submit` iOS podaje `attachment_ids`, Mac konwertuje do formatu Ollama/Hermes.

#### F5.2 — Haptyka

- Lekkie stuknięcie (`UIImpactFeedbackGenerator(.light)`) przy:
  - wysłaniu wiadomości
  - otrzymaniu pierwszej delty odpowiedzi
  - zakończeniu turna
  - błędzie
- Subtelne, nie nachalne — Paweł wspomniał ADHD-friendly feedback.

#### F5.3 — Powiadomienia lokalne

- Gdy iOS apka jest w tle, a Hermes zakończy pracę → Mac wysyła WS event `notification`, ale iOS go nie odbierze (WS martwy).
- Rozwiązanie: **Background Fetch / BGAppRefreshTask** albo **Push Notification przez lokalny proxy**.
- Prostsza wersja: iOS przy każdym reconnect robi `sync.request` i jeśli znajdzie nowe, gotowe wiadomości asystenta → lokalne powiadomienie `UNUserNotificationCenter`.
- Aby to działało w tle, trzeba dodać `Background Modes`: „Background processing" i „Remote notifications" w Info.plist. Ale lokalny serwer nie może wysłać APNs bez certyfikatu.
- **Decyzja v1:** powiadomienia działają TYLKO gdy apka jest otwarta lub w foreground (iOS dopuszcza lokalne notyfikacje z appki). Prawdziwe tło = sync po otwarciu. Nie budujemy własnego APNs.

#### F5.4 — Widget / Quick Action (opcjonalnie)

- Widget pokazuje ostatnią aktywną rozmowę + przycisk „Nowa wiadomość".
- Quick Action z ekranu głównego: „Nowa rozmowa z Hermesem".

**Test F5:**
- zrobienie zdjęcia w apce i wysłanie → pojawia się w czacie Maca i iOS
- wibracja przy odpowiedzi jest wyczuwalna
- po zablokowaniu i odblokowaniu apka syncuje nowe wiadomości

**Pułapka F5:**
- Aparat i galeria wymagają uprawnień w Info.plist (`NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`).
- Upload dużego zdjęcia może zabić WS — kompresja przed wysyłką jest obowiązkowa.
- iOS lokalne powiadomienia wymagają prośby o zgodę użytkownika — robić to dopiero po pierwszym użyciu, nie przy starcie.

---

### FALA 6 — Tailscale / poza domem (opcjonalna, ale ważna)

**Cel:** iPhone działa nie tylko w lokalnej sieci, ale też przez Tailscale.

**Implementacja:**
- iOS konfiguracja pozwala wpisać URL Tailscale zamiast lokalnego IP (np. `http://kazik.tailnet-name.ts.net:11719`).
- Kod QR może zawierać URL Tailscale, jeśli kiwiMango wykryje, że Tailscale jest aktywny na Macu.
- Wymaga Tailscale zainstalowanego na iPhone i zalogowanego do tej samej sieci.
- Hermitage: Tailscale daje HTTPS opcjonalnie, więc unikamy problemu plaintext HTTP na iOS.

**Test F6:**
- połączenie z iPhone przez Tailscale (wyłączone Wi-Fi, włączony LTE + Tailscale) działa

**Pułapka F6:**
- Tailscale na iOS wymaga VPN — użytkownik musi go włączyć ręcznie. Nie możemy tego zrobić z apki.

---

### FALA 7 — Testy, README, dystrybucja

**Cel:** apka działa stabilnie, jest udokumentowana, można ją zainstalować na iPhonie.

**Pliki:**
- `kiwiMangoPilot/README.md`
- `kiwiMangoPilot/Makefile`
- `kiwiMangoPilot/Tests/PilotConnectionTests.swift` (mock serwera / mock WS)
- `kiwiMango/Tests/` — testy `PilotServerService`

**Implementacja:**

#### F7.1 — Testy jednostkowe

- `PilotMessage` encode/decode
- `PilotSyncEngine` merge (bez duplikatów)
- `PilotConnectionManager` reconnect backoff

#### F7.2 — Testy integracyjne

- Włącz kiwiMango macOS, połącz iOS symulator, wyślij wiadomość, sprawdź czy pojawia się na Macu.
- Wykonaj approval z iOS, sprawdź czy Hermes kontynuuje.

#### F7.3 — README

- co to jest
- wymagania (iOS 26+, Mac z kiwiMango, ta sama sieć / Tailscale)
- instalacja: `make pilot-install` + trust certyfikatu / profilu deweloperskiego
- parowanie QR
- screenshots z symulatora / rzeczywistego iPhone

#### F7.4 — Dystrybucja v1

- Ad-hoc: `make pilot-archive` + udostępnienie przez AirDrop / TestFlight.
- TestFlight wymaga konta Apple Developer (99 USD/rok) — Paweł musi zdecydować czy chce.
- Dla własnego użytku wystarczy build na podłączonym iPhonie przez Xcode / `make pilot-install`.

**Test F7:**
- `make pilot-build` przechodzi
- `make pilot-install` instaluje na iPhonie Pawła
- apka startuje, skanuje QR, łączy się, wysyła wiadomość, odbiera odpowiedź

---

## 3. Pułapki i jak ich unikać

| Pułapka | Konsekwencja | Rozwiązanie |
|---------|-------------|-------------|
| iOS zabija WebSocket po zablokowaniu | Brak live streamingu | Graceful Reconnect + sync on reconnect |
| Plaintext HTTP na iOS | App Store rejection / blokada | Ad-hoc dystrybucja v1; Tailscale HTTPS v2 |
| Duplikaty wiadomości po reconnect | Bałagan w czacie | `message_id` + `sequence_number` per delta |
| Wielka baza na iPhone | Przepełnienie, synchronizacja wolna | Baza TYLKO na Macu; iPhone cache tylko aktywna rozmowa |
| Refaktoryzacja całego kiwiMango macOS pod iOS | Nieskończona robota | Wydziel tylko `kiwiMangoKit`; nie ruszaj logiki macOS |
| Swift 6 strict concurrency w iOS | Build errors | Używamy trybu `.v5` tak jak macOS |
| Port serwera zajęty | kiwiMango nie startuje serwera | Domyślny port + fallback + UI błędu |
| Brak uprawnień do aparatu/mikrofonu | Crash przy pierwszym użyciu | Dodaj Info.plist + request authorization |
| Hermes Gateway potrzebuje tokenu | iOS nie może się połączyć | Token w query + Keychain; serwer generuje token przy starcie |
| iOS app lifecycle killuje background fetch | Brak powiadomień push | Akceptujemy, że prawdziwe tło = sync po otwarciu |

---

## 4. Definition of Done (cały projekt)

- [ ] Nowy target iOS buduje się i startuje (`make pilot-build`, `make pilot-run`)
- [ ] kiwiMango macOS nadal się buduje i działa (`make build`, `make run`)
- [ ] iPhone skanuje QR i łączy się z Macem w tej samej sieci
- [ ] Pisanie z iPhone pojawia się na Macu w czasie rzeczywistym
- [ ] Odpowiedź z Macu pojawia się na iPhone w czasie rzeczywistym
- [ ] Zablokowanie iPhone na 30s + odblokowanie = reconnect bez utraty wiadomości
- [ ] Wygląd iOS jak młodszy brat kiwiMango (Graphite & Lime, mono, dymki)
- [ ] Markdown, bloki kodu, kiwi-card renderują się poprawnie na iOS
- [ ] Approval / Clarify działa z iOS
- [ ] Foto-załącznik z iPhone leci do modelu przez Maca
- [ ] Haptyka działa przy odpowiedziach
- [ ] Lista rozmów, nowa rozmowa, wybór rozmowy działają
- [ ] README iOS apki jest zrozumiałe dla Pawła
- [ ] Paweł przetestował na żywej wersji i zatwierdził

---

## 5. Kolejność i kryteria przejścia między falami

1. **F0** → F1: `make build` macOS OK + `make pilot-build` OK (pusta apka)
2. **F1** → F2: `curl health` i QR działają; WS bez tokena 403, z tokenem connect
3. **F2** → F3: iOS zeskanował QR, zapisał config, wysłał ping, dostał pong
4. **F3** → F4: UI czatu renderuje dymki i wysyła wiadomość, która dociera do Maca
5. **F4** → F5: Reconnect po zablokowaniu działa; historia syncuje się bez dziur
6. **F5** → F6: Foto + haptyka działają
7. **F6** → F7: Tailscale działa poza domem
8. **F7** → Done: README + dystrybucja + Paweł zatwierdził

**Po każdej fali:**
- commit z prefixem `F0: ...`, `F1: ...` itd.
- krótki raport: co zrobione, co do ręcznego testu, czy build przeszedł
- NIE przechodzić do następnej fali bez wyraźnego polecenia lub potwierdzenia

---

## 6. Notatki dla wykonawcy (Claude Code / Kimi)

- Pytaj PAWŁA tylko przy decyzjach kosztownych / nieodwracalnych: zmiana architektury, wybór między Hummingbird a Swifter, czy robić TestFlight.
- Jeśli coś nie działa po 2 próbach — zatrzymaj się, zapisz dokładny błąd i daj znać Pawełowi. Nie kombinuj „na zapas".
- Nie dodawaj funkcji poza tym planem. iOS Pilot to tylko czat + pilot — nie agenci, nie terminale, nie nowe modele.
- Testuj na żywej wersji: włącz kiwiMango Mac, otwórz apkię iOS, wyślij prawdziwą wiadomość, sprawdź czy obie strony ją widzą.
- Wszystkie zmiany w `PLAN.md` (jeśli potrzebne) konsultuj z Fable 5 / Pawełem. Ten plik to źródło prawdy.

---

*Koniec planu. Gotowy do realizacji.*
