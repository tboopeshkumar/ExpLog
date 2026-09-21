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
    public let total: Decimal
    public let count: Int
    /// Currency to display the totals in. Like the list's month totals, this
    /// assumes a month is single-currency and takes the first transaction's.
    public let currencyCode: String
    /// Largest first; uncategorised spending is its own row.
    public let rows: [Row]

    public init(month: Date, transactions: [Transaction], calendar: Calendar = .current) {
        let range = Formatting.monthRange(containing: month, calendar: calendar)
        let inMonth = transactions.filter { range.contains($0.date) }

        self.month = range.lowerBound
        self.total = inMonth.reduce(Decimal(0)) { $0 + $1.amount }
        self.count = inMonth.count
        self.currencyCode = inMonth.first?.currencyCode ?? "AED"

        let grouped = Dictionary(grouping: inMonth) { $0.category?.persistentModelID }
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
