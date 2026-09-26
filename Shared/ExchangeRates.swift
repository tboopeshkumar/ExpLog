import Foundation

/// Rates set by hand in Settings, for counting other currencies in main-currency
/// totals. Written as the main currency to the other: 1 AED = 22.70 INR, so
/// ₹2,500 counts as Ð 110.13.
///
/// One rate per currency, applied to every month: change it and past totals
/// follow. A currency with no rate isn't guessed at — it stays out of the total
/// and is shown beside it until a rate is set.
///
/// Stored per pair ("AED>INR"), so changing the main currency doesn't reuse
/// rates meant for the old one. An inverse pair set earlier still counts.
public struct ExchangeRates: Equatable {
    public let main: String
    /// Units of each other currency per one unit of `main`.
    private let perMain: [String: Decimal]

    public init(main: String, stored: [String: Decimal] = [:]) {
        self.main = main
        var perMain: [String: Decimal] = [:]
        for (pair, rate) in stored where rate > 0 {
            let codes = pair.split(separator: ">").map(String.init)
            guard codes.count == 2 else { continue }
            if codes[0] == main {
                perMain[codes[1]] = rate
            } else if codes[1] == main, perMain[codes[0]] == nil {
                perMain[codes[0]] = 1 / rate
            }
        }
        self.perMain = perMain
    }

    /// From the JSON string they're stored as: {"AED>INR": "22.70"}. Strings,
    /// so no precision is lost to floating point.
    public init(main: String, json: String) {
        let raw = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        self.init(main: main, stored: raw.compactMapValues { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) })
    }

    /// Units of `code` per one unit of main, if set.
    public func rate(for code: String) -> Decimal? {
        code == main ? 1 : perMain[code]
    }

    /// `amount` of `code` in the main currency, or nil when there's no rate.
    public func toMain(_ amount: Decimal, from code: String) -> Decimal? {
        rate(for: code).map { amount / $0 }
    }

    // MARK: - Storage

    public static func pairKey(main: String, other: String) -> String { "\(main)>\(other)" }

    /// `json` with the main→other rate set, or removed when `rate` is nil.
    public static func setting(_ rate: Decimal?, for other: String, main: String, in json: String) -> String {
        var raw = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        let key = pairKey(main: main, other: other)
        raw[key] = rate.flatMap { $0 > 0 ? "\($0)" : nil }
        // Drop the inverse pair, so each pair is defined one way only.
        raw[pairKey(main: other, other: main)] = nil
        let data = (try? JSONEncoder().encode(raw)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
