package net.albayyan.badan.features.healthmonitor

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.derivation.DeviationEngine
import net.albayyan.badan.domain.derivation.HealthMonitorReadModel
import net.albayyan.badan.domain.derivation.SparklinePoint
import net.albayyan.badan.domain.derivation.VitalReading
import net.albayyan.badan.domain.derivation.VitalTile
import net.albayyan.badan.ontology.SensorQualityLevel
import net.albayyan.badan.ontology.SensorQualityMap
import java.text.DateFormat
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.Date
import java.util.Locale

// The bilingual tile-state strings, the `vitalChip` mapping and `sparklineRange` live in
// `HealthMonitorModel.kt` so a JVM unit test asserts them without loading this Compose file.

// MARK: - Screen

/**
 * EPIC-27 — the Health Monitor (mirror of the iOS `HealthMonitorScreen`). A calm vitals dashboard:
 * one tile per tracked vital (RHR, HRV, respiratory rate, SpO2, wrist-temperature deviation) showing
 * the latest reading against the person's OWN usual range, a per-source sensor-quality label, a
 * gap-aware sparkline, and honest no-data/calibrating/stale states — never a population norm, never
 * an absolute skin temperature, never a fabricated zero.
 *
 * The read model is assembled by [DeviationEngine], constructed here from the environment's
 * repositories plus the bundled [SensorQualityMap] (the same in-screen construction `SourcesScreen`
 * uses for the quality contract) — this surface owns no engine state and writes nothing. The
 * "not a medical evaluation" footer is persistent and calm-amber only, as the plan's risk mitigation
 * requires.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HealthMonitorScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    // One process-wide immutable contract, read once (SourcesScreen pattern) — never a per-render load.
    val sensorQuality = remember(context) { SensorQualityMap.from(context.assets) }

    var state by remember { mutableStateOf<LoadState<HealthMonitorReadModel>>(LoadState.Loading) }

    LaunchedEffect(env.language, env.depth) {
        state = loadHealthMonitorAsync(env, sensorQuality)
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(HealthMonitorStrings.title),
                        style = BadanType.sectionTitle,
                        color = colors.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = { nav.pop() }) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = env.s(Loc.back),
                            tint = colors.textPrimary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                    navigationIconContentColor = colors.textPrimary,
                ),
            )
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(BadanSpace.s4),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
            ) {
                StatefulContainer(state) { model ->
                    Text(
                        text = env.s(HealthMonitorStrings.subtitle),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                    model.vitals.forEach { tile -> VitalTileCard(tile) }
                    // EPIC-34, below the vitals it is read alongside. Self-loading, and renders
                    // NOTHING it has not earned: on watch-class data the honest outcome is a hidden
                    // state naming the device fact in the way, and that is what the card shows.
                    StressCard()
                    // Persistent, mandatory, calm — the exact wording comes from the engine so it
                    // cannot drift between platforms or be forgotten by a view.
                    MedicalDisclaimerFooter(model.disclaimer)
                }
            }
        }
    }
}

// MARK: - Loader

private fun loadHealthMonitor(env: AppEnvironment, sensorQuality: SensorQualityMap): LoadState<HealthMonitorReadModel> =
    try {
        // The engine is a pure read model over baselines + latest readings; constructing it here (not
        // in AppEnvironment) keeps the composition root from growing a field for a surface-only reader.
        val engine = DeviationEngine(
            derivation = env.derivation,
            measurements = env.measurements,
            catalog = env.catalog,
            registry = env.registry,
            sensorQuality = sensorQuality,
            clock = env.clock,
        )
        val model = engine.buildReadModel(asOf = env.now())
        // Every tile with no reading means there is nothing to monitor yet — an honest empty screen,
        // not five "no reading" cards on first launch.
        if (model.vitals.all { it.reading == null }) {
            LoadState.Empty(env.s(HealthMonitorStrings.emptyMessage))
        } else {
            LoadState.Loaded(model)
        }
    } catch (t: Throwable) {
        LoadState.Error(env.s(healthMonitorLoadError))
    }

private suspend fun loadHealthMonitorAsync(env: AppEnvironment, sensorQuality: SensorQualityMap): LoadState<HealthMonitorReadModel> =
    withContext(Dispatchers.IO) { loadHealthMonitor(env, sensorQuality) }

private val healthMonitorLoadError = LocalizedString(
    en = "Something didn't load. Try again.",
    ar = "لم يتم تحميل شيء ما. حاول مرة أخرى.",
)

// MARK: - Tile

@Composable
private fun VitalTileCard(tile: VitalTile) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val power = env.depth.showsPowerDetail

    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.MetricDetail(tile.metricId)) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            // Header: family glyph + title, and the chip stating where the reading sits.
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = iconForKey(tile.family.symbolName),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    text = env.s(tile.title),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                vitalChip(tile.state)?.let { (status, label) ->
                    StatusChip(status = status, label = env.s(label))
                }
            }

            // The reading — an absolute value, a signed deviation, or an honest "no reading yet".
            Row(
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = readingText(env, tile),
                    style = BadanType.numeralM,
                    color = colors.textPrimary,
                )
                unitText(env, tile)?.let {
                    Text(
                        text = it,
                        style = BadanType.caption,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(bottom = 4.dp),
                    )
                }
            }

            // Staleness is stated, never hidden: an old reading is honestly "as of Tuesday".
            if (tile.isStale && tile.asOfDay != null) {
                Text(
                    text = env.s(HealthMonitorStrings.asOf.filling(mapOf("date" to formattedDay(tile.asOfDay!!, env.language)))),
                    style = BadanType.caption,
                    color = colors.outOfBand,
                )
            }

            // The calm out-of-range / above-usual note (already suppressed while stale by the engine).
            tile.annotation?.let {
                Text(text = env.s(it), style = BadanType.bodyCompact, color = colors.textSecondary)
            }

            // Gap-aware sparkline — a day the watch wasn't worn is a break in the line, not a zero.
            if (tile.sparkline.count { it.value != null } >= 2) {
                GapSparkline(points = tile.sparkline, modifier = Modifier.fillMaxWidth().height(32.dp))
            }

            // Per-source sensor quality — an honesty label about the instrument, never a verdict.
            tile.sourceQuality?.let { quality ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    PillLabel(
                        text = env.s(quality.level.label),
                        tint = sensorQualityTint(quality.level, colors),
                    )
                    Text(
                        text = env.s(HealthMonitorStrings.fromSource.filling(mapOf("source" to quality.sourceDisplayName))),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (power) {
                    Text(
                        text = env.s(quality.level.explainer),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }

            // Power altitude: the personal band edges + how many days fed it, and a calibration badge
            // while the band is still provisional (cold-start honesty).
            if (power) {
                tile.band?.let { band ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Text(
                            text = env.s(HealthMonitorStrings.usualRange),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            text = bandText(env, tile.metricId, band.low, band.high),
                            style = BadanType.monospaceDigits(BadanType.caption),
                            color = colors.textPrimary,
                        )
                    }
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Text(
                            text = "${env.format.integer(band.nPoints)} ${env.s(HealthMonitorStrings.daysUsed)}",
                            style = BadanType.monospaceDigits(BadanType.caption),
                            color = colors.textSecondary,
                        )
                        if (band.provisional) ProvisionalBadge(env.language)
                    }
                }
            }
        }
    }
}

// MARK: - Footer

/**
 * The mandatory "not a medical evaluation" footer (plan §11 EPIC-27 risk). Calm amber only — never
 * `critical` — because a typical-range notice is not an alarm. Persistent: rendered on every load of
 * this surface, with the exact wording owned by [DeviationEngine.disclaimer].
 */
