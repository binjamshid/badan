package net.albayyan.badan.domain.reports

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Numerals
import net.albayyan.badan.domain.MetricId
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The single source of a report's *wording* — the wellness-safe, bilingual copy and the
 * number→sentence logic that both the PDF renderer (`ReportRenderer`) and the on-screen surface
 * (`ReportsScreen`) draw from, so the shared PDF and the in-app view can never say different things.
 * Keeping it here (over the language-neutral [ReportModel]) is what lets one wellness-copy review and
 * one snapshot cover every place a report speaks. Mirror of iOS `ReportPresentation.swift`.
 *
 * Register: neutral and non-punitive. Directions are "higher/lower than the previous week", never
 * "good/bad"; adherence is counted, never judged. The persistent disclaimer states plainly that a
 * report is a wellness summary, not a medical assessment.
 */
object ReportPresentation {

    // MARK: - Titles / labels

    fun title(kind: ReportPeriodKind): LocalizedString = when (kind) {
        ReportPeriodKind.WEEK -> LocalizedString(en = "Weekly report", ar = "التقرير الأسبوعي")
        ReportPeriodKind.MONTH -> LocalizedString(en = "Monthly report", ar = "التقرير الشهري")
    }

    fun sectionTitle(kind: ReportSectionKind): LocalizedString = when (kind) {
        ReportSectionKind.SLEEP -> LocalizedString(en = "Sleep", ar = "النوم")
        ReportSectionKind.EFFORT -> LocalizedString(en = "Effort", ar = "الجهد")
        ReportSectionKind.READINESS -> LocalizedString(en = "Readiness", ar = "الجاهزية")
        ReportSectionKind.ADHERENCE -> LocalizedString(en = "Medication adherence", ar = "الالتزام بالدواء")
        ReportSectionKind.CHANGES -> LocalizedString(en = "Notable changes", ar = "تغيّرات ملحوظة")
    }

    fun metricLabel(metricId: String): LocalizedString = when (metricId) {
        MetricId.sleepPerformance -> LocalizedString(en = "Sleep performance", ar = "أداء النوم")
        MetricId.sleepDebt -> LocalizedString(en = "Sleep debt", ar = "عجز النوم")
        MetricId.sleepConsistency -> LocalizedString(en = "Sleep consistency", ar = "انتظام النوم")
        MetricId.effortDay -> LocalizedString(en = "Effort", ar = "الجهد")
        MetricId.readinessScore -> LocalizedString(en = "Readiness", ar = "الجاهزية")
        else -> LocalizedString(en = metricId, ar = metricId)
    }

    // MARK: - Stat labels

    val averageLabel = LocalizedString(en = "Average", ar = "المتوسط")
    val rangeLabel = LocalizedString(en = "Range", ar = "المدى")
    val latestLabel = LocalizedString(en = "Latest", ar = "الأحدث")
    val regenerateLabel = LocalizedString(en = "Regenerate", ar = "إعادة الإنشاء")

    /**
     * Shown when a build fails. Deliberately distinct from the empty-period copy AND from the
     * generic load-error copy: a period with nothing logged DOES produce a report (an honest one),
     * and nothing failed to *load* — so neither of those would be a true sentence here. Lives with
     * the rest of the report wording so the list and the detail surface say the same thing.
     */
    val generateError = LocalizedString(
        en = "Couldn't build that report. Try again.",
        ar = "تعذّر إنشاء هذا التقرير. حاول مرة أخرى.",
    )

    val disclaimer = LocalizedString(
        en = "This is a wellness summary, not a medical assessment.",
        ar = "هذا ملخّص للعافية وليس تقييماً طبياً.",
    )

    fun emptyMessage(kind: ReportPeriodKind): LocalizedString = when (kind) {
        ReportPeriodKind.WEEK -> LocalizedString(
            en = "Not enough logged this week to build a report yet.",
            ar = "لا توجد بيانات كافية هذا الأسبوع لإنشاء تقرير بعد.",
        )
        ReportPeriodKind.MONTH -> LocalizedString(
            en = "Not enough logged this month to build a report yet.",
            ar = "لا توجد بيانات كافية هذا الشهر لإنشاء تقرير بعد.",
        )
    }

    // MARK: - Period label

