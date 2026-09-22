import Foundation
import SwiftData

/// Rules for editing cards and accounts, kept out of the views so the Mac test
/// suite covers them.
///
/// The last four digits are what match a card's SMS alerts to its account
/// (TransactionDraft.account(withLast4:)), so they're held to one rule: exactly
/// four digits, or none — and no two accounts with the same four.
public enum AccountEditing {

    /// Keeps only digits, at most four, for a text field bound to card digits.
    public static func sanitizedDigits(_ text: String) -> String {
        String(text.filter(\.isASCIIDigit).prefix(4))
    }

    /// The digits to store: nil for none, the four digits, or nothing usable.
    public enum Last4: Equatable {
        case none
        case digits(String)
        /// One to three digits — an alert always shows four.
        case incomplete
    }

    public static func last4(from text: String) -> Last4 {
        let digits = sanitizedDigits(text)
        switch digits.count {
        case 0: return .none
        case 4: return .digits(digits)
        default: return .incomplete
        }
    }

    /// Another account already using these digits, if any.
    public static func owner(of digits: String, excluding account: Account? = nil, in context: ModelContext) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.last4 == digits })
        return ((try? context.fetch(descriptor)) ?? []).first { $0 !== account }
    }

    /// Moves every transaction from `source` to `target` and removes `source`.
    ///
    /// For the account ExpLog creates on its own when an SMS names an unknown
    /// card ("Card 1442"), once you add those digits to the account you
    /// actually use for that card.
    public static func merge(_ source: Account, into target: Account, in context: ModelContext) throws {
        guard source !== target else { return }
        for transaction in source.transactions ?? [] {
            transaction.account = target
        }
        if target.last4 == nil {
            target.last4 = source.last4
        }
        context.delete(source)
        try context.save()
    }
}

private extension Character {
    /// Only 0–9: `isNumber` also accepts other scripts' digits and fractions.
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
