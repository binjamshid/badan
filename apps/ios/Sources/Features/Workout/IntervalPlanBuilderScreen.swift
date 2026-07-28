import SwiftUI

/// EPIC-42: where a person builds a structured session before starting it (research doc §"Power
/// setup — work/rest sequence", and the HIIT row's "Quick Start HIIT / work-rest profile").
///
/// Four numbers, not a step editor. "8 × 400m with 90s recovery" and "20 minutes of 30-on/30-off"
/// both reduce to warm-up / work / recovery / rounds / cool-down, which is what `IntervalPlan`
/// models — so this screen is five steppers and a live preview of the resulting timeline, rather
/// than a general-purpose sequence builder nobody asked for.
struct IntervalPlanBuilderScreen: View {
    @Environment(AppEnvironment.self) private var env

    /// Called with the finished plan. The caller starts the session — this screen never does, so it
    /// stays a pure editor with no lifecycle responsibility.
    let onStart: (IntervalPlan) -> Void

    @State private var warmUpMinutes = 3
    @State private var workSeconds = 30
    @State private var recoverySeconds = 30
    @State private var rounds = 8
    @State private var coolDownMinutes = 3

    private var plan: IntervalPlan {
        IntervalPlan.hiit(workSeconds: workSeconds, recoverySeconds: recoverySeconds, rounds: rounds,
                          warmUpSeconds: warmUpMinutes * 60, coolDownSeconds: coolDownMinutes * 60)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                LText(IntervalStrings.builderIntro)
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                BadanCard {
                    VStack(spacing: BadanSpace.space3) {
                        stepper(IntervalStrings.warmUpMinutes, value: $warmUpMinutes, range: 0...30, unit: .minutes)
                        Divider()
                        stepper(IntervalStrings.workSecondsLabel, value: $workSeconds, range: 5...600, step: 5, unit: .seconds)
                        stepper(IntervalStrings.recoverySecondsLabel, value: $recoverySeconds, range: 0...600, step: 5, unit: .seconds)
                        stepper(IntervalStrings.roundsLabel, value: $rounds, range: 1...50, unit: .none)
                        Divider()
                        stepper(IntervalStrings.coolDownMinutes, value: $coolDownMinutes, range: 0...30, unit: .minutes)
                    }
                }

                previewSection

                Button {
                    onStart(plan)
                } label: {
                    LText(IntervalStrings.startSession)
                        .font(BadanFont.body.weight(.semibold))
                        .foregroundStyle(BadanColor.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: BadanSpace.touchMin)
                        .background(BadanColor.primary, in: RoundedRectangle(cornerRadius: BadanRadius.control))
                }
                .buttonStyle(.plain)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background)
        .navigationTitle(env.s(IntervalStrings.builderTitle))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Shows the real laid-out timeline, not a restatement of the inputs. The round count and the
    /// total are computed from `IntervalPlan.steps` — the same property the engine runs — so what
    /// the person previews is exactly what will run, including the deliberately-dropped final
    /// recovery.
    private var previewSection: some View {
        let steps = plan.steps
        return VStack(alignment: .leading, spacing: BadanSpace.space2) {
            SectionHeader(env.s(IntervalStrings.previewHeader))
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    Text(IntervalStrings.previewTotal
                        .filling(["duration": WorkoutTimeFormat.string(
                            seconds: TimeInterval(plan.totalSeconds),
                            language: env.language, arabicDigits: env.profile.arabicDigits),
                                  "segments": env.format.integer(steps.count)])
                        .resolved(env.language))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textPrimary)
                    Text(IntervalStrings.previewRounds
                        .filling(["rounds": env.format.integer(plan.workRoundCount)])
                        .resolved(env.language))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                    if recoverySeconds > 0 && rounds > 1 {
                        LText(IntervalStrings.lastRoundNote)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private enum StepperUnit { case minutes, seconds, none }

    private func stepper(_ label: LocalizedString, value: Binding<Int>, range: ClosedRange<Int>,
                         step: Int = 1, unit: StepperUnit) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                LText(label)
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                Text(valueLabel(value.wrappedValue, unit: unit))
                    .font(BadanFont.body.monospacedDigit())
                    .foregroundStyle(BadanColor.textSecondary)
            }
        }
    }

    private func valueLabel(_ value: Int, unit: StepperUnit) -> String {
        switch unit {
        case .minutes: return "\(env.format.integer(value)) \(env.s(IntervalStrings.minutesShort))"
        case .seconds: return "\(env.format.integer(value)) \(env.s(IntervalStrings.secondsShort))"
        case .none: return env.format.integer(value)
        }
    }
}

// MARK: - Live segment card

