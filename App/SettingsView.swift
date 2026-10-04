import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @Query(filter: #Predicate<Account> { !$0.isArchived }) private var accounts: [Account]
    @Query(filter: #Predicate<ExpenseCategory> { !$0.isArchived }) private var categories: [ExpenseCategory]
    @Query private var merchants: [MerchantAlias]
    @Query private var formats: [MessageFormat]

    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showingImporter = false
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main
    @AppStorage(Currency.exchangeRatesKey, store: Currency.defaults) private var ratesJSON = ""
    @AppStorage(Currency.orderKey, store: Currency.defaults) private var currencyOrder = ""
    @AppStorage(Currency.hiddenKey, store: Currency.defaults) private var hiddenCurrencies = ""
    @State private var importReport: ImportReport?
    @AppStorage(MessageLogging.reviewKey) private var reviewMessageExpenses = false

    /// "INR, USD": the other currencies, as listed on their page.
    private var otherCurrencies: String {
        Currency.yours(order: currencyOrder, main: mainCurrency,
                       rates: ExchangeRates(main: mainCurrency, json: ratesJSON),
                       alsoUsed: Set(transactions.map(\.currencyCode)), hidden: hiddenCurrencies)
            .joined(separator: ", ")
    }

    var body: some View {
        List {
            Section {
                // Just the code here; the list names each currency.
                NavigationLink {
                    MainCurrencyPicker(selection: $mainCurrency)
                } label: {
                    SettingsRow("Main currency", symbol: "banknote", color: .green, value: mainCurrency)
                }
                NavigationLink { ExchangeRatesView() } label: {
                    SettingsRow("Other currencies", symbol: "arrow.left.arrow.right", color: .teal,
                                value: otherCurrencies.isEmpty ? nil : otherCurrencies)
                }
            } header: {
                Text("Currency")
            } footer: {
                Text("Totals are in \(mainCurrency). Other currencies count at the rate each expense was logged with.")
            }

            Section("Organise") {
                NavigationLink { AccountsView() } label: {
                    SettingsRow("Cards & accounts", symbol: "creditcard.fill", color: .blue, value: count(accounts.count))
                }
                NavigationLink { CategoriesView() } label: {
                    SettingsRow("Categories", symbol: "tag.fill", color: .orange, value: count(categories.count))
                }
            }

            Section {
                NavigationLink { ShortcutSetupView() } label: {
                    SettingsRow("Set up automatic logging", symbol: "wand.and.sparkles", color: .indigo)
                }
                Toggle(isOn: $reviewMessageExpenses) {
                    SettingsRow("Review before saving", symbol: "checklist", color: .purple)
                }
            } header: {
                Text("Logging from Messages")
            } footer: {
                Text(reviewMessageExpenses
                     ? "ExpLog opens so you can check each alert before saving."
                     : "Alerts are saved straight away.")
            }

            Section {
                NavigationLink { MerchantsView() } label: {
                    SettingsRow("Merchants", symbol: "storefront.fill", color: .pink, value: count(merchants.count))
                }
                NavigationLink { MessageFormatsView() } label: {
                    SettingsRow("Message formats", symbol: "text.viewfinder", color: .cyan, value: count(formats.count))
                }
                NavigationLink { ParserTesterView() } label: {
                    SettingsRow("Test message parsing", symbol: "text.magnifyingglass", color: .gray)
                }
            } header: {
                Text("Learned")
            } footer: {
                Text("What ExpLog has learned from the expenses you've saved.")
            }

            Section {
                Button {
                    export()
                } label: {
                    SettingsRow("Export CSV", symbol: "square.and.arrow.up", color: .blue)
                }
                .disabled(transactions.isEmpty)
                // Plain text like the other rows, not link blue.
                .tint(.primary)

                Button {
                    showingImporter = true
                } label: {
                    SettingsRow("Import CSV", symbol: "square.and.arrow.down", color: .blue)
                }
                .tint(.primary)
            } header: {
                Text("Data")
            } footer: {
                Text("\(transactions.count == 1 ? "1 expense" : "\(transactions.count) expenses") on this device. Import skips ones already here.")
            }

            Section {
                LabeledContent("Version", value: Self.version)
            } footer: {
                Text("Your expenses stay on this device; nothing is sent anywhere.")
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $exportURL) { url in
            ShareSheet(url: url)
        }
        .alert("Export failed", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            importCSV(result)
        }
        .alert(importReport?.title ?? "", isPresented: .constant(importReport != nil)) {
            Button("OK") { importReport = nil }
        } message: {
            Text(importReport?.message ?? "")
        }
    }

    private func importCSV(_ picked: Result<URL, Error>) {
        do {
            let url = try picked.get()
            // Files from outside the app's sandbox (iCloud Drive, AirDrop
            // inbox) are only readable inside a security-scoped access.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw CSV.ImportError.unreadable }
            importReport = ImportReport(try CSV.importRows(from: text, into: context))
        } catch {
            importReport = ImportReport(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func export() {
        do {
            exportURL = try CSV.write(transactions)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

/// What an import did, phrased for an alert.
private struct ImportReport {
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(_ result: CSV.ImportResult) {
        if result.added == 0 && result.filledSubcategories > 0 {
            title = "Updated \(result.filledSubcategories) expenses"
        } else {
            title = result.added == 1 ? "Imported 1 expense" : "Imported \(result.added) expenses"
        }
        var lines: [String] = []
        if result.filledSubcategories > 0 && result.added > 0 {
            lines.append("Added subcategories to \(result.filledSubcategories) expenses already here.")
        }
        if result.duplicates > 0 {
            let filledNote = result.added == 0 && result.filledSubcategories > 0
                ? " Their subcategories were filled in; nothing was added twice."
                : ""
            lines.append("Skipped \(result.duplicates) already in ExpLog.\(filledNote)")
        }
        if !result.newCategories.isEmpty {
            lines.append("New categories: \(result.newCategories.joined(separator: ", ")).")
        }
        if !result.newSubcategories.isEmpty {
            lines.append("New subcategories: \(result.newSubcategories.joined(separator: ", ")).")
        }
        if !result.newAccounts.isEmpty {
            lines.append("New accounts: \(result.newAccounts.joined(separator: ", ")).")
        }
        if !result.rejected.isEmpty {
            let shown = result.rejected.prefix(5).map { "line \($0.line): \($0.reason)" }
            let more = result.rejected.count > 5 ? " and \(result.rejected.count - 5) more" : ""
            lines.append("Couldn't read \(result.rejected.count): \(shown.joined(separator: "; "))\(more).")
        }
        message = lines.joined(separator: "\n\n")
    }
}

extension SettingsView {
    /// A count for a row's value, or nothing for none.
    fileprivate func count(_ n: Int) -> String? { n == 0 ? nil : "\(n)" }

    /// "1.0 (12)"
    fileprivate static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}

/// A Settings row: a symbol on a filled tile of its colour, as iOS Settings
/// draws them, the title, and a value in secondary text.
private struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color
    var value: String?

    /// A disabled button's row is dimmed by hand: the colours here are set
    /// explicitly, so the usual greying doesn't reach them.
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, symbol: String, color: Color, value: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.color = color
        self.value = value
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
            if let value {
                Spacer(minLength: 8)
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Main currency

/// The currency totals are counted in. Shows the current one, then every
/// supported currency — the ones you've spent in first — with search.
/// Switching is confirmed when there are expenses, because it changes what
/// counts in the totals.
private struct MainCurrencyPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @Query private var transactions: [Transaction]
    @State private var search = ""
    /// The currency tapped, waiting for the switch to be confirmed.
    @State private var pending: String?

    private func matches(_ code: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty
            || code.localizedCaseInsensitiveContains(query)
            || Currency.name(for: code).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        let counts = Dictionary(transactions.map { ($0.currencyCode, 1) }, uniquingKeysWith: +)
        // Spent in, most used first; then the rest in the usual order.
        let used = Currency.supported.filter { counts[$0] != nil && $0 != selection }
            .sorted { counts[$0]! > counts[$1]! }
        let others = Currency.supported.filter { counts[$0] == nil && $0 != selection }

        List {
            if search.isEmpty {
                Section {
                    VStack(spacing: 6) {
                        Formatting.currencyLabel(for: selection)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        Text(Currency.name(for: selection))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("currentMain")
                } footer: {
                    Text("Totals are counted in it, and new expenses start in it.")
                }
            }

            let shownUsed = used.filter(matches)
            if !shownUsed.isEmpty {
                Section("You've spent in") {
                    ForEach(shownUsed, id: \.self) { row($0, count: counts[$0]) }
                }
            }
            let shownOthers = others.filter(matches)
            if !shownOthers.isEmpty {
                Section(used.isEmpty ? "Change to" : "All currencies") {
                    ForEach(shownOthers, id: \.self) { row($0, count: nil) }
                }
            }
        }
        // Always showing: pulling down to find it isn't obvious on a short page.
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Code or name")
        .overlay {
            if !search.isEmpty, !(used + others).contains(where: matches) {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("Main currency")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending.map { "Change main currency to \($0)?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            if let code = pending {
                Button("Change to \(code)") {
                    selection = code
                    pending = nil
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if let code = pending {
                Text(Self.warning(from: selection, to: code, counts: counts))
            }
        }
    }

    private func row(_ code: String, count: Int?) -> some View {
        Button {
            // Nothing logged: nothing to explain.
            if transactions.isEmpty {
                selection = code
                dismiss()
            } else {
                pending = code
            }
        } label: {
            HStack(spacing: 12) {
                Text(code)
                    .font(.body.monospaced().weight(.semibold))
                    .frame(width: 48, alignment: .leading)
                Text(Currency.name(for: code))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)×")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(count == 1 ? "1 expense" : "\(count) expenses")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currency-\(code)")
    }

    /// What switching does to the totals, said before it's done.
    static func warning(from old: String, to new: String, counts: [String: Int]) -> String {
        var lines = ["Totals will be counted in \(new)."]
        if let inOld = counts[old], inOld > 0 {
            lines.append("Your \(inOld == 1 ? "1 expense" : "\(inOld) expenses") in \(old) won't count until \(old) has a rate in Other currencies; that page can then apply it to them.")
        }
        lines.append("Nothing is converted or deleted, and you can change back.")
        return lines.joined(separator: " ")
    }
}

// MARK: - Exchange rates

/// Your other currencies: the current rate for each, and the order they're
/// offered in when logging an expense. Rates are for expenses logged from now
/// on — each expense keeps the rate it was logged with, so changing one here
/// leaves past totals alone.
struct ExchangeRatesView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main
    @AppStorage(Currency.exchangeRatesKey, store: Currency.defaults) private var ratesJSON = ""
    @AppStorage(Currency.orderKey, store: Currency.defaults) private var order = ""
    @AppStorage(Currency.hiddenKey, store: Currency.defaults) private var hidden = ""

    private var rates: ExchangeRates { ExchangeRates(main: mainCurrency, json: ratesJSON) }

    /// In your order, then any others spent in or with a rate.
    private var listed: [String] {
        Currency.yours(order: order, main: mainCurrency, rates: rates,
                       alsoUsed: Set(transactions.map(\.currencyCode)), hidden: hidden)
    }

    /// Off the list and out of the pickers' top section, its current rate
    /// cleared. Expenses already logged keep their own rates.
    private func remove(at offsets: IndexSet) {
        let codes = listed
        let removed = offsets.map { codes[$0] }
        for code in removed {
            ratesJSON = ExchangeRates.setting(nil, for: code, main: mainCurrency, in: ratesJSON)
        }
        order = Currency.order(codes.filter { !removed.contains($0) })
        hidden = Currency.order(Currency.codes(hidden).filter { !removed.contains($0) } + removed)
    }

    @State private var adding = false
    /// The rate field with the keyboard, by currency code.
    @FocusState private var editingRate: String?

    private func add(_ code: String) {
        order = Currency.order(listed + [code])
        hidden = Currency.order(Currency.codes(hidden).filter { $0 != code })
    }

    var body: some View {
        let listed = listed
        let counts = Dictionary(transactions.map { ($0.currencyCode, 1) }, uniquingKeysWith: +)
        List {
            if listed.isEmpty {
                ContentUnavailableView {
                    Label("No other currencies", systemImage: "arrow.left.arrow.right")
                } description: {
                    Text("Add one you spend in, with its rate, and its expenses count in your \(mainCurrency) totals.")
                } actions: {
                    Button("Add Currency") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Section {
                    ForEach(listed, id: \.self) { code in
                        RateRow(
                            code: code,
                            main: mainCurrency,
                            expenseCount: counts[code] ?? 0,
                            unratedCount: Currency.unrated(code, in: transactions).count,
                            ratesJSON: $ratesJSON,
                            focus: $editingRate,
                            applyToUnrated: { rate in
                                Currency.applyRate(rate, toUnrated: code, main: mainCurrency, in: transactions)
                                try? context.save()
                            }
                        )
                        .accessibilityIdentifier("currency-\(code)")
                    }
                    .onMove { from, to in
                        var codes = listed
                        codes.move(fromOffsets: from, toOffset: to)
                        order = Currency.order(codes)
                    }
                    .onDelete(perform: remove)
                } header: {
                    Text("Rates from \(mainCurrency)")
                } footer: {
                    Text("Offered first when logging, in this order. A rate applies to expenses logged from now on; ones already logged keep theirs.")
                }
            }
        }
        .navigationTitle("Other currencies")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Currency", systemImage: "plus") { adding = true }
            }
            if listed.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            // The number pad has no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editingRate = nil }
                    .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $adding) {
            CurrencyPickerSheet(
                selection: Binding(get: { "" }, set: { add($0) }),
                title: "Add Currency",
                excluding: Set(listed + [mainCurrency])
            )
        }
    }
}

/// A currency: its code and name, "1 AED = [22.70] INR", what a round amount
/// comes to, and — when older expenses in it have no rate — an offer to give
/// them this one.
private struct RateRow: View {
    let code: String
    let main: String
    let expenseCount: Int
    let unratedCount: Int
    @Binding var ratesJSON: String
    var focus: FocusState<String?>.Binding
    let applyToUnrated: (Decimal) -> Void

    @State private var text = ""

    private var rate: Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
            .flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(code)
                    .font(.body.weight(.semibold))
                Text(Currency.name(for: code))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if expenseCount > 0 {
                    Text("\(expenseCount)×")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(expenseCount == 1 ? "1 expense" : "\(expenseCount) expenses")
                }
            }

            HStack(spacing: 8) {
                Text("1 \(main) =")
                    .foregroundStyle(.secondary)
                TextField("Rate", text: $text)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .focused(focus, equals: code)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 120)
                    .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("Rate: \(code) per 1 \(main)")
                Text(code)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)

            Group {
                if let rate {
                    // A round amount of the other currency, and what it comes to.
                    let sample = Decimal(100) * rate >= 1000 ? Decimal(1000) : Decimal(100)
                    Formatting.moneyText(sample, code: code) + Text(" ≈ ") + Formatting.moneyText(sample / rate, code: main)
                } else if text.isEmpty {
                    Text("No rate: expenses in \(code) aren't counted in totals.")
                        .foregroundStyle(.orange)
                } else {
                    Text("Enter a number, like 22.70")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Expenses logged before any rate existed are out of the totals
            // for good unless given one. Offered, never done automatically.
            if let rate, unratedCount > 0 {
                Button(unratedCount == 1
                       ? "Apply to 1 earlier expense without a rate"
                       : "Apply to \(unratedCount) earlier expenses without a rate") {
                    applyToUnrated(rate)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            text = ExchangeRates(main: main, json: ratesJSON).rate(for: code).map { "\($0)" } ?? ""
        }
        .onChange(of: text) { _, _ in
            // Saved as typed; clearing the field removes the rate.
            if rate != nil || text.isEmpty {
                ratesJSON = ExchangeRates.setting(rate, for: code, main: main, in: ratesJSON)
            }
        }
    }
}

// MARK: - Accounts

struct AccountsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.name) private var accounts: [Account]

    /// The card open in the editor; a new one when `adding`.
    @State private var editing: Account?
    @State private var adding = false
    /// A card with expenses, waiting for the delete to be confirmed.
    @State private var deleting: Account?

    var body: some View {
        List {
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No cards yet", systemImage: "creditcard")
                } description: {
                    Text("Add a card with text from its SMS alerts, like XXX4453, and alerts from it are matched to it.")
                } actions: {
                    Button("Add Card") { adding = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                Section {
                    ForEach(accounts) { account in
                        Button {
                            editing = account
                        } label: {
                            AccountRow(account: account)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { delete(account) }
                        }
                    }
                } footer: {
                    Text("An SMS containing a card's keyword is matched to that card.")
                }
            }
        }
        .navigationTitle("Cards & accounts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Card", systemImage: "plus") { adding = true }
            }
        }
        .sheet(item: $editing) { account in
            NavigationStack { AccountEditor(account: account) }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { AccountEditor(account: nil) }
        }
        .confirmationDialog(
            deleting.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            if let account = deleting {
                Button("Delete Card", role: .destructive) { remove(account) }
            }
        } message: {
            let count = deleting?.transactions?.count ?? 0
            Text("\(count == 1 ? "Its 1 expense stays" : "Its \(count) expenses stay"), with no card. Its alerts won't be matched any more.")
        }
    }

    /// Straight away for an unused card; with a question for one with expenses.
    private func delete(_ account: Account) {
        if (account.transactions?.count ?? 0) > 0 {
            deleting = account
        } else {
            remove(account)
        }
    }

    private func remove(_ account: Account) {
        context.delete(account)
        try? context.save()
        deleting = nil
    }
}

/// A card: its tile, name, keywords as tags, and how much it's used.
private struct AccountRow: View {
    let account: Account

    var body: some View {
        let expenses = account.transactions ?? []
        let lastUsed = expenses.map(\.date).max()
        HStack(spacing: 12) {
            Image(systemName: "creditcard.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.blue.gradient, in: .rect(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(account.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if account.matchKeywords.isEmpty {
                    Text("No SMS keywords")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    HStack(spacing: 4) {
                        ForEach(account.matchKeywords.prefix(3), id: \.self) { keyword in
                            Text(keyword)
                                .font(.caption2.monospaced().weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 5))
                                .accessibilityIdentifier("keyword")
                        }
                        if account.matchKeywords.count > 3 {
                            Text("+\(account.matchKeywords.count - 3)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(expenses.count == 1 ? "1 expense" : "\(expenses.count) expenses")
                    .font(.subheadline)
                    .monospacedDigit()
                if let lastUsed {
                    Text(lastUsed.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// Explains the keyword field, or what's wrong with what's typed in it.
private struct KeywordFooter: View {
    let tooShort: [String]
    let clash: (account: Account, keyword: String)?
    let isNew: Bool

    var body: some View {
        if !tooShort.isEmpty {
            Text("“\(tooShort.joined(separator: "”, “"))” is too short. Include the mask: XXX453.")
                .foregroundStyle(.orange)
        } else if let clash, isNew {
            Text("“\(clash.keyword)” is already on “\(clash.account.name)”.")
                .foregroundStyle(.orange)
        } else {
            Text("As the bank writes it, like XXX4453. Separate several with commas.")
        }
    }
}

/// Add a card, or rename one and set the SMS keywords that identify it.
private struct AccountEditor: View {
    /// nil when adding a card.
    let account: Account?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var keywordText: String
    /// Set when a keyword already belongs to another account, pending a merge.
    @State private var conflict: (account: Account, keyword: String)?

    init(account: Account?) {
        self.account = account
        _name = State(initialValue: account?.name ?? "")
        _keywordText = State(initialValue: account?.matchKeywords.joined(separator: ", ") ?? "")
    }

    private var keywords: [String] { AccountMatching.keywords(from: keywordText) }
    private var tooShort: [String] { AccountMatching.tooShort(keywords) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// A new card can't take another card's keyword: there's nothing yet to
    /// merge, so it's flagged as you type instead.
    private var newCardClash: (account: Account, keyword: String)? {
        account == nil ? AccountMatching.conflict(for: keywords, in: context) : nil
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && tooShort.isEmpty && newCardClash == nil
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Crescent Credit", text: $name)
                    .textInputAutocapitalization(.words)
            }

            Section {
                TextField("XXX4453, XXXX4453", text: $keywordText, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .monospaced()
            } header: {
                Text("SMS keywords")
            } footer: {
                KeywordFooter(tooShort: tooShort, clash: newCardClash, isNew: account == nil)
            }

            if let account {
                Section {
                    LabeledContent("Expenses", value: "\(account.transactions?.count ?? 0)")
                    if let last = account.transactions?.map(\.date).max() {
                        LabeledContent("Last used", value: last.formatted(.dateTime.day().month(.abbreviated).year()))
                    }
                }
            }
        }
        .navigationTitle(account == nil ? "New Card" : "Edit Card")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!canSave)
            }
        }
        .confirmationDialog(
            conflict.map { "“\($0.keyword)” is already on “\($0.account.name)”" } ?? "",
            isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
            titleVisibility: .visible
        ) {
            if let other = conflict?.account {
                Button("Merge into “\(trimmedName)”") { apply(merging: other) }
            }
            Button("Cancel", role: .cancel) { conflict = nil }
        } message: {
            if let other = conflict?.account {
                let count = other.transactions?.count ?? 0
                Text("They're the same card. \(count == 1 ? "Its 1 expense moves" : "Its \(count) expenses move") here, its keywords are added to this card's, and “\(other.name)” is removed.")
            }
        }
    }

    private func save() {
        guard let account else {
            context.insert(Account(name: trimmedName, matchKeywords: keywords))
            try? context.save()
            dismiss()
            return
        }
        if let clash = AccountMatching.conflict(for: keywords, excluding: account, in: context) {
            conflict = clash
            return
        }
        apply(merging: nil)
    }

    private func apply(merging other: Account?) {
        guard let account else { return }
        account.name = trimmedName
        account.matchKeywords = keywords
        do {
            if let other {
                try AccountMatching.merge(other, into: account, in: context)
            } else {
                try context.save()
            }
        } catch {
            // Leave the sheet open with the edit still in place.
            conflict = nil
            return
        }
        conflict = nil
        dismiss()
    }
}

// MARK: - Categories

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ExpenseCategory.sortOrder) private var categories: [ExpenseCategory]

    @State private var adding = false
    /// A category with expenses, waiting for the delete to be confirmed.
    @State private var deleting: ExpenseCategory?

    var body: some View {
        List {
            Section {
                ForEach(categories) { category in
                    NavigationLink {
                        CategoryDetailView(category: category)
                    } label: {
                        CategoryRow(category: category)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { delete(category) }
                    }
                }
                .onMove(perform: move)
            } footer: {
                Text("The order here is the order they're offered in. Tap Edit to drag them.")
            }
        }
        .navigationTitle("Categories")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Category", systemImage: "plus") { adding = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                NewCategoryView(
                    nextSortOrder: (categories.map(\.sortOrder).max() ?? -1) + 1,
                    // Start on an icon no category has yet.
                    symbol: ExpenseCategory.iconChoices.first { icon in !categories.contains { $0.symbol == icon } }
                        ?? "ellipsis.circle"
                )
            }
        }
        .confirmationDialog(
            deleting.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            if let category = deleting {
                Button("Delete Category", role: .destructive) { remove(category) }
            }
        } message: {
            if let category = deleting {
                Text(CategoryDetailView.deleteWarning(for: category))
            }
        }
    }

    /// Dragged into a new order: number them in it, so every list follows.
    private func move(from source: IndexSet, to destination: Int) {
        var ordered = categories
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, category) in ordered.enumerated() where category.sortOrder != index {
            category.sortOrder = index
        }
        try? context.save()
    }

    private func delete(_ category: ExpenseCategory) {
        if (category.transactions?.count ?? 0) > 0 { deleting = category } else { remove(category) }
    }

    private func remove(_ category: ExpenseCategory) {
        context.delete(category)
        try? context.save()
        deleting = nil
    }
}

/// A category: its icon, name, subcategories, and how many expenses it has.
private struct CategoryRow: View {
    let category: ExpenseCategory

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.body.weight(.medium))
                let subcategories = category.sortedSubcategories
                if !subcategories.isEmpty {
                    Text(subcategories.map(\.name).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let count = category.transactions?.count ?? 0
            if count > 0 {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The icons on offer, each in its colour; the chosen one ringed.
private struct IconGrid: View {
    @Binding var symbol: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 10)], spacing: 10) {
            ForEach(ExpenseCategory.iconChoices, id: \.self) { choice in
                let color = ExpenseCategory.color(forSymbol: choice)
                Button {
                    symbol = choice
                } label: {
                    Image(systemName: choice)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 44, height: 44)
                        .background(color.opacity(0.16), in: .rect(cornerRadius: 12))
                        .overlay {
                            if choice == symbol {
                                RoundedRectangle(cornerRadius: 12).strokeBorder(color, lineWidth: 2.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(choice == symbol ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }
}

/// The icon grid on a page of its own; choosing one goes back.
private struct IconPickerPage: View {
    @Binding var symbol: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                IconGrid(symbol: Binding(get: { symbol }, set: { symbol = $0; dismiss() }))
            } footer: {
                Text("Each icon comes with its colour.")
            }
        }
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// True when another category already has this name, ignoring case.
private func categoryNameTaken(_ name: String, except: ExpenseCategory? = nil, in context: ModelContext) -> Bool {
    let all = (try? context.fetch(FetchDescriptor<ExpenseCategory>())) ?? []
    return all.contains { $0 !== except && $0.name.caseInsensitiveCompare(name) == .orderedSame }
}

/// A new category: its name and icon.
private struct NewCategoryView: View {
    let nextSortOrder: Int

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol: String

    init(nextSortOrder: Int, symbol: String) {
        self.nextSortOrder = nextSortOrder
        _symbol = State(initialValue: symbol)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private var taken: Bool { categoryNameTaken(trimmed, in: context) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    let preview = ExpenseCategory.color(forSymbol: symbol)
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(preview)
                        .frame(width: 36, height: 36)
                        .background(preview.opacity(0.16), in: .rect(cornerRadius: 10))
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                }
            } footer: {
                if taken {
                    Text("There's already a category called “\(trimmed)”.").foregroundStyle(.orange)
                }
            }
            Section("Icon") {
                IconGrid(symbol: $symbol)
            }
        }
        .navigationTitle("New Category")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    context.insert(ExpenseCategory(name: trimmed, symbol: symbol, sortOrder: nextSortOrder))
                    try? context.save()
                    dismiss()
                }
                .disabled(trimmed.isEmpty || taken)
            }
        }
    }
}

/// One category: rename it, change its icon, manage its subcategories, or
/// delete it. Changes apply as they're made.
private struct CategoryDetailView: View {
    @Bindable var category: ExpenseCategory

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var newSubcategory = ""
    @State private var renaming: ExpenseSubcategory?
    @State private var newName = ""
    @State private var confirmingDelete = false

    init(category: ExpenseCategory) {
        self.category = category
        _name = State(initialValue: category.name)
    }

    private var subcategories: [ExpenseSubcategory] { category.sortedSubcategories }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var nameTaken: Bool { categoryNameTaken(trimmedName, except: category, in: context) }
    private var trimmedSub: String { newSubcategory.trimmingCharacters(in: .whitespaces) }

    /// Two subcategories with one name under one category would be
    /// indistinguishable in the picker.
    private func isTaken(_ candidate: String, except: ExpenseSubcategory? = nil) -> Bool {
        subcategories.contains {
            $0 !== except && $0.name.caseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    /// What deleting does to the expenses, said before it's done.
    static func deleteWarning(for category: ExpenseCategory) -> String {
        let count = category.transactions?.count ?? 0
        let expenses = count == 1 ? "Its 1 expense becomes" : "Its \(count) expenses become"
        let subs = (category.subcategories ?? []).isEmpty ? "" : " Its subcategories are deleted with it."
        return "\(expenses) uncategorised.\(subs)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CategoryIcon(category, size: 36)
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .onSubmit(commitName)
                }
            } footer: {
                if nameTaken {
                    Text("There's already a category called “\(trimmedName)”.").foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(subcategories) { subcategory in
                    Button {
                        newName = subcategory.name
                        renaming = subcategory
                    } label: {
                        HStack {
                            Text(subcategory.name)
                            Spacer()
                            let count = subcategory.transactions?.count ?? 0
                            if count > 0 {
                                Text("\(count)")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    offsets.map { subcategories[$0] }.forEach(context.delete)
                    try? context.save()
                }
                HStack {
                    TextField("Add subcategory", text: $newSubcategory)
                        .textInputAutocapitalization(.words)
                        .onSubmit(addSubcategory)
                    Button("Add", action: addSubcategory)
                        .buttonStyle(.borderless)
                        .disabled(trimmedSub.isEmpty || isTaken(trimmedSub))
                }
            } header: {
                Text("Subcategories")
            } footer: {
                if isTaken(trimmedSub) {
                    Text("“\(category.name)” already has “\(trimmedSub)”.").foregroundStyle(.orange)
                } else if subcategories.isEmpty {
                    Text("Optional, like Transport › Taxi.")
                } else {
                    Text("Tap one to rename it. Deleting one keeps its expenses in “\(category.name)”.")
                }
            }

            Section {
                // A row, not the grid itself: forty icons would push the
                // subcategories off the screen.
                NavigationLink {
                    IconPickerPage(symbol: $category.symbol)
                } label: {
                    LabeledContent("Icon") {
                        CategoryIcon(category, size: 28)
                    }
                }
                .accessibilityIdentifier("iconRow")
            }

            Section {
                let count = category.transactions?.count ?? 0
                LabeledContent("Expenses", value: "\(count)")
                Button("Delete Category", role: .destructive) {
                    if count > 0 { confirmingDelete = true } else { delete() }
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: category.symbol) { try? context.save() }
        // The name is kept as typed once valid; an empty or duplicate one
        // goes back to what it was when the page closes.
        .onDisappear(perform: commitName)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { renameSubcategory() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete “\(category.name)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Category", role: .destructive) { delete() }
        } message: {
            Text(Self.deleteWarning(for: category))
        }
    }

    private func commitName() {
        guard category.modelContext != nil, !category.isDeleted else { return }
        if trimmedName.isEmpty || nameTaken {
            name = category.name
        } else if trimmedName != category.name {
            category.name = trimmedName
            try? context.save()
        }
    }

    private func addSubcategory() {
        guard !trimmedSub.isEmpty, !isTaken(trimmedSub) else { return }
        let next = (subcategories.map(\.sortOrder).max() ?? -1) + 1
        context.insert(ExpenseSubcategory(name: trimmedSub, category: category, sortOrder: next))
        try? context.save()
        newSubcategory = ""
    }

    private func renameSubcategory() {
        let candidate = newName.trimmingCharacters(in: .whitespaces)
        if let renaming, !candidate.isEmpty, !isTaken(candidate, except: renaming) {
            renaming.name = candidate
            try? context.save()
        }
        renaming = nil
    }

    private func delete() {
        context.delete(category)
        try? context.save()
        dismiss()
    }
}

// MARK: - Share sheet wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
