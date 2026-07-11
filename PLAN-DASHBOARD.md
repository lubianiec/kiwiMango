# PLAN: Natywny Dashboard (zastępuje webowy Hermes HUD)

> Status: DO AKCEPTACJI · v2 · 2026-07-10
> Cel: sekcja DASHBOARD w kiwiMango — 100% SwiftUI, zero Python/npm/WKWebView.
> **Zakres v2 (decyzja Pawła): pełny parytet funkcjonalny z webowym Hermes HUD** — wszystkie
> panele WebUI (poza czatem, który kiwiMango ma natywnie), nie tylko tokeny i status.
> Wykonanie: nadaje się dla taniego modelu (Sonnet) — źródła danych zbadane, zero niewiadomych.
> **⚠️ BEZ WYJĄTKÓW: Sonnet implementuje w trybie skilla `ponytail`** (wytyczne niżej).

---

## Obowiązkowy tryb pracy: ponytail (lazy senior dev)

Źródło wytycznych: `~/.hermes/plugins/ponytail/AGENTS.md` (plugin Hermesa, v4.8.4).
Każda fala, każda story, każdy plik — zero odstępstw.

**Drabina przed napisaniem JAKIEGOKOLWIEK kodu** (zatrzymaj się na pierwszym szczeblu, który wystarcza):
1. Czy to w ogóle trzeba budować? (YAGNI)
2. Czy już istnieje w codebase? Użyj istniejącego helpera/wzorca (np. komponenty MissionControlView!).
3. Czy standardowa biblioteka to robi? Użyj jej.
4. Czy natywna funkcja platformy to pokrywa? (SwiftUI/Foundation/GRDB już w projekcie).
5. Czy już zainstalowana zależność to rozwiązuje? Użyj jej.
6. Czy to może być jedna linia? Zrób jedną linię.
7. Dopiero wtedy: minimum kodu, które działa.

