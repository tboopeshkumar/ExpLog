import SwiftUI
import SwiftData

struct TransactionListView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var editing: TransactionDraft?
    @State private var searchText = ""
    @State private var showsUpcoming = false
    /// Watched so totals reorder the moment the main currency changes.
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

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
    private func months(_ items: [Transaction]) -> [(start: Date, items: [Transaction])] {
        Dictionary(grouping: items) { Formatting.monthStart($0.date) }
            .map { (start: $0.key, items: $0.value) }
            .sorted { $0.start > $1.start }
    }

    var body: some View {
        // Future-dated expenses — instalments imported ahead of time — sit in
        // a collapsed Upcoming group, so the list opens on this month's actual
        // spending rather than on next year's plan. A search shows them all.
        let now = Date.now
        let upcoming = filtered.filter { $0.date > now }
        let past = filtered.filter { $0.date <= now }
        let expandUpcoming = showsUpcoming || !searchText.isEmpty

        List {
            if !upcoming.isEmpty {
                Section {
                    Button {
                        withAnimation { showsUpcoming.toggle() }
                    } label: {
                        UpcomingRow(items: upcoming, expanded: expandUpcoming, mainCurrency: mainCurrency)
                    }
                    .buttonStyle(.plain)
                    .disabled(!searchText.isEmpty)
                }
                if expandUpcoming {
                    monthSections(months(upcoming))
                }
            }
            monthSections(months(past))
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

    private func monthSections(_ months: [(start: Date, items: [Transaction])]) -> some View {
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

    private func total(of items: [Transaction]) -> Text {
        Formatting.totalsText(Currency.totals(of: items, main: mainCurrency))
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

    /// "Sep 26 · Uncategorised · SIB Cashback"
    private var details: String {
        var parts = [transaction.date.formatted(.dateTime.day().month(.abbreviated))]
        if transaction.category == nil {
            parts.append("Uncategorised")
        } else if let subcategory = transaction.subcategory {
            parts.append(subcategory.name)
        }
        if let account = transaction.account {
            parts.append(account.name)
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(transaction.category)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchant.isEmpty ? "Unnamed" : transaction.merchant)
                    .lineLimit(1)
                // One line of text, not separate pieces side by side — those
                // each wrapped in their own column when space ran out.
                // Ordered by importance, since the end is what gets cut.
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Take all the width the amount leaves. A Spacer here would split
            // it with the text, cutting the details short beside empty space.
            .frame(maxWidth: .infinity, alignment: .leading)

            Formatting.moneyText(transaction.amount, code: transaction.currencyCode)
                .monospacedDigit()
                .layoutPriority(1)
        }
        .padding(.vertical, 2)
    }
}

extension TransactionDraft: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}

/// The collapsed stand-in for future-dated expenses: how many, how much, and
/// how far ahead.
private struct UpcomingRow: View {
    let items: [Transaction]
    let expanded: Bool
    let mainCurrency: String

    var body: some View {
        let dates = items.map(\.date)
        HStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming · \(items.count)")
                if let last = dates.max() {
                    Text("Until \(last.formatted(.dateTime.month(.abbreviated).year()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Formatting.totalsText(Currency.totals(of: items, main: mainCurrency))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded ? "Hides future expenses" : "Shows future expenses")
    }
}
