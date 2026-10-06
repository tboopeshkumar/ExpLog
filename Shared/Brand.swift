import SwiftUI
import UIKit

/// The app's indigo, for where the asset catalogue's AccentColor doesn't
/// reach: the share sheet, which has no catalogue of its own. Keep the two in
/// step (Resources/Assets.xcassets/AccentColor.colorset).
///
/// A lighter indigo in dark mode, so it reads on dark backgrounds.
public enum Brand {
    public static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0x9A / 255.0, green: 0x91 / 255.0, blue: 1.0, alpha: 1)
            : UIColor(red: 0x5B / 255.0, green: 0x4F / 255.0, blue: 0xE0 / 255.0, alpha: 1)
    })
}
