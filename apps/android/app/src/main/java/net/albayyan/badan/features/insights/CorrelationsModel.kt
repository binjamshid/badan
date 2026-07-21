package net.albayyan.badan.features.insights

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.derivation.CorrelationFinding
import net.albayyan.badan.domain.derivation.CorrelationOutcome
import net.albayyan.badan.domain.derivation.CorrelationRenderer
import net.albayyan.badan.domain.derivation.CorrelationSpec
import net.albayyan.badan.ontology.AlgorithmRegistry
import net.albayyan.badan.ontology.BehaviorDictionary
import net.albayyan.badan.ontology.InsightTemplateStore
import net.albayyan.badan.ontology.MetricRegistry

/**
 * EPIC-29 — the correlations surface's Compose-free presentation core, and the Android half of the
 * iOS `CorrelationsPresentation` / `CorrelationsStrings` / `CorrelationsReadModel` set.
 *
 * `CorrelationEngineGoldenTest` already pins the statistics and the rendered copy. What lives here
 * is the layer that could quietly undo them without touching a number: the ORDERING (a list sorted
 * by effect size reads as a feed of hits), the confidence WORD (the casual altitude's whole
 * quantitative vocabulary), and the spoken forms (a punctuation-dense stat line is accurate to read
 * and hostile to hear). `CorrelationPresentationTest` asserts all three on the JVM.
 *
 * Nothing here computes anything. Every number, every sentence and the locked association-not-cause
 * line come from `CorrelationEngine` / `CorrelationRenderer`, which both platforms share.
 */

// MARK: - Presentation

internal object CorrelationsPresentation {

    /**
     * The casual altitude's confidence vocabulary. Three bands over the SAME `confidence` value power
     * mode prints as a number, so the word and the number can never disagree — the word is a reading
     * of the number, not a second judgement of the finding.
     *
     * It is deliberately not a p-value and must never be worded as one: `CorrelationMath.confidence`
     * is sample size x interval precision, a display weight, and calling it "significance" would
     * claim a test that was never run.
     */
    enum class ConfidenceWord {
        EARLY,
        MODERATE,
        ESTABLISHED;

        val label: LocalizedString
            get() = when (this) {
                EARLY -> LocalizedString(en = "Early estimate", ar = "تقدير مبدئي")
                MODERATE -> LocalizedString(en = "Moderate confidence", ar = "ثقة متوسطة")
                ESTABLISHED -> LocalizedString(en = "Well supported", ar = "مدعوم جيداً")
            }
    }

    fun confidenceWord(confidence: Double): ConfidenceWord = when {
        confidence < 1.0 / 3.0 -> ConfidenceWord.EARLY
        confidence < 2.0 / 3.0 -> ConfidenceWord.MODERATE
        else -> ConfidenceWord.ESTABLISHED
    }

    /**
     * Two decimals with a real minus sign (U+2212) instead of an ASCII hyphen. A screen reader reads
     * the hyphen as a dash or skips it, so "−0.42" is spoken as "minus zero point four two" where
     * "-0.42" may be read as "0.42" — on the one number that carries the direction of a finding.
     */
    fun signedNumber(value: Double): String =
        CorrelationRenderer.twoDecimals(value).replace("-", "−")

    /**
     * The spoken form of the power line. The rendered `powerText` is a dense
     * "n = 18 (11 with / 7 without) · Cliff's delta 0.42 · 95% CI [0.10, 0.71] …" — accurate to read,
     * hostile to hear. This says the same numbers as sentences, in the same order, from the same
     * finding.
     */
    fun spokenPowerDetail(finding: CorrelationFinding, language: AppLanguage): String {
        val template = LocalizedString(
            en = "Based on {n} logged days: {with} with, {without} without. Effect size {delta} on a scale from minus 1 to plus 1. The 95 percent range runs from {low} to {high}. Confidence {confidence} out of 1.",
            ar = "بناءً على {n} يوماً مسجّلاً: {with} مع و{without} بدون. حجم الأثر {delta} على مقياس من سالب 1 إلى موجب 1. ويمتد نطاق 95 بالمئة من {low} إلى {high}. الثقة {confidence} من 1.",
        )
        return template.filling(
            mapOf(
                "n" to finding.nObserved.toString(),
                "with" to finding.nWith.toString(),
                "without" to finding.nWithout.toString(),
                "delta" to signedNumber(finding.delta),
                "low" to signedNumber(finding.ciLow),
                "high" to signedNumber(finding.ciHigh),
                "confidence" to CorrelationRenderer.twoDecimals(finding.confidence),
            ),
        ).resolved(language)
    }

