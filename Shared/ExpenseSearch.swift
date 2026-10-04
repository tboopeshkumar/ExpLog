import Foundation

/// What the Expenses search matches. Every word typed must match something
/// about the expense: its merchant, note, category or subcategory, card,
/// reference or currency; "uncategorised"; an amount ("72" for 72.xx, "72.5"
/// for 72.5x); a month's name ("sep", "september") or a year.
public enum ExpenseSearch {

    /// The words of a query, lowercased.
    public static func tokens(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func matches(_ transaction: Transaction, query: String, calendar: Calendar = .current) -> Bool {
        let tokens = tokens(query)
        return !tokens.isEmpty && tokens.allSatisfy { matches(transaction, token: $0, calendar: calendar) }
    }

    static func matches(_ transaction: Transaction, token: String, calendar: Calendar) -> Bool {
        let texts = [
            transaction.merchant, transaction.note,
            transaction.category?.name, transaction.subcategory?.name,
            transaction.account?.name, transaction.reference, transaction.currencyCode,
        ]
        if texts.contains(where: { $0?.lowercased().contains(token) ?? false }) { return true }

        // "uncat…" finds what still needs a category, either spelling.
        if transaction.category == nil, token.count >= 5,
           "uncategorised".hasPrefix(token) || "uncategorized".hasPrefix(token) { return true }

        if matchesAmount(transaction.amount, token: token) { return true }
        return matchesDate(transaction.date, token: token, calendar: calendar)
    }

    /// "72" matches 72.00 and 72.57 but not 720; "72.5" matches 72.50–72.59.
    static func matchesAmount(_ amount: Decimal, token: String) -> Bool {
        let typed = token.replacingOccurrences(of: ",", with: ".")
        guard !typed.isEmpty, typed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              typed.contains(where: \.isNumber) else { return false }
        let plain = NSDecimalNumber(decimal: amount).doubleValue
        let twoDecimals = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), plain)
        if typed.contains(".") { return twoDecimals.hasPrefix(typed) }
        return twoDecimals.split(separator: ".").first.map(String.init) == typed
    }

    /// A month by its full name or usual abbreviation, or a four-digit year.
    static func matchesDate(_ date: Date, token: String, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month], from: date)
        if token.count == 4, let year = Int(token) { return parts.year == year }
        guard let month = parts.month, token.count >= 3 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var names = [formatter.monthSymbols[month - 1], formatter.shortMonthSymbols[month - 1]]
        formatter.locale = .current
        names += [formatter.monthSymbols[month - 1], formatter.shortMonthSymbols[month - 1]]
        if month == 9 { names.append("sept") }
        return names.contains { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) == token }
    }
}
