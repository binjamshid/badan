import SwiftUI

enum RecomputeScoresCopy {
    static let title = LocalizedString(en: "Recompute scores", ar: "إعادة حساب الدرجات")
    static let idle = LocalizedString(
        en: "Re-derives readiness, sleep and effort across everything BADAN has stored.",
        ar: "يعيد اشتقاق الجاهزية والنوم والجهد عبر كل ما خزّنه بادن.")
    static let running = LocalizedString(en: "Recomputing…", ar: "جارٍ إعادة الحساب…")
    /// The honest answer to the common case. A recompute over unchanged data writes nothing, which
    /// is a success — but "nothing happened" and "it worked and there was nothing to change" look
    /// identical without saying so, and the second is by far the more likely.
    static let noChanges = LocalizedString(
        en: "Finished — nothing needed changing.",
        ar: "انتهى — لا شيء يحتاج تغييراً.")
    static let nothingStored = LocalizedString(
        en: "Nothing stored yet, so there is nothing to recompute.",
        ar: "لا توجد بيانات مخزّنة بعد، فلا شيء لإعادة حسابه.")

    static func touched(_ n: String) -> LocalizedString {
        LocalizedString(en: "Finished — \(n) days updated.", ar: "انتهى — تم تحديث \(n) يوماً.")
    }

    /// Named where the user can see it, because it is the surprising part. `backfill` re-derives
    /// readiness and effort per day across the whole window, but the sleep cluster is a bounded
    /// rolling measure anchored at the end — roughly the last 29 nights. Older imported nights keep
    /// their sessions, durations and stage rollups but never get a sleep score, and their readiness
    /// computes reduced-input without `sleep.performance`. Pre-existing behaviour for every archive
    /// import; stated rather than left to be discovered.
    static let sleepCaveat = LocalizedString(
        en: "Sleep scores only cover roughly the last month of nights. Older nights keep their "
            + "sleep records, but BADAN does not score them.",
        ar: "درجات النوم تغطي تقريباً ليالي الشهر الأخير فقط. تحتفظ الليالي الأقدم بسجلات نومها، "
            + "لكن بادن لا يمنحها درجة.")
}

/// D-35 / D-36 item 2a — the plain verb for re-deriving scores.
///
/// Shaped after `SyncNowRow`, and separate from it on purpose: "Sync now" fetches new readings from
/// HealthKit, this re-derives from readings already stored. Conflating them would misdescribe both,
/// and a user who has just changed a calculation method wants the second without the first.
struct RecomputeScoresRow: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                Button {
                    env.recomputeScores()
                    Announce.status(env.s(RecomputeScoresCopy.running))
                } label: {
                    HStack(spacing: BadanSpace.space3) {
                        Image(systemName: "function")
                            .imageScale(.medium)
                            .foregroundStyle(BadanColor.primary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(RecomputeScoresCopy.title, language: env.language)
                                .font(BadanFont.body)
                                .foregroundStyle(BadanColor.textPrimary)
                            Text(subtitle, language: env.language)
                                .font(BadanFont.caption)
                                .foregroundStyle(BadanColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: BadanSpace.space2)
                        if env.isRecomputeInFlight {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(minHeight: BadanSpace.touchMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Disabled rather than hidden while running, matching `SyncNowRow`: a control that
                // vanishes mid-tap is worse than one that visibly waits.
                .disabled(env.isRecomputeInFlight)

                LText(RecomputeScoresCopy.sleepCaveat)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitle: LocalizedString {
        if env.isRecomputeInFlight { return RecomputeScoresCopy.running }
        guard let touched = env.lastRecomputeTouched else { return RecomputeScoresCopy.idle }
        return touched == 0
            ? RecomputeScoresCopy.noChanges
            : RecomputeScoresCopy.touched(env.format.integer(touched))
    }
}
