import SwiftUI
import UIKit

/// The app's teal, for where the asset catalogue's AccentColor doesn't
/// reach: the share sheet, which has no catalogue of its own. Keep the two in
/// step (Resources/Assets.xcassets/AccentColor.colorset).
///
/// Deeper in light mode than the icon's teal, so it reads as text on white
/// (4.9:1); the icon's bright teal in dark mode.
public enum Brand {
    public static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x2D / 255.0, green: 0xD4 / 255.0, blue: 0xBF / 255.0, alpha: 1)
            : UIColor(red: 0x0A / 255.0, green: 0x7C / 255.0, blue: 0x88 / 255.0, alpha: 1)
    })
}
