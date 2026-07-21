package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.domain.SessionStage
import net.albayyan.badan.domain.SleepStage

// The pure model (`buildHypnogram`, `HypnogramModel`, `HYPNOGRAM_LANES`) lives in `HypnogramModel.kt`
// so a JVM unit test can assert it without loading this Compose file — same split the engines use.

// MARK: - Component

/**
 * A calm, lane-based hypnogram (mirror of the iOS `Hypnogram`). Each depth lane (awake → REM → light
 * → deep) is a labelled track; the stage's episodes are drawn as soft blocks at their position across
 * the night. Time reads left-to-right even under RTL — the track is a timeline, and a night does not
 * run backwards in Arabic — so the plotting area is pinned LTR while the surrounding labels mirror.
 *
 * Colour is never the only signal: every lane carries its stage name and its total duration, so the
 * chart is legible without relying on hue (design-system rule). The stage palette is drawn from the
 * existing tokens — one calm family, no moralising red/green — never a "good/bad" depth.
 *
 * When [stages] carries no staged sleep (an unstaged source), the caller should render
 * [model.hasStagedSleep] == false as an honest "stage detail isn't available" note instead of this —
 * this composable draws only what the source actually recorded.
 */
@Composable
fun Hypnogram(
    stages: List<SessionStage>,
    language: AppLanguage,
    modifier: Modifier = Modifier,
) {
    val model = remember(stages) { buildHypnogram(stages) }
    Hypnogram(model = model, language = language, modifier = modifier)
}

@Composable
fun Hypnogram(
    model: HypnogramModel,
    language: AppLanguage,
    modifier: Modifier = Modifier,
) {
    val colors = BadanTheme.colors
    val summary = remember(model, language) { hypnogramSummary(model, language) }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .semantics { contentDescription = summary },
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        HYPNOGRAM_LANES.forEach { stage ->
            val laneSegments = model.segments.filter { it.stage == stage }
            val tint = stageColor(stage)
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                // The stage name is the lane's label AND the legend — pairing hue with a word so the
                // chart never leans on colour alone.
                Row(
                    modifier = Modifier.width(72.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Canvas(modifier = Modifier.size(8.dp)) {
                        drawRoundRect(color = tint, cornerRadius = CornerRadius(2.dp.toPx(), 2.dp.toPx()))
                    }
                    Text(
                        text = stage.displayName.resolved(language),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
                // The lane track — pinned LTR so episodes plot along the true timeline in both
                // directions; Canvas coordinates are absolute and are not mirrored by layout.
                CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                    Canvas(
                        modifier = Modifier
                            .weight(1f)
                            .height(16.dp)
                            .clip(RoundedCornerShape(BadanRadius.chip)),
                    ) {
                        // The lane's faint bed, so an empty lane still reads as a track, not a void.
                        drawRoundRect(
                            color = colors.surfaceElevated,
                            cornerRadius = CornerRadius(4.dp.toPx(), 4.dp.toPx()),
                        )
                        val w = size.width
                        val h = size.height
                        laneSegments.forEach { seg ->
                            val x = (seg.startFraction * w).coerceIn(0f, w)
                            val segW = (seg.widthFraction * w).coerceAtLeast(1.5.dp.toPx())
                            drawRoundRect(
                                color = tint,
                                topLeft = Offset(x.coerceAtMost((w - segW).coerceAtLeast(0f)), 0f),
                                size = Size(segW.coerceAtMost(w), h),
                                cornerRadius = CornerRadius(3.dp.toPx(), 3.dp.toPx()),
                            )
                        }
                    }
                }
                Text(
                    text = laneDuration(model.stageSeconds[stage] ?: 0.0, language),
                    style = BadanType.monospaceDigits(BadanType.caption),
                    color = colors.textSecondary,
                    modifier = Modifier.width(52.dp),
                )
            }
        }
    }
}

// MARK: - Stage palette

/**
 * One calm colour per lane, drawn from the existing token family — deep is the fullest [primary],
 * light a softened [primary], REM the [info] blue, awake the neutral [textSecondary]. No red/green,
 * no "good/bad" depth: the hypnogram describes structure, it does not grade it.
 */
@Composable
private fun stageColor(stage: SleepStage): Color {
    val colors = BadanTheme.colors
    return when (stage) {
        SleepStage.DEEP -> colors.primary
        SleepStage.LIGHT -> colors.primary.copy(alpha = 0.5f)
        SleepStage.REM -> colors.info
        SleepStage.AWAKE -> colors.textSecondary
        SleepStage.IN_BED, SleepStage.ASLEEP_UNSPECIFIED -> colors.textSecondary.copy(alpha = 0.4f)
    }
}

// MARK: - Copy helpers (bilingual)

private fun laneDuration(seconds: Double, language: AppLanguage): String {
    if (seconds <= 0) return "—"
    val total = seconds.toInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    val hLabel = if (language == AppLanguage.AR) "س" else "h"
    val mLabel = if (language == AppLanguage.AR) "د" else "m"
    return if (h == 0) "$m$mLabel" else "$h$hLabel $m$mLabel"
}

private val hypnogramNoStages = LocalizedString(
    en = "Sleep stages aren't available for this night.",
    ar = "تفاصيل مراحل النوم غير متوفرة لهذه الليلة.",
)

private val hypnogramSummaryTemplate = LocalizedString(
    en = "Sleep stage chart. {stages}.",
    ar = "مخطط مراحل النوم. {stages}.",
)

/** An accessibility summary that names each present lane and its duration, in reading order. */
private fun hypnogramSummary(model: HypnogramModel, language: AppLanguage): String {
    if (!model.hasStagedSleep) return hypnogramNoStages.resolved(language)
    val parts = HYPNOGRAM_LANES.mapNotNull { stage ->
        val secs = model.stageSeconds[stage] ?: 0.0
        if (secs <= 0) null else "${stage.displayName.resolved(language)} ${laneDuration(secs, language)}"
    }
    return hypnogramSummaryTemplate.filling(mapOf("stages" to parts.joinToString("، "))).resolved(language)
}
