import Foundation
import SwiftData

/// How an SMS finds its card: each account lists keywords taken from its
/// alerts — "XXX4453", "XXXX4453" — and an alert containing one of them belongs
/// to that account.
///
/// Keywords rather than a fixed four digits because banks disagree on the
/// mask: some write three digits, some four, some "ending 4453". Kept out of
/// the views so the Mac test suite covers it.
public enum AccountMatching {

    /// Shortest keyword accepted. Three bare digits ("453") would also match
    /// amounts like "AED 453.00"; with the mask ("XXX453") there's no risk.
    public static let minimumKeywordLength = 4

    // MARK: - Matching

    /// The account an alert belongs to, or nil. When several match, the one
    /// with the longest matching keyword wins — "XXXX4453" is more specific
    /// than "4453".
    public static func account(for message: String, in context: ModelContext) -> Account? {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var best: (account: Account, length: Int)?
        for account in accounts where !account.isArchived {
            for keyword in account.matchKeywords where matches(keyword, in: message) {
                if keyword.count > (best?.length ?? 0) {
                    best = (account, keyword.count)
                }
            }
        }
        return best?.account
    }

    /// Case-insensitive, and a keyword that starts or ends with a digit can't
    /// match inside a longer number: "4453" matches "XXXX4453" and "ending
    /// 4453", but not "144531".
    public static func matches(_ keyword: String, in message: String) -> Bool {
        let needle = keyword.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return false }

        var searchRange = message.startIndex..<message.endIndex
        while let found = message.range(of: needle, options: .caseInsensitive, range: searchRange) {
            let digitBefore = found.lowerBound > message.startIndex
                && message[message.index(before: found.lowerBound)].isASCIIDigit
                && needle.first?.isASCIIDigit == true
            let digitAfter = found.upperBound < message.endIndex
                && message[found.upperBound].isASCIIDigit
                && needle.last?.isASCIIDigit == true
            if !digitBefore && !digitAfter { return true }
            searchRange = message.index(after: found.lowerBound)..<message.endIndex
        }
        return false
    }

    // MARK: - Editing

    /// Keywords from a comma-separated field: trimmed, blanks dropped, repeats
    /// removed ignoring case.
    public static func keywords(from text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// The ones too short to match safely.
    public static func tooShort(_ keywords: [String]) -> [String] {
        keywords.filter { $0.count < minimumKeywordLength }
    }

    /// Another account already using one of these keywords, and which keyword.
    /// Two accounts sharing a keyword would make matching a coin toss.
    public static func conflict(
        for keywords: [String],
        excluding account: Account? = nil,
        in context: ModelContext
    ) -> (account: Account, keyword: String)? {
        let wanted = Set(keywords.map { $0.lowercased() })
        for other in (try? context.fetch(FetchDescriptor<Account>())) ?? [] where other !== account {
            if let shared = other.matchKeywords.first(where: { wanted.contains($0.lowercased()) }) {
                return (other, shared)
            }
        }
        return nil
    }

    /// Moves every transaction from `source` to `target`, adds its keywords to
    /// the target's, and removes `source`.
    ///
    /// For the account ExpLog creates on its own when an alert names an unknown
    /// card ("Card 1442"), once you add its keyword to the account you actually
    /// use for that card.
    public static func merge(_ source: Account, into target: Account, in context: ModelContext) throws {
        guard source !== target else { return }
        for transaction in source.transactions ?? [] {
            transaction.account = target
        }
        target.matchKeywords = keywords(from: (target.matchKeywords + source.matchKeywords).joined(separator: ","))
        context.delete(source)
        try context.save()
    }

    // MARK: - Migration

    /// Turns the four digits accounts used to be matched by into their first
    /// keyword, once. Safe to call on every launch.
    public static func foldLegacyDigits(in context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        var changed = false
        for account in accounts {
            guard let digits = account.last4, !digits.isEmpty else { continue }
            if !account.matchKeywords.contains(where: { $0.caseInsensitiveCompare(digits) == .orderedSame }) {
                account.matchKeywords.insert(digits, at: 0)
            }
            account.last4 = nil
            changed = true
        }
        if changed { try? context.save() }
    }
}

extension Character {
    /// Only 0–9: `isNumber` also accepts other scripts' digits and fractions.
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
