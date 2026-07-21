package net.albayyan.badan.features.healthmonitor

import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.derivation.StressDensity
import net.albayyan.badan.domain.derivation.StressSurface
import net.albayyan.badan.domain.derivation.StressTrend
import net.albayyan.badan.domain.derivation.StressTrendBand
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * EPIC-34 — the stress surface's Compose-free presentation core, and the Android half of the iOS
 * `StressPresentation` + `StressStrings` pair. `StressSurfacePresentationTest` pins it on the JVM,
 * the same split `HealthMonitorModel` uses.
 *
 * Two rules are testable here rather than only visible in a view: a hidden surface renders the
 * engine's own device-factual explanation and nothing numeric, and every rendered trend carries the
 * window it describes rather than reading as "now".
 */

// MARK: - Presentation

internal object StressPresentation {

    /**
     * The directional chip. Never "high stress"/"low stress" — a direction relative to the person's
     * own usual, which is all a `bandNeutralHalfWidth` around 50 can honestly support. Both
     * out-of-band directions share ONE amber and disambiguate by arrow, per the design-system rule.
     */
    fun chipSpec(band: StressTrendBand): Pair<ChipStatus, LocalizedString> = when (band) {
        StressTrendBand.HIGHER_THAN_USUAL -> ChipStatus.Above to StressStrings.bandHigher
        StressTrendBand.ABOUT_USUAL -> ChipStatus.InBand to StressStrings.bandAbout
        StressTrendBand.LOWER_THAN_USUAL -> ChipStatus.Below to StressStrings.bandLower
    }

    /** The casual altitude's one sentence. */
    fun sentence(band: StressTrendBand): LocalizedString = when (band) {
        StressTrendBand.HIGHER_THAN_USUAL -> StressStrings.sentenceHigher
        StressTrendBand.ABOUT_USUAL -> StressStrings.sentenceAbout
        StressTrendBand.LOWER_THAN_USUAL -> StressStrings.sentenceLower
    }

    /**
     * "7 days" / "7 أيام" — a day-count fragment with correct Arabic agreement (1 singular · 2 dual ·
     * 3–10 plural · 11+ indeclinable). Needed because the window length is contract data
     * (`trendWindowDays`), so the copy cannot hardcode "week".
     */
    fun dayCount(n: Int, language: AppLanguage, format: ValueFormatter): String {
        val number = format.integer(n)
        if (language != AppLanguage.AR) return "$number days"
        return when {
            n == 1 -> "يوم واحد"
            n == 2 -> "يومان"
            n in 3..10 -> "$number أيام"
            else -> "$number يوماً"
        }
    }

    /**
     * The window disclosure, on every rendered trend. [StressTrend] carries `windowDays` and its end
     * day precisely so a surface cannot quietly relabel it "now"; this is where that guarantee
     * becomes visible to the reader.
     */
    fun windowNote(trend: StressTrend, language: AppLanguage, format: ValueFormatter, tz: String): String {
        val day = DayAttribution.dateFromDayKey(trend.dayKey, tz)?.let { formatDay(it, language) } ?: trend.dayKey
        return StressStrings.windowNote
            .filling(mapOf("span" to dayCount(trend.windowDays, language, format), "day" to day))
            .resolved(language)
    }

    /**
     * The power-depth stat line. Label-and-value pairs rather than prose: it keeps the Arabic free of
     * counted-noun agreement traps and matches the register the other power lines use.
     */
    fun powerLine(trend: StressTrend, language: AppLanguage, format: ValueFormatter): String =
        StressStrings.powerLine.filling(
            mapOf(
                "value" to format.integer(Math.round(trend.value).toInt()),
                "confidence" to twoDecimals(trend.confidence),
                "present" to format.integer(trend.daysPresent),
                "window" to format.integer(trend.windowDays),
            ),
        ).resolved(language)

    /**
     * The measured density, shown at power depth alongside a rendered trend — "here is the evidence
     * the gate ruled on" is more respectful than a bare number, and it is the one thing that tells a
     * user whether a different device would change the answer.
     *
     * It cannot be shown on a hidden surface, and that is by construction rather than by choice:
     * `StressSurface.Hidden` carries only the reason, so there is no `StressDensity` to read out of a
     * surface that was refused.
     */
    fun densityLine(density: StressDensity, language: AppLanguage, format: ValueFormatter): String =
        StressStrings.densityLine.filling(
            mapOf(
                "samples" to format.integer(density.daytimeSamples),
                "hours" to format.integer(Math.round(density.daytimeHours).toInt()),
                "rate" to twoDecimals(density.samplesPerHour),
            ),
        ).resolved(language)

