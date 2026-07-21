package net.albayyan.badan.features.metricdetail

import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.MetricId

/**
 * Compose-free presentation core for the anatomy sheet's contribution bars and confidence word, so
 * `ScoreAnatomyPresentationTest` asserts the arithmetic and the thresholds without loading the Compose
 * runtime (the same pure/UI split the engines use).
 */

/**
 * One row of the contribution bars: which input, its raw reading, its additive points, and its bar
 * length as a share of the LARGEST contribution (so the leading signal fills its row and the rest
 * scale against it). Sorted largest-first so the score's dominant driver reads at the top.
 */
internal data class ContributionRow(
    val metricId: String,
    val measuredValue: Double,
    val contribution: Double,
    val fractionOfMax: Float,
)

internal fun contributionRows(inputs: List<InputManifest.Input>): List<ContributionRow> {
    val present = inputs.filter { it.weight != null }
    if (present.isEmpty()) return emptyList()
    val maxAbs = present.maxOf { kotlin.math.abs(it.weight!!) }.coerceAtLeast(1e-9)
    return present
        .sortedByDescending { it.weight }
        .map { input ->
            ContributionRow(
                metricId = input.metricId,
                measuredValue = input.value,
                contribution = input.weight!!,
                fractionOfMax = (kotlin.math.abs(input.weight!!) / maxAbs).toFloat().coerceIn(0f, 1f),
            )
        }
}

/**
 * True when a Readiness manifest lacks the HRV anchor — the reduced-input variant the surface must
 * label distinctly (plan §18). Keyed off the manifest's own inputs rather than a stored flag, so it
 * is answerable straight from the lineage the sheet already holds.
 */
internal fun isReducedInputReadiness(inputs: List<InputManifest.Input>): Boolean =
    inputs.none { it.metricId == MetricId.hrv }

/**
 * A published score formula plus its plain-language alt text. [formula] carries math notation (Σ, ×, ÷)
 * for sighted users; [altText] is what TalkBack reads instead, because a screen reader announcing
 * "Sigma" or "middle dot" is noise, not comprehension. Mirror of iOS `AnatomyFormula`.
 */
data class AnatomyFormula(val formula: LocalizedString, val altText: LocalizedString)

/**
 * The published per-algorithm formulas surfaced in the anatomy sheet — the in-app half of "every score
 * ships with a published formula (in-app AND `docs/algorithms/<x>.md`)". Keyed by the raw `algorithmId`
 * (version-independent); an algorithm with no published formula simply shows no formula card rather than
 * a guess. These strings must stay in step with the per-metric `docs/algorithms` files and the iOS `AnatomyFormulas`.
 * A completeness test (`ScoreAnatomyPresentationTest`) asserts every surfaced score id resolves here, so
 * a future score without a formula fails rather than silently omitting the card (audit finding #3).
 */
