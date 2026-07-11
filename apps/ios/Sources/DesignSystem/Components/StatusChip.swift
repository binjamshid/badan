import SwiftUI

/// A calm status pill. It never uses red/green to moralize: in-band is a subtle green, both
/// out-of-band directions share ONE amber and disambiguate with an up/down arrow, and info
/// is blue. Colour is never the only signal — every state pairs hue with an icon and text.
struct StatusChip: View {
    /// The judgment-free positions this chip can render.
    enum Status {
        case inBand, above, below, info

        /// Map a personal-band position onto a chip status.
        init(_ position: Baseline.Position) {
            switch position {
            case .within: self = .inBand
            case .above: self = .above
            case .below: self = .below
            }
        }
    }

    var status: Status
    var label: String
    var language: AppLanguage

    init(_ status: Status, label: String, language: AppLanguage) {
        self.status = status
        self.label = label
        self.language = language
    }

    /// Convenience: build directly from a `Baseline.Position`.
    init(position: Baseline.Position, label: String, language: AppLanguage) {
        self.init(Status(position), label: label, language: language)
    }

    var body: some View {
        HStack(spacing: BadanSpace.space1) {
            Image(systemName: iconName)
                .imageScale(.small)
                .accessibilityHidden(true)
                // Arrows are semantic (up = higher value), not directional, so only the icon
                // is pinned LTR — the surrounding HStack/text still follow ambient direction
                // so Arabic labels mirror normally, like every other pill in the app.
                .environment(\.layoutDirection, .leftToRight)
            Text(label)
                .font(BadanFont.chip)
        }
        .foregroundStyle(textTint)
        .padding(.horizontal, BadanSpace.space2)
        .padding(.vertical, BadanSpace.space1)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityStatusValue.resolved(language))
    }

    /// Background tint (also used for the icon's "on-surface" appearance elsewhere via
    /// `tint`-derived colours). Kept separate from the text colour: at ~14% opacity this tint
    /// alone does not give small chip text enough contrast against `surface` (see `textTint`).
    private var tint: Color {
        switch status {
        case .inBand: return BadanColor.inBand
        case .above, .below: return BadanColor.outOfBand
        case .info: return BadanColor.info
        }
    }

    /// The chip's actual foreground colour: a darker/lighter on-tint variant so label text
    /// clears WCAG AA against its own translucent background (light-mode `tint` alone measures
    /// ~2.9–3.1:1 as text; `*OnTint` measures well over 4.5:1, and darkens further under
    /// "Increase Contrast").
    private var textTint: Color {
        switch status {
        case .inBand: return BadanColor.inBandOnTint
        case .above, .below: return BadanColor.outOfBandOnTint
        case .info: return BadanColor.info
        }
    }

    private var iconName: String {
        switch status {
        case .inBand: return "checkmark"
        case .above: return "arrow.up"
        case .below: return "arrow.down"
        case .info: return "info.circle"
        }
    }

    /// A semantic VoiceOver value bound directly to `status`, independent of whatever the
    /// display label text says — so meaning is guaranteed even if display copy changes later.
    private var accessibilityStatusValue: LocalizedString {
        switch status {
        case .inBand: return LocalizedString(en: "Within your usual range", ar: "ضمن نطاقك المعتاد")
        case .above: return LocalizedString(en: "Above your usual range", ar: "أعلى من نطاقك المعتاد")
        case .below: return LocalizedString(en: "Below your usual range", ar: "أقل من نطاقك المعتاد")
        case .info: return LocalizedString(en: "Informational", ar: "معلومات")
        }
    }
}
