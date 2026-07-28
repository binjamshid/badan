import SwiftUI

/// Strings only the anatomy sheet needs — the calm, honest "why is it saying that" vocabulary.
/// Non-private so `MethodChoiceTests` can assert that every method BADAN offers has copy behind
/// it. `algorithmGlossary` renders nothing for an unknown id — correct for an unpublished
/// algorithm, wrong for one the user is being asked to choose.
enum AnatomyStrings {
    static let baseline = LocalizedString(en: "Your baseline", ar: "خط الأساس")
    static let center = LocalizedString(en: "Center (median)", ar: "المركز (الوسيط)")
    // Named locally rather than reusing `Loc.personalRange` so the anatomy sheet can name the
    // method (median ± scaled deviation) without changing that string's wording anywhere else
    // it might ship in future.
    static let typicalRange = LocalizedString(en: "Typical range (median ± scaled deviation)",
                                               ar: "النطاق المعتاد (الوسيط ± انحراف مُعاير)")
    static let bandFormula = LocalizedString(en: "Center ± {k} × typical variation",
                                              ar: "المركز ± {k} × الانحراف المعتاد")
    static let daysUsed = LocalizedString(en: "Days used", ar: "الأيام المستخدمة")
    static let daysUsedOf = LocalizedString(en: "of", ar: "من")
    static let window = LocalizedString(en: "Window", ar: "النافذة الزمنية")
    static let computed = LocalizedString(en: "Last computed", ar: "آخر تحديث")
    static let confidence = LocalizedString(en: "Confidence", ar: "درجة الثقة")
    static let confidenceHigh = LocalizedString(en: "High", ar: "عالية")
    static let confidenceModerate = LocalizedString(en: "Moderate", ar: "متوسطة")
    static let confidenceLower = LocalizedString(en: "Lower", ar: "منخفضة")
    /// The one sentence that keeps the caveat from being read as "the number was adjusted". Sits
    /// under the caveat in the method card, next to the confidence it explains.
    static let contextValueUnchanged = LocalizedString(
        en: "The value itself is unchanged — only how confidently it’s read.",
        ar: "القيمة نفسها لم تتغيّر — ما تغيّر هو درجة الثقة في قراءتها فقط.")
    static let dedupHeading = LocalizedString(en: "Duplicate handling", ar: "معالجة التكرار")
    static let oneKept = LocalizedString(en: "One source kept, one suppressed.",
                                         ar: "مصدر واحد محتفظ به، وآخر مستبعد.")
    static let kept = LocalizedString(en: "Kept", ar: "المحتفظ به")
    // Repeats the same "nothing is deleted" reassurance `SourcesPriorityNote` gives on the
    // Sources screen, but placed directly next to the pill it actually explains here.
    static let reversibleNote = LocalizedString(en: "Nothing is deleted — this can be reversed.",
                                                 ar: "لا يُحذف شيء — يمكن التراجع عن هذا.")
    static let alreadyReversed = LocalizedString(en: "Already reversed", ar: "تمت الاستعادة بالفعل")
    static let overlapDetail = LocalizedString(en: "{pct}% overlap", ar: "تداخل بنسبة {pct}٪")
    static let learnDedup = LocalizedString(en: "Learn how duplicates are settled",
                                             ar: "تعرّف على كيفية تسوية التكرارات")
    static let straightFromRecords = LocalizedString(
        en: "This reads straight from your records — no extra calculation.",
        ar: "تُقرأ هذه القيمة مباشرة من سجلاتك — دون أي حساب إضافي.")
    // Distinct from `straightFromRecords`: a *derived* metric whose latest value simply isn't
    // linked to a manifest yet genuinely did involve a calculation, so it must not claim
    // otherwise (OPT-046).
    static let calculationUnavailable = LocalizedString(
        en: "This is a calculated value — the specific records behind this number aren't linked yet.",
        ar: "هذه قيمة محسوبة — السجلات المحددة التي تقف خلف هذا الرقم غير مرتبطة بعد.")
    static let noBaselineYet = LocalizedString(
        en: "Not enough history yet to draw a typical range.",
        ar: "لا يوجد سجل كافٍ بعد لرسم نطاق معتاد.")
    static let contributions = LocalizedString(en: "What went into this", ar: "ما الذي دخل في هذا")
    static let contributionShare = LocalizedString(en: "{pct}% of the score", ar: "{pct}٪ من النتيجة")
    static let formulaHeading = LocalizedString(en: "The formula", ar: "المعادلة")
    static let formulaPublishedNote = LocalizedString(
        en: "Computed on your device. This formula is published.",
        ar: "محسوبة على جهازك. هذه المعادلة منشورة.")

