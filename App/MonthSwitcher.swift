import SwiftUI
import SwiftData

/// "‹ September 2026 ›", shared by Expenses and Summary. The arrows step a
/// month within the months that have expenses (see MonthIndex.bounds); the
/// title opens a list of every month to jump straight to one.
struct MonthSwitcher: View {
    @Binding var month: Date

    @Query(MonthSwitcher.earliestDescriptor) private var earliest: [Transaction]
    @Query(MonthSwitcher.latestDescriptor) private var latest: [Transaction]
    @State private var choosing = false

    /// Just the first and last expense, not every one: all the arrows need.
    static var earliestDescriptor: FetchDescriptor<Transaction> {
        var descriptor = FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    static var latestDescriptor: FetchDescriptor<Transaction> {
        var descriptor = FetchDescriptor<Transaction>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }

    private var bounds: ClosedRange<Date> {
        MonthIndex.bounds(earliest: earliest.first?.date, latest: latest.first?.date)
    }

    var body: some View {
        HStack {
            Button("Previous month", systemImage: "chevron.left") {
                month = MonthIndex.step(month, by: -1, within: bounds)
            }
            .disabled(month <= bounds.lowerBound)

            Spacer()

            Button {
                choosing = true
            } label: {
                HStack(spacing: 4) {
                    Text(Formatting.monthTitle(month))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("monthTitle")
            .accessibilityLabel(Formatting.monthTitle(month))
            .accessibilityHint("Choose a month")

            Spacer()

            Button("Next month", systemImage: "chevron.right") {
                month = MonthIndex.step(month, by: 1, within: bounds)
            }
            .disabled(month >= bounds.upperBound)
        }
        .labelStyle(.iconOnly)
        // Three buttons in one list row: without this, a tap anywhere hits the first.
        .buttonStyle(.borderless)
        .listRowSeparator(.hidden)
        .sheet(isPresented: $choosing) {
            MonthPicker(month: $month)
        }
    }
}

/// Every month that has expenses, by year, with its total — tap one to go
/// there. "This month" comes back to today.
private struct MonthPicker: View {
    @Binding var month: Date

    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [Transaction]
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main

    var body: some View {
        let calendar = Calendar.current
        let months = MonthIndex.months(of: transactions, mainCurrency: mainCurrency)
        let years = Dictionary(grouping: months) { calendar.component(.year, from: $0.start) }
            .sorted { $0.key > $1.key }

        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(years, id: \.key) { year, monthsInYear in
                        Section(String(year)) {
                            ForEach(monthsInYear) { entry in
                                row(entry)
                                    .id(entry.start)
                            }
                        }
                    }
                }
                .onAppear { proxy.scrollTo(month, anchor: .center) }
            }
            .navigationTitle("Choose month")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("This month") {
                        month = Formatting.monthStart(.now)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ entry: MonthIndex.Month) -> some View {
        Button {
            month = entry.start
            dismiss()
        } label: {
            HStack {
                Text(entry.start.formatted(.dateTime.month(.wide)))
                if entry.start > Date.now {
                    Text("upcoming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Formatting.totalsText([Currency.Total(code: mainCurrency, amount: entry.total, count: entry.count)] + entry.unconverted)
                        .monospacedDigit()
                    Text(entry.count == 1 ? "1 expense" : "\(entry.count) expenses")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if entry.start == month {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