/// The interval screen's core (research doc §"Interval screen": current segment, next segment, time
/// remaining, target range, adherence status).
///
/// Adherence is deliberately absent. The research asks for "Below target range"-style wording, but
/// that needs a pace or power stream to compare against, and this build has neither on the live
/// path (no GPS by design, no power meter). Rendering an adherence verdict with nothing behind it
/// would be a fabricated assessment — so this shows the structure and the clock, honestly, and says
/// nothing about how well it is being followed.
struct IntervalLiveCard: View {
    @Environment(AppEnvironment.self) private var env
    let position: IntervalPosition
    let plan: IntervalPlan

    var body: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                HStack(alignment: .firstTextBaseline, spacing: BadanSpace.space2) {
                    Text(env.s(position.step.kind.displayName))
                        .font(BadanFont.sectionTitle)
                        .foregroundStyle(BadanColor.textPrimary)
                    Spacer(minLength: BadanSpace.space2)
                    if let round = position.workRound {
                        Text(IntervalStrings.roundOf
                            .filling(["n": env.format.integer(round),
                                      "total": env.format.integer(plan.workRoundCount)])
                            .resolved(env.language))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                }

                Text(WorkoutTimeFormat.string(seconds: TimeInterval(position.remainingInStep),
                                              language: env.language, arabicDigits: env.profile.arabicDigits))
                    .font(BadanFont.heroNumeral)
                    .foregroundStyle(BadanColor.textPrimary)
                    .accessibilityLabel(Text(env.s(IntervalStrings.remainingLabel)))

                ProgressView(value: position.fractionComplete)
                    .tint(BadanColor.primary)
                    .accessibilityHidden(true)

                if let next = position.nextStep {
                    Text(IntervalStrings.nextUp
                        .filling(["segment": env.s(next.kind.displayName),
                                  "duration": WorkoutTimeFormat.string(
                                    seconds: TimeInterval(next.durationSeconds),
                                    language: env.language, arabicDigits: env.profile.arabicDigits)])
                        .resolved(env.language))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                } else {
                    LText(IntervalStrings.lastSegment)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }

                if let target = position.step.targetNote, !target.isEmpty {
                    Text(target)
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                }
            }
        }
    }
}

// MARK: - Strings

enum IntervalStrings {
    static let builderTitle = LocalizedString(en: "Intervals", ar: "الفترات")
    static let builderIntro = LocalizedString(
        en: "Set up a work and recovery pattern. BADAN keeps the time and shows you where you are — it doesn't judge how you're doing.",
        ar: "اضبط نمط الجهد والاستعادة. يتابع بدن الوقت ويوضح أين أنت — دون أن يحكم على أدائك.")
    static let warmUpMinutes = LocalizedString(en: "Warm-up", ar: "الإحماء")
    static let workSecondsLabel = LocalizedString(en: "Work", ar: "الجهد")
    static let recoverySecondsLabel = LocalizedString(en: "Recovery", ar: "الاستعادة")
    static let roundsLabel = LocalizedString(en: "Rounds", ar: "الجولات")
    static let coolDownMinutes = LocalizedString(en: "Cool-down", ar: "التهدئة")
    static let minutesShort = LocalizedString(en: "min", ar: "د")
    static let secondsShort = LocalizedString(en: "sec", ar: "ث")

    static let previewHeader = LocalizedString(en: "This session", ar: "هذه الجلسة")
    static let previewTotal = LocalizedString(en: "{duration} across {segments} segments",
                                              ar: "{duration} عبر {segments} مقاطع")
    static let previewRounds = LocalizedString(en: "{rounds} work rounds", ar: "{rounds} جولات جهد")
    static let lastRoundNote = LocalizedString(
        en: "The last round goes straight to the cool-down — no recovery after it.",
        ar: "الجولة الأخيرة تنتقل مباشرة إلى التهدئة — دون استعادة بعدها.")
    static let startSession = LocalizedString(en: "Start", ar: "ابدأ")

    static let roundOf = LocalizedString(en: "Round {n} of {total}", ar: "الجولة {n} من {total}")
    static let remainingLabel = LocalizedString(en: "Time remaining in this segment",
                                                ar: "الوقت المتبقي في هذا المقطع")
    static let nextUp = LocalizedString(en: "Next: {segment} · {duration}", ar: "التالي: {segment} · {duration}")
    static let lastSegment = LocalizedString(en: "Last segment", ar: "المقطع الأخير")
    static let openBuilder = LocalizedString(en: "Intervals / HIIT", ar: "فترات / تمرين متقطع")
    static let planFinished = LocalizedString(
        en: "Your plan is done. The session keeps recording until you end it.",
        ar: "انتهت خطتك. تستمر الجلسة في التسجيل حتى تنهيها.")
}