    /**
     * The whole card as one spoken phrase: the sentence, the confidence word, the numbers (power
     * only) and — always — the association-not-cause line. The locked line is inside the spoken label
     * rather than a separate stop, so it cannot be swiped past.
     */
    fun spokenCard(row: CorrelationRow, depth: DepthPolicy, language: AppLanguage): String {
        val parts = mutableListOf(row.card.casualText.resolved(language))
        row.finding?.let { parts.add(confidenceWord(it.confidence).label.resolved(language)) }
        row.card.contextNote?.let { parts.add(it.resolved(language)) }
        if (depth.showsPowerDetail) {
            row.finding?.let { parts.add(spokenPowerDetail(it, language)) }
        }
        parts.add(row.card.associationNotCause.resolved(language))
        return parts.joinToString(" ")
    }
}

// MARK: - Rows

/**
 * One card's worth of state. [card] is built ONCE per outcome, and both altitudes read it: casual
 * shows [CorrelationRenderer.Card.casualText] plus a confidence word, power additionally shows
 * [CorrelationRenderer.Card.powerText]. There is deliberately no second render path for power mode —
 * that is the D-5 rule, and it is what stops the sentence and the numbers from ever disagreeing.
 */
internal data class CorrelationRow(
    val metricId: String,
    val behaviorId: String,
    val scoreId: String,
    val behaviorName: LocalizedString,
    val scoreName: LocalizedString,
    val card: CorrelationRenderer.Card,
    /** Null for a suppressed pair — which has no statistics, because nothing was computed. */
    val finding: CorrelationFinding?,
) {
    val isSuppressed: Boolean get() = card.isSuppressed
}

/** The list, split the way the screen renders it, carrying the gates it will state on screen. */
internal data class CorrelationsReadModel(
    val findings: List<CorrelationRow>,
    val notYet: List<CorrelationRow>,
    val minObservedDays: Int,
    val minDaysPerArm: Int,
) {
    val isEmpty: Boolean get() = findings.isEmpty() && notYet.isEmpty()

    companion object {

        /**
         * Build the list from the engine's outcomes. Pure — takes what the loader read, returns what
         * the screen draws.
         *
         * Labels are resolved DEPTH-INDEPENDENTLY (`displayName`, never `label(depth, …)`) and every
         * rendered string is bilingual, so the read model is one object serving both altitudes and
         * both languages. Nothing the user can toggle rebuilds it.
         */
        fun build(
            outcomes: List<CorrelationOutcome>,
            behaviors: BehaviorDictionary,
            registry: MetricRegistry,
            templates: InsightTemplateStore,
            params: CorrelationSpec.Params,
        ): CorrelationsReadModel {
            val findings = mutableListOf<CorrelationRow>()
            val notYet = mutableListOf<CorrelationRow>()
            for (outcome in outcomes) {
                val behaviorId: String
                val scoreId: String
                when (outcome) {
                    is CorrelationOutcome.Finding -> {
                        behaviorId = outcome.finding.behaviorId
                        scoreId = outcome.finding.scoreId
                    }
                    is CorrelationOutcome.Suppressed -> {
                        behaviorId = outcome.suppression.behaviorId
                        scoreId = outcome.suppression.scoreId
                    }
                }
                val behaviorName = behaviors.displayName(behaviorId, null)
                val scoreName = registry.definitionOrFallback(scoreId).displayName
                val card = CorrelationRenderer.render(
                    outcome = outcome, behavior = behaviorName, score = scoreName,
                    templates = templates, params = params,
                )
                val row = CorrelationRow(
                    metricId = card.metricId, behaviorId = behaviorId, scoreId = scoreId,
                    behaviorName = behaviorName, scoreName = scoreName, card = card,
                    finding = outcome.findingOrNull,
                )
                if (row.isSuppressed) notYet.add(row) else findings.add(row)
            }
            return CorrelationsReadModel(
                findings = sorted(findings), notYet = sorted(notYet),
                minObservedDays = params.minObservedDays, minDaysPerArm = params.minDaysPerArm,
            )
        }

        /**
         * **Ordering is alphabetical by behaviour, never by effect size.** Ranking the strongest
         * association first would turn the screen into a leaderboard of whichever comparison happened
         * to land hardest this week, which is the reading this epic exists to refuse; a stable order
         * also means a finding doesn't move under the reader's thumb between opens. The "not yet"
         * pairs are a separate section rather than greyed-out rows, so a shortfall is never one
         * glance away from being mistaken for a weak result.
         *
         * Sorted on the ENGLISH name so the two languages — and the two platforms — list the same
         * cards in the same order.
         */
        private fun sorted(rows: List<CorrelationRow>): List<CorrelationRow> =
            rows.sortedWith(compareBy({ it.behaviorName.en }, { it.scoreId }))
    }
}

