import SwiftUI

// Lists that open in a sheet to choose a currency, a category or an account.
// A sheet rather than an in-form menu: a menu inside a Form rebuilds the form
// around it as it opens and closes, which made the page jump and the chosen
// value crop or shift. Each list has search, so a long one stays usable.

/// A row in the form that shows the current choice and opens its sheet.
struct ChoiceRow<Value: View>: View {
    let title: String
    let action: () -> Void
    @ViewBuilder let value: () -> Value

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                Spacer(minLength: 12)
                value()
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A checkmark for the current choice, in the tint colour.
private struct Check: View {
    var body: some View {
        Image(systemName: "checkmark")
            .fontWeight(.semibold)
            .foregroundStyle(.tint)
    }
}

// MARK: - Currency

/// Every supported currency: the main one and those arranged in Settings
/// first, then the rest. Search matches code or name.
struct CurrencyPickerSheet: View {
    @Binding var selection: String
    var title = "Currency"
    /// Left out of the list: currencies that can't be chosen here.
    var excluding: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private func matches(_ code: String) -> Bool {
        guard !excluding.contains(code) else { return false }
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty
            || code.localizedCaseInsensitiveContains(query)
            || Currency.name(for: code).localizedCaseInsensitiveContains(query)
    }

    var body: some View {
        let yours = [Currency.main] + Currency.yours
        let others = Currency.supported.filter { !yours.contains($0) }
        NavigationStack {
            List {
                let shownYours = yours.filter(matches)
                if !shownYours.isEmpty {
                    Section("Yours") { ForEach(shownYours, id: \.self, content: row) }
                }
                let shownOthers = others.filter(matches)
                if !shownOthers.isEmpty {
                    Section("All currencies") { ForEach(shownOthers, id: \.self, content: row) }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Code or name")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ code: String) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(code)
                    .font(.body.monospaced().weight(.semibold))
                    .frame(width: 48, alignment: .leading)
                Text(Currency.name(for: code))
                    .foregroundStyle(.secondary)
                Spacer()
                if code == selection { Check() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("currency-\(code)")
    }
}

// MARK: - Category

/// Categories with their subcategories indented beneath, one tap to choose.
/// Search matches either; a matching subcategory shows with its category.
/// Used by the form and by swipe-to-categorise.
struct CategoryPickerList: View {
    let categories: [ExpenseCategory]
    let category: ExpenseCategory?
    let subcategory: ExpenseSubcategory?
    let onPick: (ExpenseCategory?, ExpenseSubcategory?) -> Void

    @State private var search = ""

    private var query: String { search.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        List {
            ForEach(categories) { item in
                let categoryMatches = query.isEmpty || item.name.localizedCaseInsensitiveContains(query)
                let subcategories = item.sortedSubcategories.filter {
                    categoryMatches || $0.name.localizedCaseInsensitiveContains(query)
                }
                if categoryMatches || !subcategories.isEmpty {
                    choice(item, nil)
                    ForEach(subcategories) { choice(item, $0) }
                }
            }
            if category != nil, query.isEmpty {
                Section {
                    Button("Remove category", role: .destructive) { onPick(nil, nil) }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
        .overlay {
            if !query.isEmpty, !categories.contains(where: { item in
                item.name.localizedCaseInsensitiveContains(query)
                    || item.sortedSubcategories.contains { $0.name.localizedCaseInsensitiveContains(query) }
            }) {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    /// A category row, or a subcategory row indented beneath its parent.
    private func choice(_ item: ExpenseCategory, _ sub: ExpenseSubcategory?) -> some View {
        let isCurrent = category === item && subcategory === sub
        return Button {
            onPick(item, sub)
        } label: {
            HStack(spacing: 12) {
                if let sub {
                    // Indented past the category's name, one size down, so
                    // it reads as belonging to the row above.
                    Text(sub.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                } else {
                    CategoryIcon(item, size: 28)
                    Text(item.name)
                }
                Spacer()
                if isCurrent { Check() }
            }
            // The whole row is the target, not just the text.
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(sub.map { "subcategory-\($0.name)" } ?? "category-\(item.name)")
    }
}

/// The category list in its own sheet, for the form.
struct CategoryPickerSheet: View {
    let categories: [ExpenseCategory]
    @Binding var category: ExpenseCategory?
    @Binding var subcategory: ExpenseSubcategory?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CategoryPickerList(categories: categories, category: category, subcategory: subcategory) { picked, sub in
                category = picked
                subcategory = sub
                dismiss()
            }
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

// MARK: - Account

/// Cards and accounts, each with its SMS keywords to tell similar ones apart.
struct AccountPickerSheet: View {
    let accounts: [Account]
    @Binding var selection: Account?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [Account] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return accounts }
        return accounts.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.matchKeywords.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if search.isEmpty {
                    pick(nil) {
                        Text("None").foregroundStyle(.secondary)
                    }
                }
                ForEach(shown) { account in
                    pick(account) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                            if !account.matchKeywords.isEmpty {
                                Text(account.matchKeywords.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or keyword")
            .navigationTitle("Paid with")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func pick(_ account: Account?, @ViewBuilder label: () -> some View) -> some View {
        Button {
            selection = account
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: account == nil ? "minus.circle" : "creditcard.fill")
                    .foregroundStyle(account == nil ? Color.secondary : Color.blue)
                    .frame(width: 28)
                label()
                Spacer()
                if selection === account { Check() }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(account.map { "account-\($0.name)" } ?? "account-none")
    }
}
