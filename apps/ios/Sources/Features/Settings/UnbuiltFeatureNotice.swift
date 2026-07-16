import SwiftUI

private enum UnbuiltStrings {
    static let title = LocalizedString(en: "Not built yet", ar: "غير مبني بعد")
    static let body = LocalizedString(
        en: "This isn't available in this version. When it works, it will appear here — BADAN "
            + "would rather say so than show you a control that does nothing.",
        ar: "هذه الميزة غير متاحة في هذا الإصدار. وحين تعمل ستظهر هنا — ويفضّل بدن أن يقول ذلك "
            + "على أن يعرض لك زراً لا يفعل شيئاً.")
}

/// States plainly that a named feature does not exist yet.
///
/// The alternative — a real-looking button that silently does nothing — is the exact defect three
/// audits of this codebase kept finding: Android's no-op "Connect health data" button, its four
/// notification toggles wired to nothing, the insight feedback that persisted and was never read.
/// Every one of them looked finished, which is precisely what made them harmful: a user cannot
/// route around a promise they don't know is empty.
///
/// So this is deliberately NOT a disabled button. A greyed-out control still implies "this exists,
/// something is temporarily wrong"; this says the true thing instead. Use it while a feature's
/// place in the UI is decided but its implementation isn't — and delete it the moment the feature
/// lands, not before.
///
/// Calm, `info`, no alarm — nothing has gone wrong.
struct UnbuiltFeatureNotice: View {
    @Environment(AppEnvironment.self) private var env
    /// What isn't built, named the way the user would look for it.
    let feature: LocalizedString

    var body: some View {
        HStack(alignment: .top, spacing: BadanSpace.space2) {
            Image(systemName: "hammer")
                .imageScale(.small)
                .foregroundStyle(BadanColor.info)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: BadanSpace.space2) {
                    LText(feature)
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    PillLabel(env.s(UnbuiltStrings.title))
                }
                LText(UnbuiltStrings.body)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(BadanSpace.space3)
        .background(BadanColor.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: BadanRadius.card, style: .continuous)
                .strokeBorder(BadanColor.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}
