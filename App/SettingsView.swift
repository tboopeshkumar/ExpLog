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
        title = result.added == 1 ? "Imported 1 expense" : "Imported \(result.added) expenses"
        var lines: [String] = []
        if result.duplicates > 0 {
            lines.append("Skipped \(result.duplicates) already in ExpLog.")
        }
        if !result.newCategories.isEmpty {
            lines.append("New categories: \(result.newCategories.joined(separator: ", ")).")
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
    @State private var last4 = ""
    @State private var editing: Account?

    /// Another card already using the digits typed in the Add section.
    private var takenBy: Account? {
        guard case .digits(let digits) = AccountEditing.last4(from: last4) else { return nil }
        return AccountEditing.owner(of: digits, in: context)
    }

    private var canAdd: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && AccountEditing.last4(from: last4) != .incomplete
            && takenBy == nil
    }

    var body: some View {
        List {
            Section {
                TextField("Name (e.g. Crescent Credit)", text: $name)
                TextField("Last 4 digits", text: $last4)
                    .keyboardType(.numberPad)
                    .onChange(of: last4) { _, typed in last4 = AccountEditing.sanitizedDigits(typed) }
                Button("Add card", action: add)
                    .disabled(!canAdd)
            } header: {
                Text("Add")
            } footer: {
                if let takenBy {
                    Text("••\(last4) is already on “\(takenBy.name)”. Tap it below to edit instead.")
                        .foregroundStyle(.orange)
                }
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
                Text("A card's last four digits are how its SMS alerts find it. Tap a card to add or change them.")
            }
        }
        .navigationTitle("Cards & accounts")
        .sheet(item: $editing) { account in
            NavigationStack { AccountEditor(account: account) }
        }
    }

    private func add() {
        var digits: String?
        if case .digits(let typed) = AccountEditing.last4(from: last4) { digits = typed }
        context.insert(Account(name: name.trimmingCharacters(in: .whitespaces), last4: digits))
        try? context.save()
        name = ""
        last4 = ""
    }
}

private struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Group {
                    if let digits = account.last4 {
                        Text("••\(digits)").monospacedDigit()
                    } else {
                        Text("No card digits")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            let count = account.transactions?.count ?? 0
            Text(count == 1 ? "1 expense" : "\(count) expenses")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Rename a card and set the four digits its SMS alerts show.
private struct AccountEditor: View {
    let account: Account

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var last4: String
    /// Set when the digits already belong to another account, pending a merge.
    @State private var conflict: Account?

    init(account: Account) {
        self.account = account
        _name = State(initialValue: account.name)
        _last4 = State(initialValue: account.last4 ?? "")
    }

    private var parsedDigits: AccountEditing.Last4 { AccountEditing.last4(from: last4) }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var canSave: Bool {
        !trimmedName.isEmpty && parsedDigits != .incomplete
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
            }

            Section {
                TextField("Last 4 digits", text: $last4)
                    .keyboardType(.numberPad)
                    .monospacedDigit()
                    .onChange(of: last4) { _, typed in last4 = AccountEditing.sanitizedDigits(typed) }
            } header: {
                Text("Card digits")
            } footer: {
                if parsedDigits == .incomplete {
                    Text("Enter all four digits.")
                        .foregroundStyle(.orange)
                } else {
                    Text("The last four digits as they appear in the card's SMS alerts — 1442 for XXXX1442. Leave empty for cash or accounts without SMS.")
                }
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
            conflict.map { "••\(last4) is already on “\($0.name)”" } ?? "",
            isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
            titleVisibility: .visible,
            presenting: conflict
        ) { other in
            Button("Merge into “\(trimmedName)”") { apply(merging: other) }
            Button("Cancel", role: .cancel) { conflict = nil }
        } message: { other in
            let count = other.transactions?.count ?? 0
            Text("They're the same card. \(count == 1 ? "Its 1 expense moves" : "Its \(count) expenses move") here and “\(other.name)” is removed.")
        }
    }

    private func save() {
        if case .digits(let digits) = parsedDigits,
           let other = AccountEditing.owner(of: digits, excluding: account, in: context) {
            conflict = other
            return
        }
        apply(merging: nil)
    }

    private func apply(merging other: Account?) {
        account.name = trimmedName
        if case .digits(let digits) = parsedDigits {
            account.last4 = digits
        } else {
            account.last4 = nil
        }
        do {
            if let other {
                try AccountEditing.merge(other, into: account, in: context)
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
                    HStack(spacing: 12) {
                        CategoryIcon(category, size: 28)
                        Text(category.name)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(categories[index]) }
                    try? context.save()
                }
            }
        }
        .navigationTitle("Categories")
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