    /**
     * One spoken phrase for the whole card. Numbers are read as labelled values rather than as a
     * punctuation-dense stat line — §16's "numbers spelled out for VO" applied to this surface.
     */
    /**
     * The line under the stored-history sparkline. It says how many days the app has actually KEPT,
     * which is the honest description of a series with gaps in it — the days the gate refused are
     * missing, not zero, so a plain "last 14 days" would overstate what is plotted.
     */
    fun historyNote(dayCount: Int, language: AppLanguage, format: ValueFormatter): String =
        StressStrings.historyNote
            .filling(mapOf("span" to dayCount(dayCount, language, format)))
            .resolved(language)

    fun spokenLabel(
        surface: StressSurface,
        depth: DepthPolicy,
        language: AppLanguage,
        format: ValueFormatter,
        tz: String,
        caveats: List<LocalizedString> = emptyList(),
    ): String {
        val parts = mutableListOf(StressStrings.title.resolved(language))
        val trend = surface.trend
        if (trend == null) {
            surface.absenceReason?.let { parts.add(it.explanation.resolved(language)) }
        } else {
            parts.add(chipSpec(trend.band).second.resolved(language))
            parts.add(sentence(trend.band).resolved(language))
            parts.add(windowNote(trend, language, format, tz))
            if (depth.showsPowerDetail) parts.add(powerLine(trend, language, format))
        }
        // Any context caveat is read LAST, as the frame the reading should be taken in — the same
        // order a sighted reader meets it in.
        parts.addAll(caveats.map { it.resolved(language) })
        return parts.joinToString(". ")
    }

    /** ROOT-locale fixed so the two platforms print the same digits for the same value. */
    fun twoDecimals(value: Double): String = String.format(Locale.ROOT, "%.2f", value)

    private fun formatDay(millis: Long, language: AppLanguage): String =
        DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.forLanguageTag(language.localeTag))
            .apply { timeZone = TimeZone.getDefault() }
            .format(Date(millis))
}

// MARK: - Strings

/**
 * Copy for the stress surface, mirroring the iOS `StressStrings` line for line so the two platforms
 * say the same thing. Nothing here claims a live reading — [StressStrings.windowNote] says the
 * opposite in as many words, and it is not power-gated.
 *
 * The ABSENCE copy is deliberately not here: it lives on `StressAbsenceReason.explanation`, shared
 * with the engine, so there is no code path that produces a hidden surface without a rendered
 * sentence and no way for this file to soften one.
 */
internal object StressStrings {
    val title = LocalizedString(en = "Stress trend", ar = "اتجاه التوتر")

    val bandHigher = LocalizedString(en = "Higher than usual", ar = "أعلى من المعتاد")
    val bandAbout = LocalizedString(en = "About usual", ar = "قريب من المعتاد")
    val bandLower = LocalizedString(en = "Lower than usual", ar = "أدنى من المعتاد")

    val sentenceHigher = LocalizedString(
        en = "Your daytime load has been reading higher than your own usual.",
        ar = "كان الحِمل النهاري لديك أعلى من معتادك.",
    )
    val sentenceAbout = LocalizedString(
        en = "Your daytime load has been close to your own usual.",
        ar = "كان الحِمل النهاري لديك قريباً من معتادك.",
    )
    val sentenceLower = LocalizedString(
        en = "Your daytime load has been reading lower than your own usual.",
        ar = "كان الحِمل النهاري لديك أدنى من معتادك.",
    )

    val windowNote = LocalizedString(
        en = "Describes the {span} ending {day} — not a reading for right now.",
        ar = "يصف {span} تنتهي في {day} — وليست قراءة للحظة الحالية.",
    )

    val powerLine = LocalizedString(
        en = "Trend {value} of 100 · 50 is your own usual · confidence {confidence} · days used {present} of {window}",
        ar = "الاتجاه {value} من 100 · و50 هو معتادك · الثقة {confidence} · الأيام المستخدمة {present} من أصل {window}",
    )

    val densityLine = LocalizedString(
        en = "Daytime readings {samples} · waking hours {hours} · {rate} per hour",
        ar = "القراءات النهارية {samples} · ساعات اليقظة {hours} · {rate} لكل ساعة",
    )

    val historyNote = LocalizedString(
        en = "Saved daily trend from {span} your device could read. Days it couldn't are left out, not filled in.",
        ar = "الاتجاه اليومي المحفوظ من {span} تمكّن جهازك من قراءتها. أما الأيام التي تعذّرت قراءتها فتُترك فارغة ولا تُملأ.",
    )

    val intradayNote = LocalizedString(
        en = "Your device samples often enough for an hour-by-hour view. BADAN doesn't compute one yet, so this is the daily trend.",
        ar = "يقيس جهازك بتكرار يكفي لعرض ساعة بساعة. لكن بدن لا يحسب ذلك بعد، لذا ما يظهر هنا هو الاتجاه اليومي.",
    )
}
