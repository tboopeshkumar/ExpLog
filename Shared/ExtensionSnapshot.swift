import Foundation
import Security
import SwiftData

/// What the share sheet needs from the app to offer a category and card and
/// to read a message the way the app would, when the two can't share a
/// database (no App Group — a free Apple ID): categories, cards with their
/// keywords, remembered merchants, learned message formats, and the currency
/// settings.
///
/// The app writes it to the keychain group both belong to whenever it leaves
/// the foreground; the share sheet loads it into its own scratch store before
/// showing the form. What's chosen there travels back by name in
/// TransactionLink.
public struct ExtensionSnapshot: Codable, Equatable {
    public struct Category: Codable, Equatable {
        public var name: String
        public var symbol: String
        public var sortOrder: Int
        public var subcategories: [String]
    }

    public struct Card: Codable, Equatable {
        public var name: String
        public var keywords: [String]
    }

    public struct Merchant: Codable, Equatable {
        public var key: String
        public var displayName: String
        public var category: String?
        public var subcategory: String?
    }

    public var categories: [Category] = []
    public var cards: [Card] = []
    public var merchants: [Merchant] = []
    /// MerchantFormat patterns, newest first.
    public var formats: [String] = []
    public var mainCurrency = Currency.fallback
    public var currencyOrder = ""
    public var hiddenCurrencies = ""
    public var exchangeRates = ""

    // MARK: - From the app's store

    public init(context: ModelContext) {
        let allCategories = ((try? context.fetch(FetchDescriptor<ExpenseCategory>())) ?? [])
            .filter { !$0.isArchived }
            .sorted { $0.sortOrder < $1.sortOrder }
        categories = allCategories.map {
            Category(name: $0.name, symbol: $0.symbol, sortOrder: $0.sortOrder,
                     subcategories: $0.sortedSubcategories.map(\.name))
        }
        cards = ((try? context.fetch(FetchDescriptor<Account>())) ?? [])
            .filter { !$0.isArchived }
            .map { Card(name: $0.name, keywords: $0.matchKeywords) }
        merchants = ((try? context.fetch(FetchDescriptor<MerchantAlias>())) ?? []).map {
            Merchant(key: $0.key, displayName: $0.displayName,
                     category: $0.category?.name, subcategory: $0.subcategory?.name)
        }
        formats = LearnedParsing.formats(in: context)
        mainCurrency = Currency.main
        currencyOrder = Currency.defaults.string(forKey: Currency.orderKey) ?? ""
        hiddenCurrencies = Currency.defaults.string(forKey: Currency.hiddenKey) ?? ""
        exchangeRates = Currency.defaults.string(forKey: Currency.exchangeRatesKey) ?? ""
    }

    // MARK: - Into the share sheet's store

    /// Replaces what `context` holds with this snapshot, and takes on its
    /// currency settings. For the share sheet's scratch store only: it
    /// deletes every category, card, merchant and format there first.
    public func apply(to context: ModelContext) {
        try? context.delete(model: MerchantAlias.self)
        try? context.delete(model: MessageFormat.self)
        try? context.delete(model: Account.self)
        try? context.delete(model: ExpenseSubcategory.self)
        try? context.delete(model: ExpenseCategory.self)

        var byName: [String: ExpenseCategory] = [:]
        for item in categories {
            let category = ExpenseCategory(name: item.name, symbol: item.symbol, sortOrder: item.sortOrder)
            context.insert(category)
            for (index, name) in item.subcategories.enumerated() {
                context.insert(ExpenseSubcategory(name: name, category: category, sortOrder: index))
            }
            byName[item.name.lowercased()] = category
        }
        for card in cards {
            context.insert(Account(name: card.name, matchKeywords: card.keywords))
        }
        for merchant in merchants {
            let category = merchant.category.flatMap { byName[$0.lowercased()] }
            let subcategory = merchant.subcategory.flatMap { name in
                category?.subcategories?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
            context.insert(MerchantAlias(key: merchant.key, displayName: merchant.displayName,
                                         category: category, subcategory: subcategory))
        }
        // Oldest first, so the newest ends up newest here too.
        for (offset, pattern) in formats.reversed().enumerated() {
            let format = MessageFormat(pattern: pattern, sample: "", picked: "")
            format.createdAt = Date(timeIntervalSince1970: TimeInterval(offset))
            context.insert(format)
        }
        try? context.save()

        Currency.setMain(mainCurrency)
        Currency.defaults.set(currencyOrder, forKey: Currency.orderKey)
        Currency.defaults.set(hiddenCurrencies, forKey: Currency.hiddenKey)
        Currency.defaults.set(exchangeRates, forKey: Currency.exchangeRatesKey)
    }

    // MARK: - Keychain

    private static let service = "ExpLog.Snapshot"
    private static let account = "current"

    /// The keychain group the app and the share sheet both belong to; see
    /// SharedInbox.
    private static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "ExpLogKeychainGroup") as? String
    }

    /// Writes the snapshot for the share sheet to pick up. Quietly does
    /// nothing when the group isn't configured.
    public func store() {
        guard let accessGroup = Self.accessGroup, let data = try? JSONEncoder().encode(self) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    /// The snapshot the app last wrote, if any.
    public static func load() -> ExtensionSnapshot? {
        guard let accessGroup else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ExtensionSnapshot.self, from: data)
    }
}
