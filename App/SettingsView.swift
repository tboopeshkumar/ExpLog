import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]

    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showingImporter = false
    @AppStorage("mainCurrency", store: Currency.defaults) private var mainCurrency: String = Currency.main
    @State private var importReport: ImportReport?

    var body: some View {
        List {
            Section {
                // Just the code here; the list names each currency.
                NavigationLink {
                    MainCurrencyPicker(selection: $mainCurrency)
                } label: {
                    LabeledContent {
                        Text(mainCurrency)
                    } label: {
                        Label("Main currency", systemImage: "banknote")
                    }
                }

                NavigationLink { ExchangeRatesView() } label: {
                    Label("Other currencies & rates", systemImage: "arrow.left.arrow.right")
                }
            } footer: {
                Text("New expenses start in \(mainCurrency), and totals are counted in it. Other currencies count at the rate each expense was logged with.")
            }

            Section {
                NavigationLink { AccountsView() } label: {
                    Label("Cards & accounts", systemImage: "creditcard")
                }
                NavigationLink { CategoriesView() } label: {
                    Label("Categories", systemImage: "tag")
                }
            }

            Section {
                Button {
                    export()
                } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.up")
                }
                .disabled(transactions.isEmpty)

                Button {
                    showingImporter = true
                } label: {
                    Label("Import CSV", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("\(transactions.count) transaction(s) stored on this device. Import accepts an ExpLog CSV export and skips expenses that are already here.")
            }

            Section {
                NavigationLink { MerchantsView() } label: {
                    Label("Merchants", systemImage: "storefront")
                }
                NavigationLink { MessageFormatsView() } label: {
                    Label("Message formats", systemImage: "text.viewfinder")
                }
                NavigationLink { ParserTesterView() } label: {
                    Label("Test message parsing", systemImage: "text.magnifyingglass")
                }
            } header: {
                Text("Learned from messages")
            } footer: {
                Text("The names and categories remembered for merchants, and where to find the merchant in each bank's messages. Paste a bank SMS into the tester to see exactly what ExpLog reads from it.")
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

// MARK: - Main currency

/// Every supported currency by code and name; choosing one goes back.
private struct MainCurrencyPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(Currency.pickerOrder, id: \.self) { code in
            Button {
                selection = code
                dismiss()
            } label: {
                HStack {
                    Text(code)
                        .monospaced()
                    Text(Currency.name(for: code))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if code == selection {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Main currency")
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        List {
            Section {
                if listed.isEmpty {
                    Text("No other currencies yet. You can add a rate before you travel.")
                        .foregroundStyle(.secondary)
                }
                ForEach(listed, id: \.self) { code in
                    RateRow(
                        code: code,
                        main: mainCurrency,
                        unratedCount: Currency.unrated(code, in: transactions).count,
                        ratesJSON: $ratesJSON,
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
                Text("When you log an expense, these are offered right after \(mainCurrency), in this order; tap Edit to drag them. New expenses in a currency take its rate here and keep it: changing a rate, or removing a currency, doesn't change expenses already logged. You can also adjust the rate on a single expense.")
            }

            let addable = Currency.pickerOrder.filter { $0 != mainCurrency && !listed.contains($0) }
            if !addable.isEmpty {
                Section {
                    Menu {
                        ForEach(addable, id: \.self) { code in
                            Button("\(code) · \(Currency.name(for: code))") {
                                order = Currency.order(listed + [code])
                                hidden = Currency.order(Currency.codes(hidden).filter { $0 != code })
                            }
                        }
                    } label: {
                        Label("Add a currency", systemImage: "plus")
                    }
                }
            }
        }
        .navigationTitle("Currencies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if listed.count > 1 { EditButton() }
        }
    }
}

/// "1 AED = [22.70] INR", what a round amount comes to, and — when older
/// expenses in this currency have no rate — an offer to give them this one.
private struct RateRow: View {
    let code: String
    let main: String
    let unratedCount: Int
    @Binding var ratesJSON: String
    let applyToUnrated: (Decimal) -> Void

    @State private var text = ""

    private var rate: Decimal? {
        Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
            .flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                (Text("1 ") + Formatting.currencySign(for: main) + Text(" ="))
                    .foregroundStyle(.secondary)
                TextField("Rate", text: $text)
                    .keyboardType(.decimalPad)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                Text(code)
                    .monospaced()
            }
            Group {
                if let rate {
                    // A round amount of the other currency, and what it comes to.
                    let sample = Decimal(100) * rate >= 1000 ? Decimal(1000) : Decimal(100)
                    Formatting.moneyText(sample, code: code) + Text(" ≈ ") + Formatting.moneyText(sample / rate, code: main)
                } else if text.isEmpty {
                    Text("\(Currency.name(for: code)) — no rate yet")
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
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
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

    @State private var name = ""
    @State private var keywordText = ""
    @State private var editing: Account?

    private var keywords: [String] { AccountMatching.keywords(from: keywordText) }
    private var tooShort: [String] { AccountMatching.tooShort(keywords) }
    private var clash: (account: Account, keyword: String)? {
        AccountMatching.conflict(for: keywords, in: context)
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && tooShort.isEmpty && clash == nil
    }

    var body: some View {
        List {
            Section {
                TextField("Name (e.g. Crescent Credit)", text: $name)
                TextField("SMS keywords (e.g. XXX4453)", text: $keywordText)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                Button("Add card", action: add)
                    .disabled(!canAdd)
            } header: {
                Text("Add")
            } footer: {
                KeywordFooter(tooShort: tooShort, clash: clash, isNew: true)
            }

            Section {
                ForEach(accounts) { account in
                    Button {
                        editing = account
                    } label: {
                        AccountRow(account: account)
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(accounts[index]) }
                    try? context.save()
                }
            } header: {
                Text("Cards")
            } footer: {
                Text("An SMS containing one of a card's keywords is matched to that card. Tap a card to edit its keywords.")
            }
        }
        .navigationTitle("Cards & accounts")
        .sheet(item: $editing) { account in
            NavigationStack { AccountEditor(account: account) }
        }
    }

    private func add() {
        context.insert(Account(name: name.trimmingCharacters(in: .whitespaces), matchKeywords: keywords))
        try? context.save()
        name = ""
        keywordText = ""
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Text(account.matchKeywords.isEmpty ? "No SMS keywords" : account.matchKeywords.joined(separator: ", "))
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            let count = account.transactions?.count ?? 0
            Text(count == 1 ? "1 expense" : "\(count) expenses")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Explains the keyword field, or what's wrong with what's typed in it.
private struct KeywordFooter: View {
    let tooShort: [String]
    let clash: (account: Account, keyword: String)?
    let isNew: Bool

    var body: some View {
        if !tooShort.isEmpty {
            Text("“\(tooShort.joined(separator: "”, “"))” is too short — use at least \(AccountMatching.minimumKeywordLength) characters, with the mask: XXX453, not 453.")
                .foregroundStyle(.orange)
        } else if let clash, isNew {
            Text("“\(clash.keyword)” is already on “\(clash.account.name)”. Tap it below to edit instead.")
                .foregroundStyle(.orange)
        } else {
            Text("Text from this card's SMS, as the bank writes it: XXX4453, XXXX4453. Separate several with commas. Leave empty for cash or accounts without SMS.")
        }
    }
}

/// Rename a card and set the SMS keywords that identify it.
private struct AccountEditor: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var keywordText: String
    /// Set when a keyword already belongs to another account, pending a merge.
    @State private var conflict: (account: Account, keyword: String)?

    init(account: Account) {
        self.account = account
        _name = State(initialValue: account.name)
        _keywordText = State(initialValue: account.matchKeywords.joined(separator: ", "))
    }

    private var keywords: [String] { AccountMatching.keywords(from: keywordText) }
    private var tooShort: [String] { AccountMatching.tooShort(keywords) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var canSave: Bool {
        !trimmedName.isEmpty && tooShort.isEmpty
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
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
                KeywordFooter(tooShort: tooShort, clash: nil, isNew: false)
            }

            Section {
                LabeledContent("Expenses", value: "\(account.transactions?.count ?? 0)")
            }
        }
        .navigationTitle("Edit card")
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
        if let clash = AccountMatching.conflict(for: keywords, excluding: account, in: context) {
            conflict = clash
            return
        }
        apply(merging: nil)
    }

    private func apply(merging other: Account?) {
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

    @State private var name = ""

    var body: some View {
        List {
            Section("Add") {
                HStack {
                    TextField("Category name", text: $name)
                    Button("Add") {
                        let category = ExpenseCategory(
                            name: name.trimmingCharacters(in: .whitespaces),
                            sortOrder: (categories.last?.sortOrder ?? 0) + 1
                        )
                        context.insert(category)
                        try? context.save()
                        name = ""
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section {
                ForEach(categories) { category in
                    NavigationLink {
                        SubcategoriesView(category: category)
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(category, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.name)
                                let subcategories = category.sortedSubcategories
                                if !subcategories.isEmpty {
                                    Text(subcategories.map(\.name).joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(categories[index]) }
                    try? context.save()
                }
            } footer: {
                Text("Tap a category to add subcategories.")
            }
        }
        .navigationTitle("Categories")
    }
}

/// One category's subcategories: add, rename (tap), delete (swipe).
private struct SubcategoriesView: View {
    let category: ExpenseCategory

    @Environment(\.modelContext) private var context
    @State private var name = ""
    @State private var renaming: ExpenseSubcategory?
    @State private var newName = ""

    private var subcategories: [ExpenseSubcategory] { category.sortedSubcategories }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    /// Two subcategories with one name under one category would be
    /// indistinguishable in the picker.
    private func isTaken(_ candidate: String, except: ExpenseSubcategory? = nil) -> Bool {
        subcategories.contains {
            $0 !== except && $0.name.caseInsensitiveCompare(candidate) == .orderedSame
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Subcategory name", text: $name)
                        .textInputAutocapitalization(.words)
                    Button("Add", action: add)
                        .disabled(trimmed.isEmpty || isTaken(trimmed))
                }
            } header: {
                Text("Add")
            } footer: {
                if isTaken(trimmed) {
                    Text("“\(category.name)” already has “\(trimmed)”.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(subcategories) { subcategory in
                    Button {
                        newName = subcategory.name
                        renaming = subcategory
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(category, size: 28)
                            Text(subcategory.name)
                            Spacer()
                            let count = subcategory.transactions?.count ?? 0
                            Text(count == 1 ? "1 expense" : "\(count) expenses")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { subcategories[$0] }
                    doomed.forEach(context.delete)
                    try? context.save()
                }
            } footer: {
                if subcategories.isEmpty {
                    Text("Optional. Subcategories split a category further — Transport › Taxi — and appear in the form once the category is chosen.")
                } else {
                    Text("Deleting a subcategory keeps its expenses in “\(category.name)”.")
                }
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func add() {
        let next = (subcategories.map(\.sortOrder).max() ?? -1) + 1
        context.insert(ExpenseSubcategory(name: trimmed, category: category, sortOrder: next))
        try? context.save()
        name = ""
    }

    private func rename() {
        let candidate = newName.trimmingCharacters(in: .whitespaces)
        if let renaming, !candidate.isEmpty, !isTaken(candidate, except: renaming) {
            renaming.name = candidate
            try? context.save()
        }
        renaming = nil
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
