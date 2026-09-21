import SwiftUI

extension ExpenseCategory {
    /// Colour for this category's icon.
    ///
    /// Only system colours are used: iOS adjusts each one for light mode, dark
    /// mode and Increase Contrast, so nothing here needs per-mode values.
    /// Yellow is deliberately absent — as a glyph on a light background it
    /// falls well short of readable contrast.
    ///
    /// Keyed by symbol rather than name, so renaming a category keeps its
    /// colour. Nothing is stored, so existing categories pick this up with no
    /// migration.
    public var tint: Color {
        if let color = Self.colorsBySymbol[symbol] {
            return color
        }
        // Categories added in the app all start with the "tag" symbol, so
        // spread them across the palette instead.
        return Self.palette[abs(sortOrder) % Self.palette.count]
    }

    private static let colorsBySymbol: [String: Color] = [
        "cart": .green,
        "fork.knife": .orange,
        "car": .blue,
        "fuelpump": .brown,
        "bag": .pink,
        "bolt": .indigo,
        "cross.case": .red,
        "play.tv": .purple,
        "airplane": .cyan,
        "ellipsis.circle": .gray,
    ]

    private static let palette: [Color] = [
        .teal, .indigo, .pink, .orange, .purple, .blue, .green, .mint, .cyan, .brown,
    ]
}

/// A category's symbol on a soft tile of its colour. Used wherever a category
/// is shown, so the colours stay consistent across the app.
///
/// The glyph is drawn in the colour itself on a low-opacity tile of the same
/// colour, rather than white on a solid fill: that holds its contrast in both
/// appearances, whereas white-on-colour washes out for the lighter hues.
public struct CategoryIcon: View {
    let category: ExpenseCategory?
    var size: CGFloat = 32

    public init(_ category: ExpenseCategory?, size: CGFloat = 32) {
        self.category = category
        self.size = size
    }

    public var body: some View {
        let tint = category?.tint ?? .gray
        Image(systemName: category?.symbol ?? "questionmark")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}