// MARK: - Strings

internal object CorrelationsStrings {
    val title = LocalizedString(en = "Correlations", ar = "الارتباطات")
    val subtitle = LocalizedString(
        en = "How the days you tag line up with the next day’s scores.",
        ar = "كيف تتوافق الأيام التي تضع فيها علامات مع مؤشرات اليوم التالي.",
    )
    val findingsHeader = LocalizedString(en = "What your days show", ar = "ما تُظهره أيامك")
    val notYetHeader = LocalizedString(en = "Not enough days yet", ar = "لا توجد أيام كافية بعد")

    /**
     * The gate, stated with the published numbers in it. §16's mitigation for overtrust is
     * "minimum-n gate copy" — the rule is on screen, not only in a doc, so a reader can check the app
     * against its own promise.
     */
    val gateNote = LocalizedString(
        en = "A comparison needs at least {n} logged days and at least {arm} days on each side — with the behaviour and without it. Below that, nothing is shown at all.",
        ar = "تحتاج المقارنة إلى {n} يوماً مسجّلاً على الأقل و{arm} أيام على الأقل في كل جهة — مع السلوك وبدونه. ودون ذلك لا يُعرض شيء إطلاقاً.",
    )

    val emptyTitle = LocalizedString(en = "Nothing to compare yet", ar = "لا شيء للمقارنة بعد")
    val emptyMessage = LocalizedString(
        en = "Tag a few days in the journal. Once a behaviour has enough days on both sides, its comparison appears here.",
        ar = "ضع علامات على بضعة أيام في المفكرة. وحين تتوفر أيام كافية على الجهتين لأي سلوك، تظهر مقارنته هنا.",
    )
    val openJournal = LocalizedString(en = "Open the journal", ar = "افتح المفكرة")

    val methodNote = LocalizedString(
        en = "Compared on your device with a rank-based method that assumes nothing about the shape of your scores, and an interval drawn from your own data. Nothing leaves your phone.",
        ar = "تُجرى المقارنة على جهازك بطريقة تعتمد على الترتيب ولا تفترض شيئاً عن شكل توزيع مؤشراتك، وبفاصل ثقة مُستخرج من بياناتك نفسها. ولا يغادر أي شيء هاتفك.",
    )

    val sensitiveOffMessage = LocalizedString(
        en = "Findings name the behaviour they’re about, so they live in the separate, purgeable store with the journal. Turn on Sensitive records in Settings to see them.",
        ar = "تذكر النتائج اسم السلوك الذي تخصّه، لذا تُحفظ في المخزن المنفصل القابل للحذف مع المفكرة. فعّل السجلات الحساسة من الإعدادات لعرضها.",
    )

    /** The entry point on the Insights feed. */
    val openSubtitle = LocalizedString(
        en = "Behaviours you tag, against your next-day scores",
        ar = "السلوكيات التي تسجّلها مقارنةً بمؤشرات اليوم التالي",
    )

    /**
     * Shown when the published contract did not resolve. The engine computes nothing without its
     * constants — the gates ARE the honesty guarantee — so the surface says so rather than falling
     * back to defaults nobody published.
     */
    val unavailable = LocalizedString(
        en = "Comparisons aren’t available in this version of the app.",
        ar = "المقارنات غير متاحة في هذه النسخة من التطبيق.",
    )

    val loadFailed = LocalizedString(
        en = "Couldn’t work out your comparisons — try again.",
        ar = "تعذّر إعداد المقارنات — حاول مرة أخرى.",
    )
}

/**
 * The correlation contract, resolved once per process from the classpath mirror of
 * `algorithms.json` — the same load path `StressSpec.default()` uses, and for the same reason: a
 * surface must read the published constants, never a copy of them.
 */
internal val correlationSpec: CorrelationSpec by lazy {
    CorrelationSpec.load(AlgorithmRegistry.fromClasspath())
}
