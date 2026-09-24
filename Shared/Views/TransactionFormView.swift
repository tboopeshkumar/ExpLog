import SwiftUI
import SwiftData

/// The editing form, shared by the share-sheet extension and the main app so
/// the two never drift apart.
public struct TransactionFormView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme

    @Query(filter: #Predicate<ExpenseCategory> { !$0.isArchived }, sort: \ExpenseCategory.sortOrder)
    private var categories: [ExpenseCategory]

    @Query(filter: #Predicate<Account> { !$0.isArchived }, sort: \Account.name)
    private var accounts: [Account]

    @Bindable private var draft: TransactionDraft
    private let onSave: () -> Void
    private let onCancel: () -> Void

    /// Replaces the default "write to this context" behaviour. The share
    /// extension uses it to hand the transaction to the app instead, when it has
    /// no database of its own to write to.
    private let saveAction: ((TransactionDraft) throws -> Void)?

    /// Hidden when the form has no database behind it, since the pickers would
    /// be empty. The app fills both in on receipt.
    private let showsCategoryAndAccount: Bool

    @State private var showRawMessage = false
    @State private var errorMessage: String?
    @FocusState private var amountFocused: Bool

    public init(
        draft: TransactionDraft,
        showsCategoryAndAccount: Bool = true,
        saveAction: ((TransactionDraft) throws -> Void)? = nil,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        self.showsCategoryAndAccount = showsCategoryAndAccount
        self.saveAction = saveAction
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            amountSection
            detailSection
            // Not offered for a card too short to be a safe keyword (a bare
            // "ending 453"); that one's set up in Settings with more context.
            if showsCategoryAndAccount, draft.account == nil,
               let card = draft.parsedCard, card.count >= AccountMatching.minimumKeywordLength {
                linkCardSection
            }
            noteSection
            if draft.rawMessage != nil {
                rawMessageSection
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(!draft.isValid)
            }
        }
        .alert("Couldn't save", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var amountSection: some View {
        Section {
            HStack {
                // Tap the sign to log an expense in another currency.
                Menu {
                    Picker("Currency", selection: $draft.currencyCode) {
                        ForEach(Currency.pickerOrder, id: \.self) { code in
                            Text("\(code) · \(Currency.name(for: code))").tag(code)
                        }
                    }
                } label: {
                    Formatting.currencySign(for: draft.currencyCode)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Currency: \(Currency.name(for: draft.currencyCode))")
                }
                TextField("0.00", value: $draft.amount, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .focused($amountFocused)
            }
        } footer: {
            if !draft.unparsedFields.isEmpty {
                Label(
                    "Couldn't read: \(draft.unparsedFields.joined(separator: ", ")). Check before saving.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var detailSection: some View {
        Section {
            TextField("Merchant", text: $draft.merchant)
                .textInputAutocapitalization(.words)

            DatePicker("Date", selection: $draft.date)

            if showsCategoryAndAccount {
                Picker("Category", selection: $draft.category) {
                    Text("None").tag(ExpenseCategory?.none)
                    ForEach(categories) { category in
                        // menuIcon, not systemImage: a plain symbol would be
                        // redrawn in one colour by the menu.
                        Label { Text(category.name) } icon: { category.menuIcon(for: colorScheme) }
                            .tag(ExpenseCategory?.some(category))
                    }
                }

                // Only when the chosen category has any: most won't.
                if let subcategories = draft.category?.sortedSubcategories, !subcategories.isEmpty {
                    Picker("Subcategory", selection: $draft.subcategory) {
                        Text("None").tag(ExpenseSubcategory?.none)
                        ForEach(subcategories) { subcategory in
                            Text(subcategory.name).tag(ExpenseSubcategory?.some(subcategory))
                        }
                    }
                }

                Picker("Account", selection: $draft.account) {
                    Text("None").tag(Account?.none)
                    ForEach(accounts) { account in
                        Text(account.name)
                            .tag(Account?.some(account))
                    }
                }
            }
        } footer: {
            if !showsCategoryAndAccount {
                Text("Card and category are matched by ExpLog when it opens.")
            }
        }
    }

    private var linkCardSection: some View {
        Section {
            Button {
                linkParsedCard()
            } label: {
                Label("Add card \(draft.parsedCard ?? "")", systemImage: "creditcard")
            }
        } footer: {
            Text("This card isn't set up yet. Adding it now means future messages from it are matched automatically.")
        }
    }

    private var noteSection: some View {
        Section("Note") {
            TextField("Optional", text: $draft.note, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private var rawMessageSection: some View {
        Section {
            DisclosureGroup("Original message", isExpanded: $showRawMessage) {
                Text(draft.rawMessage ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Actions

    private func linkParsedCard() {
        guard let card = draft.parsedCard else { return }
        // Named by its digits; the keyword is the card exactly as the alert
        // wrote it, so the next alert in the same format matches.
        let digits = card.filter(\.isASCIIDigit)
        let account = Account(name: "Card \(digits)", matchKeywords: [card])
        context.insert(account)
        draft.account = account
    }

    private func save() {
        do {
            if let saveAction {
                try saveAction(draft)
            } else {
                try draft.save(in: context)
            }
            onSave()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