**Zasady:**
- Żadnych abstrakcji, o które nikt nie prosił. Żadnych nowych zależności. Żadnego boilerplate'u.
- Usuwanie > dodawanie. Nudne > sprytne. Jak najmniej plików.
- Najkrótszy działający diff wygrywa — ale dopiero PO zrozumieniu problemu (prześledź realny flow end-to-end).
- Bugfix = przyczyna, nie objaw: grep wszystkich callerów, napraw wspólną funkcję raz.
- Świadome uproszczenia oznaczaj komentarzem `ponytail:` (nazwij sufit i ścieżkę upgrade'u).
- Nielazy zawsze: walidacja na granicach zaufania, error handling chroniący dane, bezpieczeństwo, dostępność. Nietrywialna logika zostawia JEDEN uruchamialny check (mały test/assert, bez frameworków).

---

## Parytet z Hermes WebUI (rekonesans `~/.hermes-hudui`, 2026-07-10)

WebUI ma 19 tabów. Wszystkie kolektory czytają **lokalne pliki `~/.hermes/` + `state.db`**
— żaden panel nie potrzebuje serwera HTTP. Natywne przepisanie = te same źródła w Swift.

| Panel WebUI | Źródło danych | Natywnie w kiwiMango |
|---|---|---|
| **Dashboard** (overview: runtime, dni, sesje, wiadomości, tokeny, pamięć %, snapshoty, rozmiar state.db) | state.db + pliki `~/.hermes/` | sekcja główna (hero + kafle) |
| **Memory** | `~/.hermes/memories/MEMORY.md`, `USER.md` | podgląd + % wypełnienia |
| **Skills** | katalog `~/.hermes/skills/` | lista + opisy |
| **Sessions** | `state.db` → `sessions` | tabela, filtry, szczegóły |
| **Replay** (+ Verify) | `state.db` (+ remote sync) | odtwarzanie sesji; remote sync = v2 |
| **Cron** | `~/.hermes/cron/jobs.json` + akcje `hermes cron …` | lista + next/last run; akcje = v2 |
| **Projects** | skan katalogów projektów (package.json, README) | lista projektów |
| **Health** | auth.json, config.yaml, cron, models cache, state.db (checki) | karta zdrowia z checkami |
| **Agents** | `state.db` (subagenci Hermesa) | lista przebiegów subagentów |
| **Profiles** | `~/.hermes/profiles/` | lista profili |
| **Token-costs** | `state.db` | sekcja ILE/ZA ILE (patrz niżej) |
| **Corrections** | `state.db` | lista korekt |
| **Patterns** | `state.db` | wykryte wzorce |
| **Sudo** | config.yaml + `state.db` | log użyć sudo |
| **Providers** | `~/.hermes/auth.json` (status OAuth) | statusy providerów |
| **Gateway** (+ restart / update) | `gateway_state.json` + akcje | status; akcje restart/update = v2 |
| **Model-info** | config.yaml + `models_dev_cache.json` | karta aktywnego modelu |
| **Plugins** | `~/.hermes/plugins/` (manifest.json / plugin.yaml) | lista pluginów; instalacja = v2 |
| **Chat** | — | ❌ pomijamy — kiwiMango ma natywny czat |

Zasada v1/v2: **v1 = pełny ODCZYT wszystkich paneli** (parytet informacyjny).
**v2 = akcje mutujące** (restart gatewaya, run crona, instalacja pluginów, remote sync) — po stabilnym odczycie.

> ⚠️ Korekta z Fali 1a (2026-07-10): w żywej `state.db` istnieją tylko tabele `sessions` i `messages`
> (+FTS/meta). **Nie ma tabel `corrections`, `patterns`, `sudo`, `agents`** — kolektory WebUI
> zakładają je dla nowszych wersji Hermesa. Subagenci = wiersze `sessions` z `source='subagent'`.
> Panele Korekty/Wzorce/Sudo w Fali 3b: pokazać stan „brak danych", dekodery dopisać dopiero
> gdy tabele realnie powstaną (YAGNI).

---

## Fakty z rekonesansu (potwierdzone testami, nie domysły)

| Dane | Źródło | Format |
|---|---|---|
| Historia sesji Hermesa: tokeny (input/output/cache/reasoning), model, czas, liczba wiadomości/tooli | `~/.hermes/state.db` → tabela `sessions` | SQLite (~156 MB, WAL) |
| Stan gatewaya + Telegram | `~/.hermes/gateway_state.json` | JSON, live |
| Cron joby (nazwa, schedule, next/last run, status) | `~/.hermes/cron/jobs.json` | JSON |
| Pamięć Hermesa + wypełnienie | `~/.hermes/memories/MEMORY.md` (limit 2200 zn.), `USER.md` (1375 zn.) | Markdown |
| Aktywny model + metadane | `~/.hermes/config.yaml`, `models_dev_cache.json` | YAML/JSON |
| Live usage per odpowiedź: `{model, input, output, total, calls, context_used, context_max, context_percent, compressions, active_subagents}` | event WS `message.complete.usage` — **już płynie** przez istniejący `HermesGatewayClient`, dziś czytamy tylko input+output | JSON-RPC WS |
| Konto Ollama: `{name: "lubianiec", email, plan: "pro"}` | `POST http://localhost:11434/api/me` | JSON |
| Modele Ollama (które są cloud → `remote_host`) | `GET /api/tags`, `/api/ps` | JSON |
| Tokeny czatów kiwiMango | odpowiedzi `/api/chat`: `prompt_eval_count` + `eval_count` (w ostatnim chunku streamu) | JSON |

**Czego NIE ma (potwierdzone):**
- Ollama nie ma API usage/billingu konta (404 wszędzie; otwarte feature requesty #15663, #15132). % limitu Pro jest tylko na webie po zalogowaniu (limity liczone GPU-time, reset 5h).
- `state.db` przy Ollama ma `estimated_cost_usd = 0`, `cost_status = "unknown"` — dolarów per request NIE policzymy uczciwie.
- RPC `billing.*` = kredyty Nous Portal; Paweł niezalogowany → `logged_in: false`. **Nie implementować.**

**Definicja „ile i za ile":**
- „ile" = **tokeny** (jedyna wiarygodna miara): dziś / 7 dni / od początku, per model, Hermes + czaty kiwiMango osobno.
- „za ile" = **koszty stałe subskrypcji**: Ollama Pro $20/mc + (opcjonalnie w ustawieniach) Claude Pro €20/mc. Uczciwe „koszt/1M tokenów tego miesiąca" liczone z flat rate. Zero zmyślonych cen per-token.

---

## Architektura

```
DashboardView (nowa sekcja, zastępuje .hud) — wewnętrzna nawigacja: segmenty/taby paneli
 ├─ DashboardStore (@Observable, @MainActor)
 │   ├─ HermesStateReader   — GRDB read-only na ~/.hermes/state.db
 │   │    (sessions, token-costs, corrections, patterns, sudo, agents, replay)
 │   ├─ HermesFilesReader   — pliki ~/.hermes/: memories/, skills/, profiles/, plugins/,
 │   │    cron/jobs.json, auth.json, config.yaml, models_dev_cache.json, gateway_state.json
 │   ├─ HermesFilesWatcher  — DispatchSource na pliki live (gateway_state, cron, MEMORY)
 │   ├─ OllamaAccountClient — /api/me, /api/tags, /api/ps
 │   └─ HermesTelemetry     — istniejący singleton (live sesje) — bez zmian
 └─ komponenty z MissionControlView (MetricItem, token bar, sparkline) — zdjąć `private`
```

Nawigacja sekcji: pasek segmentów w stylu WebUI (Przegląd · Tokeny · Sesje · Cron · Pamięć ·
Skills · Zdrowie · Gateway · Model · Providers · Profile · Projekty · Agenci · Korekty ·
Wzorce · Sudo · Pluginy · Replay). Skróty ⌘1–⌘9 jak w WebUI.

Bez nowych zależności. Bez serwerów. GRDB już jest w projekcie.

## Layout sekcji (jeden scroll, karty w stylu MissionControl)

1. **Hero:** status gatewaya (dot + bloom), Telegram connected, aktywny model, konto Ollama (`lubianiec · PRO`), uptime gatewaya.
2. **ILE — tokeny:** kafle DZIŚ / 7 DNI / TOTAL (input/output), wykres słupkowy 7 dni (Canvas, wzór sparkline), tabela per model (kimi / gemma / minimax…), rozbicie Hermes vs czat kiwiMango.
3. **ZA ILE:** karta subskrypcji — Ollama Pro $20/mc (+ Claude Pro jeśli włączone w ustawieniach), dzień rozliczeniowy, „efektywny koszt/1M tok. w tym mies.". Link „szczegóły limitu → ollama.com/settings" (bez scrapingu).
4. **Sesje live:** istniejące `HermesMissionCard` + nowe pola z `usage` (context %, model).
5. **Top sesje** (7 dni, z state.db) + **Cron** (joby z next run) + **Pamięć** (wypełnienie % MEMORY/USER).

## Fale wykonania

**Fala 1 — dane (bez UI):**
- `HermesStateReader`: GRDB `?mode=ro` na state.db; query skopiowane z `hermes insights` (sumy per dzień/model, top sesje, LIMIT-y).
- `OllamaAccountClient`: `/api/me` (POST!), `/api/tags`, `/api/ps`.
- `HermesFilesWatcher`: DispatchSource (mtime) na 3 pliki.
- Poszerzenie dekodowania `message.complete.usage` w `HermesGatewayClient` o `model`, `total`, `calls`, `context_percent`, `context_used/max` → `HermesTelemetry.SessionCard`.

**Fala 2 — licznik tokenów kiwiMango:**
- `OllamaService`: z ostatniego chunku streamu czytać `prompt_eval_count`/`eval_count` → nowa tabela `token_usage(day, model, source, input, output)` w istniejącej bazie GRDB (migracja!). Zapis tylko dla modeli cloud (lookup `remote_host` z `/api/tags`, cache 1h).

**Fala 3 — UI rdzenia:**
- `DashboardView` + `DashboardStore` + nawigacja segmentowa; refaktor: `MetricItem`, token bar, sparkline z MissionControlView do `Sources/kiwiMango/Components/` (bez zmiany wyglądu).
- Panele rdzenia: **Przegląd, Tokeny (ILE/ZA ILE), Sesje live, Gateway, Cron, Pamięć**.
- Routing: `SidebarSelection.hud` → `.dashboard`; przycisk lewego panelu bez zmian wizualnych.

**Fala 3b — panele parytetu (odczyt):**
- Z `state.db`: **Sesje (pełna tabela), Token-costs, Korekty, Wzorce, Sudo, Agenci, Replay (lokalny)**.
- Z plików: **Skills, Profile, Providers, Model-info, Pluginy, Projekty, Zdrowie**.
- Każdy panel = osobny plik widoku + metoda w odpowiednim readerze; wspólne komponenty tabel/list.

**Fala 4 — rozbiórka:**
- Usunąć `HUD/HermesHUDManager.swift`, `HUD/HermesHUDView.swift`, import WebKit.
- `make build && make install`, test manualny sekcji.
- Opcjonalnie: `rm -rf ~/.hermes-hudui` (odzysk ~kilkuset MB; PL tłumaczenia stają się zbędne — trud z 2026-07-10 idzie do kosza, świadoma decyzja).

## ⚠️ PUŁAPKI

1. **state.db = 156 MB z WAL, pisany na żywo przez Hermesa.** Otwierać WYŁĄCZNIE `mode=ro`, query z LIMIT, poza main threadem. Nigdy `immutable=1` (WAL by kłamał).
2. **`/api/me` to POST, nie GET** (GET → 405). Timeout 3 s + graceful „offline" gdy Ollama nie działa.
3. **Nie spawnować drugiego `hermes serve`** — kiwiMango już go ma przez `HermesGatewayClient`. Dashboard tylko konsumuje istniejący stream. **Prerekwizyt: naprawić K3/K4 z analizy** (zombie przy reconnect + nieczytany stderr) — bez tego dashboard będzie pokazywał stan martwego/zawieszonego gatewaya.
4. **Nie dotykać RPC `billing.*`** — bez loginu do Nous Portal zwracają śmieci.
5. **Nie pokazywać $ per request** — `cost_status: "unknown"` u Pawła zawsze; pokazuj $ tylko gdy `!= unknown` (przyszłościowo), inaczej tokeny.
6. **Iron rule F9:** żadnych shaderów/`layerEffect` w scrollowanej liście — bloom tylko na hero-dot.
7. **Migracja GRDB** dla `token_usage` — pamiętać o lekcji K1 (kolumny bez migracji = ciche „no such column" przez `try?`). Bez `try?` przy zapisie usage — logować błędy.
8. **Gateway w trybie messaging (Telegram) nie nasłuchuje na TCP** — stan czytać z `gateway_state.json` (pid + `kill -0`), nie z prób łączenia.
9. **`/api/tags` po nazwie modelu**: warianty `:cloud` w nazwie vs `remote_model` — mapować po obu, inaczej licznik ominie modele.
10. **Percent limitu Ollama Pro — NIE liczyć samemu** (rozliczanie GPU-time, nie tokeny). Żadnych pasków „78% limitu" z sufitu.

## Poza zakresem (świadomie — v2)

- Akcje mutujące: restart/update gatewaya, run crona, instalacja pluginów, replay remote sync.
- Scraping ollama.com po % limitu (kruche; ewentualna dobudówka później przez agent-browser).
- Sparkline live tokenów Hermesa (wzór `SessionTelemetry.tokenRateSamples`) — nice-to-have.
- Czat WebUI — kiwiMango ma własny natywny czat.

## Kryteria akceptacji

1. Sekcja DASHBOARD działa bez Pythona/npm/portu 3001; folder `HUD/` nie istnieje.
2. **Parytet informacyjny z WebUI:** każdy panel z tabeli parytetu (poza czatem) ma natywny odpowiednik pokazujący te same dane (odczyt; akcje = v2).
3. Widać: status gatewaya+Telegram, konto `lubianiec · PRO`, tokeny dziś/7d/total per model (zgodne z `hermes insights --days 7`), koszt subskrypcji, cron, top sesje.
4. Odświeżanie: pliki ≤2 s od zmiany, konto Ollama co 60 s, state.db co 30 s lub przy wejściu w sekcję.
5. Ollama wyłączona / brak `~/.hermes` → sekcja pokazuje stany „offline/brak danych", zero crashy.
6. `make build && make install` przechodzi.
