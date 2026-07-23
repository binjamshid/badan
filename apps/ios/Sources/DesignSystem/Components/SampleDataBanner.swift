import SwiftUI

/// STUB-01/COMP-06: a single, global, honest label for "what you're looking at right now is the
/// bundled sample dataset, not your own." Release builds bootstrap 90 days of fabricated health
/// data before onboarding ever runs (`SeedController.seed`), and "Explore with sample data" /
/// skipping onboarding lets that stand indefinitely — without this, Home/Body/Sources/Insights
/// all present it as real with no labeling anywhere.
///
/// Deliberately has **no close/dismiss control** — as long as `SeedController.isDemoDataActive`
/// is true, the banner keeps showing. It goes away on its own the moment that flag clears (a
/// real connect, or onboarding's "Start empty"), not because the user dismissed a warning about
/// their own data. Calm and small by design: it's a standing fact about the current view, not an
/// alert.
///
/// Presentational only — takes `language` explicitly (matching `StatusChip`/`DepthBadge`) rather
/// than reading `AppEnvironment` itself, so it stays a plain, reusable design-system component.
///
/// STUB-01/COMP-06 (post-onboarding data choice): the trailing chevron is a disclosure hint, not
/// a dismiss control — the doc above still holds (there is still no way to make the banner go
/// away without actually connecting or deleting sample data). `RootView`'s `MainTabView` wraps
/// this whole view in a `Button` that opens `DataConnectionChoiceScreen`; this component stays
/// unaware of that and never gains behavior of its own.
struct SampleDataBanner: View {
    var language: AppLanguage

    private static let message = LocalizedString(
        en: "Sample data — connect Apple Health to see yours",
        ar: "بيانات تجريبية — اربط صحة آبل لرؤية بياناتك")

    var body: some View {
        HStack(spacing: BadanSpace.space2) {
            Image(systemName: "info.circle.fill")
                .imageScale(.small)
                .foregroundStyle(BadanColor.info)
                .accessibilityHidden(true)
            Text(Self.message.resolved(language))
                .font(BadanFont.chip)
                .foregroundStyle(BadanColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.forward")
                .imageScale(.small)
                .foregroundStyle(BadanColor.textSecondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, BadanSpace.space4)
        .padding(.vertical, BadanSpace.space2)
        .background(BadanColor.surfaceElevated, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1)
        )
        .badanElevation()
        .padding(.horizontal, BadanSpace.space4)
        .padding(.bottom, BadanSpace.space2)
        .accessibilityElement(children: .combine)
    }
}

#Preview("SampleDataBanner") {
    ZStack(alignment: .bottom) {
        BadanColor.background.ignoresSafeArea()
        VStack {
            SampleDataBanner(language: .en)
            SampleDataBanner(language: .ar)
        }
    }
}
