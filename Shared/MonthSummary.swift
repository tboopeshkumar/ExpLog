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
    /// Spending in the main currency. Other currencies are never added in.
    public let total: Decimal
    /// Every expense in the month, whatever its currency.
    public let count: Int
    /// The main currency: what `total` and `rows` are in.
    public let currencyCode: String
    /// Largest first; uncategorised spending is its own row. Main currency
    /// only, so the shares compare like with like.
    public let rows: [Row]
    /// Spending in other currencies, per currency — shown beside the total,
    /// not in it.
    public let otherCurrencies: [Currency.Total]

    public init(
        month: Date,
        transactions: [Transaction],
        mainCurrency: String = Currency.main,
        calendar: Calendar = .current
    ) {
        let range = Formatting.monthRange(containing: month, calendar: calendar)
        let inMonth = transactions.filter { range.contains($0.date) }
        let inMain = inMonth.filter { $0.currencyCode == mainCurrency }

        self.month = range.lowerBound
        self.total = inMain.reduce(Decimal(0)) { $0 + $1.amount }
        self.count = inMonth.count
        self.currencyCode = mainCurrency
        self.otherCurrencies = Currency.totals(of: inMonth.filter { $0.currencyCode != mainCurrency }, main: mainCurrency)

        let grouped = Dictionary(grouping: inMain) { $0.category?.persistentModelID }
        let total = self.total
        self.rows = grouped.values
            .map { items in
                let amount = items.reduce(Decimal(0)) { $0 + $1.amount }
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

    /// `transactions` should already be one category's, for one month. Only
    /// the main currency's are counted, so the shares compare like with like.
    public init(transactions: [Transaction], mainCurrency: String = Currency.main) {
        let transactions = transactions.filter { $0.currencyCode == mainCurrency }
        let total = transactions.reduce(Decimal(0)) { $0 + $1.amount }
        rows = Dictionary(grouping: transactions) { $0.subcategory?.persistentModelID }
            .values
            .map { items in
                let amount = items.reduce(Decimal(0)) { $0 + $1.amount }
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
