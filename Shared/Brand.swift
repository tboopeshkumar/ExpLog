import SwiftUI
import UIKit

/// The app's coral, for where the asset catalogue's AccentColor doesn't
/// reach: the share sheet, which has no catalogue of its own. Keep the two in
/// step (Resources/Assets.xcassets/AccentColor.colorset).
///
/// Deeper in light mode than the icon's coral, so it reads as text on white
/// (4.6:1); lighter in dark mode.
public enum Brand {
    public static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0x7A / 255.0, blue: 0x5C / 255.0, alpha: 1)
            : UIColor(red: 0xD2 / 255.0, green: 0x43 / 255.0, blue: 0x2A / 255.0, alpha: 1)
    })
}
