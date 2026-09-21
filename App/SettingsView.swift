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

    var body: some View {
        List {
            Section("Add") {
                TextField("Name (e.g. Crescent Credit)", text: $name)
                TextField("Last 4 digits", text: $last4)
                    .keyboardType(.numberPad)
                Button("Add card") {
                    let account = Account(
                        name: name.trimmingCharacters(in: .whitespaces),
                        last4: last4.isEmpty ? nil : last4
                    )
                    context.insert(account)
                    try? context.save()
                    name = ""
                    last4 = ""
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Section("Cards") {
                ForEach(accounts) { account in
                    HStack {
                        Text(account.name)
                        Spacer()
                        if let digits = account.last4 {
                            Text("••\(digits)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(accounts[index]) }
                    try? context.save()
                }
            }
        }
        .navigationTitle("Cards & accounts")
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
