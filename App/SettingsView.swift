import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var transactions: [Transaction]

    @State private var exportURL: URL?
    @State private var exportError: String?

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
            } footer: {
                Text("\(transactions.count) transaction(s) stored on this device.")
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
    }

    private func export() {
        do {
            exportURL = try CSVExporter.write(transactions)
        } catch {
            exportError = error.localizedDescription
        }
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
                    Label(category.name, systemImage: category.symbol)
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