    /** A human period label: "Week 29, 2026" / "July 2026" and their Arabic forms. */
    fun periodLabel(model: ReportModel, language: AppLanguage, arabicDigits: Boolean): String =
        when (model.periodKind) {
            ReportPeriodKind.WEEK -> {
                // periodKey is "week:YYYY-Www".
                val parts = model.periodKey.removePrefix("week:").split("-")
                val yearValue = parts.getOrNull(0)?.toIntOrNull() ?: 0
                val weekValue = parts.getOrNull(1)?.drop(1)?.toIntOrNull() ?: 0
                val year = number(yearValue.toDouble(), language, arabicDigits)
                val week = number(weekValue.toDouble(), language, arabicDigits)
                when (language) {
                    AppLanguage.EN -> "Week $week, $year"
                    AppLanguage.AR -> "الأسبوع $week، $year"
                }
            }
            ReportPeriodKind.MONTH -> {
                val df = SimpleDateFormat("MMMM yyyy", localeFor(language))
                df.timeZone = TimeZone.getTimeZone(model.timezone)
                df.format(Date(model.periodStart))
            }
        }

    // MARK: - Counted nouns

    /**
     * Count-noun agreement for the nouns a report counts (days, doses, records). English needs only
     * singular/plural; Arabic follows the app-wide rule the Home surface already applies —
     * 1 singular · 2 dual · 3–10 plural · 11+ indeclinable singular — with the dual carrying no
     * numeral, since "يومين" already says two. This is not a nicety: a week's counts land squarely in
     * the 3–10 band, so a fixed "$n يوماً" would be wrong in nearly every Arabic report. A count of 0
     * takes the 3–10 plural form; in practice it never reaches here, because a section exists only
     * when it has content. Mirror of iOS `ReportPresentation.countedNoun`.
     */
    fun countedNoun(
        n: Int,
        language: AppLanguage,
        arabicDigits: Boolean,
        enSingular: String,
        enPlural: String,
        arOne: String,
        arTwo: String,
        arFew: String,
        arMany: String,
    ): String {
        val digits = number(n.toDouble(), language, arabicDigits)
        return when (language) {
            AppLanguage.EN -> "$digits ${if (n == 1) enSingular else enPlural}"
            AppLanguage.AR -> when {
                n == 1 -> arOne
                n == 2 -> arTwo
                n >= 11 -> "$digits $arMany"
                else -> "$digits $arFew"
            }
        }
    }

    /** "5 days" / "٥ أيام" — the days a metric summary covers. */
    fun dayCount(n: Int, language: AppLanguage, arabicDigits: Boolean): String =
        countedNoun(
            n, language, arabicDigits,
            enSingular = "day", enPlural = "days",
            arOne = "يوم واحد", arTwo = "يومين", arFew = "أيام", arMany = "يوماً",
        )

    /** "5 records" / "٥ سجلات" — the evidence rows a claim rests on. */
    fun recordCount(n: Int, language: AppLanguage, arabicDigits: Boolean): String =
        countedNoun(
            n, language, arabicDigits,
            enSingular = "record", enPlural = "records",
            arOne = "سجل واحد", arTwo = "سجلين", arFew = "سجلات", arMany = "سجلاً",
        )

    /** "5 doses" / "٥ جرعات" — logged medication doses. */
    fun doseCount(n: Int, language: AppLanguage, arabicDigits: Boolean): String =
        countedNoun(
            n, language, arabicDigits,
            enSingular = "dose", enPlural = "doses",
            arOne = "جرعة واحدة", arTwo = "جرعتين", arFew = "جرعات", arMany = "جرعة",
        )

    /** "3 sections" / "٣ أقسام" — how much of a report a row summarises. */
    fun sectionCount(n: Int, language: AppLanguage, arabicDigits: Boolean): String =
        countedNoun(
            n, language, arabicDigits,
            enSingular = "section", enPlural = "sections",
            arOne = "قسم واحد", arTwo = "قسمين", arFew = "أقسام", arMany = "قسماً",
        )

    // MARK: - Narratives (numbers resolved into wellness-safe sentences)

    fun metricNarrative(
        s: MetricSummary,
        kind: ReportPeriodKind,
        language: AppLanguage,
        arabicDigits: Boolean,
    ): String {
        val label = metricLabel(s.metricId).resolved(language)
        val meanStr = number(s.mean ?: 0.0, language, arabicDigits)
        val days = dayCount(s.count, language, arabicDigits)
        val dir = directionClause(s.direction, kind).resolved(language)
        return when (language) {
            AppLanguage.EN ->
                if (s.direction == TrendDirection.INSUFFICIENT) {
                    "Average $label was $meanStr across $days."
                } else {
                    "Average $label was $meanStr across $days, $dir."
                }
            AppLanguage.AR ->
                if (s.direction == TrendDirection.INSUFFICIENT) {
                    "بلغ متوسط $label $meanStr خلال $days."
                } else {
                    "بلغ متوسط $label $meanStr خلال $days، $dir."
                }
        }
    }

