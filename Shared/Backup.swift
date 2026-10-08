import Foundation
import SwiftData

/// Everything ExpLog holds, as one file: expenses with their original
/// messages and rates, categories and subcategories, cards and keywords,
/// remembered merchants, learned message formats, and the currency settings.
/// More than the CSV export carries — enough to put a fresh install back as
/// it was.
///
/// Restoring merges: it adds what's missing and never removes or overwrites
/// what's already there, so restoring the same file twice, or onto a phone
/// that already has some of it, is safe.
public struct Backup: Codable, Equatable {
    public static let currentVersion = 1

    public struct Category: Codable, Equatable {
        public var name: String
        public var symbol: String
        public var sortOrder: Int
        public var isArchived: Bool
        public var subcategories: [String]
    }

    public struct Card: Codable, Equatable {
        public var name: String
        public var keywords: [String]
        public var isArchived: Bool
    }

    public struct Merchant: Codable, Equatable {
        public var key: String
        public var displayName: String
        public var category: String?
        public var subcategory: String?
        public var useCount: Int
    }

    public struct Format: Codable, Equatable {
        public var pattern: String
        public var sample: String
        public var picked: String
        public var createdAt: Date
    }

    public struct Expense: Codable, Equatable {
        /// As text, so no precision is lost to floating point.
        public var amount: String
        public var currency: String
        public var rate: String?
        public var rateBase: String?
        public var date: Date
        public var merchant: String
        public var note: String
        public var reference: String?
        public var rawMessage: String?
        public var category: String?
        public var subcategory: String?
        public var account: String?
        public var createdAt: Date
    }

    public var version = Backup.currentVersion
    public var createdAt: Date
    public var mainCurrency: String
    public var currencyOrder: String
    public var hiddenCurrencies: String
    public var exchangeRates: String
    public var categories: [Category]
    public var cards: [Card]
    public var merchants: [Merchant]
    public var formats: [Format]
    public var expenses: [Expense]

    // MARK: - Make

