import Foundation

/// Month-by-month navigation: which months have expenses, how far the
/// switcher's arrows may go, and one month's expenses grouped by day.
///
/// Pure functions over already-fetched transactions, so the Mac test suite
/// covers them.
public enum MonthIndex {

    public struct Month: Identifiable {
        public let start: Date
        public let count: Int
        /// In the main currency, other currencies at their logged rates.
        public let total: Decimal
        /// Spending that couldn't be converted (no rate), per currency.
        public let unconverted: [Currency.Total]

        public var id: Date { start }
    }

    /// Every month with at least one expense, newest first — the jump list.
    public static func months(
        of transactions: [Transaction],
        mainCurrency: String = Currency.main,
        calendar: Calendar = .current
    ) -> [Month] {
        Dictionary(grouping: transactions) { Formatting.monthStart($0.date, calendar: calendar) }
            .map { start, items in
                let result = Currency.mainTotal(of: items, main: mainCurrency)
                return Month(start: start, count: items.count, total: result.total, unconverted: result.unconverted)
            }
            .sorted { $0.start > $1.start }
    }

    /// The months the arrows can reach: from the earliest month with expenses
    /// to this month — or further, when there are future-dated expenses such
    /// as instalments. With no expenses at all, just this month.
    public static func bounds(
        earliest: Date?,
        latest: Date?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> ClosedRange<Date> {
        let thisMonth = Formatting.monthStart(now, calendar: calendar)
        let first = earliest.map { min(Formatting.monthStart($0, calendar: calendar), thisMonth) } ?? thisMonth
        let last = latest.map { max(Formatting.monthStart($0, calendar: calendar), thisMonth) } ?? thisMonth
        return first...last
    }

    /// `month` moved by `offset` months, kept within `bounds`.
    public static func step(
        _ month: Date,
        by offset: Int,
        within bounds: ClosedRange<Date>,
        calendar: Calendar = .current
    ) -> Date {
        guard let moved = calendar.date(byAdding: .month, value: offset, to: month) else { return month }
        return min(max(Formatting.monthStart(moved, calendar: calendar), bounds.lowerBound), bounds.upperBound)
    }

    /// One month's expenses grouped by day, newest day first, each day's
    /// expenses newest first.
    public static func days(
        of transactions: [Transaction],
        calendar: Calendar = .current
    ) -> [(day: Date, items: [Transaction])] {
        Dictionary(grouping: transactions) { calendar.startOfDay(for: $0.date) }
            .map { (day: $0.key, items: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }
}
