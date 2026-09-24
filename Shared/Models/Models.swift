import Foundation
import SwiftData

// The schema is deliberately CloudKit-compatible from day one, even though sync
// is off: every attribute has a default or is optional, there are no unique
// constraints, and every relationship is optional with an inverse. Turning sync
// on later is then an entitlement plus one line in SharedStore — no migration.

@Model
public final class Account {
    public var name: String = ""

    /// Text from this card's SMS alerts — "XXX4453", "XXXX4453". An alert
    /// containing any of them belongs to this account; see AccountMatching.
    /// Several, because banks don't agree on how many digits to show.
    public var matchKeywords: [String] = []

    /// Legacy: the four digits accounts were matched by before keywords.
    /// Folded into `matchKeywords` at launch (AccountMatching.foldLegacyDigits)
    /// and never written. Kept only so stores from that version can be read.
    public var last4: String?

    public var isArchived: Bool = false
    public var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \Transaction.account)
    public var transactions: [Transaction]?

    public init(name: String, matchKeywords: [String] = []) {
        self.name = name
        self.matchKeywords = matchKeywords
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

    /// One optional level below: Transport › Taxi. Deleting a category takes
    /// its subcategories with it; their expenses keep the category.
    @Relationship(deleteRule: .cascade, inverse: \ExpenseSubcategory.category)
    public var subcategories: [ExpenseSubcategory]?

    @Relationship(deleteRule: .nullify, inverse: \MerchantAlias.category)
    public var aliases: [MerchantAlias]?

    public init(name: String, symbol: String = "tag", sortOrder: Int = 0) {
        self.name = name
        self.symbol = symbol
        self.sortOrder = sortOrder
        self.createdAt = .now
    }

    /// Subcategories in display order.
    public var sortedSubcategories: [ExpenseSubcategory] {
        (subcategories ?? []).sorted {
            ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased())
        }
    }
}

/// The optional second level of a category. Only one level: a subcategory has
/// no subcategories. Drawn with its parent's icon and colour.
@Model
public final class ExpenseSubcategory {
    public var name: String = ""
    public var sortOrder: Int = 0
    public var createdAt: Date = Date.now

    public var category: ExpenseCategory?

    @Relationship(deleteRule: .nullify, inverse: \Transaction.subcategory)
    public var transactions: [Transaction]?

    @Relationship(deleteRule: .nullify, inverse: \MerchantAlias.subcategory)
    public var aliases: [MerchantAlias]?

    public init(name: String, category: ExpenseCategory, sortOrder: Int = 0) {
        self.name = name
        self.category = category
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

    public var category: ExpenseCategory?
    public var subcategory: ExpenseSubcategory?

    public init(
        key: String,
        displayName: String = "",
        category: ExpenseCategory? = nil,
        subcategory: ExpenseSubcategory? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.category = category
        self.subcategory = subcategory
        self.updatedAt = .now
    }
}

@Model
public final class Transaction {
    public var amount: Decimal = Decimal(0)
    /// ISO 4217. Each expense keeps its own; see Currency.
    public var currencyCode: String = Currency.fallback
    public var date: Date = Date.now
    public var merchant: String = ""
    public var note: String = ""

    /// Bank reference, when the SMS carried one. Also used to avoid saving the
    /// same alert twice.
    public var reference: String?

    /// The original SMS. Costs nothing to keep and makes it possible to fix a
    /// parser mistake months later without losing the transaction.
    public var rawMessage: String?

    public var createdAt: Date = Date.now

    public var category: ExpenseCategory?
    /// Always one of `category`'s subcategories, or nil. TransactionDraft.save
    /// enforces it.
    public var subcategory: ExpenseSubcategory?
    public var account: Account?

    public init(
        amount: Decimal = 0,
        currencyCode: String = Currency.main,
        date: Date = .now,
        merchant: String = "",
        note: String = "",
        reference: String? = nil,
        rawMessage: String? = nil,
        category: ExpenseCategory? = nil,
        subcategory: ExpenseSubcategory? = nil,
        account: Account? = nil
    ) {
        self.amount = amount
        self.currencyCode = currencyCode
        self.date = date
        self.merchant = merchant
        self.note = note
        self.reference = reference
        self.rawMessage = rawMessage
        self.category = category
        self.subcategory = subcategory?.category === category ? subcategory : nil
        self.account = account
        self.createdAt = .now
    }
}