    /// Plain-language description of each frozen algorithm id BaselineEngine actually emits
    /// (see `BaselineEngine.swift`), keyed by the id portion before "@version". Unknown ids
    /// simply show no extra line rather than a guess.
    static let algorithmGlossary: [String: LocalizedString] = [
        "baseline.rolling_median_mad": LocalizedString(
            en: "Uses your typical value and how much it usually varies, ignoring occasional outliers.",
            ar: "تستخدم قيمتك المعتادة ومقدار تغيّرها عادة، متجاهلةً القيم الشاذة العارضة."),
        "composite.sleep_efficiency": LocalizedString(
            en: "Time asleep divided by time in bed, as a percentage.",
            ar: "زمن النوم مقسوماً على زمن البقاء في الفراش، كنسبة مئوية."),
        "composite.readiness_score": LocalizedString(
            en: "Combines how your sleep and resting heart rate compare to your own baselines.",
            ar: "يجمع بين مقارنة نومك ومعدل نبضك أثناء الراحة بخط أساسك الشخصي."),
        // D-35 method variants. Each says what the WEIGHTING does, in the user's terms — never
        // that it is better, more accurate or recommended, because none of them is validated.
        "composite.readiness_score_equal": LocalizedString(
            en: "Weighs every measure it has equally, so no single one can carry the score.",
            ar: "يوازن بين كل المقاييس المتاحة بالتساوي، فلا يحمل مقياسٌ واحد النتيجة وحده."),
        "composite.readiness_score_sleep_led": LocalizedString(
            en: "Weighs how you slept most heavily; your heart measures adjust around it.",
            ar: "يعطي وزناً أكبر لكيفية نومك؛ وتعدّل مقاييس قلبك حوله."),
        "composite.readiness_score_autonomic": LocalizedString(
            en: "Uses only your heart-rate variability and resting heart rate. Sleep is not included.",
            ar: "يستخدم تغيّر نبضك ومعدل نبضك أثناء الراحة فقط. النوم غير مُدرج."),
        "sleep.score": LocalizedString(
            en: "Combines how long you slept against your own need, how regular your timing was, and how unbroken the night stayed.",
            ar: "يجمع بين مدة نومك مقارنةً بحاجتك، وانتظام توقيتك، ومدى استمرارية الليلة."),
        "sleep.score_duration_led": LocalizedString(
            en: "Weighs how much you slept against your own need most heavily.",
            ar: "يعطي أكبر وزن لمقدار نومك مقارنةً بحاجتك."),
        "sleep.score_regularity_led": LocalizedString(
            en: "Weighs how regular your sleep timing was most heavily.",
            ar: "يعطي أكبر وزن لانتظام توقيت نومك."),
        "sleep.score_continuity_led": LocalizedString(
            en: "Weighs how unbroken the night stayed most heavily.",
            ar: "يعطي أكبر وزن لمدى استمرارية الليلة دون انقطاع."),
    ]

    /// Plain-language description of a reconciliation rule id, journaled verbatim on every
    /// dedup decision (`ReconciliationDecision.rule`). Only the one rule BADAN ships
    /// (`DedupLite.ruleId`) is listed; unknown ids simply show no extra line.
    static let ruleGlossary: [String: LocalizedString] = [
        "sleep.session_overlap.v1": LocalizedString(
            en: "Two sleep sessions overlapped heavily, so the higher-priority source's reading was kept.",
            ar: "تداخلت جلستا نوم بشكل كبير، فتم الاحتفاظ بقراءة المصدر الأعلى أولوية."),
    ]
}

/// One contribution-bar row: which input, its formatted value, its share of the score, and the bar
/// fill fraction (its weight relative to the largest contributor). Pure value type so the property
/// that matters — bars read straight from the stored manifest weights, and their shares sum to 1 — is
/// unit-tested without a view (`AnatomyContributions.rows`).
struct AnatomyContribution: Hashable {
    let metricId: String
    let value: Double
    let weight: Double
    /// weight ÷ Σweight, 0…1 — the share text ("50% of the score").
    let share: Double
    /// weight ÷ maxWeight, 0…1 — the bar fill, so the top contributor fills the track.
    let barFraction: Double
}

/// Builds the contribution breakdown from a `DerivedValue`'s `InputManifest`.
///
/// Only a manifest that is genuinely a *contribution* breakdown qualifies: at least two DISTINCT
/// input metrics, each carrying a positive `weight`. Readiness stores exactly this — one input per
/// metric, `weight` = that input's additive points-out-of-100 contribution, so Σ(weights) is the
/// score and the bars are the score's anatomy (see `ReadinessEngine`'s manifest note). A per-zone
/// manifest (Effort), where every input shares one metric id, is deliberately rejected — a
/// metric-keyed bar there would just repeat one label — and falls through to the plain "Records used"
/// list instead. This is the gate that keeps the bars honest rather than forcing every manifest into
/// a shape it isn't.
enum AnatomyContributions {
    static func rows(from manifest: InputManifest) -> [AnatomyContribution]? {
        let weighted = manifest.inputs.compactMap { input -> (metricId: String, value: Double, weight: Double)? in
            guard let w = input.weight, w > 0 else { return nil }
            return (input.metricId, input.value, w)
        }
        guard weighted.count >= 2 else { return nil }
        guard Set(weighted.map(\.metricId)).count == weighted.count else { return nil }
        let total = weighted.reduce(0.0) { $0 + $1.weight }
        let maxWeight = weighted.map(\.weight).max() ?? 0
        guard total > 0, maxWeight > 0 else { return nil }
        return weighted
            .sorted { $0.weight > $1.weight }
            .map { AnatomyContribution(metricId: $0.metricId, value: $0.value, weight: $0.weight,
                                       share: $0.weight / total, barFraction: $0.weight / maxWeight) }
    }
}