object AnatomyFormulas {
    val byAlgorithmId: Map<String, AnatomyFormula> = mapOf(
        "composite.readiness_score" to AnatomyFormula(
            formula = LocalizedString(
                en = "Readiness = Σ (weightᵢ × sub-scoreᵢ), over the inputs present",
                ar = "الجاهزية = Σ (الوزنᵢ × النتيجة-الفرعيةᵢ)، للمدخلات المتوفرة",
            ),
            altText = LocalizedString(
                en = "Readiness is a weighted average of how your HRV, resting heart rate, respiratory rate and sleep performance compare to your own baselines. Each input's weight is renormalized over whatever was recorded, so a missing input redistributes its weight rather than being filled in.",
                ar = "الجاهزية متوسط مرجّح لمدى مقارنة تغيّر نبضك ومعدل نبضك أثناء الراحة ومعدل تنفسك وأداء نومك بخط أساسك الشخصي. يُعاد توزيع وزن كل مدخل على ما تم تسجيله فعلاً، فالمدخل الغائب يُعاد توزيع وزنه بدل تعويضه.",
            ),
        ),
        "composite.sleep_efficiency" to AnatomyFormula(
            formula = LocalizedString(
                en = "Efficiency = time asleep ÷ time in bed × 100%",
                ar = "الكفاءة = زمن النوم ÷ زمن البقاء في الفراش × 100٪",
            ),
            altText = LocalizedString(
                en = "Sleep efficiency is the time you were asleep divided by the time you were in bed, shown as a percentage.",
                ar = "كفاءة النوم هي زمن نومك مقسوماً على زمن بقائك في الفراش، معروضة كنسبة مئوية.",
            ),
        ),
        "sleep.performance" to AnatomyFormula(
            formula = LocalizedString(
                en = "Performance = time asleep ÷ your sleep need",
                ar = "الأداء = زمن النوم ÷ حاجتك للنوم",
            ),
            altText = LocalizedString(
                en = "Sleep performance is how much you slept compared to what your body needed. The need is a personal range, so performance is shown as a range too when confidence is low.",
                ar = "أداء النوم هو مقدار نومك مقارنةً بما يحتاجه جسمك. الحاجة نطاق شخصي، لذا يُعرض الأداء كنطاق أيضاً حين تكون الثقة منخفضة.",
            ),
        ),
        "sleep.need" to AnatomyFormula(
            formula = LocalizedString(
                en = "Need = baseline + recent debt − nap credit + prior-day effort",
                ar = "الحاجة = خط الأساس + الدين الأخير − رصيد القيلولة + جهد اليوم السابق",
            ),
            altText = LocalizedString(
                en = "Your sleep need starts from your personal baseline duration, adds a little for recent sleep debt and yesterday's effort, and subtracts credit for any naps. It is always shown as a range, never a fake-exact number of minutes.",
                ar = "تبدأ حاجتك للنوم من مدة خط أساسك الشخصي، وتضيف قليلاً للدين الأخير وجهد الأمس، وتطرح رصيداً لأي قيلولة. تُعرض دائماً كنطاق، لا كرقم دقيق زائف من الدقائق.",
            ),
        ),
        // sleep.debt / .consistency / .disturbances transcribe the published formulas in
        // docs/algorithms/sleep.md — the debt accumulator, the timing-regularity blend, and the
        // merge-then-count disturbance rule — so a surfaced sleep score is never docs-yes / in-app-no.
        "sleep.debt" to AnatomyFormula(
            formula = LocalizedString(
                en = "Debt = Σ (needᵢ − actualᵢ) × 0.5^(ageᵢ ÷ half-life), bounded to [0, max]",
                ar = "الدين = مجموع (الحاجةᵢ − الفعليᵢ) × 0.5^(العمرᵢ ÷ نصف-العمر)، محصوراً بين 0 والحد الأقصى",
            ),
            altText = LocalizedString(
                en = "Sleep debt adds up how far each recent night fell short of the sleep it needed, with older nights counting for less, and is held between zero and a capped maximum. A night you sleep more than you needed pays the debt back down.",
                ar = "يجمع دين النوم مقدار ما قصّرت به كل ليلة أخيرة عن حاجتها من النوم، مع احتساب الليالي الأقدم بوزن أقل، ويبقى محصوراً بين صفر وحدٍّ أقصى. الليلة التي تنام فيها أكثر من حاجتك تسدّد جزءاً من الدين.",
            ),
        ),
        "sleep.consistency" to AnatomyFormula(
            formula = LocalizedString(
                en = "Consistency = 100 × ( w × bed-regularity + (1 − w) × wake-regularity )",
                ar = "الاتساق = 100 × ( وزن × انتظام-موعد-النوم + (1 − وزن) × انتظام-موعد-الاستيقاظ )",
            ),
            altText = LocalizedString(
                en = "Timing consistency scores how steady your bedtimes and wake times are over the last two weeks. The tighter the spread, the higher the score; bedtime and wake-time regularity are blended, and the spread is measured wrap-aware so times either side of midnight count as close.",
                ar = "يقيس اتساق التوقيت مدى ثبات مواعيد نومك واستيقاظك خلال الأسبوعين الماضيين. كلما ضاق التشتّت ارتفعت النتيجة؛ ويُمزج انتظام موعد النوم مع انتظام موعد الاستيقاظ، ويُقاس التشتّت بطريقة تراعي التفاف منتصف الليل فتُحتسب الأوقات على جانبي منتصف الليل متقاربة.",
            ),
        ),
        "sleep.disturbances" to AnatomyFormula(
            formula = LocalizedString(
                en = "Disturbances = count of awake episodes ≥ min length, after merging gaps < merge threshold",
                ar = "الاضطرابات = عدد فترات اليقظة التي طولها ≥ الحد الأدنى، بعد دمج الفجوات < حد الدمج",
            ),
            altText = LocalizedString(
                en = "Overnight disturbances count the times you were awake long enough to notice. Brief awakenings closer together than a short gap are merged into one, and anything under a few minutes is dropped. A night with no sleep-stage data gets no count rather than a zero.",
                ar = "تُحصي الاضطرابات الليلية المرّات التي كنت فيها مستيقظاً مدةً كافية لتلاحظها. تُدمج فترات اليقظة القصيرة المتقاربة أقرب من فجوة قصيرة في فترة واحدة، ويُسقَط ما يقل عن بضع دقائق. والليلة التي لا تتوفّر لها بيانات مراحل النوم لا تحصل على عدد بدل أن تُحتسب صفراً.",
            ),
        ),
        "effort.day" to AnatomyFormula(
            formula = LocalizedString(
                en = "Effort = scale × (1 − e^(−k × weighted zone-minutes))",
                ar = "الجهد = المقياس × (1 − e^(−k × دقائق-النطاق-المرجّحة))",
            ),
            altText = LocalizedString(
                en = "Effort rises with the minutes you spend in each heart-rate zone, weighted so harder zones count for more. The curve flattens as effort accumulates, so the same extra minutes add less near the top.",
                ar = "يرتفع الجهد مع الدقائق التي تقضيها في كل نطاق لمعدل ضربات القلب، مرجّحةً بحيث تُحتسب النطاقات الأصعب أكثر. ينبسط المنحنى كلما تراكم الجهد، فالدقائق الإضافية نفسها تضيف أقل قرب القمة.",
            ),
        ),
        // effort.workout shares effort.day's published curve (asserted by a golden), so it maps to the
        // same formula rather than duplicating the string.
        "effort.workout" to AnatomyFormula(
            formula = LocalizedString(
                en = "Effort = scale × (1 − e^(−k × weighted zone-minutes))",
                ar = "الجهد = المقياس × (1 − e^(−k × دقائق-النطاق-المرجّحة))",
            ),
            altText = LocalizedString(
                en = "Workout effort uses the same curve as your daily effort, over the minutes in each heart-rate zone during the workout.",
                ar = "يستخدم جهد التمرين المنحنى نفسه لجهدك اليومي، على الدقائق في كل نطاق لمعدل ضربات القلب خلال التمرين.",
            ),
        ),
        "baseline.rolling_median_mad" to AnatomyFormula(
            formula = LocalizedString(
                en = "Band = median ± k × typical variation",
                ar = "النطاق = الوسيط ± k × التغيّر المعتاد",
            ),
            altText = LocalizedString(
                en = "Your typical range is your personal median plus or minus a multiple of how much this value usually varies, ignoring occasional outliers.",
                ar = "نطاقك المعتاد هو وسيطك الشخصي زائداً أو ناقصاً مضاعفاً لمقدار تغيّر هذه القيمة عادةً، متجاهلاً القيم الشاذة العارضة.",
            ),
        ),
    )

    /** Resolve for a method token that may be a raw `algorithmId` or the composed `"algorithmId@semver"`. */
    fun lookup(method: String): AnatomyFormula? = byAlgorithmId[method.substringBefore("@")]
}

/** Confidence as a plain, honest word — the meaning the number stands for (never bare precision). */
internal fun confidenceWord(confidence: Double): LocalizedString = when {
    confidence >= 0.75 -> AnatomyScoreStrings.confidenceEstablished
    confidence >= 0.4 -> AnatomyScoreStrings.confidenceFirming
    else -> AnatomyScoreStrings.confidenceEarly
}

/** The confidence words, kept beside the pure mapping that returns them (bilingual, wellness-safe). */
internal object AnatomyScoreStrings {
    val confidenceEstablished = LocalizedString(en = "Established", ar = "راسخة")
    val confidenceFirming = LocalizedString(en = "Firming up", ar = "تترسّخ")
    val confidenceEarly = LocalizedString(en = "Early estimate", ar = "تقدير مبكّر")
}
