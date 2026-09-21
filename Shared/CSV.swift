import Foundation
import SwiftData

/// ExpLog's CSV format, both directions:
///
///     Date,Amount,Currency,Merchant,Category,Account,Note,Reference
///
/// Export keeps the data from being trapped in the app; import restores an
/// export and brings in history converted from elsewhere (see
/// Tools/MoneyManagerImport). Dates are local date-times,
/// "2026-09-20T21:25:42"; plain dates are accepted on import too.
public enum CSV {
    public static let header = ["Date", "Amount", "Currency", "Merchant", "Category", "Account", "Note", "Reference"]

    // MARK: - Export

    public static func write(_ transactions: [Transaction]) throws -> URL {
        var lines = [header.joined(separator: ",")]
        for transaction in transactions.sorted(by: { $0.date > $1.date }) {
            let fields = [
                dateTimeFormatter.string(from: transaction.date),
                "\(transaction.amount)",
                transaction.currencyCode,
                transaction.merchant,
                transaction.category?.name ?? "",
                transaction.account?.name ?? "",
                transaction.note,
                transaction.reference ?? "",
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        let stamp = dateFormatter.string(from: .now)
        let url = FileManager.default.temporaryDirectory.appending(path: "ExpLog-\(stamp).csv")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    // MARK: - Import

    public struct ImportResult: Equatable {
        public var added = 0
        public var duplicates = 0
        /// 1-based line numbers of rows that couldn't be read, with the reason.
        public var rejected: [(line: Int, reason: String)] = []
        public var newCategories: [String] = []
        public var newAccounts: [String] = []

        public static func == (lhs: ImportResult, rhs: ImportResult) -> Bool {
            lhs.added == rhs.added && lhs.duplicates == rhs.duplicates
                && lhs.rejected.map(\.line) == rhs.rejected.map(\.line)
                && lhs.newCategories == rhs.newCategories && lhs.newAccounts == rhs.newAccounts
        }
    }

    public enum ImportError: LocalizedError {
        case unreadable
        case wrongHeader(found: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "The file couldn't be read as UTF-8 text."
            case .wrongHeader(let found):
                return "This isn't an ExpLog CSV. Expected the columns \(header.joined(separator: ", ")); found \(found)."
            }
        }
    }

    /// Adds every row that isn't already in the store. Categories and accounts
    /// are matched by name, ignoring case and surrounding spaces, and created
    /// when missing. Saves once at the end.
    public static func importRows(from text: String, into context: ModelContext) throws -> ImportResult {
        let rows = parse(text)
        guard let first = rows.first else { return ImportResult() }
        let found = first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard found.prefix(header.count).map({ $0.lowercased() }) == header.map({ $0.lowercased() }) else {
            throw ImportError.wrongHeader(found: found.joined(separator: ", "))
        }

        var result = ImportResult()
        var categories = Dictionary(
            ((try? context.fetch(FetchDescriptor<ExpenseCategory>())) ?? []).map { (key($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var accounts = Dictionary(
            ((try? context.fetch(FetchDescriptor<Account>())) ?? []).map { (key($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var nextSortOrder = (categories.values.map(\.sortOrder).max() ?? -1) + 1
        let alreadyStored = ExistingIndex(context: context)

        for (index, fields) in rows.dropFirst().enumerated() {
            let line = index + 2
            if fields.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            let field = { (i: Int) in i < fields.count ? fields[i].trimmingCharacters(in: .whitespaces) : "" }

            guard let date = parseDate(field(0)) else {
                result.rejected.append((line, "unreadable date \"\(field(0))\""))
                continue
            }
            guard let amount = Decimal(string: field(1), locale: Locale(identifier: "en_US_POSIX")), amount > 0 else {
                result.rejected.append((line, "unreadable amount \"\(field(1))\""))
                continue
            }
            let merchant = field(3)
            guard !merchant.isEmpty else {
                result.rejected.append((line, "no merchant"))
                continue
            }

            let currencyCode = field(2).isEmpty ? "AED" : field(2).uppercased()
            let reference = field(7).isEmpty ? nil : field(7)

            if alreadyStored.contains(merchant: merchant, amount: amount, date: date, reference: reference) {
                result.duplicates += 1
                continue
            }

            var category: ExpenseCategory?
            if !field(4).isEmpty {
                if let existing = categories[key(field(4))] {
                    category = existing
                } else {
                    let created = ExpenseCategory(
                        name: field(4),
                        symbol: symbolsForNewCategories[key(field(4))] ?? "tag",
                        sortOrder: nextSortOrder
                    )
                    nextSortOrder += 1
                    context.insert(created)
                    categories[key(field(4))] = created
                    result.newCategories.append(field(4))
                    category = created
                }
            }

            var account: Account?
            if !field(5).isEmpty {
                if let existing = accounts[key(field(5))] {
                    account = existing
                } else {
                    let created = Account(name: field(5))
                    context.insert(created)
                    accounts[key(field(5))] = created
                    result.newAccounts.append(field(5))
                    account = created
                }
            }

            context.insert(Transaction(
                amount: amount,
                currencyCode: currencyCode,
                date: date,
                merchant: merchant,
                note: field(6),
                reference: reference,
                category: category,
                account: account
            ))
            result.added += 1
        }

        try context.save()
        return result
    }

    /// A snapshot of what was stored before an import began, for spotting rows
    /// already there. Uses the same rule as TransactionDraft.duplicate — same
    /// bank reference, or same merchant and amount within five minutes.
    ///
    /// Taken once up front rather than queried per row: that's what keeps a
    /// year of history (1,400 rows) from freezing the screen. And because it's a
    /// snapshot, rows added by this import never count against each other — two
    /// rows in one file are two records, even a pair of identical taxi fares.
    private struct ExistingIndex {
        private var references: Set<String> = []
        private var dates: [String: [Date]] = [:]

        init(context: ModelContext) {
            for transaction in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] {
                if let reference = transaction.reference, !reference.isEmpty {
                    references.insert(reference)
                }
                dates[Self.key(transaction.merchant, transaction.amount), default: []].append(transaction.date)
            }
        }

        func contains(merchant: String, amount: Decimal, date: Date, reference: String?) -> Bool {
            if let reference, references.contains(reference) { return true }
            return dates[Self.key(merchant, amount)]?.contains { abs($0.timeIntervalSince(date)) <= 300 } ?? false
        }

        private static func key(_ merchant: String, _ amount: Decimal) -> String {
            "\(merchant)\u{1F}\(amount)"
        }
    }

    /// Icons for categories an import commonly brings in that ExpLog doesn't
    /// seed. Anything else starts with the generic tag, editable later.
    private static let symbolsForNewCategories: [String: String] = [
        "education": "book",
        "household": "sofa",
        "rent": "house",
    ]

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Parsing

    /// RFC 4180 CSV: quoted fields may contain commas, quotes (doubled) and
    /// line breaks. Accepts \n, \r\n and \r line endings, and a leading BOM.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        chars.append("\n")   // flushes a final line without a trailing newline

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    row.append(field)
                    field = ""
                case "\n", "\r", "\r\n":
                    // Swift treats "\r\n" as one Character; a lone \r ends a line too.
                    row.append(field)
                    field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        return rows
    }

    private static func parseDate(_ text: String) -> Date? {
        dateTimeFormatter.date(from: text) ?? dateFormatter.date(from: text)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
