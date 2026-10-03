import SwiftUI
import SwiftData

/// What ExpLog has remembered about merchants from saved expenses: the name
/// to show and the category to fill in when a message from them arrives.
struct MerchantsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MerchantAlias.key) private var aliases: [MerchantAlias]
    @State private var search = ""
    @State private var editing: MerchantAlias?

    private var shown: [MerchantAlias] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return aliases }
        return aliases.filter {
            $0.key.contains(query) || $0.displayName.lowercased().contains(query)
                || ($0.category?.name.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        List {
            if aliases.isEmpty {
                ContentUnavailableView(
                    "No merchants yet",
                    systemImage: "storefront",
                    description: Text("Categorise an expense from a message and its merchant is remembered.")
                )
            } else {
                Section {
                    ForEach(shown) { alias in
                        Button {
                            editing = alias
                        } label: {
                            row(alias)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let doomed = offsets.map { shown[$0] }
                        doomed.forEach(context.delete)
                        try? context.save()
                    }
                } footer: {
                    Text("Tap to rename or recategorise. Swipe to forget.")
                }
            }
        }
        .searchable(text: $search, prompt: "Search merchants")
        .navigationTitle("Merchants")
        .sheet(item: $editing) { alias in
            MerchantEditor(alias: alias)
        }
    }

    private func row(_ alias: MerchantAlias) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(alias.category, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.name(of: alias))
                Text(Self.placement(of: alias))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(.rect)
    }

    static func name(of alias: MerchantAlias) -> String {
        alias.displayName.isEmpty ? alias.key.capitalized : alias.displayName
    }

    /// "Transport › Taxi · from “aman taxi”"
    static func placement(of alias: MerchantAlias) -> String {
        let category = [alias.category?.name, alias.subcategory?.name].compactMap { $0 }.joined(separator: " › ")
        let source = "from “\(alias.key)”"
        return category.isEmpty ? source : "\(category) · \(source)"
    }
}

/// Rename a remembered merchant or change its category. Applies to messages
/// from now on; expenses already logged keep what they have.
private struct MerchantEditor: View {
    let alias: MerchantAlias

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Query(filter: #Predicate<ExpenseCategory> { !$0.isArchived }, sort: \ExpenseCategory.sortOrder)
    private var categories: [ExpenseCategory]

    @State private var name = ""
    @State private var category: ExpenseCategory?
    @State private var subcategory: ExpenseSubcategory?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Show as")
                } footer: {
                    Text("Read from messages as “\(alias.key)”.")
                }

                Section {
                    Picker("Category", selection: $category) {
                        Text("None").tag(ExpenseCategory?.none)
                        ForEach(categories) { category in
                            Label { Text(category.name) } icon: { category.menuIcon(for: colorScheme) }
                                .tag(ExpenseCategory?.some(category))
                        }
                    }
                    .onChange(of: category) {
                        if subcategory?.category !== category { subcategory = nil }
                    }
                    if let subcategories = category?.sortedSubcategories, !subcategories.isEmpty {
                        Picker("Subcategory", selection: $subcategory) {
                            Text("None").tag(ExpenseSubcategory?.none)
                            ForEach(subcategories) { subcategory in
                                Text(subcategory.name).tag(ExpenseSubcategory?.some(subcategory))
                            }
                        }
                    }
                } footer: {
                    Text("Applies to future messages only.")
                }
            }
            .navigationTitle(MerchantsView.name(of: alias))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = MerchantsView.name(of: alias)
                category = alias.category
                subcategory = alias.subcategory
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Unchanged from how the message reads it: nothing to substitute.
        alias.displayName = trimmed.lowercased() == alias.key ? "" : trimmed
        alias.category = category
        alias.subcategory = subcategory?.category === category ? subcategory : nil
        alias.updatedAt = .now
        try? context.save()
        dismiss()
    }
}

/// The bank message formats ExpLog was taught where to find the merchant in.
struct MessageFormatsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MessageFormat.createdAt, order: .reverse) private var formats: [MessageFormat]

    var body: some View {
        List {
            if formats.isEmpty {
                ContentUnavailableView {
                    Label("No message formats", systemImage: "text.viewfinder")
                } description: {
                    Text("Merchant misread? Tap \(Image(systemName: "text.viewfinder")) beside Merchant and pick it from the message.")
                }
            } else {
                Section {
                    ForEach(formats) { format in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(Self.highlighting(format.picked, in: format.sample))
                                .font(.footnote)
                            Text("Merchant: \(format.picked) · learned \(format.createdAt.formatted(.dateTime.day().month(.abbreviated)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        offsets.map { formats[$0] }.forEach(context.delete)
                        try? context.save()
                    }
                } footer: {
                    Text("The merchant is read from the highlighted words. Swipe to forget.")
                }
            }
        }
        .navigationTitle("Message formats")
    }

    private static func highlighting(_ picked: String, in sample: String) -> AttributedString {
        var text = AttributedString(sample)
        if let range = text.range(of: picked) {
            text[range].font = .footnote.bold()
            text[range].foregroundColor = .accentColor
        }
        return text
    }
}

/// The steps for a Messages automation that runs Log Expense from Message.
struct ShortcutSetupView: View {
    private let steps: [(String, String)] = [
        ("In Shortcuts, tap Automation, then +.", "plus.circle"),
        ("Choose When I Receive a Message.", "message"),
        ("Set Message contains to a phrase all your bank's alerts use, like “was used for”.", "text.quote"),
        ("Turn off Confirm Before Run.", "bolt"),
        ("Add Log Expense from Message, and set its Message to the trigger's Message.", "checkmark.seal"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    Label {
                        Text(step.0)
                    } icon: {
                        Text("\(index + 1)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.tint, in: .circle)
                    }
                }
            } footer: {
                Text("Make one automation per bank if their wording differs.")
            }

            Section {
                Link(destination: URL(string: "shortcuts://")!) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
            }
        }
        .navigationTitle("Automatic logging")
        .navigationBarTitleDisplayMode(.inline)
    }
}
