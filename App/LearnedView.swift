import SwiftUI
import SwiftData

/// What ExpLog has remembered about merchants from saved expenses: the name
/// to show and the category to fill in when a message from them arrives.
struct MerchantsView: View {
    enum Sort: String, CaseIterable {
        case name = "Name"
        case expenses = "Most Expenses"
        case recent = "Recently Used"
    }

    /// How much a merchant is used: its logged expenses and the latest one.
    struct Usage {
        var count = 0
        var last: Date?
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \MerchantAlias.key) private var aliases: [MerchantAlias]
    @Query private var transactions: [Transaction]
    @State private var search = ""
    @State private var editing: MerchantAlias?
    @AppStorage("merchantSort") private var sort: Sort = .name

    var body: some View {
        // Counted once per refresh, by the name as the summaries group it.
        let usage = Self.usage(of: transactions)
        let shown = shown(usage)
        List {
            if aliases.isEmpty {
                ContentUnavailableView(
                    "No merchants yet",
                    systemImage: "storefront",
                    description: Text("Categorise an expense from a message and its merchant is remembered.")
                )
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                Section {
                    ForEach(shown) { alias in
                        Button {
                            editing = alias
                        } label: {
                            MerchantRow(alias: alias, usage: Self.usage(of: alias, in: usage))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("merchantRow")
                        .swipeActions(edge: .trailing) {
                            Button("Forget", role: .destructive) { forget(alias) }
                        }
                    }
                } footer: {
                    Text("Messages from these merchants arrive named and categorised like this. Swipe to forget one; logged expenses aren't changed.")
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search merchants")
        .navigationTitle("Merchants")
        .toolbar {
            if aliases.count > 1 {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .sheet(item: $editing) { alias in
            MerchantEditor(alias: alias, usage: Self.usage(of: alias, in: usage))
        }
    }

    private func shown(_ usage: [String: Usage]) -> [MerchantAlias] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? aliases : aliases.filter {
            $0.key.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.category?.name.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.subcategory?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
        let byName: (MerchantAlias, MerchantAlias) -> Bool = {
            Self.name(of: $0).localizedCaseInsensitiveCompare(Self.name(of: $1)) == .orderedAscending
        }
        switch sort {
        case .name:
            return matching.sorted(by: byName)
        case .expenses:
            return matching.sorted {
                let a = Self.usage(of: $0, in: usage).count, b = Self.usage(of: $1, in: usage).count
                return a == b ? byName($0, $1) : a > b
            }
        case .recent:
            return matching.sorted {
                let a = Self.usage(of: $0, in: usage).last ?? $0.updatedAt
                let b = Self.usage(of: $1, in: usage).last ?? $1.updatedAt
                return a == b ? byName($0, $1) : a > b
            }
        }
    }

    private func forget(_ alias: MerchantAlias) {
        context.delete(alias)
        try? context.save()
    }

    /// Expenses per merchant name, keyed as the summaries group them.
    static func usage(of transactions: [Transaction]) -> [String: Usage] {
        var usage: [String: Usage] = [:]
        for transaction in transactions {
            let key = MerchantBreakdown.key(for: transaction.merchant)
            var entry = usage[key] ?? Usage()
            entry.count += 1
            entry.last = max(entry.last ?? transaction.date, transaction.date)
            usage[key] = entry
        }
        return usage
    }

    /// A merchant's expenses: those under the name it's shown as, and any
    /// still under the name as the message wrote it.
    static func usage(of alias: MerchantAlias, in usage: [String: Usage]) -> Usage {
        let keys = Set([MerchantBreakdown.key(for: name(of: alias)), MerchantBreakdown.key(for: alias.key)])
        return keys.compactMap { usage[$0] }.reduce(Usage()) { total, next in
            Usage(count: total.count + next.count, last: [total.last, next.last].compactMap { $0 }.max())
        }
    }

    /// The name to show: the one given, else the message's text with its
    /// words capitalised (keys are stored lowercased).
    static func name(of alias: MerchantAlias) -> String {
        guard alias.displayName.isEmpty else { return alias.displayName }
        return alias.key.split(separator: " ")
            .map { $0.contains(where: \.isNumber) ? $0.uppercased() : $0.capitalized }
            .joined(separator: " ")
    }

    /// True when the merchant was renamed from how its messages write it.
    static func isRenamed(_ alias: MerchantAlias) -> Bool {
        !alias.displayName.isEmpty && alias.displayName.lowercased() != alias.key
    }
}

/// A merchant: its category's icon, name, category, and how much it's used.
private struct MerchantRow: View {
    let alias: MerchantAlias
    let usage: MerchantsView.Usage

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(alias.category, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(MerchantsView.name(of: alias))
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let category = alias.category {
                    Text([category.name, alias.subcategory?.name].compactMap { $0 }.joined(separator: " › "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("No category")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // Only when renamed: otherwise it repeats the name above.
                if MerchantsView.isRenamed(alias) {
                    Text(alias.key.uppercased())
                        .font(.caption2.monospaced().weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 5))
                        .lineLimit(1)
                        .accessibilityLabel("In messages as \(alias.key)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Compact, so a long name keeps the width; the last date is in
            // the editor.
            if usage.count > 0 {
                Text("\(usage.count)×")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(usage.count == 1 ? "1 expense" : "\(usage.count) expenses")
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}

/// Rename a remembered merchant, change its category, or forget it. Applies
/// to messages from now on; expenses already logged keep what they have.
private struct MerchantEditor: View {
    let alias: MerchantAlias
    let usage: MerchantsView.Usage

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<ExpenseCategory> { !$0.isArchived }, sort: \ExpenseCategory.sortOrder)
    private var categories: [ExpenseCategory]

    @State private var name: String
    @State private var category: ExpenseCategory?
    @State private var subcategory: ExpenseSubcategory?
    @State private var choosingCategory = false

    init(alias: MerchantAlias, usage: MerchantsView.Usage) {
        self.alias = alias
        self.usage = usage
        _name = State(initialValue: MerchantsView.name(of: alias))
        _category = State(initialValue: alias.category)
        _subcategory = State(initialValue: alias.subcategory)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        CategoryIcon(category, size: 36)
                        TextField("Name", text: $name)
                            .textInputAutocapitalization(.words)
                    }
                } header: {
                    Text("Show as")
                } footer: {
                    Text("In messages as “\(alias.key.uppercased())”.")
                }

                Section {
                    // A list in a sheet, as in the expense form: menus inside
                    // a form made the page jump.
                    ChoiceRow(title: "Category", action: { choosingCategory = true }) {
                        if let category {
                            Text([category.name, subcategory?.name].compactMap { $0 }.joined(separator: " › "))
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                        } else {
                            Text("Choose").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("categoryRow")
                } footer: {
                    Text("Used for this merchant's messages from now on. Logged expenses aren't changed.")
                }

                if usage.count > 0 {
                    Section {
                        LabeledContent("Expenses", value: "\(usage.count)")
                        if let last = usage.last {
                            LabeledContent("Last used", value: last.formatted(.dateTime.day().month(.abbreviated).year()))
                        }
                    }
                }

                Section {
                    Button("Forget Merchant", role: .destructive) {
                        context.delete(alias)
                        try? context.save()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Merchant")
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
            .sheet(isPresented: $choosingCategory) {
                CategoryPickerSheet(categories: categories, category: $category, subcategory: $subcategory)
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
    @Query(filter: #Predicate<Transaction> { $0.rawMessage != nil }) private var fromMessages: [Transaction]

    var body: some View {
        List {
            if formats.isEmpty {
                ContentUnavailableView {
                    Label("No message formats", systemImage: "text.viewfinder")
                } description: {
                    Text("Merchant misread? Open the expense, tap \(Image(systemName: "text.viewfinder")) beside Merchant and pick it from the message. ExpLog remembers where to look.")
                }
            } else {
                // A card each: they're few, and each is a block of text.
                ForEach(formats) { format in
                    Section {
                        NavigationLink {
                            MessageFormatDetail(format: format)
                        } label: {
                            MessageFormatRow(format: format, matches: Self.matches(format, in: fromMessages))
                        }
                        .accessibilityIdentifier("formatRow")
                        .swipeActions(edge: .trailing) {
                            Button("Forget", role: .destructive) {
                                context.delete(format)
                                try? context.save()
                            }
                        }
                    }
                }
                Section {
                } footer: {
                    Text("Messages shaped like these have their merchant read from the highlighted words. Other messages are read the usual way.")
                }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Message formats")
    }

    /// How many logged expenses came from messages in this format.
    static func matches(_ format: MessageFormat, in transactions: [Transaction]) -> Int {
        transactions.filter { transaction in
            transaction.rawMessage.map { MerchantFormat.merchant(in: $0, pattern: format.pattern) != nil } ?? false
        }.count
    }

    /// A name for a format: how its messages open, up to the first part that
    /// changes — "Debit Card", "Thank you for using".
    static func title(of format: MessageFormat) -> String {
        let opening = format.sample.split(separator: " ")
            .prefix { !$0.contains(where: \.isNumber) }
            .prefix(4)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        return opening.isEmpty ? "Message format" : opening + "…"
    }

    /// The sample with the merchant's words picked out: bold, in the tint
    /// colour, on a wash of it.
    static func highlighting(_ picked: String, in sample: String) -> AttributedString {
        var text = AttributedString(sample)
        // Without the comma or full stop the pick ended on.
        let words = picked.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:"))
        if let range = text.range(of: words) {
            text[range].inlinePresentationIntent = .stronglyEmphasized
            text[range].foregroundColor = .accentColor
            text[range].backgroundColor = .accentColor.opacity(0.15)
        }
        return text
    }

    /// The merchant a format reads from its own sample, as it would be shown.
    static func reading(of format: MessageFormat) -> String {
        MerchantFormat.merchant(in: format.sample, pattern: format.pattern) ?? format.picked
    }
}

/// A format in the list: how its messages open, the sample with the merchant
/// highlighted, and what it reads.
private struct MessageFormatRow: View {
    let format: MessageFormat
    let matches: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MessageFormatsView.title(of: format))
                .font(.body.weight(.medium))
                .lineLimit(1)
            Text(MessageFormatsView.highlighting(format.picked, in: format.sample))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Text("Reads “\(MessageFormatsView.reading(of: format))”"
                 + (matches > 0 ? " · \(matches == 1 ? "1 expense" : "\(matches) expenses")" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One format: its sample, what it reads, a place to try another message
/// against it, picking the merchant again, and forgetting it.
private struct MessageFormatDetail: View {
    @Bindable var format: MessageFormat

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Transaction> { $0.rawMessage != nil }) private var fromMessages: [Transaction]
    @State private var trial = ""
    @State private var picking = false
    @State private var pickFailed = false

    var body: some View {
        let matches = MessageFormatsView.matches(format, in: fromMessages)
        Form {
            Section("Learned from") {
                Text(MessageFormatsView.highlighting(format.picked, in: format.sample))
                    .font(.footnote)
                    .textSelection(.enabled)
            }

            Section {
                LabeledContent("Reads", value: MessageFormatsView.reading(of: format))
                LabeledContent("Learned", value: format.createdAt.formatted(.dateTime.day().month(.abbreviated).year()))
                LabeledContent("Expenses", value: "\(matches)")
            }

            Section {
                TextField("Paste another message", text: $trial, axis: .vertical)
                    .lineLimit(2...8)
                    .font(.footnote)
                    .accessibilityIdentifier("trialMessage")
                if !trial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let merchant = MerchantFormat.merchant(in: trial, pattern: format.pattern) {
                        Label("Reads “\(merchant)”", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not this format", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Try a message")
            } footer: {
                Text("See what this format reads from another of the bank's messages.")
            }

            Section {
                Button("Pick the Merchant Again") { picking = true }
                Button("Forget Format", role: .destructive) {
                    context.delete(format)
                    try? context.save()
                    dismiss()
                }
            }
        }
        .navigationTitle("Message format")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $picking) {
            MerchantPickerView(message: format.sample, current: MessageFormatsView.reading(of: format),
                               asksToRemember: false) { words, _ in
                repick(words)
            }
        }
        .alert("Couldn't learn that", isPresented: $pickFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("ExpLog couldn't work out where those words are in this message. The format is unchanged.")
        }
    }

    /// Correct where the merchant is, from the same sample.
    private func repick(_ words: ClosedRange<Int>) {
        guard let pattern = MerchantFormat.pattern(from: format.sample, picking: words) else {
            pickFailed = true
            return
        }
        format.pattern = pattern
        format.picked = MerchantFormat.words(of: format.sample)[words].map(\.text).joined(separator: " ")
        try? context.save()
    }
}
