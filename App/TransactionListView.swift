import SwiftUI
import SwiftData

struct TransactionListView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var editing: TransactionDraft?
    @State private var searchText = ""

    private var filtered: [Transaction] {
        guard !searchText.isEmpty else { return transactions }
        let needle = searchText.lowercased()
        return transactions.filter {
            $0.merchant.lowercased().contains(needle)
                || $0.note.lowercased().contains(needle)
                || ($0.category?.name.lowercased().contains(needle) ?? false)
        }
    }

    /// Newest month first, transactions already in reverse date order.
    private var months: [(start: Date, items: [Transaction])] {
        Dictionary(grouping: filtered) { Formatting.monthStart($0.date) }
            .map { (start: $0.key, items: $0.value) }
            .sorted { $0.start > $1.start }
    }

    var body: some View {
        List {
            ForEach(months, id: \.start) { month in
                Section {
                    ForEach(month.items) { transaction in
                        Button {
                            editing = TransactionDraft(editing: transaction)
                        } label: {
                            TransactionRow(transaction: transaction)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        delete(offsets, in: month.items)
                    }
                } header: {
                    HStack {
                        Text(Formatting.monthTitle(month.start))
                        Spacer()
                        total(of: month.items)
                            .monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("Expenses")
        .searchable(text: $searchText, prompt: "Merchant, note or category")
        .overlay {
            if transactions.isEmpty {
                ContentUnavailableView {
                    Label("Nothing logged yet", systemImage: "tray")
                } description: {
                    Text("Share a bank SMS from Messages, or add one by hand.")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    editing = TransactionDraft()
                }
            }
        }
        .sheet(item: $editing) { draft in
            NavigationStack {
                TransactionFormView(
                    draft: draft,
                    onSave: { editing = nil },
                    onCancel: { editing = nil }
                )
                .navigationTitle("Expense")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private func total(of items: [Transaction]) -> Text {
        let sum = items.reduce(Decimal(0)) { $0 + $1.amount }
        return Formatting.moneyText(sum, code: items.first?.currencyCode ?? "AED")
    }

    private func delete(_ offsets: IndexSet, in items: [Transaction]) {
        for index in offsets {
            context.delete(items[index])
        }
        try? context.save()
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(transaction.category)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant.isEmpty ? "Unnamed" : transaction.merchant)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(transaction.date.formatted(.dateTime.day().month(.abbreviated)))
                    if let account = transaction.account {
                        Text("· \(account.last4.map { "••\($0)" } ?? account.name)")
                    }
                    if transaction.category == nil {
                        Text("· Uncategorised")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Formatting.moneyText(transaction.amount, code: transaction.currencyCode)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

extension TransactionDraft: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
