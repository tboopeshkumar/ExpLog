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

    /// Shared with Expenses, so both tabs show the same month.
    @Binding var month: Date
    /// Category or merchant view; remembered between launches.
    @AppStorage("summaryBreakdown") private var breakdown: Breakdown = .category
    /// Watched so the totals follow a change of main currency immediately.
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    private var summary: MonthSummary {
        MonthSummary(month: month, transactions: transactions, mainCurrency: mainCurrency)
    }


    var body: some View {
        let summary = summary
        List {
            Section {
                VStack(spacing: 14) {
                    MonthSwitcher(month: $month)
                    if !summary.isEmpty {
                        headline(summary)
                    }
                }
                .padding(.vertical, 4)
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


    private func headline(_ summary: MonthSummary) -> some View {
        VStack(spacing: 6) {
            // The one hero figure on the screen.
            Formatting.moneyText(summary.total, code: summary.currencyCode)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            countLine(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            // Only expenses logged without a rate: they can't be counted in
            // the total, so they're shown beside it.
            if !summary.otherCurrencies.isEmpty {
                (Text("Plus ") + Formatting.totalsText(summary.otherCurrencies)
                    + Text(" with no exchange rate"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            comparison(summary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    /// Spending to date: the month up to today, so instalments dated later
    /// in it don't count towards the pace. nil for a future month.
    private var spentSoFar: Decimal? {
        guard let range = MonthPace.countedRange(for: month) else { return nil }
        return Currency.mainTotal(of: transactions.filter { range.contains($0.date) }, main: mainCurrency).total
    }

    /// "23 expenses · Ð 70.17 a day"
    private func countLine(_ summary: MonthSummary) -> Text {
        let count = Text(summary.count == 1 ? "1 expense" : "\(summary.count) expenses")
        guard let spent = spentSoFar, spent > 0,
              let perDay = MonthPace.dailyAverage(of: spent, in: month) else { return count }
        return count + Text(" · ") + Formatting.moneyText(perDay, code: summary.currencyCode) + Text(" a day")
    }

    /// "↑ 18% vs August", or for this month "↓ 6% vs 1–3 Sep": the same days
    /// of the month before, so an early month isn't set against a whole one.
    @ViewBuilder
    private func comparison(_ summary: MonthSummary) -> some View {
        if let range = MonthPace.comparisonRange(for: month), let spent = spentSoFar {
            let before = Currency.mainTotal(of: transactions.filter { range.contains($0.date) }, main: mainCurrency).total
            if let change = MonthPace.change(from: before, to: spent) {
                let label = Self.comparisonLabel(range, wholeMonth: range == Formatting.monthRange(containing: range.lowerBound))
                let same = abs(change) < 0.005
                HStack(spacing: 4) {
                    if !same {
                        Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                    }
                    Text(same ? "Same as \(label)" : "\(abs(change), format: .percent.precision(.fractionLength(0))) vs \(label)")
                }
                .font(.footnote.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                // More spent is the one to notice; less is good news.
                .foregroundStyle(same ? Color.secondary : change > 0 ? Color.orange : Color.green)
                .background((same ? Color.secondary : change > 0 ? Color.orange : Color.green).opacity(0.15), in: .capsule)
                .accessibilityLabel(same ? "Same as \(label)"
                                    : "\(abs(change), format: .percent.precision(.fractionLength(0))) \(change > 0 ? "more" : "less") than \(label)")
            }
        }
    }

    /// "August", or "1–3 Aug" for part of it.
    private static func comparisonLabel(_ range: Range<Date>, wholeMonth: Bool) -> String {
        if wholeMonth { return range.lowerBound.formatted(.dateTime.month(.wide)) }
        let last = Calendar.current.date(byAdding: .day, value: -1, to: range.upperBound) ?? range.lowerBound
        let month = range.lowerBound.formatted(.dateTime.month(.abbreviated))
        let first = Calendar.current.component(.day, from: range.lowerBound)
        let end = Calendar.current.component(.day, from: last)
        return first == end ? "\(first) \(month)" : "\(first)–\(end) \(month)"
    }

    /// This month's merchants, main currency only.
    private var merchantRows: [MerchantBreakdown.Row] {
        let range = Formatting.monthRange(containing: month)
        return MerchantBreakdown(
            transactions: transactions.filter { range.contains($0.date) },
            mainCurrency: mainCurrency
        ).rows
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
                        .font(.body.weight(.medium))
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
                        .font(.body.weight(.semibold))
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

        let monthTotal = MonthSummary(month: month, transactions: transactions, mainCurrency: mainCurrency).total
        let total = Currency.mainTotal(of: matching, main: mainCurrency)

        List {
            if !matching.isEmpty {
                Section {
                    VStack(spacing: 4) {
                        Formatting.totalsText([Currency.Total(code: mainCurrency, amount: total.total, count: 0)] + total.unconverted)
                            .font(.system(.title, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        shareLine(count: matching.count, amount: total.total, of: monthTotal)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
            }
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
                        // The page is already the category: say only what's more specific.
                        TransactionRow(transaction: transaction, showsCategory: !isCategory)
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
        .listSectionSpacing(.compact)
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

extension MonthExpensesView {
    /// "8 expenses · 47% of September"
    fileprivate func shareLine(count: Int, amount: Decimal, of monthTotal: Decimal) -> Text {
        let expenses = Text(count == 1 ? "1 expense" : "\(count) expenses")
        guard monthTotal > 0 else { return expenses }
        let share = NSDecimalNumber(decimal: amount / monthTotal).doubleValue
        return expenses + Text(" · \(share, format: .percent.precision(.fractionLength(0))) of \(month.formatted(.dateTime.month(.wide)))")
    }
}

enum Breakdown: String {
    case category, merchant
}
