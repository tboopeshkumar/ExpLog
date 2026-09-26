import SwiftUI
import SwiftData

/// Spending for one month, by category.
///
/// The ranked list is the chart. Each row carries a share bar, all in one
/// hue: the bars only encode size, and identity comes from the coloured icon
/// and name beside them. Colouring bars by category was ruled out — nine
/// category hues can't all be told apart (system red and pink measure ΔE 3.3,
/// below the 15 floor), and a chart that needs you to match colours would
/// inherit that.
struct SummaryView: View {
    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var month = Formatting.monthStart(.now)
    /// Category or merchant view; remembered between launches.
    @AppStorage("summaryBreakdown") private var breakdown: Breakdown = .category
    /// Watched so the totals follow a change of main currency immediately.
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    private var summary: MonthSummary {
        MonthSummary(month: month, transactions: transactions, mainCurrency: mainCurrency)
    }

    /// The furthest month worth stepping to: this one, or later when there are
    /// future-dated expenses, such as instalments imported from Money Manager.
    private var isLastMonth: Bool {
        let latest = transactions.first?.date ?? .now   // sorted newest first
        return month >= Formatting.monthStart(max(latest, .now))
    }

    var body: some View {
        let summary = summary
        List {
            Section {
                monthSwitcher
                headline(summary)
            }

            if summary.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No expenses",
                        systemImage: "chart.bar",
                        description: Text("Nothing logged in \(Formatting.monthTitle(month)).")
                    )
                }
            } else if !summary.rows.isEmpty {
                Section {
                    switch breakdown {
                    case .category:
                        ForEach(summary.rows) { row in
                            NavigationLink {
                                MonthExpensesView(scope: .category(row.category), month: month)
                            } label: {
                                ShareRow(
                                    category: row.category,
                                    title: row.category?.name ?? "Uncategorised",
                                    amount: row.amount,
                                    share: row.share,
                                    currencyCode: summary.currencyCode
                                )
                            }
                        }
                    case .merchant:
                        ForEach(merchantRows) { row in
                            NavigationLink {
                                MonthExpensesView(scope: .merchant(key: row.key, name: row.name), month: month)
                            } label: {
                                ShareRow(
                                    category: row.category,
                                    title: row.name,
                                    amount: row.amount,
                                    share: row.share,
                                    currencyCode: summary.currencyCode,
                                    count: row.count
                                )
                            }
                        }
                    }
                } header: {
                    Picker("Breakdown", selection: $breakdown) {
                        Text("Category").tag(Breakdown.category)
                        Text("Merchant").tag(Breakdown.merchant)
                    }
                    .pickerStyle(.segmented)
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
            }
        }
        .navigationTitle("Summary")
    }

    // MARK: - Header

    private var monthSwitcher: some View {
        HStack {
            Button("Previous month", systemImage: "chevron.left") { step(-1) }
            Spacer()
            Text(Formatting.monthTitle(month))
                .font(.headline)
            Spacer()
            Button("Next month", systemImage: "chevron.right") { step(1) }
                .disabled(isLastMonth)
        }
        .labelStyle(.iconOnly)
        // Two buttons in one row: without this, a tap anywhere hits the first.
        .buttonStyle(.borderless)
        // The switcher and the total read as one header block.
        .listRowSeparator(.hidden)
    }

    private func headline(_ summary: MonthSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The one hero figure on the screen.
            Formatting.moneyText(summary.total, code: summary.currencyCode)
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(summary.count == 1 ? "1 expense" : "\(summary.count) expenses")
                .foregroundStyle(.secondary)
            // Only expenses logged without a rate: they can't be counted in
            // the total, so they're shown beside it.
            if !summary.otherCurrencies.isEmpty {
                (Text("Plus ") + Formatting.totalsText(summary.otherCurrencies)
                    + Text(" with no exchange rate"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// This month's merchants, main currency only.
    private var merchantRows: [MerchantBreakdown.Row] {
        let range = Formatting.monthRange(containing: month)
        return MerchantBreakdown(
            transactions: transactions.filter { range.contains($0.date) },
            mainCurrency: mainCurrency
        ).rows
    }

    private func step(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month) else { return }
        month = Formatting.monthStart(next)
    }
}

/// One line of a breakdown: icon and name, amount and share, and a share bar.
/// Used for categories, subcategories and merchants.
private struct ShareRow: View {
    let category: ExpenseCategory?
    let title: String
    let amount: Decimal
    let share: Double
    let currencyCode: String
    /// How many expenses, where that says something — "12×" at a merchant.
    /// Shown from two up.
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .lineLimit(1)
                    // Once is the default; only repeat visits are worth a mark.
                    if let count, count > 1 {
                        Text("\(count)×")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(count == 1 ? "1 expense" : "\(count) expenses")
                    }
                    Spacer(minLength: 8)
                    // Tabular digits so amounts align down the column.
                    Formatting.moneyText(amount, code: currencyCode)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    ShareBar(share: share)
                    Text(share, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A thin horizontal bar: the filled part is the share of the month, on a
/// recessive track. One hue for every row.
private struct ShareBar: View {
    let share: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(.tint)
                    // A sliver stays visible for tiny shares rather than vanishing.
                    .frame(width: max(geometry.size.width * share, share > 0 ? 3 : 0))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// One month's expenses for a category or a merchant, opened from a summary
/// row. A category also gets its breakdowns: by subcategory, and by merchant.
private struct MonthExpensesView: View {
    enum Scope {
        case category(ExpenseCategory?)
        /// MerchantBreakdown.key, and the name to show.
        case merchant(key: String, name: String)
    }

    let scope: Scope
    let month: Date

    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var editing: TransactionDraft?
    @State private var categorising: Transaction?
    @State private var showsAllMerchants = false
    @Environment(\.modelContext) private var context
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    /// Merchants shown before "Show all", so a long tail doesn't push the
    /// expenses off the screen.
    private let merchantPreview = 5

    private var matching: [Transaction] {
        let range = Formatting.monthRange(containing: month)
        return transactions.filter { transaction in
            guard range.contains(transaction.date) else { return false }
            switch scope {
            case .category(let category):
                return transaction.category?.persistentModelID == category?.persistentModelID
            case .merchant(let key, _):
                return MerchantBreakdown.key(for: transaction.merchant) == key
            }
        }
    }

    private var title: String {
        switch scope {
        case .category(let category): return category?.name ?? "Uncategorised"
        case .merchant(_, let name): return name
        }
    }

    var body: some View {
        let matching = matching
        let category: ExpenseCategory? = if case .category(let category) = scope { category } else { nil }
        let isCategory = if case .category = scope { true } else { false }
        let subcategories = SubcategoryBreakdown(transactions: matching, mainCurrency: mainCurrency)
        let merchants = MerchantBreakdown(transactions: matching, mainCurrency: mainCurrency)
        let showsSubcategories = isCategory && subcategories.isWorthShowing
        // One merchant would be a row saying "100%".
        let showsMerchants = isCategory && merchants.rows.count > 1

        List {
            if showsSubcategories {
                Section("By subcategory") {
                    ForEach(subcategories.rows) { row in
                        ShareRow(
                            category: category,
                            title: row.subcategory?.name ?? "No subcategory",
                            amount: row.amount,
                            share: row.share,
                            currencyCode: mainCurrency
                        )
                    }
                }
            }
            if showsMerchants {
                Section("By merchant") {
                    let shown = showsAllMerchants ? merchants.rows : Array(merchants.rows.prefix(merchantPreview))
                    ForEach(shown) { row in
                        NavigationLink {
                            MonthExpensesView(scope: .merchant(key: row.key, name: row.name), month: month)
                        } label: {
                            ShareRow(
                                category: category,
                                title: row.name,
                                amount: row.amount,
                                share: row.share,
                                currencyCode: mainCurrency,
                                count: row.count
                            )
                        }
                    }
                    if merchants.rows.count > merchantPreview {
                        Button(showsAllMerchants ? "Show fewer" : "Show all \(merchants.rows.count) merchants") {
                            withAnimation { showsAllMerchants.toggle() }
                        }
                    }
                }
            }
            Section(showsSubcategories || showsMerchants ? "Expenses" : "") {
                ForEach(matching) { transaction in
                    Button {
                        editing = TransactionDraft(editing: transaction)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                    .buttonStyle(.plain)
                    .expenseActions(
                        for: transaction,
                        categorise: { categorising = $0 },
                        copy: { editing = TransactionDraft(copying: $0) },
                        delete: { context.delete($0); try? context.save() }
                    )
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            // Editing the last one out of this scope empties the list.
            if matching.isEmpty {
                ContentUnavailableView("No expenses", systemImage: "tray")
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

enum Breakdown: String {
    case category, merchant
}
