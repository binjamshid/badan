import SwiftUI
import UIKit

/// Hex bridging so mined design tokens can be expressed as literal `#RRGGBB` strings and
/// stay one-to-one with `docs/design/design-tokens.json`.
extension Color {
    /// Create a colour from a `#RRGGBB` hex string (leading `#` optional).
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    /// Resolve one of two hex values against the active interface style, so every token is
    /// dual-theme from day one without any per-view environment read (principle: dark-first
    /// but fully dual-theme).
    init(light: String, dark: String) {
        let dynamic = UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? Color(hex: dark) : Color(hex: light))
        }
        self.init(dynamic)
    }
}

/// The semantic colour ontology. Each token carries the exact mined light/dark pair so
/// screens reference meaning ("surface", "inBand") rather than raw hex.
enum BadanColor {
    // Surfaces & text
    static let background = Color(light: "#FAFAF8", dark: "#0C0E11")
    static let surface = Color(light: "#FFFFFF", dark: "#16191E")
    static let surfaceElevated = Color(light: "#F1F1EE", dark: "#1E2228")
    static let primary = Color(light: "#157A6E", dark: "#5BC5BA")
    static let textPrimary = Color(light: "#17191C", dark: "#F2F3F5")
    static let textSecondary = Color(light: "#5C636D", dark: "#9AA1AB")
    static let separator = Color(light: "#E5E5E0", dark: "#252A31")

    // Status — never moralize state. Out-of-band above OR below share ONE amber; direction
    // is carried by icon + text, never by hue alone.
    static let inBand = Color(light: "#2E9E63", dark: "#57C785")
    static let outOfBand = Color(light: "#B97A14", dark: "#E8A13A")
    static let info = Color(light: "#2678C4", dark: "#4C9FE8")
    /// Reserved; near-never used so it keeps its power.
    static let critical = Color(light: "#C9353B", dark: "#E5484D")
}

/// The 4pt spacing scale plus card padding and the strict minimum touch target.
enum BadanSpace {
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
    static let space7: CGFloat = 32
    static let space8: CGFloat = 40
    static let cardPadding: CGFloat = 16
    static let touchMin: CGFloat = 44
}

/// Corner radii — soft, tactile, generous by default.
enum BadanRadius {
    static let chip: CGFloat = 10
    static let control: CGFloat = 12
    static let card: CGFloat = 20
    static let sheet: CGFloat = 24
}

/// The type ramp. Numerals use tabular monospaced digits so values never jitter as they
/// tick (principle: data-forward typography).
enum BadanFont {
    static let heroNumeral = Font.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit()
    static let numeralM = Font.system(size: 28, weight: .medium).monospacedDigit()
    static let sectionTitle = Font.system(size: 20, weight: .bold)
    static let body = Font.system(size: 16, weight: .regular)
    static let bodyCompact = Font.system(size: 15, weight: .regular)
    static let chip = Font.system(size: 13, weight: .medium)
    static let caption = Font.system(size: 13, weight: .regular)
}
