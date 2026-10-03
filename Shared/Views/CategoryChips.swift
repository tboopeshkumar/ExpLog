import SwiftUI

/// Categories as a row of coloured chips, one tap to choose and a second to
/// clear; the chosen category's subcategories, if it has any, as a row below.
/// Every choice is visible at once, in its colour, where a menu showed "None".
///
/// The chosen chip keeps the category's colour for its text on a stronger
/// tile of the same colour, with an outline — not white on a solid fill,
/// which washes out for the lighter hues (see CategoryIcon).
struct CategoryChips: View {
    let categories: [ExpenseCategory]
    @Binding var category: ExpenseCategory?
    @Binding var subcategory: ExpenseSubcategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(categories) { item in
                            chip(item)
                                .id(item.persistentModelID)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 1)
                }
                .onAppear {
                    // A category set from a message or an edit may be off-screen.
                    if let category { proxy.scrollTo(category.persistentModelID, anchor: .center) }
                }
            }

            if let category, !category.sortedSubcategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(category.sortedSubcategories) { item in
                            subchip(item, tint: category.tint)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 1)
                }
                .transition(.opacity)
            }
        }
        .padding(.vertical, 10)
        .listRowInsets(EdgeInsets())
        .animation(.snappy, value: category?.persistentModelID)
    }

    private func chip(_ item: ExpenseCategory) -> some View {
        let isSelected = category === item
        return Button {
            category = isSelected ? nil : item
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(item.tint)
                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(isSelected ? item.tint : .primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? item.tint.opacity(0.2) : Color(.tertiarySystemFill), in: .capsule)
            .overlay {
                if isSelected { Capsule().strokeBorder(item.tint, lineWidth: 1.5) }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("category-\(item.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func subchip(_ item: ExpenseSubcategory, tint: Color) -> some View {
        let isSelected = subcategory === item
        return Button {
            subcategory = isSelected ? nil : item
        } label: {
            Text(item.name)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isSelected ? tint : .secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(isSelected ? tint.opacity(0.2) : Color(.quaternarySystemFill), in: .capsule)
                .overlay {
                    if isSelected { Capsule().strokeBorder(tint, lineWidth: 1.5) }
                }
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("subcategory-\(item.name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
