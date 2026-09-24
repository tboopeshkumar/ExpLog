import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]

    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showingImporter = false
    @State private var importReport: ImportReport?

    var body: some View {
        List {
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
                NavigationLink { ParserTesterView() } label: {
                    Label("Test message parsing", systemImage: "text.magnifyingglass")
                }
            } footer: {
                Text("Paste a bank SMS to see exactly which fields ExpLog reads from it.")
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
