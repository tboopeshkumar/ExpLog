import Foundation
import SwiftData

/// First-run content. Runs from the app only — the share extension should never
/// write seed data, since it can be the first thing launched.
public enum SeedData {
    private static let defaultCategories: [(String, String)] = [
        ("Groceries", "cart"),
        ("Dining", "fork.knife"),
        ("Transport", "car"),
        ("Fuel", "fuelpump"),
        ("Shopping", "bag"),
        ("Bills & Utilities", "bolt"),
        ("Health", "cross.case"),
        ("Entertainment", "play.tv"),
        ("Travel", "airplane"),
        ("Other", "ellipsis.circle"),
    ]

    public static func seedIfNeeded(_ context: ModelContext) {
        let existing = (try? context.fetchCount(FetchDescriptor<ExpenseCategory>())) ?? 0
        guard existing == 0 else { return }

        for (index, entry) in defaultCategories.enumerated() {
            context.insert(ExpenseCategory(name: entry.0, symbol: entry.1, sortOrder: index))
        }
        try? context.save()
    }
}
