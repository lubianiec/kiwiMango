# kiwiMango — Kolejka po F26, wykonanie: `glm-5.2:cloud`

> Osobny plan (nie miesza się z `PLAN.md`, ale czyta z niego zakres i STOP-gate'y).
> Model wykonawczy: **`glm-5.2:cloud`** (756B/40B aktywnych, agentic/coding SOTA,
> ~976K kontekst — zastępuje deepseek-v4-pro jako najmocniejszy cloud na Ollama,
> zweryfikowane 2026-07-08). Powód zmiany: duży kontekst = mniej ucinania przy
> czytaniu całego PLAN.md + kodu appki naraz; agentic-first = lepszy do
> wieloplikowych edycji Swift niż ogólne modele chat.
>
> Zasada jak zawsze: **zero kodu przed Twoją akceptacją tego planu.** Każdy
> punkt niżej to osobna mini-fala z własnym STOP-gate i `make install` +
> Twoje potwierdzenie na żywo — dokładnie jak F25/F26 dotąd.
>
> Pominięte celowo (zawieszone przez Ciebie, nie ruszać bez wyraźnego polecenia):
> **F20, F23, F16, F27** (cały F27 — mózg z vaulta, OCR/PDF, licznik kosztów —
> zostaje "na później").

---

## Kolejność wykonania

### Runda 1 — najtańsze, największy zwrot
1. **25.6** 🛡️ Approval z uzasadnieniem ryzyka
2. **26.6** 🪪 Tożsamość nadawcy (ikona/kolor user/model/narzędzie/subagent)
3. **26.10** 🎴 Kiwi-cards polish (mikro-animacja wejścia, ikony kolorowane)

### Runda 2 — jakość czatu (reszta 26.1/26.2/26.5)
4. **26.5 (reszta)** 🌊 Smooth reflow + wizualne oddzielenie MYŚLI od odpowiedzi
   (kursor już zrobiony w 26.14 — pomiń tę część)
5. **26.1** 📐 Sticky scroll-to-bottom, grupowanie wiadomości w czasie, empty
   state z sugestiami promptów (max-width już zrobiony w 26.13 — pomiń)
6. **26.2** ✍️ Markdown/typografia domknięcie — **hover-fetch linków (favicon+
   tytuł) TYLKO lazy on-hover, cache, timeout 1s, failure = goły URL, zero
   fetchy przy renderze historii** (pułapka z recenzji Fable)

### Runda 3 — media i dane
7. **26.8** 🖼️ Lightbox obrazów (pinch/scroll-zoom, nawigacja strzałkami),
   miniatury blur-up, progress-ring
8. **26.7** 📊 Tabele — **STOP-gate: 1-dniowy spike custom Grid vs SwiftUI
   `Table` PRZED kodowaniem docelowym** (Table to komponent do list danych,
   może walczyć z layoutem dymka). Sortowanie = nice-to-have, nie wymóg.

### Runda 4 — agentowe (większe, po jakości czatu)
9. **25.3** 🧠 Agent z pamięcią projektu per-rozmowa (notatka kontekstu
   edytowalna + auto-propozycja dopisania po ważnym ustaleniu)
10. **25.2** ⚔️ Multi-agent debata / "drugie zdanie" (split-view dwóch modeli
    + opcjonalny sędzia)
11. **25.5** 👁️ Agent-obserwator folderu — **domyślnie OFF, jeden folder na
    start, digest zamiast pojedynczych pingów** (Paweł historycznie wyłącza
    powiadomienia — nie łamać tego wzorca)

### Runda 5 — sprzątanie zakresu (małe, przy okazji)
12. **25.4** 📝 Auto-TL;DR — **scalić z F21.3** (już zrobione ucinanie do 30
    wiadomości), dopisać TYLKO generowanie streszczenia jako "wiadomość
    systemowa" zastępująca ucięte, nie osobny system
13. **25.7** 📚 Marketplace promptów — **NIE nowy system.** Rozszerzyć
    Persony (F2.2) o gotowy zestaw startowy (code-review, research-mode,
    debug-mode, ELI5, tłumacz) + przycisk w composerze. Sejf promptów (F11)
    zostaje osobno.
14. **26.12 (okrojone)** 🎨 TYLKO audyt hover-states na całym drzewie widoków
    + dedykowane puste stany. **Bez jasnego motywu** — kiwiMango to
    tożsamościowo neon-na-czerni, drugi design system = drugi koszt
    utrzymania na zawsze.

---

## Wyrzucone z kolejki (nie odgrzewać bez nowej decyzji Pawła)
- **25.9** Agent-łańcuch — Hermes już robi wieloetapowe zadania z polecenia
  naturalnego; edytor workflow to appka-w-appce.
- **25.10** Self-critique pass — podwójny koszt/czas na każdą odpowiedź;
  jak temat jakości wróci, lepszy jest przycisk "⚔️ drugie zdanie" (25.2).
- **25.8** Sterowanie głosowe w tle — zależy od F23 (zawieszona).

---

## Definition of Done (per punkt, nie całej rundy naraz)
Jak w F25/F26: własny STOP-gate na starcie, `make install`, potwierdzenie
Pawła na żywo (zrzut ekranu + krótki test interakcji, nie tylko "kompiluje
się"). Priorytet w obrębie rundy — do Twojego uznania przy starcie każdej.

## Po zakończeniu tej kolejki
→ **F28** — README.md od zera (ostatni krok całej serii, screenshots
finalnego UI). F27 wraca do gry tylko na wyraźne polecenie.