/// A published score formula plus its plain-language alt text. The `formula` carries math notation
/// (Σ, ×, ÷) for sighted users; `altText` is what VoiceOver reads instead, because a screen reader
/// announcing "Sigma" or "middle dot" is noise, not comprehension (plan §16: "formula alt-text").
struct AnatomyFormula: Hashable {
    let formula: LocalizedString
    let altText: LocalizedString
}

/// The published per-algorithm formulas surfaced in the anatomy sheet — the in-app half of "every
/// score ships with a published formula (in-app AND `docs/algorithms/<x>.md`)". Keyed by the raw
/// `algorithmId` (version-independent); an algorithm with no published formula simply shows no
/// formula card rather than a guess. These strings must stay in step with `docs/algorithms/*.md`.
enum AnatomyFormulas {
    static let byAlgorithmId: [String: AnatomyFormula] = [
        "composite.readiness_score": AnatomyFormula(
            formula: LocalizedString(
                en: "Readiness = Σ (weightᵢ × sub-scoreᵢ), over the inputs present",
                ar: "الجاهزية = Σ (الوزنᵢ × النتيجة-الفرعيةᵢ)، للمدخلات المتوفرة"),
            altText: LocalizedString(
                en: "Readiness is a weighted average of how your HRV, resting heart rate, respiratory rate and sleep performance compare to your own baselines. Each input's weight is renormalized over whatever was recorded, so a missing input redistributes its weight rather than being filled in.",
                ar: "الجاهزية متوسط مرجّح لمدى مقارنة تغيّر نبضك ومعدل نبضك أثناء الراحة ومعدل تنفسك وأداء نومك بخط أساسك الشخصي. يُعاد توزيع وزن كل مدخل على ما تم تسجيله فعلاً، فالمدخل الغائب يُعاد توزيع وزنه بدل تعويضه.")),
        // D-35: every variant is Class A — the SAME computation with different constants — so each
        // shares its default's published formula. Listing them explicitly rather than falling back
        // by prefix keeps `AnatomyFormulas` a closed map, so adding a contract entry without copy
        // still shows nothing rather than the wrong thing.
        "composite.readiness_score_equal": AnatomyFormula(
            formula: LocalizedString(
                en: "Readiness = Σ (weightᵢ × sub-scoreᵢ), over the inputs present",
                ar: "الجاهزية = Σ (الوزنᵢ × النتيجة-الفرعيةᵢ)، للمدخلات المتوفرة"),
            altText: LocalizedString(
                en: "The same weighted average as the standard method, with every input given equal weight.",
                ar: "المتوسط المرجّح نفسه كالطريقة القياسية، مع إعطاء كل مدخل وزناً متساوياً.")),
        "composite.readiness_score_sleep_led": AnatomyFormula(
            formula: LocalizedString(
                en: "Readiness = Σ (weightᵢ × sub-scoreᵢ), over the inputs present",
                ar: "الجاهزية = Σ (الوزنᵢ × النتيجة-الفرعيةᵢ)، للمدخلات المتوفرة"),
            altText: LocalizedString(
                en: "The same weighted average as the standard method, with sleep performance carrying most of the weight.",
                ar: "المتوسط المرجّح نفسه كالطريقة القياسية، مع حمل أداء النوم لمعظم الوزن.")),
        "composite.readiness_score_autonomic": AnatomyFormula(
            formula: LocalizedString(
                en: "Readiness = Σ (weightᵢ × sub-scoreᵢ), over HRV and resting heart rate only",
                ar: "الجاهزية = Σ (الوزنᵢ × النتيجة-الفرعيةᵢ)، لتغيّر النبض ومعدل النبض أثناء الراحة فقط"),
            altText: LocalizedString(
                en: "The same weighted average as the standard method, restricted to the two heart measures. Sleep and respiratory rate are given no weight at all.",
                ar: "المتوسط المرجّح نفسه كالطريقة القياسية، مقصوراً على مقياسي القلب. لا يُعطى النوم ولا معدل التنفس أي وزن.")),
        "sleep.score": AnatomyFormula(
            formula: LocalizedString(
                en: "Sleep score = (w₁ × duration) + (w₂ × regularity) + (w₃ × continuity)",
                ar: "درجة النوم = (و₁ × المدة) + (و₂ × الانتظام) + (و₃ × الاستمرارية)"),
            altText: LocalizedString(
                en: "A weighted blend of how long you slept against your own need, how regular your timing was, and how unbroken the night stayed. The weights are renormalized over whichever parts exist, and no score is produced at all without the duration part.",
                ar: "مزيج مرجّح من مدة نومك مقارنةً بحاجتك، وانتظام توقيتك، ومدى استمرارية الليلة. يُعاد توزيع الأوزان على الأجزاء المتوفرة، ولا تُنتج درجة دون جزء المدة.")),
        "sleep.score_duration_led": AnatomyFormula(
            formula: LocalizedString(
                en: "Sleep score = (w₁ × duration) + (w₂ × regularity) + (w₃ × continuity)",
                ar: "درجة النوم = (و₁ × المدة) + (و₂ × الانتظام) + (و₃ × الاستمرارية)"),
            altText: LocalizedString(
                en: "The same blend as the standard method, weighted hard toward how much you slept against your own need.",
                ar: "المزيج نفسه كالطريقة القياسية، مع ترجيح قوي لمقدار نومك مقارنةً بحاجتك.")),
        "sleep.score_regularity_led": AnatomyFormula(
            formula: LocalizedString(
                en: "Sleep score = (w₁ × duration) + (w₂ × regularity) + (w₃ × continuity)",
                ar: "درجة النوم = (و₁ × المدة) + (و₂ × الانتظام) + (و₃ × الاستمرارية)"),
            altText: LocalizedString(
                en: "The same blend as the standard method, weighted toward how regular your sleep timing was.",
                ar: "المزيج نفسه كالطريقة القياسية، مع ترجيح لانتظام توقيت نومك.")),
        "sleep.score_continuity_led": AnatomyFormula(
            formula: LocalizedString(
                en: "Sleep score = (w₁ × duration) + (w₂ × regularity) + (w₃ × continuity)",
                ar: "درجة النوم = (و₁ × المدة) + (و₂ × الانتظام) + (و₃ × الاستمرارية)"),
            altText: LocalizedString(
                en: "The same blend as the standard method, weighted toward how unbroken the night stayed.",
                ar: "المزيج نفسه كالطريقة القياسية، مع ترجيح لمدى استمرارية الليلة دون انقطاع.")),
        "composite.sleep_efficiency": AnatomyFormula(
            formula: LocalizedString(
                en: "Efficiency = time asleep ÷ time in bed × 100%",
                ar: "الكفاءة = زمن النوم ÷ زمن البقاء في الفراش × 100٪"),
            altText: LocalizedString(
                en: "Sleep efficiency is the time you were asleep divided by the time you were in bed, shown as a percentage.",
                ar: "كفاءة النوم هي زمن نومك مقسوماً على زمن بقائك في الفراش، معروضة كنسبة مئوية.")),
        "sleep.performance": AnatomyFormula(
            formula: LocalizedString(
                en: "Performance = time asleep ÷ your sleep need",
                ar: "الأداء = زمن النوم ÷ حاجتك للنوم"),
            altText: LocalizedString(
                en: "Sleep performance is how much you slept compared to what your body needed. The need is a personal range, so performance is shown as a range too when confidence is low.",
                ar: "أداء النوم هو مقدار نومك مقارنةً بما يحتاجه جسمك. الحاجة نطاق شخصي، لذا يُعرض الأداء كنطاق أيضاً حين تكون الثقة منخفضة.")),
        "sleep.need": AnatomyFormula(
            formula: LocalizedString(
                en: "Need = baseline + recent debt − nap credit + prior-day effort",
                ar: "الحاجة = خط الأساس + الدين الأخير − رصيد القيلولة + جهد اليوم السابق"),
            altText: LocalizedString(
                en: "Your sleep need starts from your personal baseline duration, adds a little for recent sleep debt and yesterday's effort, and subtracts credit for any naps. It is always shown as a range, never a fake-exact number of minutes.",
                ar: "تبدأ حاجتك للنوم من مدة خط أساسك الشخصي، وتضيف قليلاً للدين الأخير وجهد الأمس، وتطرح رصيداً لأي قيلولة. تُعرض دائماً كنطاق، لا كرقم دقيق زائف من الدقائق.")),
        // sleep.debt / .consistency / .disturbances transcribe the published formulas in
        // docs/algorithms/sleep.md verbatim in intent — the debt accumulator, the timing-regularity
        // blend, and the merge-then-count disturbance rule — so a surfaced sleep score is never
        // docs-yes / in-app-no (the transparency invariant; audit finding #3).
        "sleep.debt": AnatomyFormula(
            formula: LocalizedString(
                en: "Debt = Σ (needᵢ − actualᵢ) × 0.5^(ageᵢ ÷ half-life), bounded to [0, max]",
                ar: "الدين = مجموع (الحاجةᵢ − الفعليᵢ) × 0.5^(العمرᵢ ÷ نصف-العمر)، محصوراً بين 0 والحد الأقصى"),
            altText: LocalizedString(
                en: "Sleep debt adds up how far each recent night fell short of the sleep it needed, with older nights counting for less, and is held between zero and a capped maximum. A night you sleep more than you needed pays the debt back down.",
                ar: "يجمع دين النوم مقدار ما قصّرت به كل ليلة أخيرة عن حاجتها من النوم، مع احتساب الليالي الأقدم بوزن أقل، ويبقى محصوراً بين صفر وحدٍّ أقصى. الليلة التي تنام فيها أكثر من حاجتك تسدّد جزءاً من الدين.")),
        "sleep.consistency": AnatomyFormula(
            formula: LocalizedString(
                en: "Consistency = 100 × ( w × bed-regularity + (1 − w) × wake-regularity )",
                ar: "الاتساق = 100 × ( وزن × انتظام-موعد-النوم + (1 − وزن) × انتظام-موعد-الاستيقاظ )"),
            altText: LocalizedString(
                en: "Timing consistency scores how steady your bedtimes and wake times are over the last two weeks. The tighter the spread, the higher the score; bedtime and wake-time regularity are blended, and the spread is measured wrap-aware so times either side of midnight count as close.",
                ar: "يقيس اتساق التوقيت مدى ثبات مواعيد نومك واستيقاظك خلال الأسبوعين الماضيين. كلما ضاق التشتّت ارتفعت النتيجة؛ ويُمزج انتظام موعد النوم مع انتظام موعد الاستيقاظ، ويُقاس التشتّت بطريقة تراعي التفاف منتصف الليل فتُحتسب الأوقات على جانبي منتصف الليل متقاربة.")),
        "sleep.disturbances": AnatomyFormula(
            formula: LocalizedString(
                en: "Disturbances = count of awake episodes ≥ min length, after merging gaps < merge threshold",
                ar: "الاضطرابات = عدد فترات اليقظة التي طولها ≥ الحد الأدنى، بعد دمج الفجوات < حد الدمج"),
            altText: LocalizedString(
                en: "Overnight disturbances count the times you were awake long enough to notice. Brief awakenings closer together than a short gap are merged into one, and anything under a few minutes is dropped. A night with no sleep-stage data gets no count rather than a zero.",
                ar: "تُحصي الاضطرابات الليلية المرّات التي كنت فيها مستيقظاً مدةً كافية لتلاحظها. تُدمج فترات اليقظة القصيرة المتقاربة أقرب من فجوة قصيرة في فترة واحدة، ويُسقَط ما يقل عن بضع دقائق. والليلة التي لا تتوفّر لها بيانات مراحل النوم لا تحصل على عدد بدل أن تُحتسب صفراً.")),
        "effort.day": AnatomyFormula(
            formula: LocalizedString(
                en: "Effort = scale × (1 − e^(−k × weighted zone-minutes))",
                ar: "الجهد = المقياس × (1 − e^(−k × دقائق-النطاق-المرجّحة))"),
            altText: LocalizedString(
                en: "Effort rises with the minutes you spend in each heart-rate zone, weighted so harder zones count for more. The curve flattens as effort accumulates, so the same extra minutes add less near the top.",
                ar: "يرتفع الجهد مع الدقائق التي تقضيها في كل نطاق لمعدل ضربات القلب، مرجّحةً بحيث تُحتسب النطاقات الأصعب أكثر. ينبسط المنحنى كلما تراكم الجهد، فالدقائق الإضافية نفسها تضيف أقل قرب القمة.")),
        // effort.workout shares effort.day's published curve (asserted by a golden), so it maps to
        // the same formula rather than duplicating the string.
        "effort.workout": AnatomyFormula(
            formula: LocalizedString(
                en: "Effort = scale × (1 − e^(−k × weighted zone-minutes))",
                ar: "الجهد = المقياس × (1 − e^(−k × دقائق-النطاق-المرجّحة))"),
            altText: LocalizedString(
                en: "Workout effort uses the same curve as your daily effort, over the minutes in each heart-rate zone during the workout.",
                ar: "يستخدم جهد التمرين المنحنى نفسه لجهدك اليومي، على الدقائق في كل نطاق لمعدل ضربات القلب خلال التمرين.")),
        "baseline.rolling_median_mad": AnatomyFormula(
            formula: LocalizedString(
                en: "Band = median ± k × typical variation",
                ar: "النطاق = الوسيط ± k × التغيّر المعتاد"),
            altText: LocalizedString(
                en: "Your typical range is your personal median plus or minus a multiple of how much this value usually varies, ignoring occasional outliers.",
                ar: "نطاقك المعتاد هو وسيطك الشخصي زائداً أو ناقصاً مضاعفاً لمقدار تغيّر هذه القيمة عادةً، متجاهلاً القيم الشاذة العارضة.")),
    ]