    public init(context: ModelContext, now: Date = .now) {
        createdAt = now
        mainCurrency = Currency.main
        currencyOrder = Currency.defaults.string(forKey: Currency.orderKey) ?? ""
        hiddenCurrencies = Currency.defaults.string(forKey: Currency.hiddenKey) ?? ""
        exchangeRates = Currency.defaults.string(forKey: Currency.exchangeRatesKey) ?? ""

        categories = ((try? context.fetch(FetchDescriptor<ExpenseCategory>())) ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map {
                Category(name: $0.name, symbol: $0.symbol, sortOrder: $0.sortOrder, isArchived: $0.isArchived,
                         subcategories: $0.sortedSubcategories.map(\.name))
            }
        cards = ((try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.name)]))) ?? [])
            .map { Card(name: $0.name, keywords: $0.matchKeywords, isArchived: $0.isArchived) }
        merchants = ((try? context.fetch(FetchDescriptor<MerchantAlias>(sortBy: [SortDescriptor(\.key)]))) ?? [])
            .map {
                Merchant(key: $0.key, displayName: $0.displayName, category: $0.category?.name,
                         subcategory: $0.subcategory?.name, useCount: $0.useCount)
            }
        formats = ((try? context.fetch(FetchDescriptor<MessageFormat>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .map { Format(pattern: $0.pattern, sample: $0.sample, picked: $0.picked, createdAt: $0.createdAt) }
        expenses = ((try? context.fetch(FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date)]))) ?? [])
            .map {
                Expense(amount: "\($0.amount)", currency: $0.currencyCode,
                        rate: $0.exchangeRate.map { "\($0)" }, rateBase: $0.rateBase,
                        date: $0.date, merchant: $0.merchant, note: $0.note,
                        reference: $0.reference, rawMessage: $0.rawMessage,
                        category: $0.category?.name, subcategory: $0.subcategory?.name,
                        account: $0.account?.name, createdAt: $0.createdAt)
            }
    }

    // MARK: - File

    public enum BackupError: LocalizedError {
        case notABackup
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup:
                return "That file isn't an ExpLog backup."
            case .newerVersion(let version):
                return "That backup was made by a newer ExpLog (format \(version)). Update the app to restore it."
            }
        }
    }

    public func encoded() throws -> Data {
        // Dates are written as Foundation stores them (seconds from its
        // reference date): exact, where converting to another epoch drops
        // the last bits, and the same on every device and region.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> Backup {
        let decoder = JSONDecoder()
        guard let backup = try? decoder.decode(Backup.self, from: data) else { throw BackupError.notABackup }
        guard backup.version <= currentVersion else { throw BackupError.newerVersion(backup.version) }
        return backup
    }

    // MARK: - Restore

    public struct RestoreReport: Equatable {
        public var expenses = 0
        public var alreadyHere = 0
        public var categories = 0
        public var cards = 0
        public var merchants = 0
        public var formats = 0
    }

    /// Adds whatever this backup has that `context` doesn't. Nothing already
    /// there is removed or changed, except that a card gains keywords it was
    /// missing. Currency settings are taken on only when there were no
    /// expenses before — a fresh install.
    @discardableResult
    public func restore(into context: ModelContext) throws -> RestoreReport {
        var report = RestoreReport()
        let same: (String, String) -> Bool = { $0.caseInsensitiveCompare($1) == .orderedSame }
        let existingExpenses = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let wasEmpty = existingExpenses.isEmpty

        // Categories and their subcategories, by name.
        var allCategories = (try? context.fetch(FetchDescriptor<ExpenseCategory>())) ?? []
        func category(named name: String?) -> ExpenseCategory? {
            guard let name else { return nil }
            return allCategories.first { same($0.name, name) }
        }
        for item in categories {
            let target: ExpenseCategory
            if let found = category(named: item.name) {
                target = found
            } else {
                target = ExpenseCategory(name: item.name, symbol: item.symbol, sortOrder: item.sortOrder)
                target.isArchived = item.isArchived
                context.insert(target)
                allCategories.append(target)
                report.categories += 1
            }
            for (index, name) in item.subcategories.enumerated()
            where !(target.subcategories ?? []).contains(where: { same($0.name, name) }) {
                context.insert(ExpenseSubcategory(name: name, category: target, sortOrder: index))
            }
        }
        func subcategory(named name: String?, in category: ExpenseCategory?) -> ExpenseSubcategory? {
            guard let name, let category else { return nil }
            return (category.subcategories ?? []).first { same($0.name, name) }
        }

        // Cards, by name; a keyword already on another card stays where it is.
        var allCards = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for item in cards {
            let taken = Set(allCards.flatMap(\.matchKeywords).map { $0.lowercased() })
            if let found = allCards.first(where: { same($0.name, item.name) }) {
                let missing = item.keywords.filter { !taken.contains($0.lowercased()) }
                if !missing.isEmpty { found.matchKeywords += missing }
            } else {
                let card = Account(name: item.name, matchKeywords: item.keywords.filter { !taken.contains($0.lowercased()) })
                card.isArchived = item.isArchived
                context.insert(card)
                allCards.append(card)
                report.cards += 1
            }
        }

        // Remembered merchants, by the text their messages use.
        var knownKeys = Set(((try? context.fetch(FetchDescriptor<MerchantAlias>())) ?? []).map(\.key))
        for item in merchants where !knownKeys.contains(item.key) {
            let owner = category(named: item.category)
            let alias = MerchantAlias(key: item.key, displayName: item.displayName, category: owner,
                                      subcategory: subcategory(named: item.subcategory, in: owner))
            alias.useCount = item.useCount
            context.insert(alias)
            knownKeys.insert(item.key)
            report.merchants += 1
        }

        // Learned formats, by pattern.
        var knownPatterns = Set(((try? context.fetch(FetchDescriptor<MessageFormat>())) ?? []).map(\.pattern))
        for item in formats where !knownPatterns.contains(item.pattern) {
            let format = MessageFormat(pattern: item.pattern, sample: item.sample, picked: item.picked)
            format.createdAt = item.createdAt
            context.insert(format)
            knownPatterns.insert(item.pattern)
            report.formats += 1
        }

        // Expenses. There's no ID to match on, so one counts as already here
        // when the same moment, amount, currency and merchant is — and each
        // one here answers for only one in the backup, so a genuine pair of
        // identical expenses comes back as a pair.
        var here: [String: Int] = [:]
        for expense in existingExpenses {
            here[Self.key(date: expense.date, amount: expense.amount, currency: expense.currencyCode,
                          merchant: expense.merchant), default: 0] += 1
        }
        let posix = Locale(identifier: "en_US_POSIX")
        for item in expenses {
            guard let amount = Decimal(string: item.amount, locale: posix) else { continue }
            let key = Self.key(date: item.date, amount: amount, currency: item.currency, merchant: item.merchant)
            if let count = here[key], count > 0 {
                here[key] = count - 1
                report.alreadyHere += 1
                continue
            }
            let owner = category(named: item.category)
            let expense = Transaction(
                amount: amount, currencyCode: item.currency, date: item.date, merchant: item.merchant,
                note: item.note, reference: item.reference, rawMessage: item.rawMessage,
                category: owner, subcategory: subcategory(named: item.subcategory, in: owner),
                account: item.account.flatMap { name in allCards.first { same($0.name, name) } }
            )
            expense.exchangeRate = item.rate.flatMap { Decimal(string: $0, locale: posix) }
            expense.rateBase = item.rateBase
            expense.createdAt = item.createdAt
            context.insert(expense)
            report.expenses += 1
        }

        try context.save()

        if wasEmpty {
            Currency.setMain(mainCurrency)
            Currency.defaults.set(currencyOrder, forKey: Currency.orderKey)
            Currency.defaults.set(hiddenCurrencies, forKey: Currency.hiddenKey)
            Currency.defaults.set(exchangeRates, forKey: Currency.exchangeRatesKey)
        }
        return report
    }

    private static func key(date: Date, amount: Decimal, currency: String, merchant: String) -> String {
        "\(Int(date.timeIntervalSince1970.rounded()))|\(amount)|\(currency)|\(merchant.lowercased())"
    }
}

