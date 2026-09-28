import Foundation
import SwiftData

/// The parser plus what it has been taught: the merchant formats picked out
/// of messages (MessageFormat). Everywhere the app reads a message goes
/// through here, so a correction applies to all of them.
public enum LearnedParsing {

    /// Newest first, so a later correction to the same format wins.
    public static func formats(in context: ModelContext) -> [String] {
        let descriptor = FetchDescriptor<MessageFormat>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? []).map(\.pattern)
    }

    public static func parse(_ text: String, receivedAt: Date = .now, in context: ModelContext) -> ParsedTransaction? {
        SMSParser.parse(text, receivedAt: receivedAt, formats: formats(in: context))
    }

    /// Saves a picked format, replacing any earlier one that reads messages of
    /// the same shape — the new pick is the correction.
    public static func learn(_ format: TransactionDraft.PickedFormat, in context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<MessageFormat>())) ?? []
        for old in existing where old.pattern == format.pattern
            || MerchantFormat.merchant(in: format.sample, pattern: old.pattern) != nil {
            context.delete(old)
        }
        context.insert(MessageFormat(pattern: format.pattern, sample: format.sample, picked: format.picked))
    }

    /// Forgets merchant memories keyed on a sentence fragment rather than a
    /// name — left by a misreading such as "account XX810001 was used", which
    /// every alert in that format would otherwise have matched, pre-filling
    /// one shop's name and category on all of them.
    @discardableResult
    public static func forgetImplausibleAliases(in context: ModelContext) -> Int {
        let aliases = (try? context.fetch(FetchDescriptor<MerchantAlias>())) ?? []
        let bad = aliases.filter { !SMSParser.isPlausibleMerchant($0.key) }
        bad.forEach(context.delete)
        if !bad.isEmpty { try? context.save() }
        return bad.count
    }
}
