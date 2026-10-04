import SwiftUI
import SwiftData
import Charts

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
                                MonthExpensesView(scope: .category(row.category), month: $month)
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
                                MonthExpensesView(scope: .merchant(key: row.key, name: row.name), month: $month)
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
            PaceChip(transactions: transactions, month: month, mainCurrency: mainCurrency)
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

/// "↑ 18% vs August", or for this month "↓ 6% vs 1–3 Sep": the same days
/// of the month before, so an early month isn't set against a whole one,
/// counting only what's dated up to today. Nothing when there's nothing
/// before to compare with. Give it the expenses to compare — everything, or
/// one category's or merchant's.
private struct PaceChip: View {
    let transactions: [Transaction]
    let month: Date
    let mainCurrency: String

    private func total(in range: Range<Date>) -> Decimal {
        Currency.mainTotal(of: transactions.filter { range.contains($0.date) }, main: mainCurrency).total
    }

    var body: some View {
        if let counted = MonthPace.countedRange(for: month),
           let range = MonthPace.comparisonRange(for: month),
           let change = MonthPace.change(from: total(in: range), to: total(in: counted)) {
            let label = Self.label(range, wholeMonth: range == Formatting.monthRange(containing: range.lowerBound))
            let same = abs(change) < 0.005
            let percent = abs(change).formatted(.percent.precision(.fractionLength(0)))
            // More spent is the one to notice; less is good news.
            let color: Color = same ? .secondary : change > 0 ? .orange : .green
            HStack(spacing: 4) {
                if !same {
                    Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                }
                Text(same ? "Same as \(label)" : "\(percent) vs \(label)")
            }
            .font(.footnote.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(same ? "Same as \(label)" : "\(percent) \(change > 0 ? "more" : "less") than \(label)")
        }
    }

    /// "August", or "1–3 Aug" for part of it.
    private static func label(_ range: Range<Date>, wholeMonth: Bool) -> String {
        if wholeMonth { return range.lowerBound.formatted(.dateTime.month(.wide)) }
        let last = Calendar.current.date(byAdding: .day, value: -1, to: range.upperBound) ?? range.lowerBound
        let month = range.lowerBound.formatted(.dateTime.month(.abbreviated))
        let first = Calendar.current.component(.day, from: range.lowerBound)
        let end = Calendar.current.component(.day, from: last)
        return first == end ? "\(first) \(month)" : "\(first)–\(end) \(month)"
    }
}

/// Six months of totals as thin bars, the month on screen at full strength
/// and the rest recessive; tap a bar to go to its month.
///
/// One series, so one hue and no legend — the page's title says what it is —
/// and no value on every bar: the month's own total is the figure above it.
private struct TrendChart: View {
    let points: [MonthTrend.Point]
    let selected: Date
    let currencyCode: String
    let onSelect: (Date) -> Void

    var body: some View {
        Chart(points) { point in
            // A baseline, so a month with nothing reads as zero, not missing.
            RuleMark(y: .value("Zero", 0))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color(.separator))
                .accessibilityHidden(true)
            BarMark(
                x: .value("Month", point.month, unit: .month),
                y: .value("Spent", NSDecimalNumber(decimal: point.total).doubleValue),
                width: .ratio(0.55)
            )
            .foregroundStyle(.tint.opacity(point.month == selected ? 1 : 0.3))
            .clipShape(.rect(topLeadingRadius: 4, topTrailingRadius: 4))
            .accessibilityLabel(point.month.formatted(.dateTime.month(.wide).year()))
            .accessibilityValue(Formatting.money(point.total, code: currencyCode))
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: points.map(\.month)) { value in
                AxisValueLabel(centered: true) {
                    if let month = value.as(Date.self) {
                        Text(month.formatted(.dateTime.month(.abbreviated)))
                            .font(.caption2)
                            .fontWeight(month == selected ? .semibold : .regular)
                            .foregroundStyle(month == selected ? Color.primary : Color.secondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                // The whole column is the target, not just the bar: a small
                // month's bar is a sliver.
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame.map({ geometry[$0] }),
                              let date: Date = proxy.value(atX: location.x - frame.minX) else { return }
                        let month = Formatting.monthStart(date)
                        if points.contains(where: { $0.month == month }) { onSelect(month) }
                    }
            }
        }
        .frame(height: 92)
        .accessibilityIdentifier("trendChart")
    }
}

/// One month's expenses for a category, a subcategory or a merchant, opened
/// from a summary row: the month's total and how it compares, six months of
/// it, its breakdowns, and the expenses by day. The month switcher is the
/// same one as Summary's, so stepping here keeps your place there.
private struct MonthExpensesView: View {
    enum Scope {
        case category(ExpenseCategory?)
        /// One of a category's subcategories; nil for its expenses with none.
        case subcategory(ExpenseCategory, ExpenseSubcategory?)
        /// MerchantBreakdown.key, and the name to show.
        case merchant(key: String, name: String)
    }

