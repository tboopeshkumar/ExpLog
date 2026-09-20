import Foundation
import SwiftData
import Observation

/// Editable state behind both the share-sheet form and the in-app editor, so
/// the two stay consistent without duplicating logic.
@Observable
public final class TransactionDraft {
    public var amount: Decimal = 0
    public var currencyCode: String = "AED"
    public var date: Date = .now
    public var merchant: String = ""
    public var note: String = ""
    public var isCredit: Bool = false
    public var reference: String?
    public var rawMessage: String?

    public var category: ExpenseCategory?
    public var account: Account?

    /// Fields the parser could not find, so the form can point at them.
    public var unparsedFields: [String] = []

    /// Card digits read from the SMS. Kept even when no Account matches, so the
    /// form can offer to create one.
    public var parsedLast4: String?

    /// The transaction being edited, when editing rather than creating.
    private var existing: Transaction?

    public init() {}

    public init(editing transaction: Transaction) {
        existing = transaction
        amount = transaction.amount
        currencyCode = transaction.currencyCode
        date = transaction.date
        merchant = transaction.merchant
        note = transaction.note
        isCredit = transaction.isCredit
        reference = transaction.reference
        rawMessage = transaction.rawMessage
        category = transaction.category
        account = transaction.account
    }

    /// Builds a draft from a parsed SMS, filling in the account and category the
    /// message itself cannot supply by looking at what was saved before.
    public init(parsed: ParsedTransaction, context: ModelContext, receivedAt: Date = .now) {
        amount = parsed.amount ?? 0
        currencyCode = parsed.currency ?? "AED"
        date = parsed.date ?? receivedAt
        isCredit = parsed.kind == .credit
        reference = parsed.reference
        rawMessage = parsed.raw
        unparsedFields = parsed.missingFields

        let parsedMerchant = parsed.merchant ?? ""
        merchant = parsedMerchant

        if let alias = Self.alias(for: parsedMerchant, in: context) {
            if !alias.displayName.isEmpty { merchant = alias.displayName }
            category = alias.category
        }
        parsedLast4 = parsed.cardLast4
        if let last4 = parsed.cardLast4 {
            account = Self.account(withLast4: last4, in: context)
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

    public static func account(withLast4 last4: String, in context: ModelContext) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.last4 == last4 })
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
        transaction.date = date
        transaction.merchant = merchant.trimmingCharacters(in: .whitespaces)
        transaction.note = note
        transaction.isCredit = isCredit
        transaction.reference = reference
        transaction.rawMessage = rawMessage
        transaction.category = category
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

        if let alias = Self.alias(for: parsedMerchant, in: context) {
            alias.category = category
            alias.displayName = display == parsedMerchant ? "" : display
            alias.useCount += 1
            alias.updatedAt = .now
        } else {
            let alias = MerchantAlias(
                key: key,
                displayName: display == parsedMerchant ? "" : display,
                category: category
            )
            alias.useCount = 1
            context.insert(alias)
        }
    }
}