    /// Resolve for a method token that may be a raw `algorithmId` or the composed `"algorithmId@semver"`.
    static func lookup(_ method: String) -> AnatomyFormula? {
        let id = method.split(separator: "@").first.map(String.init) ?? method
        return byAlgorithmId[id]
    }
}

/// Small in-place memoization so the sheet's formatted values (manifest rows, band text,
/// method string) are computed once per presentation instead of on every re-render — `data`
/// is immutable for the sheet's lifetime, so nothing cached here can go stale.
private final class AnatomyDisplayCache {
    var recordRows: [(label: String, value: String)]?
    var bandText: String?
    var methodStringComputed = false
    var methodString: String?
    var contributionsComputed = false
    var contributions: [AnatomyContribution]?
}

/// The "How this was worked out" sheet (VS-4). Presented modally in its own stack, it shows the
/// personal baseline (center, band, days used, provisional honesty), the records that fed the
/// latest computed value, the frozen algorithm version, and — for sleep time-asleep — the
/// reversible dedup decision that kept one source and suppressed a duplicate sibling.
struct MetricAnatomySheet: View {
    let data: MetricDetailData

    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var cache = AnatomyDisplayCache()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BadanSpace.space5) {
                    baselineCard
                    // Contribution bars first when the latest value has a contribution breakdown
                    // (Readiness): the "why this number" answer leads, the raw records follow.
                    if let contributions {
                        contributionsCard(contributions)
                    }
                    if let method = methodString, let formula = AnatomyFormulas.lookup(method) {
                        formulaCard(formula)
                    }
                    manifestOrFallbackCard
                    if let method = methodString {
                        methodCard(method)
                    }
                    if !data.recentDedup.isEmpty {
                        dedupCard
                    }
                }
                .padding(BadanSpace.space4)
            }
            .background(BadanColor.background)
            .navigationTitle(env.s(Loc.anatomyTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(env.s(Loc.close)) { dismiss() }
                }
            }
        }
        // Short-content metrics (e.g. a raw metric with just the baseline card) don't need a
        // full-height sheet; longer ones (manifest + dedup) can still expand to `.large`.
        .presentationDetents([.medium, .large])
    }

    // MARK: Baseline

    private var baselineCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.baseline)) {
                    if data.baseline?.provisional ?? true { ProvisionalBadge(language: env.language) }
                }
                if let b = data.baseline {
                    infoRow(label: env.s(AnatomyStrings.center),
                            value: env.format.full(metricId: data.def.metricId, canonicalValue: b.center))
                    infoRow(label: env.s(AnatomyStrings.typicalRange), value: bandText(b))
                    if let k = bandMultiplier(b) {
                        Text(env.s(AnatomyStrings.bandFormula.filling(["k": env.format.number(k, fraction: 2)])))
                            .font(BadanFont.caption)
                            .foregroundStyle(BadanColor.textSecondary)
                    }
                    infoRow(label: env.s(AnatomyStrings.daysUsed), value: daysUsedText(b))
                    infoRow(label: env.s(AnatomyStrings.window), value: windowRangeText(b), forceLTR: true)
                    infoRow(label: env.s(AnatomyStrings.computed), value: computedAtText(b.computedAt), forceLTR: true)
                } else {
                    Text(env.s(AnatomyStrings.noBaselineYet))
                        .font(BadanFont.body)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The multiplier the band was actually built with (`bandHigh = center + k × spread`),
    /// derived from the stored fields instead of duplicating BaselineEngine's own constant.
    private func bandMultiplier(_ b: Baseline) -> Double? {
        guard b.spread > 0 else { return nil }
        return (b.bandHigh - b.center) / b.spread
    }

    private func daysUsedText(_ b: Baseline) -> String {
        "\(env.format.integer(b.nPoints)) \(env.s(AnatomyStrings.daysUsedOf)) \(env.format.integer(b.windowDays))"
    }

    /// `Baseline` carries no timezone field of its own, so the window's day math needs a tz
    /// from elsewhere. The metric's own most-recent raw interval record is the closest honest
    /// source (its `tzId` is where this metric's data actually lives); a composite/derived-only
    /// metric has no raw interval to read at all, so this falls back to the device's current tz
    /// exactly like the rest of the app already does when no measurement tz is available
    /// (FIX-12).
    private var windowTz: String {
        data.intervals.last?.tzId ?? TimeZone.current.identifier
    }

    /// The window BaselineEngine queried for this baseline (`validFrom` minus `windowDays`).
    /// Not necessarily the exact span of contributing data points — a sparser baseline may
    /// only have data covering part of this window — but it's the honest bound the app can
    /// show today without a domain-model change to carry per-point dates. Uses `DayAttribution`
    /// day math in the measurement tz rather than `Calendar.current` (the device's current tz),
    /// so a baseline computed while the user was traveling doesn't shift its window boundary.
    private func windowRangeText(_ b: Baseline) -> String {
        let tz = windowTz
        let start = DayAttribution.addingDays(-b.windowDays, to: b.validFrom, tz: tz)
        return "\(dateOnlyText(start)) – \(dateOnlyText(b.validFrom))"
    }

    // MARK: Contribution bars (score anatomy)

    /// The contribution breakdown of the latest computed value, when its manifest is one (Readiness).
    /// Cached like the sheet's other derived values — `data` is immutable for the sheet's lifetime.
    private var contributions: [AnatomyContribution]? {
        if cache.contributionsComputed { return cache.contributions }
        let rows = data.manifest.flatMap(AnatomyContributions.rows)
        cache.contributions = rows
        cache.contributionsComputed = true
        return rows
    }

    /// Horizontal bars, one per input, each filled to its weight relative to the top contributor, with
    /// the input's own value and its share of the score. This is the transparent-vs-black-box promise
    /// made visual: the bars read straight off the stored manifest weights, so Σ(shares) = 1 by
    /// construction and the picture cannot disagree with the number it explains.
    private func contributionsCard(_ rows: [AnatomyContribution]) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.contributions))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    contributionRow(row)
                }
            }
        }
    }

    private func contributionRow(_ row: AnatomyContribution) -> some View {
        let def = env.registry.definitionOrFallback(row.metricId)
        let label = def.label(depth: env.depth, language: env.language)
        let valueText = env.format.full(metricId: row.metricId, canonicalValue: row.value)
        let shareText = env.s(AnatomyStrings.contributionShare.filling(
            ["pct": env.format.integer(Int((row.share * 100).rounded()))]))
        return VStack(alignment: .leading, spacing: BadanSpace.space1) {
            HStack(spacing: BadanSpace.space2) {
                Text(label)
                    .font(BadanFont.bodyCompact)
                    .foregroundStyle(BadanColor.textPrimary)
                Spacer(minLength: BadanSpace.space2)
                Text(valueText)
                    .font(BadanFont.bodyCompact.monospacedDigit())
                    .foregroundStyle(BadanColor.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BadanColor.surfaceElevated)
                    Capsule()
                        .fill(BadanColor.primary.opacity(0.7))
                        .frame(width: max(2, geo.size.width * row.barFraction))
                }
                // The bar grows from the leading edge in reading order (RTL mirrors normally).
            }
            .frame(height: 8)
            Text(shareText)
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
        }
        .frame(minHeight: BadanSpace.touchMin)
        // Read as one phrase per input rather than four disconnected stops.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(valueText), \(shareText)")
    }

    // MARK: Formula (published, with VoiceOver alt-text)

    /// The published formula for the value's algorithm. The math notation is shown for sighted users;
    /// VoiceOver reads the plain-language `altText` instead (a screen reader announcing "Sigma" is
    /// noise). The "computed on your device, formula published" note is the trust line plan §16 asks
    /// this surface to carry.
    private func formulaCard(_ formula: AnatomyFormula) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(AnatomyStrings.formulaHeading))
                // The formula is bilingual prose + math, so it follows the ambient direction (RTL in
                // Arabic); the math symbols fall into place under standard bidi. VoiceOver reads the
                // plain-language alt-text instead of the notation.
                Text(env.s(formula.formula))
                    .font(BadanFont.bodyCompact.monospaced())
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel(env.s(formula.altText))
                Text(env.s(AnatomyStrings.formulaPublishedNote))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Contributing records

    @ViewBuilder
    private var manifestOrFallbackCard: some View {
        if let manifest = data.manifest, !manifest.inputs.isEmpty {
            recordsCard(manifest)
        } else if data.def.kind == .derived {
            // A derived/composite metric with no manifest link is a data gap, not evidence
            // that "no calculation" happened — telling the user otherwise would be false.
            calculationUnavailableCard
        } else {
            straightFromRecordsCard
        }
    }

    private func recordsCard(_ manifest: InputManifest) -> some View {
        let rows = cachedRecordRows(manifest)
        return BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(Loc.contributingRecords))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    infoRow(label: row.label, value: row.value)
                }
            }
        }
    }

    private func cachedRecordRows(_ manifest: InputManifest) -> [(label: String, value: String)] {
        if let cached = cache.recordRows { return cached }
        let rows = manifest.inputs.map { input -> (label: String, value: String) in
            let inputDef = env.registry.definitionOrFallback(input.metricId)
            var value = env.format.full(metricId: input.metricId, canonicalValue: input.value)
            if let weight = input.weight {
                value += " (\(env.format.integer(Int((weight * 100).rounded())))%)"
            }
            return (label: inputDef.label(depth: env.depth, language: env.language), value: value)
        }
        cache.recordRows = rows
        return rows
    }

    private var straightFromRecordsCard: some View {
        BadanCard {
            Text(env.s(AnatomyStrings.straightFromRecords))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var calculationUnavailableCard: some View {
        BadanCard {
            Text(env.s(AnatomyStrings.calculationUnavailable))
                .font(BadanFont.body)
                .foregroundStyle(BadanColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Method

    private func methodCard(_ method: String) -> some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space2) {
                SectionHeader(env.s(Loc.algorithm))
                Text(method)
                    .font(BadanFont.bodyCompact.monospacedDigit())
                    .foregroundStyle(BadanColor.textPrimary)
                    .textSelection(.enabled)
                if let explanation = algorithmExplanation(method) {
                    Text(env.s(explanation))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let confidence = data.latestDerivedValue?.confidence {
                    infoRow(label: env.s(AnatomyStrings.confidence), value: confidenceLabel(confidence))
                }
                // EPIC-29 (plan §18). Placed directly under the confidence row because that is the
                // number a declared period actually moved: the engine capped this row's confidence
                // and left its value untouched. Saying so where the capped number is shown is the
                // difference between an unexplained "Lower" and an honest one.
                if !data.contextCaveats.isEmpty {
                    ContextCaveatNote(caveats: data.contextCaveats, language: env.language)
                    Text(env.s(AnatomyStrings.contextValueUnchanged))
                        .font(BadanFont.caption)
                        .foregroundStyle(BadanColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Looks up the plain-language explanation for an algorithm id, tolerating both the raw
    /// `algorithmId` and the composed `"algorithmId@semver"` form `methodString` can produce.
    private func algorithmExplanation(_ method: String) -> LocalizedString? {
        let id = method.split(separator: "@").first.map(String.init) ?? method
        return AnatomyStrings.algorithmGlossary[id]
    }

    /// A qualitative, wellness-safe reading of `DerivedValue.confidence` (0...1) — never a
    /// bare percentage framed as "accuracy", and never red/green.
    private func confidenceLabel(_ confidence: Double) -> String {
        let label: LocalizedString
        switch confidence {
        case ..<0.34: label = AnatomyStrings.confidenceLower
        case ..<0.67: label = AnatomyStrings.confidenceModerate
        default: label = AnatomyStrings.confidenceHigh
        }
        return env.s(label)
    }

    // MARK: Dedup (sleep time-asleep only)

    private var dedupCard: some View {
        BadanCard {
            VStack(alignment: .leading, spacing: BadanSpace.space3) {
                SectionHeader(env.s(AnatomyStrings.dedupHeading))
                Text(env.s(AnatomyStrings.oneKept))
                    .font(BadanFont.body)
                    .foregroundStyle(BadanColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(data.recentDedup.prefix(3)) { decision in
                    dedupRow(decision)
                }
                NavigationLink {
                    SourcesScreen()
                } label: {
                    HStack(spacing: BadanSpace.space1) {
                        Text(env.s(AnatomyStrings.learnDedup))
                            .font(BadanFont.link)
                        Image(systemName: "chevron.forward")
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(BadanColor.primary)
                }
                .frame(minHeight: BadanSpace.touchMin, alignment: .leading)
            }
        }
    }

    private func dedupRow(_ decision: ReconciliationDecision) -> some View {
        VStack(alignment: .leading, spacing: BadanSpace.space1) {
            // Stacked (not side-by-side) since each pill now names its source and can run long.
            VStack(alignment: .leading, spacing: BadanSpace.space1) {
                PillLabel(pillText(decision.detail["winner_source"], suffix: env.s(AnatomyStrings.kept)),
                          systemImage: "checkmark", tint: BadanColor.inBand)
                PillLabel(pillText(decision.detail["loser_source"], suffix: env.s(Loc.suppressedDuplicate)),
                          systemImage: "arrow.uturn.backward", tint: BadanColor.textSecondary)
            }
            if let explanation = AnatomyStrings.ruleGlossary[decision.rule] {
                Text(env.s(explanation))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(decisionDetailLine(decision))
                .font(BadanFont.caption)
                .foregroundStyle(BadanColor.textSecondary)
            if decision.isReversed {
                PillLabel(env.s(AnatomyStrings.alreadyReversed), systemImage: "arrow.uturn.backward.circle",
                          tint: BadanColor.textSecondary, filled: false)
            } else if decision.reversible {
                Text(env.s(AnatomyStrings.reversibleNote))
                    .font(BadanFont.caption)
                    .foregroundStyle(BadanColor.textSecondary)
            }
            Text("\(decision.rule) · \(decision.ruleVersion)")
                .font(BadanFont.caption.monospacedDigit())
                .foregroundStyle(BadanColor.textSecondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pillText(_ sourceId: String?, suffix: String) -> String {
        guard let sourceId, !sourceId.isEmpty else { return suffix }
        let name = data.sourceNames[sourceId] ?? sourceId
        return "\(name) — \(suffix)"
    }

    /// Overlap percentage and decision timestamp from `ReconciliationDecision.detail`/`decidedAt`
    /// — the fields the model carries specifically to explain a dedup decision, previously
    /// unread by this card.
    private func decisionDetailLine(_ decision: ReconciliationDecision) -> String {
        let when = decidedAtText(decision.decidedAt)
        guard let pctString = decision.detail["overlap_pct"], let pct = Double(pctString) else { return when }
        let pctText = env.s(AnatomyStrings.overlapDetail.filling(["pct": env.format.number(pct, fraction: 0)]))
        return "\(pctText) · \(when)"
    }

    // MARK: Helpers

    private func infoRow(label: String, value: String, forceLTR: Bool = false) -> some View {
        HStack(spacing: BadanSpace.space2) {
            Text(label)
                .font(BadanFont.bodyCompact)
                .foregroundStyle(BadanColor.textSecondary)
            Spacer(minLength: BadanSpace.space2)
            Group {
                if forceLTR {
                    // Dates/window bounds are technical, not prose — keep them left-to-right in
                    // both languages, matching `ProvenanceRow`'s timestamp treatment.
                    Text(value).environment(\.layoutDirection, .leftToRight)
                } else {
                    Text(value)
                }
            }
            .font(BadanFont.bodyCompact.monospacedDigit())
            .foregroundStyle(BadanColor.textPrimary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
        .frame(minHeight: BadanSpace.touchMin)
    }

    private func bandText(_ b: Baseline) -> String {
        if let cached = cache.bandText { return cached }
        let low = env.format.heroValue(metricId: data.def.metricId, canonicalValue: b.bandLow)
        let high = env.format.heroValue(metricId: data.def.metricId, canonicalValue: b.bandHigh)
        let text: String
        if let unit = env.format.unitLabel(metricId: data.def.metricId) {
            text = "\(low) – \(high) \(unit)"
        } else {
            text = "\(low) – \(high)"
        }
        cache.bandText = text
        return text
    }

    private var methodString: String? {
        if cache.methodStringComputed { return cache.methodString }
        let value: String?
        if let d = data.latestDerivedValue { value = "\(d.algorithmId)@\(d.algorithmVersion)" }
        else { value = data.baseline?.algorithmVersion }
        cache.methodString = value
        cache.methodStringComputed = true
        return value
    }

    // Cached once per type instead of allocating a fresh `DateFormatter` on every render,
    // matching the pattern already used by `ProvenanceRow`/`MetricDetailScreen`.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func decidedAtText(_ date: Date) -> String {
        Self.timestampFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.timestampFormatter.string(from: date)
    }

    private func computedAtText(_ date: Date) -> String {
        Self.timestampFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.timestampFormatter.string(from: date)
    }

    private func dateOnlyText(_ date: Date) -> String {
        Self.dateOnlyFormatter.locale = Locale(identifier: env.language.localeIdentifier)
        return Self.dateOnlyFormatter.string(from: date)
    }
}
