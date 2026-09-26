import SwiftUI
import SwiftData

/// The Expenses tab: one month at a time, grouped by day, with the month
/// switcher on top. Searching looks across every month instead.
struct TransactionListView: View {
    /// Shared with Summary, so both tabs show the same month.
    @Binding var month: Date

    @Environment(\.modelContext) private var context
    @State private var editing: TransactionDraft?
    @State private var categorising: Transaction?
    @State private var searchText = ""
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    private var actions: RowActions {
        RowActions(
            edit: { editing = TransactionDraft(editing: $0) },
            categorise: { categorising = $0 },
            copy: { editing = TransactionDraft(copying: $0) },
            delete: { context.delete($0); try? context.save() }
        )
    }

    var body: some View {
        Group {
            if searchText.isEmpty {
                MonthLedger(month: $month, mainCurrency: mainCurrency, actions: actions)
                    // A fresh view per month: its own query, scrolled to the top.
                    .id(month)
            } else {
                SearchResults(searchText: searchText, mainCurrency: mainCurrency, actions: actions)
            }
        }
        .navigationTitle("Expenses")
        .searchable(text: $searchText, prompt: "Search all months")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add", systemImage: "plus") {
                    editing = TransactionDraft()
                }
            }
        }
        .sheet(item: $categorising) { transaction in
            QuickCategorySheet(transaction: transaction)
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
}

/// What a row can do, passed down so month and search views share it.
struct RowActions {
    let edit: (Transaction) -> Void
    let categorise: (Transaction) -> Void
    let copy: (Transaction) -> Void
    let delete: (Transaction) -> Void
}

/// A tappable expense row with its swipe and long-press actions.
private struct ExpenseRowButton: View {
    let transaction: Transaction
    let actions: RowActions

    var body: some View {
        Button {
            actions.edit(transaction)
        } label: {
            TransactionRow(transaction: transaction)
        }
        .buttonStyle(.plain)
        .expenseActions(
            for: transaction,
            categorise: actions.categorise,
            copy: actions.copy,
            delete: actions.delete
        )
    }
}

/// One month's expenses. Fetches only that month — not every expense ever —
/// so it stays quick however many years are logged.
private struct MonthLedger: View {
    @Binding var month: Date
    let mainCurrency: String
    let actions: RowActions

    @Query private var items: [Transaction]
    @Query(MonthSwitcher.earliestDescriptor) private var anyExpense: [Transaction]

    init(month: Binding<Date>, mainCurrency: String, actions: RowActions) {
        _month = month
        self.mainCurrency = mainCurrency
        self.actions = actions
        let range = Formatting.monthRange(containing: month.wrappedValue)
        let start = range.lowerBound, end = range.upperBound
        _items = Query(
            filter: #Predicate<Transaction> { $0.date >= start && $0.date < end },
            sort: \Transaction.date,
            order: .reverse
        )
    }

    var body: some View {
        List {
            Section {
                MonthSwitcher(month: $month)
                if !items.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(items.count == 1 ? "1 expense" : "\(items.count) expenses")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Formatting.mainTotalText(of: items, main: mainCurrency)
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
            }

            if items.isEmpty {
                Section {
                    if anyExpense.isEmpty {
                        ContentUnavailableView {
                            Label("Nothing logged yet", systemImage: "tray")
                        } description: {
                            Text("Share a bank SMS from Messages, or add one by hand.")
                        }
                    } else {
                        ContentUnavailableView(
                            "No expenses",
                            systemImage: "tray",
                            description: Text("Nothing logged in \(Formatting.monthTitle(month)).")
                        )
                    }
                }
            }

            ForEach(MonthIndex.days(of: items), id: \.day) { day in
                Section {
                    ForEach(day.items) { transaction in
                        ExpenseRowButton(transaction: transaction, actions: actions)
                    }
                } header: {
                    HStack {
                        Text(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        Spacer()
                        Formatting.mainTotalText(of: day.items, main: mainCurrency)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

/// Search results from every month, grouped by month, newest first.
private struct SearchResults: View {
    let searchText: String
    let mainCurrency: String
    let actions: RowActions

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]

    private var matches: [Transaction] {
        let needle = searchText.lowercased()
        return transactions.filter {
            $0.merchant.lowercased().contains(needle)
                || $0.note.lowercased().contains(needle)
                || ($0.category?.name.lowercased().contains(needle) ?? false)
                || ($0.subcategory?.name.lowercased().contains(needle) ?? false)
        }
    }

    var body: some View {
        let matches = matches
        let months = Dictionary(grouping: matches) { Formatting.monthStart($0.date) }
            .map { (start: $0.key, items: $0.value) }
            .sorted { $0.start > $1.start }
        List {
            ForEach(months, id: \.start) { month in
                Section {
                    ForEach(month.items) { transaction in
                        ExpenseRowButton(transaction: transaction, actions: actions)
                    }
                } header: {
                    HStack {
                        Text(Formatting.monthTitle(month.start))
                        Spacer()
                        Formatting.mainTotalText(of: month.items, main: mainCurrency)
                            .monospacedDigit()
                    }
                }
            }
        }
        .overlay {
            if matches.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction

    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    /// For an expense in another currency: what it counts as in the totals,
    /// at the rate it was logged with.
    private var converted: Decimal? {
        guard transaction.currencyCode != mainCurrency else { return nil }
        return transaction.amount(in: mainCurrency)
    }

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

            VStack(alignment: .trailing, spacing: 2) {
                Formatting.moneyText(transaction.amount, code: transaction.currencyCode)
                    .monospacedDigit()
                if let converted {
                    (Text("≈ ") + Formatting.moneyText(converted, code: mainCurrency))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 2)
    }
}

extension TransactionDraft: Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
