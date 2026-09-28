import Foundation
import SwiftData

/// The main-currency setting and per-currency totals. Separate from
/// Currency.swift, which stays Foundation-only for the parser's test harness.
extension Currency {

    // MARK: - Main currency

    private static let key = "mainCurrency"

    /// Where the choice is stored. Shared with the share extension through the
    /// App Group when there is one. Replaceable so tests don't depend on the
    /// machine they run on.
    nonisolated(unsafe) public static var defaults: UserDefaults =
        UserDefaults(suiteName: SharedStore.appGroupID).flatMap { SharedStore.isAppGroupAvailable ? $0 : nil }
        ?? .standard

    /// The chosen main currency; otherwise this device's region's, if
    /// supported; otherwise USD. On first launch the app sets it from existing
    /// data instead (`adoptMainIfUnset`), so a year of dirhams stays dirhams.
    public static var main: String {
        if let chosen = defaults.string(forKey: key), supported.contains(chosen) { return chosen }
        if let regional = Locale.current.currency?.identifier, supported.contains(regional) { return regional }
        return fallback
    }

    /// Supported currencies for pickers: the main one, then yours in your
    /// order, then the rest.
    public static var pickerOrder: [String] {
        let top = [main] + yours
        return top + supported.filter { !top.contains($0) }
    }

    // MARK: - Your currencies

    /// The order the other currencies were dragged into in Settings →
    /// Currencies, comma-separated ("INR,USD") so a view can watch it with
    /// @AppStorage.
    public static let orderKey = "currencyOrder"

    /// The other currencies you use, offered right after the main one when
    /// logging an expense.
    public static var yours: [String] {
        yours(order: defaults.string(forKey: orderKey) ?? "", main: main, rates: exchangeRates)
    }

    /// Those arranged in Settings, in that order; then any others with a
    /// rate, or in `alsoUsed` (currencies already spent in), in the usual
    /// order. Never the main currency.
    public static func yours(order: String, main: String, rates: ExchangeRates, alsoUsed: Set<String> = []) -> [String] {
        var arranged: [String] = []
        for code in order.split(separator: ",").map(String.init)
        where supported.contains(code) && code != main && !arranged.contains(code) {
            arranged.append(code)
        }
        let others = supported.filter {
            $0 != main && !arranged.contains($0) && (rates.rate(for: $0) != nil || alsoUsed.contains($0))
        }
        return arranged + others
    }

    /// Stores `codes` as the order of your currencies.
    public static func setOrder(_ codes: [String]) {
        defaults.set(order(codes), forKey: orderKey)
    }

    /// `codes` as stored under `orderKey`.
    public static func order(_ codes: [String]) -> String {
        codes.joined(separator: ",")
    }

    public static func setMain(_ code: String) {
        guard supported.contains(code) else { return }
        defaults.set(code, forKey: key)
    }

    /// First launch after currencies became configurable: take the currency
    /// most existing expenses use, so nothing about the totals changes. A no-op
    /// once a main currency is stored.
    public static func adoptMainIfUnset(from context: ModelContext) {
        guard defaults.string(forKey: key) == nil else { return }
        let codes = ((try? context.fetch(FetchDescriptor<Transaction>())) ?? []).map(\.currencyCode)
        let counted = Dictionary(codes.map { ($0, 1) }, uniquingKeysWith: +)
        if let mostUsed = counted.max(by: { $0.value < $1.value })?.key, supported.contains(mostUsed) {
            setMain(mostUsed)
        }
    }

    // MARK: - Exchange rates

    /// Where the current rates live, as a JSON string (see ExchangeRates).
    /// They're only the default for expenses logged from now on: each expense
    /// stores its own rate when saved.
    public static let exchangeRatesKey = "exchangeRates"

    /// Current rates from the main currency.
    public static var exchangeRates: ExchangeRates {
        ExchangeRates(main: main, json: defaults.string(forKey: exchangeRatesKey) ?? "")
    }

    /// One main-currency total for `transactions`, each converted at the rate
    /// it was logged with. Anything that can't be converted — no stored rate —
    /// is left out and returned per currency, to show beside the total.
    public static func mainTotal(
        of transactions: [Transaction],
        main: String = Currency.main
    ) -> (total: Decimal, unconverted: [Total]) {
        var total = Decimal(0)
        var unconverted: [Transaction] = []
        for transaction in transactions {
            if let value = transaction.amount(in: main) {
                total += value
            } else {
                unconverted.append(transaction)
            }
        }
        return (total, totals(of: unconverted, main: main))
    }

    /// Expenses in `code` that have no rate: logged before one was set, so
    /// they're left out of totals.
    public static func unrated(_ code: String, in transactions: [Transaction]) -> [Transaction] {
        transactions.filter { $0.currencyCode == code && $0.exchangeRate == nil }
    }

    /// Gives those expenses `rate` against `main`. Only ones without a rate:
    /// an expense that already has one keeps it. Returns how many changed.
    @discardableResult
    public static func applyRate(
        _ rate: Decimal,
        toUnrated code: String,
        main: String,
        in transactions: [Transaction]
    ) -> Int {
        guard rate > 0, code != main else { return 0 }
        let targets = unrated(code, in: transactions)
        for transaction in targets {
            transaction.exchangeRate = rate
            transaction.rateBase = main
        }
        return targets.count
    }

    // MARK: - Totals

    public struct Total: Equatable {
        public let code: String
        public let amount: Decimal
        public let count: Int
    }

    /// Per-currency totals, main currency first, then the rest by size. Never
    /// one number across currencies.
    public static func totals(of transactions: [Transaction], main: String = Currency.main) -> [Total] {
        Dictionary(grouping: transactions, by: \.currencyCode)
            .map { code, items in
                Total(code: code, amount: items.reduce(Decimal(0)) { $0 + $1.amount }, count: items.count)
            }
            .sorted { lhs, rhs in
                if (lhs.code == main) != (rhs.code == main) { return lhs.code == main }
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                return lhs.code < rhs.code
            }
    }
}