    let scope: Scope
    @Binding var month: Date

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

    /// Everything in this scope, any month: for the trend and the comparison.
    private var inScope: [Transaction] {
        transactions.filter { transaction in
            switch scope {
            case .category(let category):
                return transaction.category?.persistentModelID == category?.persistentModelID
            case .subcategory(let category, let subcategory):
                return transaction.category?.persistentModelID == category.persistentModelID
                    && transaction.subcategory?.persistentModelID == subcategory?.persistentModelID
            case .merchant(let key, _):
                return MerchantBreakdown.key(for: transaction.merchant) == key
            }
        }
    }

    private var title: String {
        switch scope {
        case .category(let category): return category?.name ?? "Uncategorised"
        case .subcategory(_, let subcategory): return subcategory?.name ?? "No subcategory"
        case .merchant(_, let name): return name
        }
    }

    var body: some View {
        let inScope = inScope
        let range = Formatting.monthRange(containing: month)
        let matching = inScope.filter { range.contains($0.date) }
        let category: ExpenseCategory? = switch scope {
        case .category(let category): category
        case .subcategory(let category, _): category
        case .merchant: nil
        }
        let isCategory = if case .category = scope { true } else { false }
        let isMerchant = if case .merchant = scope { true } else { false }
        let isSubcategory = if case .subcategory = scope { true } else { false }
        let subcategories = SubcategoryBreakdown(transactions: matching, mainCurrency: mainCurrency)
        let merchants = MerchantBreakdown(transactions: matching, mainCurrency: mainCurrency)
        // One row of either would only say "100%".
        let showsSubcategories = isCategory && subcategories.isWorthShowing && subcategories.rows.count > 1
        let showsMerchants = !isMerchant && merchants.rows.count > 1

        let monthTotal = MonthSummary(month: month, transactions: transactions, mainCurrency: mainCurrency).total
        let total = Currency.mainTotal(of: matching, main: mainCurrency)
        let trend = MonthTrend.points(of: inScope, selected: month, mainCurrency: mainCurrency)

        List {
            Section {
                VStack(spacing: 14) {
                    MonthSwitcher(month: $month)
                    if !matching.isEmpty {
                        VStack(spacing: 6) {
                            Formatting.totalsText([Currency.Total(code: mainCurrency, amount: total.total, count: 0)] + total.unconverted)
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                            shareLine(count: matching.count, amount: total.total, of: monthTotal)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            PaceChip(transactions: inScope, month: month, mainCurrency: mainCurrency)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    // A trend needs a second month to be one.
                    if trend.filter({ $0.total > 0 }).count > 1 {
                        TrendChart(points: trend, selected: Formatting.monthStart(month), currencyCode: mainCurrency) {
                            month = $0
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if matching.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No expenses",
                        systemImage: "tray",
                        description: Text("Nothing in \(title) in \(Formatting.monthTitle(month)).")
                    )
                }
            }

            if showsSubcategories {
                Section {
                    ForEach(subcategories.rows) { row in
                        NavigationLink {
                            if let category {
                                MonthExpensesView(scope: .subcategory(category, row.subcategory), month: $month)
                            }
                        } label: {
                            ShareRow(
                                category: category,
                                title: row.subcategory?.name ?? "No subcategory",
                                amount: row.amount,
                                share: row.share,
                                currencyCode: mainCurrency
                            )
                        }
                    }
                } header: {
                    sectionTitle("By subcategory")
                }
            }
            if showsMerchants {
                Section {
                    let shown = showsAllMerchants ? merchants.rows : Array(merchants.rows.prefix(merchantPreview))
                    ForEach(shown) { row in
                        NavigationLink {
                            MonthExpensesView(scope: .merchant(key: row.key, name: row.name), month: $month)
                        } label: {
                            ShareRow(
                                category: category ?? row.category,
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
                } header: {
                    sectionTitle("By merchant")
                }
            }

            // The expenses, by day, as on the Expenses tab.
            ForEach(MonthIndex.days(of: matching), id: \.day) { day in
                Section {
                    ForEach(day.items) { transaction in
                        Button {
                            editing = TransactionDraft(editing: transaction)
                        } label: {
                            // The page is already the category: say only what's more specific.
                            TransactionRow(transaction: transaction, showsDate: false, showsCategory: isMerchant,
                                           showsSubcategory: !isSubcategory)
                        }
                        .buttonStyle(.plain)
                        .expenseActions(
                            for: transaction,
                            categorise: { categorising = $0 },
                            copy: { editing = TransactionDraft(copying: $0) },
                            delete: { context.delete($0); try? context.save() }
                        )
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .textCase(nil)
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
