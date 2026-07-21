package net.albayyan.badan.designsystem.components

import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Numerals
import net.albayyan.badan.domain.Baseline

/**
 * The pure calibration model (mirror of the iOS `CalibrationProgress`). Compose-free so
 * `CalibrationStateTest` pins the day count and fraction exactly — the "Day 9 of 14" a set of inputs
 * produces must not depend on the view, and a JVM unit test loads this without the Compose runtime.
 *
 * BADAN renders nothing as a settled score until a baseline clears provisional, and this is the honest
 * "we're still getting to know you" state that carries the wait (plan §16 calibration view, §18 cold
 * start).
 *
 * [dayOf] is capped at [windowDays]: once enough points exist the copy reads "Day 14 of 14", never
 * "Day 21 of 14", which would read as broken. [fraction] is clamped to `0..1` for the same reason.
 */
data class CalibrationProgress(
    val nPoints: Int,
    val windowDays: Int,
) {
    /** The current calibration day, 1-based and capped at the window length; 0 when nothing yet. */
    val dayOf: Int get() = if (windowDays <= 0) 0 else nPoints.coerceIn(0, windowDays)

    /** Completion in `0..1`, clamped so a full-plus baseline never overflows the bar. */
    val fraction: Float
        get() = if (windowDays <= 0) 0f else (nPoints.toFloat() / windowDays.toFloat()).coerceIn(0f, 1f)

    /** True once the window is satisfied — the point past which the score can render for real. */
    val isComplete: Boolean get() = windowDays > 0 && nPoints >= windowDays

    companion object {
        /**
         * Read a baseline's calibration progress. A null baseline (none materialized yet) reads as
         * zero-of-[windowDaysFallback] rather than crashing — day one, not an error. [windowDaysFallback]
         * is the window the metric WILL calibrate over, so the "of 14" is honest before the first
         * baseline row exists.
         */
        fun from(baseline: Baseline?, windowDaysFallback: Int): CalibrationProgress =
            if (baseline == null) {
                CalibrationProgress(nPoints = 0, windowDays = windowDaysFallback)
            } else {
                CalibrationProgress(nPoints = baseline.nPoints, windowDays = baseline.windowDays.coerceAtLeast(1))
            }
    }
}

/** "Day 9 of 14" in the reader's language (Arabic-Indic digits handled by [Numerals]). */
fun calibrationDayLabel(progress: CalibrationProgress, language: AppLanguage, arabicDigits: Boolean): String {
    val day = Numerals.format(progress.dayOf, language, arabicDigits)
    val of = Numerals.format(progress.windowDays, language, arabicDigits)
    return if (language == AppLanguage.AR) "اليوم $day من $of" else "Day $day of $of"
}

/**
 * The reassurance line (plan §16 copy). States the principle plainly — BADAN waits until it knows you
 * before it estimates — so the wait reads as care, not as a broken feature.
 */
val calibrationDefaultMessage = LocalizedString(
    en = "We don't guess before we know you.",
    ar = "لا نُقدّر قبل أن نتعرّف عليك.",
)
