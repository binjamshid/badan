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
    static let whatThisDoes = LocalizedString(
        en: "BADAN uses this to adjust future values of this metric on this device. It is never "
            + "sent anywhere, and it never changes readings already calculated.",
        ar: "يستخدم بادن هذا لتعديل القيم المستقبلية لهذا المؤشر على هذا الجهاز. لا يُرسل إلى أي "
            + "مكان، ولا يغيّر القراءات المحسوبة سابقاً.")

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

                LText(FeedbackCopy.whatThisDoes)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Says how far off the threshold is, so ten taps that appear to do nothing read as
                // progress rather than as a broken control.
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
        let spec = CalibrationSpec.defaultShared
        guard spec.isLoaded, env.profile.calibrationEnabled else { return nil }
        let have = (try? env.feedback.feedback(metricId: metricId,
                                               algorithmId: value.algorithmId).count) ?? 0
        guard have < spec.minFeedbackEvents else { return nil }
        return (have, spec.minFeedbackEvents)
    }
}
