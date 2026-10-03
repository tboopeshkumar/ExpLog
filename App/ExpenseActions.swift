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
            CategoryPickerList(
                categories: categories,
                category: transaction.category,
                subcategory: transaction.subcategory,
                onPick: apply
            )
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

    private func apply(_ category: ExpenseCategory?, _ subcategory: ExpenseSubcategory?) {
        try? TransactionDraft.categorise(transaction, as: category, subcategory: subcategory, in: context)
        dismiss()
    }
}
