import SwiftUI

// MARK: - EPIC-39 CYCLE-06 integration — the one-tap-explainable phase-covariate indicator.
//
// Research doc §7 ("Cycle phase as a cross-app covariate") names both the copy pattern and the
// interaction rule this component exists to satisfy:
//   * "Compared with your usual late-luteal pattern" instead of "HRV is low." (§7, "Cross-app
//     implementation rules").
//   * "Any phase-conditioned interpretation must be explainable in one tap with source inputs and
//     confidence." (same section).
//   * "Phase context should appear as optional overlay chips or chart layers, not forced narrative
//     in every screen." (same section) — this renders ONLY when a caller actually chose a
//     phase-conditioned band over the default one (`PhaseCovariateReading` is non-nil), never as
//     a standing fixture on every metric.
//
// A calm caption, not a redesign: styled like `BodyPillarCard`'s existing `bandCaption`/
// `PillLabel` captions elsewhere in Home/Body, tappable to a plain `.alert` (mirrors
// `ShortcutsSetupGuideScreen`'s own alert pattern) rather than a new sheet/screen.

private enum CyclePhaseCovariateNoteStrings {
    static let caption = LocalizedString(
        en: "Compared with your usual {phase} pattern",
        ar: "بالمقارنة مع نمطك المعتاد في مرحلة {phase}")
    static let explainerTitle = LocalizedString(en: "Why this range?", ar: "لماذا هذا النطاق؟")
    static let explainerBody = LocalizedString(
        en: "This range reflects your own {phase}-phase history specifically, not your overall "
            + "average — calendar-based, {confidence}% confidence.",
        ar: "يعكس هذا النطاق سجلّك الخاص في مرحلة {phase} تحديداً، وليس متوسطك العام — بالاعتماد "
            + "على التقويم، بثقة {confidence}٪.")
}

/// Renders beside a metric whose shown band is phase-conditioned (never beside a plain default
/// one) — see `PhaseAwareBaselineReader.Result.covariate`.
struct CyclePhaseCovariateNote: View {
    @Environment(AppEnvironment.self) private var env
    let covariate: PhaseCovariateReading

    @State private var showsExplainer = false

    var body: some View {
        Button {
            showsExplainer = true
        } label: {
            HStack(spacing: BadanSpace.space1) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(captionText)
                    .font(BadanFont.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(BadanColor.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(Loc.why, language: env.language))
        .alert(env.s(CyclePhaseCovariateNoteStrings.explainerTitle), isPresented: $showsExplainer) {
            Button(env.s(Loc.close), role: .cancel) {}
        } message: {
            Text(explainerBodyText)
        }
    }

    private var captionText: String {
        CyclePhaseCovariateNoteStrings.caption
            .filling(["phase": covariate.phase.displayName.resolved(env.language)])
            .resolved(env.language)
    }

    private var explainerBodyText: String {
        CyclePhaseCovariateNoteStrings.explainerBody
            .filling([
                "phase": covariate.phase.displayName.resolved(env.language),
                "confidence": env.format.integer(Int((covariate.confidence * 100).rounded())),
            ])
            .resolved(env.language)
    }
}
