import SwiftUI

enum FeedbackCopy {
    /// The question, and every word of it is deliberate. It asks about the NUMBER's fit — not about
    /// health, not about symptoms, not "how are you feeling". BADAN is not entitled to ask the
    /// second, and an answer to it would be a health datum rather than an opinion about a metric.
    static let prompt = LocalizedString(en: "Does this match how you felt?",
                                        ar: "هل يطابق هذا ما شعرت به؟")
    static let matches = LocalizedString(en: "Matches", ar: "يطابق")
    static let doesntMatch = LocalizedString(en: "Doesn't match", ar: "لا يطابق")
    static let feltBetter = LocalizedString(en: "Felt better than this", ar: "شعرت بأفضل من هذا")
    static let feltWorse = LocalizedString(en: "Felt worse than this", ar: "شعرت بأسوأ من هذا")
    static let thanks = LocalizedString(en: "Recorded.", ar: "تم التسجيل.")
    static let change = LocalizedString(en: "Change", ar: "تغيير")

    /// No advice, no interpretation, no encouragement — it states the mechanism and stops.
    ///
    /// Only true where an engine actually reads the calibration back. Use `whatThisDoes(for:)`,
    /// never this constant directly.
    static let whatThisDoesAdjusts = LocalizedString(
        en: "BADAN uses this to adjust future values of this metric on this device. It is never "
            + "sent anywhere, and it never changes readings already calculated.",
        ar: "يستخدم بادن هذا لتعديل القيم المستقبلية لهذا المؤشر على هذا الجهاز. لا يُرسل إلى أي "
            + "مكان، ولا يغيّر القراءات المحسوبة سابقاً.")

    /// The same paragraph for every metric no engine calibrates — which, today, is every derived
    /// metric except readiness (see `CalibrationConsumers`).
    ///
    /// The card used to say "BADAN uses this to adjust future values of this metric" under ANY
    /// derived value, and for sleep, effort, stress and mood that was a promise nothing in the app
    /// kept: the row was written and never read. Saying less is not a downgrade of the feature —
    /// the feedback is still recorded, still deletable, and still what a future calibration would
    /// be learned from. It is the sentence that has to match the code, per this repository's
    /// "says plainly when it doesn't know".
    static let whatThisDoesRecordOnly = LocalizedString(
        en: "BADAN records this on this device and never sends it anywhere. It does not change "
            + "this metric's values — BADAN does not adjust this one from feedback yet. Your "
            + "answers are kept as a record of where the calculation missed.",
        ar: "يسجّل بادن هذا على هذا الجهاز ولا يرسله إلى أي مكان. لا يغيّر قيم هذا المؤشر — لا "
            + "يعدّل بادن هذا المؤشر بناءً على الملاحظات بعد. تُحفظ إجاباتك كسجل للمواضع التي "
            + "أخطأ فيها الحساب.")

    /// The mechanism paragraph for one metric: the adjustment promise only where an adjustment is
    /// consumed.
    static func whatThisDoes(for metricId: String) -> LocalizedString {
        CalibrationConsumers.adjustsFutureValues(of: metricId) ? whatThisDoesAdjusts
                                                               : whatThisDoesRecordOnly
    }

    static func progress(_ have: String, _ need: String) -> LocalizedString {
        LocalizedString(en: "\(have) of \(need) before BADAN adjusts anything.",
                        ar: "\(have) من \(need) قبل أن يعدّل بادن أي شيء.")
    }
}

/// D-36 — "does this match how you felt?" under a derived value.
///
/// Shown only for metrics BADAN actually calculates. Asking whether a directly-measured reading
/// "matches how you felt" would be incoherent: a recorded heart rate is not BADAN's opinion to
/// adjust.
struct DerivedFeedbackCard: View {
    @Environment(AppEnvironment.self) private var env
    let metricId: String
    let value: DerivedValue

    @State private var expanded = false

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                LText(FeedbackCopy.prompt)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let existing = current {
                    HStack(spacing: BadanSpace.space2) {
                        Text(label(for: existing.direction), language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        Button { expanded = true } label: {
                            Text(FeedbackCopy.change, language: env.language)
                                .font(BadanFont.link)
                                .foregroundStyle(BadanColor.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if current == nil || expanded {
                    HStack(spacing: BadanSpace.space2) {
                        choice(FeedbackCopy.matches, .matches)
                        choice(FeedbackCopy.doesntMatch, nil)
                    }
                    if showingDirections {
                        HStack(spacing: BadanSpace.space2) {
                            // "Felt better than this" means the number read LOW — under-scored.
                            choice(FeedbackCopy.feltBetter, .under)
                            choice(FeedbackCopy.feltWorse, .over)
                        }
                    }
                }

                LText(FeedbackCopy.whatThisDoes(for: metricId))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Says how far off the threshold is, so ten taps that appear to do nothing read as
                // progress rather than as a broken control. Renders only for a metric that has a
                // threshold to reach — see `adjustmentProgress`.
                if let remaining = remainingBeforeAdjustment {
                    LText(FeedbackCopy.progress(env.format.integer(remaining.have),
                                                env.format.integer(remaining.need)))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }

    @State private var showingDirections = false

    private func choice(_ title: LocalizedString, _ direction: FeedbackDirection?) -> some View {
        Button {
            guard let direction else {
                // "Doesn't match" alone is not a direction — it opens the two that are.
                showingDirections = true
                return
            }
            env.recordDerivedFeedback(metricId: metricId, value: value, direction: direction)
            showingDirections = false
            expanded = false
        } label: {
            Text(title, language: env.language)
                .font(BadanFont.caption)
                .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }

    private func label(for direction: FeedbackDirection) -> LocalizedString {
        switch direction {
        case .matches: return FeedbackCopy.matches
        case .under: return FeedbackCopy.feltBetter
        case .over: return FeedbackCopy.feltWorse
        }
    }

    private var current: DerivedFeedback? {
        try? env.feedback.feedbackForPeriod(metricId: metricId, periodKey: value.periodKey,
                                            algorithmId: value.algorithmId)
    }

    private var remainingBeforeAdjustment: (have: Int, need: Int)? {
        let have = (try? env.feedback.feedback(metricId: metricId,
                                               algorithmId: value.algorithmId).count) ?? 0
        return Self.adjustmentProgress(metricId: metricId, have: have,
                                       spec: .defaultShared,
                                       calibrationEnabled: env.profile.calibrationEnabled)
    }

    /// "N of M before BADAN adjusts anything", or `nil` when there is nothing to count down TO.
    ///
    /// Pure and static so a test can hold it to `CalibrationConsumers` alongside the paragraph
    /// above it: a counter that fills up toward an adjustment no engine performs is the same false
    /// promise as the sentence, just told in numbers, and it was the more convincing half of it —
    /// "10 of 10" reads as a thing having happened.
    static func adjustmentProgress(metricId: String, have: Int, spec: CalibrationSpec,
                                   calibrationEnabled: Bool) -> (have: Int, need: Int)? {
        guard spec.isLoaded, calibrationEnabled,
              CalibrationConsumers.adjustsFutureValues(of: metricId),
              have < spec.minFeedbackEvents else { return nil }
        return (have, spec.minFeedbackEvents)
    }
}
