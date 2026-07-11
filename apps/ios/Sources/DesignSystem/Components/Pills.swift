import SwiftUI

/// A small, generic labelled pill (optional leading icon + tint). The base shape reused by
/// the depth and provisional badges.
struct PillLabel: View {
    var text: String
    var systemImage: String?
    var tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = BadanColor.textSecondary) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
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
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: BadanRadius.chip, style: .continuous))
    }
}

/// Indicates the current depth altitude ("Simple"/"Balanced"/"Detailed"). One model, two
/// altitudes — this badge just names which altitude is showing.
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
            tint: BadanColor.primary
        )
    }

    private var iconName: String {
        switch depth {
        case .casual: return "leaf"
        case .balanced: return "circle.lefthalf.filled"
        case .power: return "slider.horizontal.3"
        }
    }
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
            tint: BadanColor.info
        )
    }
}