// MARK: - Undoing a delete

/// An expense's values, kept for a moment after it's deleted so the delete
/// can be undone. Restoring makes a new expense with the same values.
public struct ExpenseSnapshot {
    public let amount: Decimal
    public let currencyCode: String
    public let exchangeRate: Decimal?
    public let rateBase: String?
    public let date: Date
    public let merchant: String
    public let note: String
    public let reference: String?
    public let rawMessage: String?
    public let createdAt: Date
    public let category: ExpenseCategory?
    public let subcategory: ExpenseSubcategory?
    public let account: Account?

    public init(_ expense: Transaction) {
        amount = expense.amount
        currencyCode = expense.currencyCode
        exchangeRate = expense.exchangeRate
        rateBase = expense.rateBase
        date = expense.date
        merchant = expense.merchant
        note = expense.note
        reference = expense.reference
        rawMessage = expense.rawMessage
        createdAt = expense.createdAt
        category = expense.category
        subcategory = expense.subcategory
        account = expense.account
    }

    /// Puts the expense back. A category or card deleted in the meantime is
    /// left off rather than brought back.
    @discardableResult
    public func restore(in context: ModelContext) -> Transaction {
        let owner = category.flatMap { $0.isDeleted || $0.modelContext == nil ? nil : $0 }
        let expense = Transaction(
            amount: amount, currencyCode: currencyCode, date: date, merchant: merchant, note: note,
            reference: reference, rawMessage: rawMessage, category: owner,
            subcategory: subcategory.flatMap { $0.isDeleted || $0.modelContext == nil ? nil : $0 },
            account: account.flatMap { $0.isDeleted || $0.modelContext == nil ? nil : $0 }
        )
        expense.exchangeRate = exchangeRate
        expense.rateBase = rateBase
        expense.createdAt = createdAt
        context.insert(expense)
        try? context.save()
        return expense
    }
}
