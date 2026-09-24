import Foundation

/// The result of reading a bank SMS. Every field is optional: the parser reports
/// what it found and the UI lets you fill in the rest. Nothing is ever silently
/// invented.
public struct ParsedTransaction: Equatable, Sendable {
    public var amount: Decimal?
    public var currency: String?
    public var merchant: String?
    /// The card as the SMS writes it: "XXXX4417", "XXX453", or bare digits for
    /// "Card ending 6150". Masks vary by bank, so it's kept verbatim — it's
    /// what "Add card" uses as the new account's match keyword.
    public var card: String?
    public var date: Date?
    public var reference: String?

    /// The original message, kept on the record so a parser bug can be fixed
    /// after the fact without losing the transaction.
    public var raw: String = ""

    public init() {}

    /// Enough was recognised to be worth showing a pre-filled form.
    public var isUsable: Bool {
        amount != nil && (card != nil || merchant != nil)
    }

    /// Fields the form should highlight for review.
    public var missingFields: [String] {
        var missing: [String] = []
        if amount == nil { missing.append("amount") }
        if merchant == nil { missing.append("merchant") }
        if card == nil { missing.append("card") }
        if date == nil { missing.append("date") }
        return missing
    }
}