@Composable
private fun MedicalDisclaimerFooter(disclaimer: LocalizedString) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.outOfBand.copy(alpha = 0.10f))
            .border(1.dp, colors.outOfBand.copy(alpha = 0.30f), shape)
            .padding(BadanSpace.cardPadding),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.HealthAndSafety,
            contentDescription = null,
            tint = colors.outOfBand,
            modifier = Modifier.size(20.dp),
        )
        Text(
            text = env.s(disclaimer),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

// MARK: - Gap-aware sparkline

/**
 * A sparkline that BREAKS at missing days rather than bridging them — a gap is drawn as a gap, never
 * interpolated and never zero-filled (plan §18). Stays visually LTR so time reads left-to-right under
 * RTL, matching [net.albayyan.badan.designsystem.components.MetricSparkline].
 */
@Composable
private fun GapSparkline(points: List<SparklinePoint>, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    val range = remember(points) { sparklineRange(points) }
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Canvas(modifier = modifier) {
            val r = range ?: return@Canvas
            val (minV, span) = r
            val w = size.width
            val h = size.height
            val n = points.size
            if (n < 2) return@Canvas
            var run: Path? = null
            points.forEachIndexed { index, p ->
                val v = p.value
                if (v == null) {
                    // Close the current run at the gap so the line does not leap the missing day.
                    run = null
                    return@forEachIndexed
                }
                val x = index.toFloat() / (n - 1).toFloat() * w
                val y = h - ((v - minV) / span).toFloat() * h
                val path = run
                if (path == null) {
                    run = Path().apply { moveTo(x, y) }
                } else {
                    path.lineTo(x, y)
                    drawPath(
                        path = path,
                        color = colors.primary,
                        style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
                    )
                }
                // A lone present point between two gaps has no segment to draw — mark it with a dot so
                // an isolated reading is still visible.
                val prevMissing = index == 0 || points[index - 1].value == null
                val nextMissing = index == n - 1 || points[index + 1].value == null
                if (prevMissing && nextMissing) {
                    drawCircle(color = colors.primary, radius = 2.dp.toPx(), center = Offset(x, y))
                }
            }
        }
    }
}

