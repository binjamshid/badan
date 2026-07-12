import SwiftUI

/// A small, generic labelled pill (optional leading icon + tint). The base shape reused by
/// the depth and provisional badges.
///
/// `filled` distinguishes purely informational pills from the default filled treatment: a
/// filled pill reads as a small status/data tag, while an outlined (`filled: false`) pill
/// signals "read-only, not tappable" — used for badges that share the pill's rounded chrome
/// but have no interactive behavior (see `DepthBadge`/`ProvisionalBadge`).
struct PillLabel: View {
    var text: String
    var systemImage: String?
    var tint: Color
    var filled: Bool

    init(_ text: String, systemImage: String? = nil, tint: Color = BadanColor.textSecondary, filled: Bool = true) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.filled = filled
    }

    var body: some View {
        HStack(spacing: BadanSpace.space1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(BadanFont.chip)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, BadanSpace.space2)
        .padding(.vertical, BadanSpace.space1)
        .background {
            if filled {
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .fill(tint.opacity(0.12))
            } else {
                RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous)
                    .strokeBorder(tint.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

#Preview("PillLabel") {
    VStack(alignment: .leading, spacing: BadanSpace.space2) {
        PillLabel("Filled", systemImage: "heart.text.square", tint: BadanColor.primary)
        PillLabel("Outlined", systemImage: "hourglass", tint: BadanColor.info, filled: false)
    }
    .padding()
}

/// Indicates the current depth altitude ("Simple"/"Detailed"). One model, two altitudes —
/// this badge just names which altitude is showing.
struct DepthBadge: View {
    var depth: DepthPolicy
    var language: AppLanguage

    init(_ depth: DepthPolicy, language: AppLanguage) {
        self.depth = depth
        self.language = language
    }

    var body: some View {
        PillLabel(
            depth.displayName.resolved(language),
            systemImage: iconName,
            tint: BadanColor.primary,
            filled: false
        )
    }

    // A coherent "level" family (low/high dial) so the two depths read as one spectrum
    // rather than unrelated glyphs.
    private var iconName: String {
        switch depth {
        case .casual: return "dial.low.fill"
        case .power: return "dial.high.fill"
        }
    }
}

#Preview("DepthBadge") {
    VStack(alignment: .leading, spacing: BadanSpace.space2) {
        DepthBadge(.casual, language: .en)
        DepthBadge(.power, language: .en)
        DepthBadge(.power, language: .ar)
    }
    .padding()
}

/// A "still learning" badge for provisional derivations/baselines — honest that a number is
/// not yet settled, without alarming.
struct ProvisionalBadge: View {
    var language: AppLanguage

    init(language: AppLanguage) {
        self.language = language
    }

    private static let label = LocalizedString(en: "Still learning", ar: "قيد التعلّم")

    var body: some View {
        PillLabel(
            Self.label.resolved(language),
            systemImage: "hourglass",
            tint: BadanColor.info,
            filled: false
        )
    }
}

#Preview("ProvisionalBadge") {
    VStack(alignment: .leading, spacing: BadanSpace.space2) {
        ProvisionalBadge(language: .en)
        ProvisionalBadge(language: .ar)
    }
    .padding()
}
