package net.albayyan.badan.features.healthmonitor

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.ChartStyle
import net.albayyan.badan.designsystem.components.ContextCaveatNote
import net.albayyan.badan.designsystem.components.MetricChart
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.designsystem.components.iconForKey
import androidx.compose.foundation.layout.height
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.domain.journal.ContextCaveats
import net.albayyan.badan.domain.derivation.StressDensityState
import net.albayyan.badan.domain.derivation.StressEngine
import net.albayyan.badan.domain.derivation.StressSpec
import net.albayyan.badan.domain.derivation.StressSurface
import java.util.TimeZone

/**
 * EPIC-34 — the stress surface, under the Health Monitor. **The gate is the feature.** Mirror of the
 * iOS `StressTrendCard`.
 *
 * The card renders exactly the three states [StressSurface] can express and cannot assemble a
 * fourth, because the type is sealed and carries its payload:
 *
 * * **Hidden** — the engine's own explanation, which is always a statement about what the DEVICE
 *   records ("your device doesn't record daytime heart-rate variability often enough for this").
 *   Never phrased as the user having done something wrong, never as BADAN having failed, and never
 *   styled as an error — no warning tint, no retry, no red. This is the default for watch-only data
 *   and it is a shipped state, not an empty one. It shows no density numbers even at power depth,
 *   because `Hidden` holds no `StressDensity` at all — nothing downstream can rebuild a reading out
 *   of a surface that was refused.
 * * **Moderate** — a daily, explicitly low-confidence trend. Casual gets a direction word and one
 *   sentence; the number itself is power-only, because a 0–100 index printed large beside sparse
 *   sampling is precisely the false precision this epic exists to refuse.
 * * **Dense** — the same daily trend plus an honest note that the hour-by-hour view is not computed
 *   in this build ([StressEngine.INTRADAY_INDEX_IMPLEMENTED] is false, in code, not in a comment).
 *
 * **There is no live number here and no code path that could produce one.** Every rendered value
 * comes from a `StressTrend`, which carries the window it describes and no timestamp at all, and the
 * window is printed on the card at every altitude.
 *
 * The read path is [StressEngine.evaluate], which WRITES NOTHING — the correct entry point for a
 * surface whose common answer is "hidden". An absence is not stored as a zero, a null row or a
 * sentinel; persisting a trend is the derivation pipeline's job, not a screen's.
 */
