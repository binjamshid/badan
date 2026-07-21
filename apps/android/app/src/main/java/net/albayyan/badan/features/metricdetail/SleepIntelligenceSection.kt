package net.albayyan.badan.features.metricdetail

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.Hypnogram
import net.albayyan.badan.designsystem.components.MetricSparkline
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.buildHypnogram
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.derivation.SleepSpec
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.TimeZone
import kotlin.math.max
import kotlin.math.min

// MARK: - Strings

private object SleepSectionStrings {
    val sleepStages = LocalizedString(en = "Sleep stages", ar = "مراحل النوم")
    val noStages = LocalizedString(
        en = "This source didn't record sleep stages for this night — the totals above still hold.",
        ar = "لم يسجّل هذا المصدر مراحل النوم لهذه الليلة — لكن الإجماليات أعلاه لا تزال صحيحة.",
    )
    val needVsActual = LocalizedString(en = "Last night vs your need", ar = "الليلة الماضية مقارنةً بحاجتك")
    val youSlept = LocalizedString(en = "You slept", ar = "نمت")
    val estimatedNeed = LocalizedString(en = "Estimated need", ar = "الحاجة المقدّرة")
    val performance = LocalizedString(en = "Sleep performance", ar = "أداء النوم")
    val debtTrend = LocalizedString(en = "Sleep debt", ar = "دَيْن النوم")
    val debtCaption = LocalizedString(
        en = "Accumulated shortfall over recent nights — it decays as you catch up.",
        ar = "العجز المتراكم عبر الليالي الأخيرة — يتناقص كلما عوّضت.",
    )
}

// MARK: - Loaded data

/**
 * Everything the sleep-intelligence section needs for one night, gathered once off the main thread.
 * Every field is nullable because a night may have a hypnogram but no need estimate yet (cold start),
 * or a need estimate but an unstaged source — the section renders exactly the parts it has.
 */
internal data class SleepIntelligenceData(
    val stages: List<SessionStage>,
    val actualAsleepSeconds: Double?,
    val need: DerivedValue?,
    val performance: DerivedValue?,
    val debtSeries: List<Double>,
)

// MARK: - Section

/**
 * EPIC-24 sleep detail (mirror of the iOS `SleepIntelligenceSection`): the hypnogram, a need-vs-actual
 * bar (need shown as an honest RANGE, never fake-exact minutes), and a debt trend. Rendered inline in
 * the metric detail for `sleep.time_asleep` only; a no-op for every other metric, so the shared detail
 * screen wires it with a single call and no branch.
 *
 * It runs its own small off-thread load rather than threading sleep state through the shared
 * `MetricDetailData`, keeping the score-surface concern self-contained. The published sleep constants
 * ([SleepSpec]) are read as DATA to render the need range with the same half-width the engine used —
 * the surface reproduces the published band, it does not invent one.
 */
@Composable
fun SleepIntelligenceSection(metricId: String) {
    if (metricId != MetricId.timeAsleep) return
    val env = LocalAppEnvironment.current
    val spec = remember { SleepSpec.default() }
    var data by remember { mutableStateOf<SleepIntelligenceData?>(null) }

    LaunchedEffect(metricId) {
        data = withContext(Dispatchers.IO) { loadSleepIntelligence(env) }
    }

    val d = data ?: return
    // Nothing to add beyond the standard chart if this night has neither stages nor a need estimate.
    if (d.stages.isEmpty() && d.need == null && d.performance == null && d.debtSeries.isEmpty()) return

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
        HypnogramCard(d)
        if (d.need != null && d.actualAsleepSeconds != null) {
            NeedVsActualCard(d, spec)
        }
        if (d.debtSeries.size >= 2) {
            DebtTrendCard(d.debtSeries)
        }
    }
}

// MARK: - Hypnogram

@Composable
private fun HypnogramCard(data: SleepIntelligenceData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val model = remember(data.stages) { buildHypnogram(data.stages) }
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(SleepSectionStrings.sleepStages))
            if (model.hasStagedSleep) {
                Hypnogram(model = model, language = env.language)
            } else {
                Text(
                    text = env.s(SleepSectionStrings.noStages),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Need vs actual

@Composable
private fun NeedVsActualCard(data: SleepIntelligenceData, spec: SleepSpec) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val actual = data.actualAsleepSeconds ?: return
    val needValue = data.need ?: return
    val range = remember(needValue, spec) {
        needRangeDisplay(needValue.value, needValue.confidence ?: 1.0, spec)
    }
    val axisMax = max(range.highSeconds, actual) * 1.05

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(
                title = env.s(SleepSectionStrings.needVsActual),
                trailing = if (needValue.provisional) {
                    { ProvisionalBadge(env.language) }
                } else {
                    null
                },
            )
            NeedActualBar(
                actualFraction = (actual / axisMax).toFloat().coerceIn(0f, 1f),
                needLowFraction = (range.lowSeconds / axisMax).toFloat().coerceIn(0f, 1f),
                needHighFraction = (range.highSeconds / axisMax).toFloat().coerceIn(0f, 1f),
                needCenterFraction = (range.centerSeconds / axisMax).toFloat().coerceIn(0f, 1f),
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
                LabelledValue(
                    label = env.s(SleepSectionStrings.youSlept),
                    value = env.format.duration(actual),
                )
                LabelledValue(
                    label = env.s(SleepSectionStrings.estimatedNeed),
                    value = needRangeText(range, env),
                )
            }
            data.performance?.let { perf ->
                val capped = min(perf.value, if (spec.isLoaded) spec.upperBoundPercent else 100.0)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(
                        text = env.s(SleepSectionStrings.performance),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        text = "${env.format.number(capped, 0)}%",
                        style = BadanType.monospaceDigits(BadanType.body),
                        color = colors.textPrimary,
                    )
                }
            }
        }
    }
}

