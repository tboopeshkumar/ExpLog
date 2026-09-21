import Foundation

/// The result of reading a bank SMS. Every field is optional: the parser reports
/// what it found and the UI lets you fill in the rest. Nothing is ever silently
/// invented.
public struct ParsedTransaction: Equatable, Sendable {
    public var amount: Decimal?
    public var currency: String?
    public var merchant: String?
    public var cardLast4: String?
    public var date: Date?
    public var reference: String?

    /// The original message, kept on the record so a parser bug can be fixed
    /// after the fact without losing the transaction.
    public var raw: String = ""

    public init() {}

    /// Enough was recognised to be worth showing a pre-filled form.
    public var isUsable: Bool {
        amount != nil && (cardLast4 != nil || merchant != nil)
    }

    /// Fields the form should highlight for review.
    public var missingFields: [String] {
        var missing: [String] = []
        if amount == nil { missing.append("amount") }
        if merchant == nil { missing.append("merchant") }
        if cardLast4 == nil { missing.append("card") }
        if date == nil { missing.append("date") }
        return missing
    }
}
