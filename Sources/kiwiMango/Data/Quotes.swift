import Foundation

// MARK: - Quote (PLAN-DASHBOARD-QUOTES.md — Fala 2)

struct Quote: Equatable {
    let text: String
    let author: String
}

enum Quotes {
    /// Lista offline — WKLEJONA 1:1 z planu, zero własnych cytatów, zero zmian.
    /// Używana jako fallback gdy API Bonjourr nie odpowie (patrz `QuoteProvider`).
    static let fallback: [Quote] = [
        Quote(text: "Wiem, że nic nie wiem.", author: "Sokrates"),
        Quote(text: "Myślę, więc jestem.", author: "Kartezjusz"),
        Quote(text: "Nie można dwa razy wejść do tej samej rzeki.", author: "Heraklit"),
        Quote(text: "Los prowadzi tego, kto chce, a ciągnie tego, kto się opiera.", author: "Seneka"),
        Quote(text: "Nie dlatego nie odważamy się, że jest trudno; jest trudno dlatego, że się nie odważamy.", author: "Seneka"),
        Quote(text: "Masz władzę nad swoim umysłem, nie nad zewnętrznymi wydarzeniami. Uświadom to sobie, a znajdziesz siłę.", author: "Marek Aureliusz"),
        Quote(text: "Nie rzeczy nas martwią, lecz nasze mniemania o rzeczach.", author: "Epiktet"),
        Quote(text: "Kropla drąży skałę nie siłą, lecz częstym padaniem.", author: "Owidiusz"),
        Quote(text: "Podróż tysiąca mil zaczyna się od jednego kroku.", author: "Laozi"),
        Quote(text: "Poznaj wroga i poznaj siebie, a w stu bitwach nie doznasz klęski.", author: "Sun Zi"),
        Quote(text: "Człowiek, który popełnił błąd i go nie naprawił, popełnia drugi błąd.", author: "Konfucjusz"),
        Quote(text: "Serce ma swoje racje, których rozum nie zna.", author: "Blaise Pascal"),
        Quote(text: "Niebo gwiaździste nade mną, prawo moralne we mnie.", author: "Immanuel Kant"),
        Quote(text: "Lepsze jest wrogiem dobrego.", author: "Wolter"),
        Quote(text: "Co mnie nie zabije, to mnie wzmocni.", author: "Friedrich Nietzsche"),
        Quote(text: "Jeśli widziałem dalej, to dlatego, że stałem na ramionach olbrzymów.", author: "Isaac Newton"),
        Quote(text: "Wyobraźnia jest ważniejsza od wiedzy.", author: "Albert Einstein"),
        Quote(text: "Niczego w życiu nie należy się bać, należy to tylko zrozumieć.", author: "Maria Skłodowska-Curie"),
        Quote(text: "Jestem z tych, którzy wierzą, że nauka jest czymś bardzo pięknym.", author: "Maria Skłodowska-Curie"),
        Quote(text: "Pierwsza zasada: nie wolno oszukiwać samego siebie, a siebie oszukać najłatwiej.", author: "Richard Feynman"),
        Quote(text: "Nie poniosłem porażki. Odkryłem po prostu dziesięć tysięcy sposobów, które nie działają.", author: "Thomas Edison"),
        Quote(text: "Człowiek z nowym pomysłem jest dziwakiem, dopóki pomysł nie zwycięży.", author: "Mark Twain"),
        Quote(text: "Jedyny sposób, by robić wielkie rzeczy, to kochać to, co się robi.", author: "Steve Jobs"),
        Quote(text: "Dobrze widzi się tylko sercem. Najważniejsze jest niewidoczne dla oczu.", author: "Antoine de Saint-Exupéry"),
        Quote(text: "Nie wszyscy, którzy błądzą, są zgubieni.", author: "J.R.R. Tolkien"),
        Quote(text: "W środku zimy odkryłem w sobie niezwyciężone lato.", author: "Albert Camus"),
        Quote(text: "Nie bój się doskonałości — i tak jej nie osiągniesz.", author: "Salvador Dalí"),
        Quote(text: "Nic dwa razy się nie zdarza i nie zdarzy.", author: "Wisława Szymborska"),
        Quote(text: "Tyle wiemy o sobie, ile nas sprawdzono.", author: "Wisława Szymborska"),
        Quote(text: "Bądź wierny. Idź.", author: "Zbigniew Herbert"),
        Quote(text: "Piękno na to jest, by zachwycało do pracy.", author: "Cyprian Kamil Norwid"),
        Quote(text: "Nie ma dzieci — są ludzie.", author: "Janusz Korczak"),
        Quote(text: "Dopóki nie skorzystałem z internetu, nie wiedziałem, że na świecie jest tylu idiotów.", author: "Stanisław Lem"),
        Quote(text: "Niejeden bumerang nie wraca. Wybiera wolność.", author: "Stanisław Jerzy Lec"),
        Quote(text: "Wszystko jest w rękach człowieka. Dlatego należy je często myć.", author: "Stanisław Jerzy Lec"),
        Quote(text: "Gdy plotka się starzeje, staje się mitem.", author: "Stanisław Jerzy Lec"),
        Quote(text: "Podróż nie zaczyna się w momencie, kiedy ruszamy w drogę, i nie kończy się, kiedy dotarliśmy do mety.", author: "Ryszard Kapuściński"),
    ]
}

// MARK: - QuoteProvider — API Bonjourr + cichy fallback offline

/// Jeden fetch na uruchomienie appki (cache w pamięci, nie na dysku — ponytail:
/// dopisać cache na dysku dopiero gdyby Paweł chciał cytaty offline od startu).
/// Błąd sieci/timeout/pusta odpowiedź → cicho fallback do `Quotes.fallback`,
/// hero nigdy nie jest puste i nigdy nie pokazuje błędu.
@MainActor
final class QuoteProvider {
    static let shared = QuoteProvider()
    private var cached: [Quote]?
    private var lastText: String?

    func nextQuote() async -> Quote {
        if cached == nil { cached = await Self.fetchBonjourr() }
        let pool = (cached?.isEmpty == false) ? cached! : Quotes.fallback
        var pick = pool.randomElement()!
        if pool.count > 1 {
            while pick.text == lastText { pick = pool.randomElement()! }
        }
        lastText = pick.text
        return pick
    }

    private static func fetchBonjourr() async -> [Quote] {
        struct Item: Decodable { let author: String; let content: String }
        guard let url = URL(string: "https://api.bonjourr.fr/quotes/classic/pl") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let items = try? JSONDecoder().decode([Item].self, from: data), !items.isEmpty
        else { return [] }
        return items.map { Quote(text: $0.content, author: $0.author) }
    }
}
