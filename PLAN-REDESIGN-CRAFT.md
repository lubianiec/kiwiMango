# PLAN-REDESIGN-CRAFT — redesign kiwiMango wg referencji (2026-07-11)

**Zastępuje PLAN-REDESIGN-MONO.md (skasowany).** Piąte podejście. Cztery poprzednie odrzucone —
wszystkie poległy na tym samym: agent pracował z opisów słownych zamiast z obrazu i nigdy nie
widział efektu na ekranie.

## Źródło prawdy

`Assets/ui-reference-craft.jpg` — dashboard "Ali Sayed". **Obraz wygrywa z każdym opisem w tym
planie.** Wymóg Pawła: apka ma wyglądać jak referencja, z nawigacją i treścią które kiwiMango
JUŻ MA, plus kolor (amber #F2994A) i animacje wyłącznie w wykresach.

## Metoda (to jest zmiana vs 4 porażki)

1. **Skille wykonawcy** (ładowane Skill toolem na starcie, obowiązkowo):
   - `ui-ux-pro-max` — system designu (paleta/typografia/spacing dla SwiftUI dashboardu)
   - `macos-ui-verification` — weryfikacja na ekranie, nie "kompiluje się"
   - `ponytail` (full) + `anthropic-skills:pawel-swift-macos`
2. **Pętla wizualna po każdej rundzie**: `make run` → 4 s → `screencapture -x /tmp/ui_check.png`
   → Read screenshotu ORAZ referencji → porównanie (ton tła, powietrze, wagi fontów, grubość
   słupków, sidebar) → poprawka → powtórka. Max 4 iteracje, potem raport co blokuje.
   Na koniec `pkill -x kiwiMango`.
3. Wykonawca: **wyłącznie Sonnet 5** (subagent), główny agent tylko orkiestruje i pokazuje
   Pawłowi screenshot PRZED uznaniem czegokolwiek za gotowe.

## Stan wyjściowy (working tree, NIC nie zacommitowane)

- Amber-cleanup ~180 miejsc (passy 1–3) — zachować
- Przebudowa RootView (NavRow zamiast kafli) + DashboardView flat (hero, włosowate słupki,
  ModelShareRows zamiast donuta) — fundament dobry, wykończenie zepsute

## Znane bugi do naprawy w rundzie 1

1. **Layout ucina zamiast adaptować**: sidebar wystaje poza LEWĄ krawędź okna (labelki obcięte:
   "weł", "ENCI", "HBOARD"), prawa strona dashboardu obcięta. Sidebar = stałe ~230 px od lewej,
   treść elastyczna (maxWidth: .infinity), nic nie wystaje przy szerokości ≥ minWidth 760.
2. **Sidebar znika przy resize** — widoczny tylko w jednej szerokości okna; ma być stały
   (chowany wyłącznie ręcznym toggle, jeśli istnieje).
3. **Sierota**: opis "…pamięci, sesji, zadań cron i Hermesa — natywnie, bez WebView." nadal
   renderowany — usunąć.
4. **"MODEL" pionowo** (M/O/D/E/L) w tabeli per-model — za wąski frame, fixedSize/szerokość.
5. **Paleta za ciemna** — "zjebane czernie, nic nie widać". Tła = ciepły grafit jak referencja
   (okolice #2C2C2E treść, sidebar o ton ciemniejszy), NIE #141414. Dokładny ton zdjąć z obrazu.
   Kontrast tekstu: secondary ≥ 55%.

## Zasady stylu (skrót; rozstrzyga obraz)

- Płasko: zero kart/ramek/cieni; sekcje = odstęp 40–56 px + mały UPPERCASE nagłówek
- Typografia: light/regular, liczby `.monospacedDigit`, etykiety 10.5 px UPPERCASE tracking ~1.5
- Wykresy: słupki 2–3 px wysokie, bez siatki/osi; listy z liniami postępu 2 px
- Kolor TYLKO: słupki, sparkline, badge %, linie postępu, aktywna pozycja nawigacji
- Animacje: wzrost słupków od zera, `.numericText()`, springs, respektować reduceMotion

## Pułapki

1. **Nie ruszać logiki** — store'y, readery, DB, mechanizm przełączania sekcji bez zmian
2. Working tree brudny (F27 + amber-cleanup) — scoped `git add` po plikach, NIGDY `add -A`
3. Dane tylko realne — zero placeholderów i zmyślonych trendów
4. Wątpliwość co do wyglądu → obraz; wątpliwość funkcjonalna → pytanie do Pawła
5. Nie oddawać rundy bez screenshotu — "build zielony" ≠ gotowe
6. Gałąź `archiwum-prywatne` nie istnieje w tym kontekście — pushować tylko main, na prośbę

## Definicja ukończenia

Paweł patrzy na screenshot obok referencji i mówi że pasuje. Dopiero wtedy commit
(scoped, per obszar: layout / paleta / dashboard) i push na prośbę.
