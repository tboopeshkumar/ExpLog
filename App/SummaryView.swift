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

    private var summary: MonthSummary {
        MonthSummary(month: month, transactions: transactions)
    }

    private var isCurrentMonth: Bool {
        month >= Formatting.monthStart(.now)
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
            } else {
                Section("By category") {
                    ForEach(summary.rows) { row in
                        NavigationLink {
                            CategoryMonthView(category: row.category, month: month)
                        } label: {
                            CategoryShareRow(row: row, currencyCode: summary.currencyCode)
                        }
                    }
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
                .disabled(isCurrentMonth)
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
        }
        .padding(.vertical, 4)
    }

    private func step(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month) else { return }
        month = Formatting.monthStart(next)
    }
}

/// One category's line: icon and name, amount and share, and a share bar.
private struct CategoryShareRow: View {
    let row: MonthSummary.Row
    let currencyCode: String

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(row.category)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.category?.name ?? "Uncategorised")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Tabular digits so amounts align down the column.
                    Formatting.moneyText(row.amount, code: currencyCode)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    ShareBar(share: row.share)
                    Text(row.share, format: .percent.precision(.fractionLength(0)))
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

/// One category's transactions in one month, opened from a summary row.
private struct CategoryMonthView: View {
    let category: ExpenseCategory?
    let month: Date

    @Query(sort: \Transaction.date, order: .reverse)
    private var transactions: [Transaction]

    @State private var editing: TransactionDraft?

    private var matching: [Transaction] {
        let range = Formatting.monthRange(containing: month)
        return transactions.filter {
            range.contains($0.date) && $0.category?.persistentModelID == category?.persistentModelID
        }
    }

    var body: some View {
        List(matching) { transaction in
            Button {
                editing = TransactionDraft(editing: transaction)
            } label: {
                TransactionRow(transaction: transaction)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle(category?.name ?? "Uncategorised")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            // Recategorising the last one empties this list.
            if matching.isEmpty {
                ContentUnavailableView("No expenses", systemImage: "tray")
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
}
