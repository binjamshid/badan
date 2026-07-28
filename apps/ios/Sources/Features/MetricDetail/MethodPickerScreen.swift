import SwiftUI

enum MethodPickerCopy {
    static let title = LocalizedString(en: "Calculation method", ar: "طريقة الحساب")
    static let current = LocalizedString(en: "Current", ar: "الحالية")
    static let standard = LocalizedString(en: "Standard", ar: "القياسية")
    static let todaysValue = LocalizedString(en: "Today under this method", ar: "اليوم بهذه الطريقة")
    static let noValue = LocalizedString(en: "No value today", ar: "لا قيمة اليوم")

    /// The wellness-safe warning. Describes, never instructs; no "recommended", no "best", no "more
    /// accurate", no second-person imperative.
    static let warning = LocalizedString(
        en: "These methods weigh your inputs differently, so they can give different numbers for "
            + "the same day. None of them is validated — BADAN's constants are still provisional, "
            + "and this is a choice about which reading you find useful, not which one is correct. "
            + "Readings already computed keep the method that produced them.",
        ar: "توازن هذه الطرق مدخلاتك بشكل مختلف، لذا قد تعطي أرقاماً مختلفة لليوم نفسه. لا شيء منها "
            + "مُتحقَّق منه — ما تزال ثوابت بادن أولية، وهذا اختيار لأي قراءة تجدها مفيدة، لا أيّها "
            + "صحيحة. تحتفظ القراءات المحسوبة سابقاً بالطريقة التي أنتجتها.")

    static let goingForward = LocalizedString(
        en: "Switching takes effect from your next calculation. Nothing already stored changes.",
        ar: "يسري التبديل من الحساب التالي. لا يتغيّر شيء مخزّن بالفعل.")

    static let withdrawnNote = LocalizedString(
        en: "The method you had chosen is no longer available in this version, so the standard "
            + "method is being used.",
        ar: "الطريقة التي اخترتها لم تعد متاحة في هذه النسخة، لذا تُستخدم الطريقة القياسية.")
}

