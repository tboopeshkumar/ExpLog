import Foundation
import SwiftData

// The schema is deliberately CloudKit-compatible from day one, even though sync
// is off: every attribute has a default or is optional, there are no unique
// constraints, and every relationship is optional with an inverse. Turning sync
// on later is then an entitlement plus one line in SharedStore — no migration.

@Model
public final class Account {
    public var name: String = ""
    /// Last four digits as they appear in the SMS. How a card alert is matched
    /// to an account.
    public var last4: String?
    public var isArchived: Bool = false
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Transaction.account)
    public var transactions: [Transaction]?

    public init(name: String, last4: String? = nil) {
        self.name = name
        self.last4 = last4
        self.createdAt = .now
    }
}

@Model
public final class ExpenseCategory {
    public var name: String = ""
    /// SF Symbol name.
    public var symbol: String = "tag"
    public var sortOrder: Int = 0
    public var isArchived: Bool = false
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Transaction.category)
    public var transactions: [Transaction]?

    public init(name: String, symbol: String = "tag", sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.createdAt = .now
    }
}

/// Remembers that "Mega Center Riverton Xyz" is groceries, so the second time that
/// merchant appears the category is already filled in. Written whenever a
/// transaction is saved with a category — there is no separate training step.
@Model
public final class MerchantAlias {
    /// Parsed merchant text, lowercased, used as the lookup key.
    public var key: String = ""
    /// What to show instead. Empty means keep the parsed text.
    public var displayName: String = ""
    public var useCount: Int = 0
    public var updatedAt: Date = Date.now

    @Relationship(deleteRule: .nullify)
    public var category: ExpenseCategory?

    public init(key: String, displayName: String = "", category: ExpenseCategory? = nil) {
        self.key = key
        self.displayName = displayName
        self.category = category
        self.updatedAt = .now
    }
}

@Model
public final class Transaction {
    public var amount: Decimal = Decimal(0)
    public var currencyCode: String = "AED"
    public var date: Date = Date.now
    public var merchant: String = ""
    public var note: String = ""
    public var isCredit: Bool = false

    /// Bank reference, when the SMS carried one. Also used to avoid saving the
    /// same alert twice.
    public var reference: String?

    /// The original SMS. Costs nothing to keep and makes it possible to fix a
    /// parser mistake months later without losing the transaction.
    public var rawMessage: String?

    public var createdAt: Date = Date.now

    public var category: ExpenseCategory?
    public var account: Account?

    public init(
        amount: Decimal = 0,
        currencyCode: String = "AED",
        date: Date = .now,
        merchant: String = "",
        note: String = "",
        isCredit: Bool = false,
        reference: String? = nil,
        rawMessage: String? = nil,
        category: ExpenseCategory? = nil,
        account: Account? = nil
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.date = date
        self.merchant = merchant
        self.note = note
        self.isCredit = isCredit
        self.reference = reference
        self.rawMessage = rawMessage
        self.category = category
        self.account = account
        self.createdAt = .now
    }

    /// Signed value for summing: credits count as money coming back.
    public var signedAmount: Decimal {
        isCredit ? -amount : amount
    }
}