    fun changeNarrative(
        c: ChangeItem,
        kind: ReportPeriodKind,
        language: AppLanguage,
        arabicDigits: Boolean,
    ): String {
        val label = metricLabel(c.metricId).resolved(language)
        val cur = number(c.currentMean, language, arabicDigits)
        val prior = number(c.priorMean, language, arabicDigits)
        return when (language) {
            AppLanguage.EN -> {
                val word = if (c.direction == TrendDirection.UP) "higher" else "lower"
                val period = if (kind == ReportPeriodKind.WEEK) "week" else "month"
                "$label was $word this $period: $cur vs $prior."
            }
            AppLanguage.AR -> {
                val word = if (c.direction == TrendDirection.UP) "أعلى" else "أدنى"
                val period = if (kind == ReportPeriodKind.WEEK) "الأسبوع" else "الشهر"
                "كان $label $word هذا $period: $cur مقابل $prior."
            }
        }
    }

    fun adherenceNarrative(
        a: AdherenceSummary,
        kind: ReportPeriodKind,
        language: AppLanguage,
        arabicDigits: Boolean,
    ): String {
        val logged = doseCount(a.logged, language, arabicDigits)
        val taken = number(a.taken.toDouble(), language, arabicDigits)
        val late = number(a.late.toDouble(), language, arabicDigits)
        val skipped = number(a.skipped.toDouble(), language, arabicDigits)
        var base = when (language) {
            AppLanguage.EN -> {
                val period = if (kind == ReportPeriodKind.WEEK) "week" else "month"
                "You logged $logged this $period: $taken taken, $late late, $skipped skipped."
            }
            AppLanguage.AR -> {
                // The counts after the first are elided doses, so each adjective agrees with a
                // non-human plural — feminine singular ("٣ مأخوذة"), which is the correct form.
                val period = if (kind == ReportPeriodKind.WEEK) "الأسبوع" else "الشهر"
                "سجّلت $logged هذا $period: $taken مأخوذة، و$late متأخرة، و$skipped متخطّاة."
            }
        }
        val rate = a.adherenceRate
        if (rate != null) {
            val pct = number(rate * 100, language, arabicDigits)
            base += when (language) {
                AppLanguage.EN -> " That's $pct% on schedule."
                AppLanguage.AR -> " أي $pct% ضمن الموعد."
            }
        }
        return base
    }

    /** "Based on {n} records" — the transparency line under a claim. */
    fun evidenceCountPhrase(n: Int, language: AppLanguage, arabicDigits: Boolean): String {
        val count = recordCount(n, language, arabicDigits)
        return when (language) {
            AppLanguage.EN -> "Based on $count"
            AppLanguage.AR -> "استناداً إلى $count"
        }
    }

    // MARK: - Helpers

    private fun directionClause(d: TrendDirection, kind: ReportPeriodKind): LocalizedString {
        val periodEn = if (kind == ReportPeriodKind.WEEK) "week" else "month"
        val periodAr = if (kind == ReportPeriodKind.WEEK) "الأسبوع" else "الشهر"
        return when (d) {
            TrendDirection.UP -> LocalizedString(
                en = "higher than the previous $periodEn", ar = "أعلى من $periodAr السابق",
            )
            TrendDirection.DOWN -> LocalizedString(
                en = "lower than the previous $periodEn", ar = "أدنى من $periodAr السابق",
            )
            TrendDirection.FLAT -> LocalizedString(
                en = "about the same as the previous $periodEn", ar = "قريب من $periodAr السابق",
            )
            TrendDirection.INSUFFICIENT -> LocalizedString(
                en = "no prior $periodEn to compare", ar = "لا يوجد $periodAr سابق للمقارنة",
            )
        }
    }

    fun number(v: Double, language: AppLanguage, arabicDigits: Boolean, fractionDigits: Int = 0): String =
        Numerals.format(v, language, arabicDigits, fractionDigits)

    /**
     * The month-name locale for a report's period label. Built from the language's own tag — the
     * `Locale(String, String)` constructors are deprecated, and `localeTag` is already the app-wide
     * source for this, so a report's month name matches every other date the app renders.
     */
    private fun localeFor(language: AppLanguage): Locale = Locale.forLanguageTag(language.localeTag)
}
