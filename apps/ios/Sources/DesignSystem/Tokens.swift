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
    /// but fully dual-theme). Both hex strings are parsed once, up front, rather than inside
    /// the trait-resolution closure (which UIKit can invoke repeatedly per appearance change).
    init(light: String, dark: String) {
        let lightColor = UIColor(Color(hex: light))
        let darkColor = UIColor(Color(hex: dark))
        let dynamic = UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        }
        self.init(dynamic)
    }

    /// Resolve against both interface style AND the system "Increase Contrast" accessibility
    /// setting, so status-bearing tokens stay perceivable for low-vision users without losing
    /// their calm default appearance for everyone else. All four hex strings are parsed once,
    /// up front, for the same reason as `init(light:dark:)`.
    init(light: String, dark: String, lightHighContrast: String, darkHighContrast: String) {
        let l = UIColor(Color(hex: light))
        let d = UIColor(Color(hex: dark))
        let lHC = UIColor(Color(hex: lightHighContrast))
        let dHC = UIColor(Color(hex: darkHighContrast))
        let dynamic = UIColor { traits in
            let highContrast = traits.accessibilityContrast == .high
            switch (traits.userInterfaceStyle == .dark, highContrast) {
            case (false, false): return l
            case (false, true): return lHC
            case (true, false): return d
            case (true, true): return dHC
            }
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
    /// Reserved and intentionally unused everywhere today. This is a deliberate, permanent
    /// design decision, not an oversight: BADAN never moralizes a reading past "in range" /
    /// "outside your usual range" (one calm amber covers every out-of-band case, regardless of
    /// magnitude). Do not reach for this token for a "more severe" out-of-band state without a
    /// considered product decision to introduce a second severity tier.
    static let critical = Color(light: "#C9353B", dark: "#E5484D")

    /// Darker/lighter on-tint variants of `inBand`/`outOfBand`, for use as *text* colour over
    /// their own translucent tint background (e.g. `StatusChip`). The base tokens above read
    /// fine as icons/borders but fall under WCAG AA (~2.9–3.1:1) as small text on their own
    /// ~14%-opacity tint fill; these variants keep the same hue while passing AA (and further
    /// darken/lighten under "Increase Contrast").
    static let inBandOnTint = Color(
        light: "#1E6E37", dark: "#57C785",
        lightHighContrast: "#0F4A24", darkHighContrast: "#8FF0B3"
    )
    static let outOfBandOnTint = Color(
        light: "#8F5D10", dark: "#E8A13A",
        lightHighContrast: "#5C3B05", darkHighContrast: "#FFC168"
    )
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
    /// Minimum gap between two adjacent tappable targets (distinct from `touchMin`, which
    /// governs a single target's own size). Use this wherever two controls sit side by side.
    static let touchGap: CGFloat = 16
}

/// Corner radii — soft, tactile, generous by default.
///
/// Border rule of thumb: `BadanCard` gets a visible `separator` hairline because it's an
/// opaque content container the eye needs to parse as a distinct region. Tinted "signal"
/// shapes (status pills, chart bands) intentionally do NOT get a stroke — their translucent
/// fill against the surface already reads as bounded, and a border on top of a soft tint would
/// compete with, rather than support, the calm/non-alarming status language.
enum BadanRadius {
    static let chip: CGFloat = 10
    static let control: CGFloat = 12
    static let card: CGFloat = 20
    static let sheet: CGFloat = 24
}

/// The type ramp. Numerals use tabular monospaced digits so values never jitter as they
/// tick (principle: data-forward typography).
///
/// (BUG-08) Every token used to be a fixed-size `Font.system(size:weight:design:)`, which
/// never responds to the user's preferred Dynamic Type size — Accessibility text sizes had no
/// effect anywhere in the app. Each token now maps to the nearest system text style (with an
/// explicit weight/design override to keep the mined visual hierarchy) via
/// `Font.system(_:design:weight:)`, so the whole ramp scales with Dynamic Type. `monospacedDigit()`
/// is preserved everywhere it was already applied. Trade-off: at the default (non-scaled) text
/// size, each token's exact point size shifts slightly from the originally-mined value to its
/// text-style's default anchor (e.g. `heroNumeral` was a fixed 44pt, `.largeTitle` anchors at
/// 34pt) — the relative hierarchy (hero > numeralM > sectionTitle > body > bodyCompact >
/// chip/caption) is unchanged.
enum BadanFont {
    static let heroNumeral = Font.system(.largeTitle, design: .rounded, weight: .semibold).monospacedDigit()
    static let numeralM = Font.system(.title, weight: .medium).monospacedDigit()
    static let sectionTitle = Font.system(.title3, weight: .bold)
    static let body = Font.system(.callout)
    static let bodyCompact = Font.system(.subheadline)
    static let chip = Font.system(.footnote, weight: .medium)
    static let caption = Font.system(.footnote)
    /// Tappable text-only actions (e.g. "See all", "Why"). Distinct from `chip`, which is
    /// reserved for passive status/pill labels — the smallest size in the ramp shouldn't also
    /// carry the app's interactive call-to-action text.
    static let link = Font.system(.subheadline, weight: .medium)
}
