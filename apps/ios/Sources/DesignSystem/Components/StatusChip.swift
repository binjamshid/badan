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
            Text(label)
                .font(BadanFont.chip)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, BadanSpace.space2)
        .padding(.vertical, BadanSpace.space1)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
        // Arrows are semantic (up = higher value), not directional, so they must not mirror.
        .environment(\.layoutDirection, .leftToRight)
    }

    private var tint: Color {
        switch status {
        case .inBand: return BadanColor.inBand
        case .above, .below: return BadanColor.outOfBand
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
}
