import Foundation
import SwiftData

/// ExpLog's CSV format, both directions:
///
///     Date,Amount,Currency,Merchant,Category,Account,Note,Reference,Subcategory
///
/// Subcategory came later, so it's last and optional on import: files from
/// before it still read.
/// Export keeps the data from being trapped in the app; import restores an
/// export and brings in history converted from elsewhere (see
/// Tools/MoneyManagerImport). Dates are local date-times,
/// "2026-09-20T21:25:42"; plain dates are accepted on import too.
public enum CSV {
    public static let header = ["Date", "Amount", "Currency", "Merchant", "Category", "Account", "Note", "Reference", "Subcategory"]
    /// Columns every file must have; Subcategory may be missing.
    private static let requiredColumns = 8

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
                transaction.subcategory?.name ?? "",
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
        /// "Transport › Taxi".
        public var newSubcategories: [String] = []
        /// Expenses already stored that gained a subcategory from the file.
        public var filledSubcategories = 0
        public var newAccounts: [String] = []

        public static func == (lhs: ImportResult, rhs: ImportResult) -> Bool {
            lhs.added == rhs.added && lhs.duplicates == rhs.duplicates
                && lhs.rejected.map(\.line) == rhs.rejected.map(\.line)
                && lhs.newCategories == rhs.newCategories && lhs.newAccounts == rhs.newAccounts
                && lhs.newSubcategories == rhs.newSubcategories
                && lhs.filledSubcategories == rhs.filledSubcategories
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
                return "This isn't an ExpLog CSV. Expected the columns \(header.prefix(requiredColumns).joined(separator: ", ")); found \(found)."
            }
        }
    }

    /// Adds every row that isn't already in the store. Categories and accounts
    /// are matched by name, ignoring case and surrounding spaces, and created
    /// when missing. Saves once at the end.
    ///
    /// A row that is already stored adds nothing — but if it carries a
    /// subcategory and the stored expense has none, the stored one gains it.
    /// That's how history imported before subcategories existed gets them:
    /// import the same data again, with the column. Only when the stored
    /// expense still has the row's category, so a recategorised expense is left
    /// as it was edited.
    public static func importRows(from text: String, into context: ModelContext) throws -> ImportResult {
        let rows = parse(text)
        guard let first = rows.first else { return ImportResult() }
        let found = first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard found.prefix(requiredColumns).map({ $0.lowercased() })
                == header.prefix(requiredColumns).map({ $0.lowercased() }) else {
            throw ImportError.wrongHeader(found: found.joined(separator: ", "))
        }
        let hasSubcategories = found.count > requiredColumns && found[requiredColumns].lowercased() == "subcategory"

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
        /// Keyed by category and subcategory name, both normalised.
        var subcategories: [String: ExpenseSubcategory] = [:]
        for category in categories.values {
            for subcategory in category.subcategories ?? [] {
                subcategories[key(category.name) + "\u{1F}" + key(subcategory.name)] = subcategory
            }
        }
        let alreadyStored = ExistingIndex(context: context)
        var filledThisRun = Set<ObjectIdentifier>()

        func subcategory(named name: String, in category: ExpenseCategory) -> ExpenseSubcategory {
            let subKey = key(category.name) + "\u{1F}" + key(name)
            if let existing = subcategories[subKey] { return existing }
            let order = ((category.subcategories ?? []).map(\.sortOrder).max() ?? -1) + 1
            let created = ExpenseSubcategory(name: name, category: category, sortOrder: order)
            context.insert(created)
            subcategories[subKey] = created
            result.newSubcategories.append("\(category.name) › \(name)")
            return created
        }

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

            let currencyCode = field(2).isEmpty ? Currency.main : field(2).uppercased()
            let reference = field(7).isEmpty ? nil : field(7)

            let stored = alreadyStored.matches(merchant: merchant, amount: amount, date: date, reference: reference)
            if !stored.isEmpty {
                result.duplicates += 1
                // Fill a missing subcategory — on this row's own twin. Of
                // near-identical stored expenses (two taxi fares minutes apart),
                // only the closest in time counts: a re-import has the exact
                // timestamp, and picking any other would put the subcategory on
                // the wrong one. Among exact ties, take one not yet filled.
                let nearest = stored.map { abs($0.date.timeIntervalSince(date)) }.min() ?? 0
                let twins = stored.filter { abs($0.date.timeIntervalSince(date)) == nearest }
                if hasSubcategories, !field(8).isEmpty, !field(4).isEmpty,
                   let target = twins.first(where: { candidate in
                       candidate.subcategory == nil
                           && !filledThisRun.contains(ObjectIdentifier(candidate))
                           && candidate.category.map { key($0.name) == key(field(4)) } == true
                   }),
                   let category = target.category {
                    target.subcategory = subcategory(named: field(8), in: category)
                    target.note = removingNotePart(field(8), from: target.note)
                    filledThisRun.insert(ObjectIdentifier(target))
                    result.filledSubcategories += 1
                }
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

            // Needs a category to live under; one without is dropped rather
            // than guessed.
            var rowSubcategory: ExpenseSubcategory?
            if hasSubcategories, let category, !field(8).isEmpty {
                rowSubcategory = subcategory(named: field(8), in: category)
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
                subcategory: rowSubcategory,
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
        private var references: [String: [Transaction]] = [:]
        private var byMerchantAndAmount: [String: [Transaction]] = [:]

        init(context: ModelContext) {
            for transaction in (try? context.fetch(FetchDescriptor<Transaction>())) ?? [] {
                if let reference = transaction.reference, !reference.isEmpty {
                    references[reference, default: []].append(transaction)
                }
                byMerchantAndAmount[Self.key(transaction.merchant, transaction.amount), default: []].append(transaction)
            }
        }

        /// Stored expenses this row is a copy of; empty when it's new.
        func matches(merchant: String, amount: Decimal, date: Date, reference: String?) -> [Transaction] {
            if let reference, let byReference = references[reference] { return byReference }
            return byMerchantAndAmount[Self.key(merchant, amount)]?
                .filter { abs($0.date.timeIntervalSince(date)) <= 300 } ?? []
        }

        private static func key(_ merchant: String, _ amount: Decimal) -> String {
            "\(merchant)\u{1F}\(amount)"
        }
    }

    /// Drops one " · "-separated part from a note when it's exactly `part`
    /// (ignoring case). Imports from before subcategories wrote the subcategory
    /// into the note that way; once it's a real subcategory the copy is noise.
    /// Anything else in the note is kept as written.
    static func removingNotePart(_ part: String, from note: String) -> String {
        let parts = note.components(separatedBy: " · ")
        let kept = parts.filter { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(part) != .orderedSame }
        return kept.count == parts.count ? note : kept.joined(separator: " · ")
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
