import SwiftUI
import SwiftData

extension View {
    /// The quick actions on an expense row, as swipes and in the long-press
    /// menu: swipe right to categorise or copy, swipe left to delete.
    ///
    /// Delete is spelled out rather than left to `onDelete`: once a row has
    /// custom swipe actions, relying on the list's default is how a delete
    /// quietly goes missing.
    func expenseActions(
        for transaction: Transaction,
        categorise: @escaping (Transaction) -> Void,
        copy: @escaping (Transaction) -> Void,
        delete: @escaping (Transaction) -> Void
    ) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    categorise(transaction)
                } label: {
                    Label("Categorise", systemImage: "tag")
                }
                .tint(.indigo)
                Button {
                    copy(transaction)
                } label: {
                    Label("Copy", systemImage: "plus.square.on.square")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    delete(transaction)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    categorise(transaction)
                } label: {
                    Label("Categorise…", systemImage: "tag")
                }
                Button {
                    copy(transaction)
                } label: {
                    Label("Copy with Today's Date", systemImage: "plus.square.on.square")
                }
                Divider()
                Button(role: .destructive) {
                    delete(transaction)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}

/// Pick a category — or one of its subcategories — in one tap. Saves through
/// the same path as the editor, so a merchant from an SMS is learned for next
/// time.
struct QuickCategorySheet: View {
    let transaction: Transaction

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<ExpenseCategory> { !$0.isArchived }, sort: \ExpenseCategory.sortOrder)
    private var categories: [ExpenseCategory]

    var body: some View {
        NavigationStack {
            List {
                ForEach(categories) { category in
                    choice(category: category, subcategory: nil)
                    ForEach(category.sortedSubcategories) { subcategory in
                        choice(category: category, subcategory: subcategory)
                    }
                }
                if transaction.category != nil {
                    Section {
                        Button("Remove category", role: .destructive) { apply(nil, nil) }
                    }
                }
            }
            .navigationTitle(transaction.merchant.isEmpty ? "Categorise" : transaction.merchant)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// A category row, or a subcategory row indented beneath its parent.
    private func choice(category: ExpenseCategory, subcategory: ExpenseSubcategory?) -> some View {
        let isCurrent = transaction.category === category && transaction.subcategory === subcategory
        return Button {
            apply(category, subcategory)
        } label: {
            HStack(spacing: 12) {
                if let subcategory {
                    // Indented past the category's name, one size down, so
                    // it reads as belonging to the row above.
                    Text(subcategory.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                } else {
                    CategoryIcon(category, size: 28)
                    Text(category.name)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            // The whole row is the target, not just the text.
            .contentShape(.rect)
        }
        // Plain, so names are text, not blue link-coloured buttons.
        .buttonStyle(.plain)
    }

    private func apply(_ category: ExpenseCategory?, _ subcategory: ExpenseSubcategory?) {
        try? TransactionDraft.categorise(transaction, as: category, subcategory: subcategory, in: context)
        dismiss()
    }
}
