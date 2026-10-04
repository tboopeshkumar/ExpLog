import Foundation

/// What the Expenses search matches. Every word typed must match something
/// about the expense: its merchant, note, category or subcategory, card,
/// reference or currency; "uncategorised"; an amount ("72" for 72.xx, "72.5"
/// for 72.5x); a month's name ("sep", "september") or a year.
///
/// An expense is boiled down to an `Entry` once, when search opens, so each
/// keystroke only compares strings — reading every expense's fields and
/// formatting its date on every keystroke made typing lag behind.
public enum ExpenseSearch {

    /// What's searchable about one expense, ready to compare.
    public struct Entry: Sendable {
        /// The text fields, lowercased, separated by newlines.
        let text: String
        /// "72.57"
        let amount: String
        /// 1...12
        let month: Int
        let year: Int
        let isUncategorised: Bool
    }

    /// The words of a query, lowercased.
    public static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func entry(for transaction: Transaction, calendar: Calendar = .current) -> Entry {
        let parts = calendar.dateComponents([.year, .month], from: transaction.date)
        let text = [
            transaction.merchant, transaction.note,
            transaction.category?.name, transaction.subcategory?.name,
            transaction.account?.name, transaction.reference, transaction.currencyCode,
        ].compactMap { $0 }.joined(separator: "\n").lowercased()
        return Entry(
            text: text,
            amount: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"),
                           NSDecimalNumber(decimal: transaction.amount).doubleValue),
            month: parts.month ?? 0,
            year: parts.year ?? 0,
            isUncategorised: transaction.category == nil
        )
    }

    /// True when every token matches the entry. No tokens match nothing.
    public static func matches(_ entry: Entry, tokens: [String]) -> Bool {
        !tokens.isEmpty && tokens.allSatisfy { matches(entry, token: $0) }
    }

    /// One-off form, for a single expense.
    public static func matches(_ transaction: Transaction, query: String, calendar: Calendar = .current) -> Bool {
        matches(entry(for: transaction, calendar: calendar), tokens: tokens(query))
    }

    static func matches(_ entry: Entry, token: String) -> Bool {
        if entry.text.contains(token) { return true }

        // "uncat…" finds what still needs a category, either spelling.
        if entry.isUncategorised, token.count >= 5,
           "uncategorised".hasPrefix(token) || "uncategorized".hasPrefix(token) { return true }

        if matchesAmount(entry.amount, token: token) { return true }

        // A four-digit year, or a month by its full name or abbreviation.
        if token.count == 4, let year = Int(token) { return entry.year == year }
        guard token.count >= 3, (1...12).contains(entry.month) else { return false }
        return monthNames[entry.month - 1].contains(token)
    }

    /// "72" matches 72.00 and 72.57 but not 720; "72.5" matches 72.50–72.59.
    /// `amount` is written to two decimals.
    static func matchesAmount(_ amount: String, token: String) -> Bool {
        let typed = token.replacingOccurrences(of: ",", with: ".")
        guard typed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              typed.contains(where: \.isNumber) else { return false }
        if typed.contains(".") { return amount.hasPrefix(typed) }
        return amount.split(separator: ".").first.map { $0 == typed } ?? false
    }

    /// Each month's names, lowercased: English and the device's language,
    /// full and abbreviated. Built once.
    private static let monthNames: [Set<String>] = {
        var names = Array(repeating: Set<String>(), count: 12)
        for locale in [Locale(identifier: "en_US_POSIX"), Locale.current] {
            let formatter = DateFormatter()
            formatter.locale = locale
            for symbols in [formatter.monthSymbols ?? [], formatter.shortMonthSymbols ?? []] {
                for (index, name) in symbols.prefix(12).enumerated() {
                    names[index].insert(name.lowercased().trimmingCharacters(in: .punctuationCharacters))
                }
            }
        }
        names[8].insert("sept")
        return names
    }()
}
