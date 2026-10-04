import SwiftUI
import SwiftData

/// The editing form, shared by the share-sheet extension and the main app so
/// the two never drift apart.
public struct TransactionFormView: View {
    @Environment(\.modelContext) private var context

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

    /// Off where a card made in the form couldn't be kept: the share sheet
    /// working from a copy of the app's cards.
    private let canAddCard: Bool

    @State private var showRawMessage = false
    @State private var pickingMerchant = false
    /// What happened to the last pick, shown under the merchant.
    @State private var pickNote: String?
    @State private var errorMessage: String?
    @State private var choosingCurrency = false
    @State private var choosingCategory = false
    @State private var choosingAccount = false
    /// Which field has the keyboard: the amount first, then the merchant.
    private enum Field { case amount, merchant }
    @FocusState private var focus: Field?
    /// The amount as typed, so an empty field means "not entered" rather
    /// than showing a 0 to delete first.
    @State private var amountText: String

    public init(
        draft: TransactionDraft,
        showsCategoryAndAccount: Bool = true,
        canAddCard: Bool = true,
        saveAction: ((TransactionDraft) throws -> Void)? = nil,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.draft = draft
        _amountText = State(initialValue: draft.amount == 0
            ? ""
            : draft.amount.formatted(.number.grouping(.never).precision(.fractionLength(0...3))))
        self.showsCategoryAndAccount = showsCategoryAndAccount
        self.canAddCard = canAddCard
        self.saveAction = saveAction
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            amountSection
            detailSection
            if showsCategoryAndAccount {
                Section {
                    categoryRow
                    accountRow
                }
            }
            // Not offered for a card too short to be a safe keyword (a bare
            // "ending 453"); that one's set up in Settings with more context.
            if showsCategoryAndAccount, canAddCard, draft.account == nil,
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
            // The number pad has no return key: this is the way on.
            ToolbarItemGroup(placement: .keyboard) {
                if focus == .amount {
                    Spacer()
                    Button("Next") { focus = .merchant }
                        .fontWeight(.semibold)
                }
            }
        }
        .onChange(of: amountText) { _, text in
            let clean = Self.sanitized(text, minorUnits: Currency.minorUnits(of: draft.currencyCode))
            if clean != text {
                amountText = clean   // comes back round with the clean text
                return
            }
            draft.amount = Self.decimal(from: clean) ?? 0
        }
        .task {
            // A blank expense starts at the amount; one from a message or an
            // edit already has it, so the keyboard would only get in the way.
            guard draft.amount == 0, draft.rawMessage == nil else { return }
            try? await Task.sleep(for: .milliseconds(450))
            focus = .amount
        }
        .sheet(isPresented: $choosingCurrency) {
            CurrencyPickerSheet(selection: $draft.currencyCode)
        }
        .sheet(isPresented: $choosingCategory) {
            CategoryPickerSheet(categories: categories, category: $draft.category, subcategory: $draft.subcategory)
        }
        .sheet(isPresented: $choosingAccount) {
            AccountPickerSheet(accounts: accounts, selection: $draft.account)
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
            VStack(spacing: 6) {
                currencyMenu
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .focused($focus, equals: .amount)
                    .accessibilityLabel("Amount")
                    .accessibilityIdentifier("amount")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            // Another currency: the rate this expense counts at. Starts from
            // Settings and stays with the expense once saved, so a later rate
            // change leaves it alone.
            if draft.currencyCode != Currency.main {
                HStack(spacing: 8) {
                    (Text("1 ") + Formatting.currencySign(for: draft.rateBase ?? Currency.main) + Text(" ="))
                        .foregroundStyle(.secondary)
                    TextField("Rate", value: $draft.exchangeRate, format: .number.precision(.fractionLength(0...6)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text(draft.currencyCode)
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if draft.currencyCode != Currency.main {
                if let rate = draft.exchangeRate, rate > 0 {
                    (Text("Counts as ") + Formatting.moneyText(draft.amount / rate, code: draft.rateBase ?? Currency.main)
                        + Text(" in your totals."))
                } else {
                    Text("No exchange rate: this expense won't count in your totals until it has one.")
                }
            }
            if !draft.unparsedFields.isEmpty {
                Label(
                    draft.unparsedFields.contains("merchant") && draft.rawMessage != nil
                        ? "Couldn't read: \(draft.unparsedFields.joined(separator: ", ")). Check before saving; the button beside Merchant picks it from the message."
                        : "Couldn't read: \(draft.unparsedFields.joined(separator: ", ")). Check before saving.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    /// The currency as a pill above the amount; tap for the list — the main
    /// one and those arranged in Settings first.
    private var currencyMenu: some View {
        Button {
            focus = nil
            choosingCurrency = true
        } label: {
            HStack(spacing: 4) {
                Formatting.currencyLabel(for: draft.currencyCode)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.tint.opacity(0.12), in: .capsule)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Currency: \(Currency.name(for: draft.currencyCode))")
        .accessibilityIdentifier("currencyPill")
    }

    /// "Transport › Taxi" with its icon, or a prompt when there's none yet.
    private var categoryRow: some View {
        ChoiceRow(title: "Category", action: { focus = nil; choosingCategory = true }) {
            if let category = draft.category {
                HStack(spacing: 8) {
                    CategoryIcon(category, size: 24)
                    Text([category.name, draft.subcategory?.name].compactMap { $0 }.joined(separator: " › "))
                        .foregroundStyle(.secondary)
                        .truncationMode(.middle)
                }
            } else {
                Text("Choose").foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("categoryRow")
    }

    private var accountRow: some View {
        ChoiceRow(title: "Paid with", action: { focus = nil; choosingAccount = true }) {
            Text(draft.account?.name ?? "None")
                .foregroundStyle(.secondary)
                .truncationMode(.middle)
        }
        .accessibilityIdentifier("accountRow")
    }

    /// Keeps what can be part of an amount: digits and one decimal mark,
    /// with no more decimals than the currency has — so a stray second "."
    /// or a third decimal on dirhams goes nowhere.
    static func sanitized(_ text: String, minorUnits: Int) -> String {
        let mark = Character(Locale.current.decimalSeparator ?? ".")
        var result = ""
        var seenMark = false
        var decimals = 0
        for character in text {
            if character.isASCII, character.isNumber {
                if seenMark {
                    guard decimals < minorUnits else { continue }
                    decimals += 1
                }
                result.append(character)
            } else if (character == mark || character == "."), !seenMark, minorUnits > 0 {
                seenMark = true
                result.append(character)
            }
        }
        return result
    }

    /// Reads what was typed with either decimal mark: the keypad gives this
    /// region's, and "." is accepted everywhere.
    static func decimal(from text: String) -> Decimal? {
        let mark = Locale.current.decimalSeparator ?? "."
        let grouping = Locale.current.groupingSeparator ?? ","
        var cleaned = text.trimmingCharacters(in: .whitespaces)
        if mark != "." {
            cleaned = cleaned.replacingOccurrences(of: ".", with: mark)
        }
        if grouping != mark {
            cleaned = cleaned.replacingOccurrences(of: grouping, with: "")
        }
        cleaned = cleaned.replacingOccurrences(of: mark, with: ".")
        guard let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        return value
    }

    @ViewBuilder
    private var detailSection: some View {
        Section {
            HStack {
                TextField("Merchant", text: $draft.merchant)
                    .textInputAutocapitalization(.words)
                    .focused($focus, equals: .merchant)
                    .submitLabel(.done)
                // Misread? Pick the merchant's words out of the message.
                if let raw = draft.rawMessage, !raw.isEmpty {
                    Button("Pick merchant from message", systemImage: "text.viewfinder") {
                        pickingMerchant = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("pickMerchant")
                }
            }
            .sheet(isPresented: $pickingMerchant) {
                MerchantPickerView(message: draft.rawMessage ?? "", current: draft.merchant) { words, remember in
                    let learned = draft.pickMerchant(words, remember: remember, context: showsCategoryAndAccount ? context : nil)
                    if remember {
                        pickNote = learned
                            ? "Messages like this one will read the merchant from the same place."
                            : "Couldn't learn where the merchant is in this message, so it's set for this expense only."
                    } else {
                        pickNote = nil
                    }
                }
            }

            DatePicker("Date", selection: $draft.date)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let pickNote {
                    Text(pickNote)
                }
                if !showsCategoryAndAccount {
                    Text("ExpLog fills in the card and category when it opens. Open it once, and you can choose them here.")
                }
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
        Section {
            TextField("Add a note", text: $draft.note, axis: .vertical)
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
