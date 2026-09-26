import Foundation
import SwiftData
import Observation

/// Editable state behind both the share-sheet form and the in-app editor, so
/// the two stay consistent without duplicating logic.
@Observable
public final class TransactionDraft {
    public var amount: Decimal = 0
    public var currencyCode: String = Currency.main {
        // Another currency: start from the rate set in Settings.
        didSet { if currencyCode != oldValue { applyCurrentRate() } }
    }
    /// Units of `currencyCode` per one unit of `rateBase`; see Transaction.
    /// Taken from Settings when the currency is chosen, editable per expense,
    /// and fixed on the expense when saved.
    public var exchangeRate: Decimal?
    public var rateBase: String?
    public var date: Date = .now
    public var merchant: String = ""
    public var note: String = ""
    public var reference: String?
    public var rawMessage: String?

    public var category: ExpenseCategory? {
        // A subcategory only makes sense under its own category.
        didSet { if subcategory?.category !== category { subcategory = nil } }
    }
    public var subcategory: ExpenseSubcategory?
    public var account: Account?

    /// Fields the parser could not find, so the form can point at them.
    public var unparsedFields: [String] = []

    /// The card as the SMS wrote it ("XXX453"). Kept even when no account
    /// matches, so the form can offer to create one with it as the keyword.
    public var parsedCard: String?

    /// The transaction being edited, when editing rather than creating.
    private var existing: Transaction?

    public init() {}

    public init(editing transaction: Transaction) {
        existing = transaction
        amount = transaction.amount
        currencyCode = transaction.currencyCode
        exchangeRate = transaction.exchangeRate
        rateBase = transaction.rateBase
        date = transaction.date
        merchant = transaction.merchant
        note = transaction.note
        reference = transaction.reference
        rawMessage = transaction.rawMessage
        category = transaction.category
        subcategory = transaction.subcategory
        account = transaction.account
    }

    /// Builds a draft from a parsed SMS, filling in the account and category the
    /// message itself cannot supply by looking at what was saved before.
    public init(parsed: ParsedTransaction, context: ModelContext, receivedAt: Date = .now) {
        amount = parsed.amount ?? 0
        currencyCode = parsed.currency ?? Currency.main
        applyCurrentRate()
        date = parsed.date ?? receivedAt
        reference = parsed.reference
        rawMessage = parsed.raw
        unparsedFields = parsed.missingFields

        let parsedMerchant = parsed.merchant ?? ""
        merchant = parsedMerchant

        if let alias = Self.alias(for: parsedMerchant, in: context) {
            if !alias.displayName.isEmpty { merchant = alias.displayName }
            category = alias.category
            subcategory = alias.subcategory
        }
        parsedCard = parsed.card
        account = AccountMatching.account(for: parsed.raw, in: context)
    }

    /// The rate from Settings for the current currency, against today's main
    /// currency; none when the expense is in the main currency.
    public func applyCurrentRate() {
        if currencyCode == Currency.main {
            exchangeRate = nil
            rateBase = nil
        } else {
            exchangeRate = Currency.exchangeRates.rate(for: currencyCode)
            rateBase = Currency.main
        }
    }

    public var isValid: Bool {
        amount > 0 && !merchant.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Lookups

    public static func alias(for merchant: String, in context: ModelContext) -> MerchantAlias? {
        let key = merchant.lowercased()
        guard !key.isEmpty else { return nil }
        let descriptor = FetchDescriptor<MerchantAlias>(predicate: #Predicate { $0.key == key })
        return try? context.fetch(descriptor).first
    }

    /// Guards against saving the same alert twice — easy to do when a message is
    /// shared once and then caught again by a re-share.
    public static func duplicate(of draft: TransactionDraft, in context: ModelContext) -> Transaction? {
        if let reference = draft.reference, !reference.isEmpty {
            let descriptor = FetchDescriptor<Transaction>(predicate: #Predicate { $0.reference == reference })
            if let match = try? context.fetch(descriptor).first { return match }
        }
        // No reference: treat same merchant and amount within a few minutes as
        // the same transaction.
        let amount = draft.amount
        let merchant = draft.merchant
        let window = draft.date.addingTimeInterval(-300)...draft.date.addingTimeInterval(300)
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { transaction in
                transaction.amount == amount
                    && transaction.merchant == merchant
                    && transaction.date >= window.lowerBound
                    && transaction.date <= window.upperBound
            }
        )
        return try? context.fetch(descriptor).first
    }

    // MARK: - Save

    @discardableResult
    public func save(in context: ModelContext) throws -> Transaction {
        let transaction: Transaction
        if let existing {
            transaction = existing
        } else {
            transaction = Transaction()
            context.insert(transaction)
        }

        transaction.amount = amount
        transaction.currencyCode = currencyCode
        if currencyCode == Currency.main || exchangeRate == nil {
            transaction.exchangeRate = nil
            transaction.rateBase = nil
        } else {
            transaction.exchangeRate = exchangeRate
            transaction.rateBase = rateBase ?? Currency.main
        }
        transaction.date = date
        transaction.merchant = merchant.trimmingCharacters(in: .whitespaces)
        transaction.note = note
        transaction.reference = reference
        transaction.rawMessage = rawMessage
        transaction.category = category
        transaction.subcategory = subcategory?.category === category ? subcategory : nil
        transaction.account = account

        learnAlias(in: context)
        try context.save()
        return transaction
    }

    /// Records merchant → category so the next alert from the same place
    /// arrives already categorised.
    private func learnAlias(in context: ModelContext) {
        guard let category, let rawMessage, !rawMessage.isEmpty else { return }
        guard let parsedMerchant = SMSParser.parse(rawMessage)?.merchant else { return }

        let key = parsedMerchant.lowercased()
        let display = merchant.trimmingCharacters(in: .whitespaces)

        let subcategory = subcategory?.category === category ? subcategory : nil
        if let alias = Self.alias(for: parsedMerchant, in: context) {
            alias.category = category
            alias.subcategory = subcategory
            alias.displayName = display == parsedMerchant ? "" : display
            alias.useCount += 1
            alias.updatedAt = .now
        } else {
            let alias = MerchantAlias(
                key: key,
                displayName: display == parsedMerchant ? "" : display,
                category: category,
                subcategory: subcategory
            )
            alias.useCount = 1
            context.insert(alias)
        }
    }
}
