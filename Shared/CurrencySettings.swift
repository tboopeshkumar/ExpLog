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

    /// Supported currencies with the main one first, for pickers.
    public static var pickerOrder: [String] {
        [main] + supported.filter { $0 != main }
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
