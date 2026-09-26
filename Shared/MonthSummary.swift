import Foundation
import SwiftData

/// Spending in one month, broken down by category.
///
/// Pure aggregation over transactions already fetched, so it's covered by the
/// Mac test suite (Tools/StoreCheck) rather than only by looking at a screen.
public struct MonthSummary {
    public struct Row: Identifiable {
        /// nil for transactions with no category.
        public let category: ExpenseCategory?
        public let amount: Decimal
        public let count: Int
        /// Fraction of the month's total, 0...1.
        public let share: Double

        public var id: PersistentIdentifier? { category?.persistentModelID }
    }

    public let month: Date
    /// Spending in the main currency, other currencies converted at the rate
    /// each was logged with.
    public let total: Decimal
    /// Every expense in the month, whatever its currency.
    public let count: Int
    /// The main currency: what `total` and `rows` are in.
    public let currencyCode: String
    /// Largest first; uncategorised spending is its own row. In the main
    /// currency, so the shares compare like with like.
    public let rows: [Row]
    /// Spending that couldn't be converted (logged without a rate), per
    /// currency — shown beside the total, not in it.
    public let otherCurrencies: [Currency.Total]

    public init(
        month: Date,
        transactions: [Transaction],
        mainCurrency: String = Currency.main,
        calendar: Calendar = .current
    ) {
        let range = Formatting.monthRange(containing: month, calendar: calendar)
        let inMonth = transactions.filter { range.contains($0.date) }
        let converted = inMonth.compactMap { t in t.amount(in: mainCurrency).map { (t, $0) } }

        self.month = range.lowerBound
        self.total = converted.reduce(Decimal(0)) { $0 + $1.1 }
        self.count = inMonth.count
        self.currencyCode = mainCurrency
        self.otherCurrencies = Currency.mainTotal(of: inMonth, main: mainCurrency).unconverted

        let grouped = Dictionary(grouping: converted) { $0.0.category?.persistentModelID }
        let total = self.total
        self.rows = grouped.values
            .map { pairs in
                let items = pairs.map(\.0)
                let amount = pairs.reduce(Decimal(0)) { $0 + $1.1 }
                let share = total > 0
                    ? NSDecimalNumber(decimal: amount / total).doubleValue
                    : 0
                return Row(category: items.first?.category, amount: amount, count: items.count, share: share)
            }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                // Stable order for ties: named categories by name, uncategorised last.
                switch (lhs.category, rhs.category) {
                case let (l?, r?): return l.name < r.name
                case (_?, nil): return true
                default: return false
                }
            }
    }

    public var isEmpty: Bool { count == 0 }
}

/// One category's spending split by subcategory, for the Summary drill-down.
/// Expenses without a subcategory form their own row, so the rows always add
/// up to the category's total.
public struct SubcategoryBreakdown {
    public struct Row: Identifiable {
        /// nil for the category's expenses with no subcategory.
        public let subcategory: ExpenseSubcategory?
        public let amount: Decimal
        public let count: Int
        public let share: Double

        public var id: PersistentIdentifier? { subcategory?.persistentModelID }
    }

    public let rows: [Row]

    /// `transactions` should already be one category's, for one month. In the
    /// main currency, others at the rate each was logged with; ones without a
    /// rate are left out.
    public init(transactions: [Transaction], mainCurrency: String = Currency.main) {
        let converted = transactions.compactMap { t in t.amount(in: mainCurrency).map { (t, $0) } }
        let total = converted.reduce(Decimal(0)) { $0 + $1.1 }
        rows = Dictionary(grouping: converted) { $0.0.subcategory?.persistentModelID }
            .values
            .map { pairs in
                let items = pairs.map(\.0)
                let amount = pairs.reduce(Decimal(0)) { $0 + $1.1 }
                let share = total > 0 ? NSDecimalNumber(decimal: amount / total).doubleValue : 0
                return Row(subcategory: items.first?.subcategory, amount: amount, count: items.count, share: share)
            }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                switch (lhs.subcategory, rhs.subcategory) {
                case let (l?, r?): return l.name < r.name
                case (_?, nil): return true
                default: return false
                }
            }
    }

    /// Only worth a section when at least one expense has a subcategory; a
    /// single "No subcategory" row would say nothing.
    public var isWorthShowing: Bool {
        rows.contains { $0.subcategory != nil }
    }
}

/// Spending grouped by merchant, largest first — for the Summary's merchant
/// view and a category's drill-down.
///
/// Merchant names are grouped by a normalised key, ignoring case and extra
/// spaces, so "LULU Hypermarket" and "Lulu  hypermarket" are one row, shown
/// under whichever spelling is most common. Different names stay apart —
/// "Lulu" and "Lulu Center" may well be different shops, and merging on a
/// guess would be worse than two rows. In the main currency, like the other
/// breakdowns, so the shares compare like with like.
public struct MerchantBreakdown {
    public struct Row: Identifiable {
        public let key: String
        public let name: String
        public let amount: Decimal
        public let count: Int
        public let share: Double
        /// The category most of this merchant's expenses are in, for its icon.
        public let category: ExpenseCategory?

        public var id: String { key }
    }

    public let rows: [Row]

    public init(transactions: [Transaction], mainCurrency: String = Currency.main) {
        let converted = transactions.compactMap { t in t.amount(in: mainCurrency).map { (t, $0) } }
        let total = converted.reduce(Decimal(0)) { $0 + $1.1 }
        rows = Dictionary(grouping: converted) { Self.key(for: $0.0.merchant) }
            .map { key, pairs in
                let items = pairs.map(\.0)
                let amount = pairs.reduce(Decimal(0)) { $0 + $1.1 }
                return Row(
                    key: key,
                    name: Self.mostCommon(items.map { Self.tidy($0.merchant) }) ?? "Unnamed",
                    amount: amount,
                    count: items.count,
                    share: total > 0 ? NSDecimalNumber(decimal: amount / total).doubleValue : 0,
                    category: Self.mostCommonCategory(of: items)
                )
            }
            .sorted { lhs, rhs in
                if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// The grouping key: lower-cased, spaces collapsed.
    public static func key(for merchant: String) -> String {
        tidy(merchant).lowercased()
    }

    private static func tidy(_ merchant: String) -> String {
        merchant.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Most frequent value; `max(by:)` keeps the first of equals, so ties go
    /// to the first seen.
    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return values.max { counts[$0]! < counts[$1]! }
    }

    private static func mostCommonCategory(of items: [Transaction]) -> ExpenseCategory? {
        let categorised = items.compactMap(\.category)
        var counts: [PersistentIdentifier: Int] = [:]
        for category in categorised { counts[category.persistentModelID, default: 0] += 1 }
        return categorised.max { counts[$0.persistentModelID]! < counts[$1.persistentModelID]! }
    }
}