@Composable
internal fun StressCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val tz = remember { TimeZone.getDefault().id }
    var data by remember { mutableStateOf<StressCardData?>(null) }

    // Evaluated once per visit: a `StressSurface` is bilingual by construction (its band words and
    // its absence explanation are `LocalizedString`s carrying both languages), and depth only
    // decides whether the number is drawn beside the sentence. Neither toggle re-runs the gate —
    // one evaluation stands behind every rendering of it.
    LaunchedEffect(Unit) {
        data = withContext(Dispatchers.IO) { loadStressCard(env, tz) }
    }

    val loaded = data ?: return
    val resolved = loaded.surface
    val trend = resolved.trend
    val spoken = StressPresentation.spokenLabel(
        resolved, env.depth, env.language, env.format, tz, loaded.caveats,
    )

    BadanCard(
        // One accessibility stop for the card, read as a phrase: the stat lines below are dense
        // punctuation that a screen reader would otherwise spell out symbol by symbol.
        modifier = Modifier.clearAndSetSemantics { contentDescription = spoken },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = iconForKey(MetricFamily.STRESS.symbolName),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    text = env.s(StressStrings.title),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                trend?.let {
                    val (status, label) = StressPresentation.chipSpec(it.band)
                    StatusChip(status = status, label = env.s(label))
                }
            }

            if (trend == null) {
                // Calm and factual, and deliberately plain. There is nothing for the user to fix, so
                // offering an action would imply there is.
                resolved.absenceReason?.let { reason ->
                    Text(
                        text = env.s(reason.explanation),
                        style = BadanType.body,
                        color = colors.textPrimary,
                    )
                }
            } else {
                Text(
                    text = env.s(StressPresentation.sentence(trend.band)),
                    style = BadanType.body,
                    color = colors.textPrimary,
                )
                // The window, always. This is the line that stops a daily trend from being read as a
                // live number, so it is neither power-gated nor optional.
                Text(
                    text = StressPresentation.windowNote(trend, env.language, env.format, tz),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
                if (trend.provisional) ProvisionalBadge(env.language)
                if (trend.densityState == StressDensityState.DENSE) {
                    Text(
                        text = env.s(StressStrings.intradayNote),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
                // EPIC-29: "computed while you were travelling". Below the trend body so it frames
                // everything above it; nothing on an ordinary day, and nothing on a hidden day
                // (there is no reading to frame).
                ContextCaveatNote(caveats = loaded.caveats, language = env.language)
                if (env.depth.showsPowerDetail) {
                    // Stat lines stay visually left-to-right in both languages: "50 of 100 · 0.42"
                    // is a technical fragment, not prose, and mirroring it moves the separators off
                    // the values they belong to (the rule `InsightsScreen`'s detail rows follow).
                    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                            Text(
                                text = StressPresentation.powerLine(trend, env.language, env.format),
                                style = BadanType.monospaceDigits(BadanType.caption),
                                color = colors.textSecondary,
                            )
                            Text(
                                text = StressPresentation.densityLine(trend.density, env.language, env.format),
                                style = BadanType.monospaceDigits(BadanType.caption),
                                color = colors.textSecondary,
                            )
                        }
                    }
                }
                // The persisted history the derivation pipeline wrote. Only shown once there is more
                // than one day of it — a "history" of a single point is a number with a chart drawn
                // round it. Days the gate refused are absent from the series and stay absent: the
                // line spans fewer points, never a zero-filled dip that would read as a calm day.
                if (loaded.history.size > 1) {
                    MetricChart(
                        series = loaded.history,
                        style = ChartStyle.Line,
                        language = env.language,
                        modifier = Modifier.height(64.dp),
                    )
                    Text(
                        text = StressPresentation.historyNote(loaded.history.size, env.language, env.format),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

/**
 * What the card renders: today's surface state, the persisted history behind it, and any caveat for
 * the day it describes. Mirror of the iOS `StressCardData`.
 *
 * The two halves answer different questions and neither can answer the other's. [surface] is the
 * GATE's verdict — including, on a hidden day, the reason — and no stored row can express that (a
 * hidden day writes nothing at all, by design). [history] is what the derivation pipeline actually
 * persisted: the `stress.day_trend` rows that make this a trend with a past rather than a number
 * recomputed from scratch on every open.
 */
internal data class StressCardData(
    val surface: StressSurface,
    /** Persisted rows over the recent window as (dayStartMillis, value), oldest first. */
    val history: List<Pair<Long, Double>>,
    /** EPIC-29 caveats for the day the surface describes. Empty on an ordinary day. */
    val caveats: List<LocalizedString>,
)

/** How many recent days of persisted trend the card shows behind today's value. Short on purpose:
 *  the trend value already describes a multi-day span. */
private const val STRESS_HISTORY_DAYS = 14

/**
 * Evaluate the gate for today, read the history the pipeline persisted, and resolve any caveat.
 *
 * A read failure returns null and the card does not appear — deliberately NOT mapped onto one of the
 * absence reasons, since every one of those is a specific, checkable claim about the device's
 * sampling or about this build, and a transient storage error is neither.
 */
private fun loadStressCard(env: AppEnvironment, tz: String): StressCardData? = runCatching {
    val surface = evaluateStress(env, tz) ?: return@runCatching null
    val earliest = DayAttribution.addingDays(
        -(STRESS_HISTORY_DAYS - 1), DayAttribution.startOfDay(env.now(), tz), tz,
    )
    val history = env.derivation.latestDerivedSeries(MetricId.stressDayTrend)
        .mapNotNull { row ->
            if (!row.periodKey.startsWith("day:")) return@mapNotNull null
            val day = DayAttribution.dateFromDayKey(row.periodKey.removePrefix("day:"), tz)
                ?: return@mapNotNull null
            if (day < earliest) null else day to row.value
        }
        .sortedBy { it.first }
    // A hidden day has no value to frame, so it gets no caveat either — the card is already saying
    // nothing about the person's pattern.
    val caveats = if (surface.trend != null && env.profile.sensitiveModulesEnabled) {
        ContextCaveats.forDay(env.now(), tz, env.contextAnnotations)
    } else {
        emptyList()
    }
    StressCardData(surface, history, caveats)
}.getOrNull()

/**
 * Evaluate the gate for today. Constructed per read rather than held on `AppEnvironment`, matching
 * `DeviationEngine` on this same screen: a surface-only reader should not grow a field in the
 * composition root. [StressSpec.default] resolves the published constants once per process from the
 * classpath contract mirror — never a hardcoded threshold.
 *
 * A read failure returns null and the card does not appear. Deliberately NOT mapped onto one of the
 * absence reasons: every one of those is a specific, checkable claim about the device's sampling or
 * about this build, and a transient storage error is neither. Saying nothing is the only honest
 * thing left.
 */
private fun evaluateStress(env: AppEnvironment, tz: String): StressSurface? = runCatching {
    StressEngine(
        derivation = env.derivation,
        measurements = env.measurements,
        registry = env.registry,
        clock = env.clock,
        deviceId = env.deviceId,
        spec = StressSpec.default(),
    ).evaluate(env.now(), tz)
}.getOrNull()
