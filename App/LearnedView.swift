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
                    description: Text("Save an expense from a message with a category, and ExpLog remembers that merchant's name and category for next time.")
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
                    Text("Messages from these merchants arrive named and categorised as shown. Tap one to change it; swipe to forget it.")
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
                    Text("Used for this merchant's messages from now on. Expenses already logged keep theirs.")
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
                    Text("When a merchant is misread, tap \(Image(systemName: "text.viewfinder")) beside Merchant and pick its words from the message. ExpLog then knows where to look in that bank's messages.")
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
                    Text("Messages shaped like these have their merchant read from the highlighted place. Swipe to forget one; to correct one, pick the merchant again from a message.")
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