/// D-35 — pick the calculation method for a derived metric, with each candidate's actual number on
/// the user's own data.
///
/// The preview is what makes this choice fact-based. Three separately published, independently
/// validated methods for readiness do not exist to be cited — BADAN's own `paramNotes` say the
/// current weights are its own launch guesses — so what is offered instead is a set of weighting
/// variants whose behaviour is stateable and whose numbers the user can compare directly. None is
/// labelled recommended, best, or more accurate, because none of them is any of those things.
///
/// **The preview cannot write.** It calls `ReadinessEngine.composite` /
/// `SleepIntelligenceEngine.score`, which are static functions of samples and params holding no
/// repository — so there is nothing here to append through. That is a structural guarantee, not a
/// convention, and `testComputingEveryCandidateWritesNoDerivedRows` is what keeps it one.
struct MethodPickerScreen: View {
    @Environment(AppEnvironment.self) private var env
    let metricId: String
    let contractDefault: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BadanSpace.space5) {
                if resolution.withdrawnChoice != nil {
                    BadanCard {
                        LText(MethodPickerCopy.withdrawnNote)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(spacing: BadanSpace.space3) {
                    ForEach(methods, id: \.algorithmId) { method in
                        methodCard(method)
                    }
                }

                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    LText(MethodPickerCopy.warning)
                    LText(MethodPickerCopy.goingForward)
                }
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(BadanSpace.space4)
        }
        .background(BadanColor.background.ignoresSafeArea())
        .navigationTitle(env.s(MethodPickerCopy.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func methodCard(_ method: AlgorithmDefinition) -> some View {
        let isActive = method.algorithmId == resolution.algorithmId
        return Button {
            env.update { profile in
                // Storing the default explicitly would be indistinguishable from a stale choice
                // once that id is the default again; removing the key is the honest "no preference".
                if method.algorithmId == contractDefault { profile.methodChoices[metricId] = nil }
                else { profile.methodChoices[metricId] = method.algorithmId }
            }
        } label: {
            BadanCard {
                VStack(alignment: .leading, spacing: BadanSpace.space2) {
                    HStack(spacing: BadanSpace.space2) {
                        Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(isActive ? BadanColor.primary : BadanColor.separator)
                            .accessibilityHidden(true)
                        Text(name(for: method), language: env.language)
                            .font(BadanFont.body)
                            .foregroundStyle(BadanColor.textPrimary)
                        Spacer(minLength: BadanSpace.space2)
                        // Marked as CURRENT, never as best. The distinction is the whole point.
                        if isActive {
                            Text(MethodPickerCopy.current, language: env.language)
                                .font(BadanFont.chip)
                                .foregroundStyle(BadanColor.primary)
                        }
                    }
                    if let description = AnatomyStrings.algorithmGlossary[method.algorithmId] {
                        LText(description)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: BadanSpace.space2) {
                        Text(MethodPickerCopy.todaysValue, language: env.language)
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                        Spacer(minLength: BadanSpace.space2)
                        Text(previewText(for: method))
                            .font(BadanFont.numeralM)
                            .foregroundStyle(BadanColor.textPrimary)
                    }
                    if env.depth.showsPowerDetail {
                        Text("\(method.algorithmId)@\(method.semver)")
                            .font(BadanFont.caption.monospaced())
                            .foregroundStyle(BadanColor.textSecondary)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    /// A human-readable name. Derived from the id's suffix rather than a second hand-kept table:
    /// the glossary line under it carries the meaning, and a second table would be one more thing
    /// to forget when a variant is added.
    private func name(for method: AlgorithmDefinition) -> LocalizedString {
        guard method.algorithmId != contractDefault else { return MethodPickerCopy.standard }
        switch method.algorithmId {
        case "composite.readiness_score_equal":
            return LocalizedString(en: "Balanced", ar: "متوازنة")
        case "composite.readiness_score_sleep_led":
            return LocalizedString(en: "Sleep-led", ar: "بقيادة النوم")
        case "composite.readiness_score_autonomic":
            return LocalizedString(en: "Heart-only", ar: "القلب فقط")
        case "sleep.score_duration_led":
            return LocalizedString(en: "Duration-led", ar: "بقيادة المدة")
        case "sleep.score_regularity_led":
            return LocalizedString(en: "Regularity-led", ar: "بقيادة الانتظام")
        case "sleep.score_continuity_led":
            return LocalizedString(en: "Continuity-led", ar: "بقيادة الاستمرارية")
        default:
            return LocalizedString(en: method.algorithmId, ar: method.algorithmId)
        }
    }

    private func previewText(for method: AlgorithmDefinition) -> String {
        guard let value = preview[method.algorithmId] else { return env.s(MethodPickerCopy.noValue) }
        return env.format.integer(Int(value.rounded()))
    }

    // MARK: - Data

    private var methods: [AlgorithmDefinition] {
        MethodResolver.selectableMethods(for: metricId, registry: .shared)
    }

    private var resolution: MethodResolver.Resolution {
        MethodResolver.resolve(metricId: metricId, contractDefault: contractDefault,
                               profile: env.profile, registry: .shared)
    }

    /// Today's number under each candidate, computed from ONE read of the day's inputs.
    ///
    /// Readiness only for now: the sleep composite needs a full night assembly, and building one
    /// here would mean a second assembly path beside `SleepIntelligenceEngine`'s — the sort of
    /// duplicate that drifts. Sleep methods still show their description and can still be chosen;
    /// they simply show no preview number until that assembly is exposed. Saying "no value" is
    /// honest; inventing one from a partial assembly would not be.
    private var preview: [String: Double] {
        guard metricId == MetricID.readinessScore,
              let samples = try? env.readiness.inputSamplesForPreview(asOf: env.now()) else { return [:] }
        var out: [String: Double] = [:]
        for method in methods {
            let spec = ReadinessSpec.load(from: .shared, contractId: method.algorithmId)
            guard spec.isLoaded,
                  let computation = ReadinessEngine.composite(present: samples, params: spec.params)
            else { continue }
            out[method.algorithmId] = computation.score
        }
        return out
    }
}
