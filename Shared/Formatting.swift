import Foundation

public enum Formatting {
    public static func money(_ amount: Decimal, code: String) -> String {
        amount.formatted(.currency(code: code).precision(.fractionLength(2)))
    }

    /// "Today", "Yesterday", else "Mon, 28 Sep": the heading over a day's
    /// expenses.
    public static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    public static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    /// Start of the month containing `date`, used for grouping and totals.
    public static func monthStart(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    public static func monthRange(containing date: Date, calendar: Calendar = .current) -> Range<Date> {
        let start = monthStart(date, calendar: calendar)
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return start..<end
    }
}
