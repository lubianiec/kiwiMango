import Foundation
import Observation

// MARK: - NBPClient (§6/§11.14 PLAN-V2)
//
// USD/EUR mid rate from NBP (Polish central bank), cached 24h in
// UserDefaults. Offline / no cache yet → nil, never a made-up rate
// (pułapka #14).
@MainActor
@Observable
final class NBPClient {

    private(set) var usdRate: Double?
    private(set) var eurRate: Double?
    private(set) var rateDate: String?

    private let defaults = UserDefaults.standard
    private let cacheKey = "nbpCache"

    private struct Cache: Codable {
        let usd: Double
        let eur: Double
        let date: String
        let fetchedAt: Date
    }

    init() {
        loadCache()
    }

    /// Fetches fresh rates if the cache is older than 24h; otherwise keeps the cached values.
    func refreshIfNeeded() async {
        if let cache = readCache(), Date().timeIntervalSince(cache.fetchedAt) < 86_400 {
            return
        }
        async let usd = fetchRate(code: "usd")
        async let eur = fetchRate(code: "eur")
        let (usdResult, eurResult) = await (usd, eur)
        guard let usdResult, let eurResult else { return } // ponytail: offline → keep whatever cache we had
        let cache = Cache(usd: usdResult.rate, eur: eurResult.rate, date: usdResult.date, fetchedAt: Date())
        writeCache(cache)
        usdRate = cache.usd
        eurRate = cache.eur
        rateDate = cache.date
    }

    private func fetchRate(code: String) async -> (rate: Double, date: String)? {
        guard let url = URL(string: "https://api.nbp.pl/api/exchangerates/rates/a/\(code)/") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let decoded = try? JSONDecoder().decode(NBPResponse.self, from: data),
              let rate = decoded.rates.first else { return nil }
        return (rate.mid, rate.effectiveDate)
    }

    private func loadCache() {
        guard let cache = readCache() else { return }
        usdRate = cache.usd
        eurRate = cache.eur
        rateDate = cache.date
    }

    private func readCache() -> Cache? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func writeCache(_ cache: Cache) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        defaults.set(data, forKey: cacheKey)
    }
}

private struct NBPResponse: Decodable {
    let rates: [Rate]
    struct Rate: Decodable {
        let mid: Double
        let effectiveDate: String
    }
}