/**
 * The need-vs-actual bar: a soft track, the need RANGE drawn as a shaded band with a centre tick, and
 * the actual sleep as a filled bar. No good/bad colour — the band is the in-band tint, the fill is
 * primary; where the fill lands relative to the band is the whole message, stated without judgment.
 */
@Composable
private fun NeedActualBar(
    actualFraction: Float,
    needLowFraction: Float,
    needHighFraction: Float,
    needCenterFraction: Float,
) {
    val colors = BadanTheme.colors
    Box(modifier = Modifier.fillMaxWidth().height(28.dp)) {
        Canvas(modifier = Modifier.fillMaxWidth().height(28.dp)) {
            val w = size.width
            val h = size.height
            val radius = CornerRadius(6.dp.toPx(), 6.dp.toPx())
            // Track.
            drawRoundRect(color = colors.surfaceElevated, cornerRadius = radius)
            // Need band (shaded).
            val bandLeft = (needLowFraction * w).coerceIn(0f, w)
            val bandRight = (needHighFraction * w).coerceIn(0f, w)
            drawRoundRect(
                color = colors.inBand.copy(alpha = 0.18f),
                topLeft = Offset(bandLeft, 0f),
                size = Size((bandRight - bandLeft).coerceAtLeast(0f), h),
                cornerRadius = radius,
            )
            // Actual fill.
            drawRoundRect(
                color = colors.primary.copy(alpha = 0.55f),
                topLeft = Offset(0f, h * 0.28f),
                size = Size((actualFraction * w).coerceIn(0f, w), h * 0.44f),
                cornerRadius = CornerRadius(4.dp.toPx(), 4.dp.toPx()),
            )
            // Need centre tick.
            val cx = (needCenterFraction * w).coerceIn(0f, w)
            drawRoundRect(
                color = colors.inBand,
                topLeft = Offset((cx - 1.dp.toPx()).coerceIn(0f, w), 0f),
                size = Size(2.dp.toPx(), h),
            )
        }
    }
}

@Composable
private fun LabelledValue(label: String, value: String) {
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(text = label, style = BadanType.caption, color = colors.textSecondary)
        Text(
            text = value,
            style = BadanType.monospaceDigits(BadanType.body),
            color = colors.textPrimary,
        )
    }
}

// MARK: - Debt trend

@Composable
private fun DebtTrendCard(debtSeconds: List<Double>) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(SleepSectionStrings.debtTrend))
            // Debt shown in hours so the sparkline's shape reads at a human scale; gaps between nights
            // are already absent from the derived series (only computed nights appear).
            MetricSparkline(values = debtSeconds.map { it / 3600.0 }, modifier = Modifier.height(40.dp))
            Text(
                text = env.s(SleepSectionStrings.debtCaption),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Loader

private fun loadSleepIntelligence(env: AppEnvironment): SleepIntelligenceData {
    val tz = TimeZone.getDefault().id
    val now = env.now()
    val nightKey = DayAttribution.localNight(sessionEndMillis = now, tz = tz)
    val session = env.measurements.primarySleep(nightKey)
    val resolvedNight = session?.localNight ?: nightKey

    val stages = session?.let { env.measurements.stages(it.id) } ?: emptyList()
    val actual = session?.let { it.detail.timeAsleepSeconds ?: it.durationSeconds }

    val need = env.derivation.latestDerived(MetricId.sleepNeed, "day:$resolvedNight")
    val performance = env.derivation.latestDerived(MetricId.sleepPerformance, "day:$resolvedNight")
    val debtSeries = env.derivation.latestDerivedSeries(MetricId.sleepDebt)
        .takeLast(14)
        .map { it.value }

    return SleepIntelligenceData(
        stages = stages,
        actualAsleepSeconds = actual,
        need = need,
        performance = performance,
        debtSeries = debtSeries,
    )
}

// MARK: - Copy helper

// The pure `needRangeDisplay`/`NeedRangeDisplay` live in `SleepIntelligenceModel.kt` so a JVM unit
// test asserts the published range reconstruction without loading this Compose file.

/** The need shown as a range ("7h 20m – 8h 10m") when confidence is low, else the centre alone. */
private fun needRangeText(range: NeedRangeDisplay, env: AppEnvironment): String =
    if (range.showRange) {
        "${env.format.duration(range.lowSeconds)} – ${env.format.duration(range.highSeconds)}"
    } else {
        env.format.duration(range.centerSeconds)
    }
