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
    /// Offered as suggestions when the search field is empty.
    @Query(filter: #Predicate<ExpenseCategory> { !$0.isArchived }, sort: \ExpenseCategory.sortOrder)
    private var categories: [ExpenseCategory]

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
                SearchResults(searchText: searchText, mainCurrency: mainCurrency, actions: actions) { start in
                    // From a result's month heading: that month, in full.
                    month = start
                    searchText = ""
                }
            }
        }
        .navigationTitle("Expenses")
        .searchable(text: $searchText, prompt: "Search all months")
        .searchSuggestions {
            // Before anything's typed: one tap to a category, or to what
            // still needs one.
            if searchText.isEmpty {
                Label("Uncategorised", systemImage: "tag")
                    .searchCompletion("Uncategorised")
                ForEach(categories) { category in
                    Label {
                        Text(category.name)
                    } icon: {
                        Image(systemName: category.symbol).foregroundStyle(category.tint)
                    }
                    .searchCompletion(category.name)
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
                .navigationTitle(draft.isEditing ? "Edit Expense" : "New Expense")
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
    var showsDate = true
    let actions: RowActions

    var body: some View {
        Button {
            actions.edit(transaction)
        } label: {
            TransactionRow(transaction: transaction, showsDate: showsDate)
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

    /// Only the month's uncategorised expenses, to work through them.
    @State private var onlyUncategorised = false

    private var uncategorised: Int { items.filter { $0.category == nil }.count }

    private var shown: [Transaction] {
        onlyUncategorised ? items.filter { $0.category == nil } : items
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    MonthSwitcher(month: $month)
                    if !items.isEmpty {
                        summary
                    }
                }
                .padding(.vertical, 4)
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

            ForEach(MonthIndex.days(of: shown), id: \.day) { day in
                Section {
                    ForEach(day.items) { transaction in
                        ExpenseRowButton(transaction: transaction, showsDate: false, actions: actions)
                    }
                } header: {
                    HStack {
                        Text(Formatting.dayTitle(day.day))
                        Spacer()
                        Formatting.mainTotalText(of: day.items, main: mainCurrency)
                            .monospacedDigit()
                    }
                    .font(.subheadline.weight(.semibold))
                    .textCase(nil)
                }
            }
        }
        .listSectionSpacing(.compact)
        .onChange(of: uncategorised) { _, count in
            // Nothing left to filter for: back to the whole month.
            if count == 0 { onlyUncategorised = false }
        }
    }

    /// The month's total, large, with its count — and, when some are
    /// uncategorised, a chip that narrows the list to them.
    private var summary: some View {
        VStack(spacing: 6) {
            Formatting.mainTotalText(of: items, main: mainCurrency)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(items.count == 1 ? "1 expense" : "\(items.count) expenses")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if uncategorised > 0 {
                Button {
                    withAnimation { onlyUncategorised.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: onlyUncategorised ? "xmark.circle.fill" : "tag")
                        Text(onlyUncategorised ? "Showing \(uncategorised) uncategorised" : "\(uncategorised) uncategorised")
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .foregroundStyle(onlyUncategorised ? Color.white : Color.orange)
                    .background(onlyUncategorised ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.orange.opacity(0.15)),
                                in: .capsule)
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("uncategorisedFilter")
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

}

/// Search results from every month: how many and what they come to, then
/// the matches grouped by month, newest first. A month's heading opens that
/// month.
private struct SearchResults: View {
    let searchText: String
    let mainCurrency: String
    let actions: RowActions
    let openMonth: (Date) -> Void

    @Query(sort: \Transaction.date, order: .reverse) private var transactions: [Transaction]
    @Environment(\.dismissSearch) private var dismissSearch

    /// Every expense with what's searchable about it, newest first. Built
    /// once when search opens: a keystroke then only compares strings.
    @State private var index: [(transaction: Transaction, entry: ExpenseSearch.Entry)] = []
    @State private var matches: [Transaction] = []
    /// The text `matches` is for; nil until the first search has run.
    @State private var searched: String?

    private func buildIndex() {
        index = transactions.map { ($0, ExpenseSearch.entry(for: $0)) }
    }

    private func run() {
        let tokens = ExpenseSearch.tokens(searchText)
        matches = index.filter { ExpenseSearch.matches($0.entry, tokens: tokens) }.map(\.transaction)
        searched = searchText
    }

    var body: some View {
        let months = Dictionary(grouping: matches) { Formatting.monthStart($0.date) }
            .map { (start: $0.key, items: $0.value) }
            .sorted { $0.start > $1.start }
        List {
            if !matches.isEmpty {
                Section {
                    HStack(alignment: .firstTextBaseline) {
                        Text(matches.count == 1 ? "1 expense" : "\(matches.count) expenses")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Formatting.mainTotalText(of: matches, main: mainCurrency)
                            .font(.headline)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("searchSummary")
                }
            }
            ForEach(months, id: \.start) { month in
                Section {
                    ForEach(month.items) { transaction in
                        ExpenseRowButton(transaction: transaction, actions: actions)
                    }
                } header: {
                    Button {
                        dismissSearch()
                        openMonth(month.start)
                    } label: {
                        HStack(spacing: 4) {
                            Text(Formatting.monthTitle(month.start))
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Formatting.mainTotalText(of: month.items, main: mainCurrency)
                                .monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityHint("Opens this month")
                    .accessibilityIdentifier("searchMonth")
                }
            }
        }
        .listSectionSpacing(.compact)
        // Typing isn't held up by the search: it runs once the keys pause.
        .task(id: searchText) {
            if index.isEmpty {
                buildIndex()
            } else {
                try? await Task.sleep(for: .milliseconds(150))
                if Task.isCancelled { return }
            }
            run()
        }
        .onChange(of: transactions.count) {
            // One was deleted or added from here.
            buildIndex()
            run()
        }
        .overlay {
            if matches.isEmpty, searched == searchText {
                ContentUnavailableView {
                    Label("No results for “\(searchText)”", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a merchant, category, card, amount or month.")
                }
            }
        }
    }
}

struct TransactionRow: View {
    let transaction: Transaction
    /// Off under a day heading, which already says the date.
    var showsDate = true
    /// Off on a category's own page: only a subcategory is worth saying.
    var showsCategory = true
    /// Off on a subcategory's own page.
    var showsSubcategory = true

    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    /// For an expense in another currency: what it counts as in the totals,
    /// at the rate it was logged with.
    private var converted: Decimal? {
        guard transaction.currencyCode != mainCurrency else { return nil }
        return transaction.amount(in: mainCurrency)
    }

    /// "Taxi · SIB Cashback", with the date in front when it isn't shown
    /// elsewhere. The subcategory, being more specific, stands in for its
    /// category; "Uncategorised" is in orange, so it's easy to spot.
    private var detailsText: Text {
        var parts: [Text] = []
        if showsDate { parts.append(Text(transaction.date.formatted(.dateTime.day().month(.abbreviated)))) }
        if let category = transaction.category {
            if let subcategory = transaction.subcategory {
                if showsSubcategory { parts.append(Text(subcategory.name)) }
            } else if showsCategory {
                parts.append(Text(category.name))
            }
        } else if showsCategory {
            parts.append(Text("Uncategorised").foregroundStyle(.orange))
        }
        if let account = transaction.account {
            parts.append(Text(account.name))
        }
        guard let first = parts.first else { return Text("") }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(transaction.category)

            VStack(alignment: .leading, spacing: 3) {
                Text(transaction.merchant.isEmpty ? "Unnamed" : transaction.merchant)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                // One line of text, not separate pieces side by side — those
                // each wrapped in their own column when space ran out.
                // Ordered by importance, since the end is what gets cut.
                detailsText
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // Take all the width the amount leaves. A Spacer here would split
            // it with the text, cutting the details short beside empty space.
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 3) {
                Formatting.moneyText(transaction.amount, code: transaction.currencyCode)
                    .font(.body.weight(.semibold))
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