// MARK: - Value formatting helpers

private fun readingText(env: AppEnvironment, tile: VitalTile): String = when (val r = tile.reading) {
    null -> "—"
    is VitalReading.Absolute -> env.format.heroValue(tile.metricId, r.value)
    // Temperature deviation: a SIGNED value, never an absolute skin temperature — the sign is the
    // whole point, so it is always shown.
    is VitalReading.Deviation -> {
        val sign = if (r.value > 0) "+" else if (r.value < 0) "−" else ""
        "$sign${env.format.number(kotlin.math.abs(r.value), 1)}"
    }
}

private fun unitText(env: AppEnvironment, tile: VitalTile): String? = when (tile.reading) {
    is VitalReading.Absolute -> env.format.unitLabel(tile.metricId)
    // Temperature deviation is shown in degrees; the canonical unit label ("degC") would read oddly
    // beside a signed delta, so the degree sign carries it.
    is VitalReading.Deviation -> "°${if (tile.unit == "degF") "F" else "C"}"
    null -> null
}

private fun bandText(env: AppEnvironment, metricId: String, low: Double, high: Double): String {
    val lo = env.format.heroValue(metricId, low)
    val hi = env.format.heroValue(metricId, high)
    val unit = env.format.unitLabel(metricId)
    return if (unit != null) "$lo – $hi $unit" else "$lo – $hi"
}

private fun sensorQualityTint(level: SensorQualityLevel, colors: net.albayyan.badan.designsystem.BadanColors) = when (level) {
    SensorQualityLevel.HIGH -> colors.inBand
    SensorQualityLevel.MEDIUM -> colors.textSecondary
    // One calm amber for "tells you less", never critical — a sensor is not an alarm (SourcesScreen rule).
    SensorQualityLevel.LOW, SensorQualityLevel.UNSUPPORTED -> colors.outOfBand
}

/** "YYYY-MM-DD" → a medium localized date; falls back to the raw key if it is not a valid date. */
private fun formattedDay(dayKey: String, language: AppLanguage): String {
    val parts = dayKey.split("-").mapNotNull { it.toIntOrNull() }
    if (parts.size != 3) return dayKey
    val millis = runCatching {
        LocalDate.of(parts[0], parts[1], parts[2]).atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    }.getOrNull() ?: return dayKey
    val fmt = DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.forLanguageTag(language.localeTag))
    return fmt.format(Date(millis))
}
