import SwiftUI

/// The original message as tappable words, for when the merchant was misread:
/// tap its first word, then its last. The parser's own reading starts out
/// selected, when it's in there.
struct MerchantPickerView: View {
    let message: String
    /// The picked words, and whether to remember the place for messages like it.
    let onPick: (ClosedRange<Int>, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: ClosedRange<Int>?
    @State private var remember = true

    private let words: [MerchantFormat.Word]

    init(message: String, current: String, onPick: @escaping (ClosedRange<Int>, Bool) -> Void) {
        self.message = message
        self.onPick = onPick
        let words = MerchantFormat.words(of: message)
        self.words = words
        _selection = State(initialValue: Self.range(of: current, in: message, count: words.count))
    }

    private var preview: String? {
        selection.flatMap { MerchantFormat.merchant(picking: $0, of: message) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    WordFlow(spacing: 6) {
                        ForEach(words.indices, id: \.self) { index in
                            wordButton(index)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Tap the merchant's first word, then its last")
                }

                Section {
                    LabeledContent("Merchant") {
                        Text(preview ?? "—")
                            .foregroundStyle(preview == nil ? .secondary : .primary)
                    }
                    Toggle("Remember for messages like this", isOn: $remember)
                } footer: {
                    Text("ExpLog will read the merchant from the same place in this bank's future messages, and name and categorise it the way you save this one.")
                }
            }
            .navigationTitle("Pick merchant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let selection { onPick(selection, remember) }
                        dismiss()
                    }
                    .disabled(preview == nil)
                }
            }
        }
    }

    private func wordButton(_ index: Int) -> some View {
        let isSelected = selection?.contains(index) ?? false
        return Button {
            tap(index)
        } label: {
            Text(words[index].text)
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.fill.tertiary),
                    in: .rect(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("word-\(index)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// First tap picks a word; a second extends to it; a third starts again.
    /// Tapping the only picked word clears it.
    private func tap(_ index: Int) {
        guard let current = selection else {
            selection = index...index
            return
        }
        if current.count == 1 {
            selection = current.lowerBound == index
                ? nil
                : min(index, current.lowerBound)...max(index, current.lowerBound)
        } else {
            selection = index...index
        }
    }

    /// The words that read as `merchant`, if any — the parser's reading.
    private static func range(of merchant: String, in message: String, count: Int) -> ClosedRange<Int>? {
        let target = merchant.lowercased()
        guard !target.isEmpty else { return nil }
        for start in 0..<count {
            for end in start..<min(start + 8, count)
            where MerchantFormat.merchant(picking: start...end, of: message)?.lowercased() == target {
                return start...end
            }
        }
        return nil
    }
}

/// Lays views out left to right, wrapping onto new lines like text.
struct WordFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(width: item.width, height: nil)
                )
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat, width: CGFloat)] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row(y: 0)]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            let x = rows[rows.count - 1].width == 0 ? 0 : rows[rows.count - 1].width + spacing
            if x > 0, x + itemWidth > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let start = rows[rows.count - 1].width == 0 ? 0 : rows[rows.count - 1].width + spacing
            rows[rows.count - 1].items.append((index, start, itemWidth))
            rows[rows.count - 1].width = start + itemWidth
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
