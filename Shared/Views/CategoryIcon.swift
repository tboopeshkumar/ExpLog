import SwiftUI
import UIKit

extension ExpenseCategory {
    /// Colour for this category's icon.
    ///
    /// Only system colours are used: they're dynamic, so iOS adjusts each one
    /// for light mode, dark mode and Increase Contrast with no per-mode values
    /// here. Yellow is deliberately absent — as a glyph on a light background it
    /// falls well short of readable contrast.
    ///
    /// Keyed by symbol rather than name, so renaming a category keeps its
    /// colour. Nothing is stored, so existing categories pick this up with no
    /// migration.
    public var tint: Color { Color(uiColor: uiTint) }

    /// UIKit form of `tint`, the single source both are drawn from.
    public var uiTint: UIColor {
        if let color = Self.colorsBySymbol[symbol] {
            return color
        }
        // Categories added in the app all start with the "tag" symbol, so
        // spread them across the palette instead.
        return Self.palette[abs(sortOrder) % Self.palette.count]
    }

    /// The symbol pre-coloured for use inside a Picker or Menu.
    ///
    /// iOS redraws menu icons as single-colour templates, which would strip
    /// `tint`. An image marked `.alwaysOriginal` is drawn as-is, so the colour
    /// survives. The colour goes in as a symbol palette colour rather than a
    /// flat tint, so its dynamic light/dark value is resolved when the menu
    /// draws, not fixed when the image is made.
    public var menuIcon: Image {
        let configuration = UIImage.SymbolConfiguration(paletteColors: [uiTint])
        let image = UIImage(systemName: symbol, withConfiguration: configuration)
            ?? UIImage(systemName: "tag", withConfiguration: configuration)
            ?? UIImage()
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
    }

    private static let colorsBySymbol: [String: UIColor] = [
        "cart": .systemGreen,
        "fork.knife": .systemOrange,
        "car": .systemBlue,
        "fuelpump": .systemBrown,
        "bag": .systemPink,
        "bolt": .systemIndigo,
        "cross.case": .systemRed,
        "play.tv": .systemPurple,
        "airplane": .systemCyan,
        "ellipsis.circle": .systemGray,
    ]

    private static let palette: [UIColor] = [
        .systemTeal, .systemIndigo, .systemPink, .systemOrange, .systemPurple,
        .systemBlue, .systemGreen, .systemMint, .systemCyan, .systemBrown,
    ]
}

/// A category's symbol on a soft tile of its colour. Used wherever a category
/// is shown outside a menu, so the colours stay consistent across the app.
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
