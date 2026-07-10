package net.albayyan.badan.features.body

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.MetricSparkline
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.MetricKind
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.TimeZone

// MARK: - Model

/**
 * One pillar shown on the Body front door: a family, its headline metric, and just enough data
 * to render a calm value + status word + recent-trend sparkline. Mirror of the iOS `BodyPillar`.
 */
private data class BodyPillar(
    val family: MetricFamily,
    val metricId: String,
    val latest: Double,
    val values: List<Double>,   // chronological; last == most recent (for the sparkline)
    val baseline: Baseline?,
)

private data class BodyData(val pillars: List<BodyPillar>)

// MARK: - Loading (mirror of iOS BodyViewModel)

/**
 * Headline metric preference per family; falls back to any baseline-eligible metric that
 * actually carries data. Same data, curated altitude — never a second dataset.
 */
private val headlineCandidates: Map<MetricFamily, List<String>> = mapOf(
    MetricFamily.SLEEP to listOf(MetricId.timeAsleep, MetricId.sleepEfficiency),
    MetricFamily.HEART to listOf(MetricId.restingHeartRate, MetricId.hrv, MetricId.heartRate),
    MetricFamily.ACTIVITY to listOf(MetricId.steps, MetricId.activeEnergy, MetricId.distance, MetricId.exerciseMinutes),
    MetricFamily.BODY to listOf(MetricId.weight, MetricId.bmi),
    MetricFamily.RESPIRATORY to listOf(MetricId.respiratoryRate, MetricId.spo2),
    MetricFamily.NUTRITION to listOf(MetricId.energyIn, MetricId.protein, MetricId.water),
)

private fun loadBodyData(env: AppEnvironment): BodyData =
    BodyData(pillars = env.registry.families.mapNotNull { makePillar(env, it) })

private fun makePillar(env: AppEnvironment, family: MetricFamily): BodyPillar? {
    val candidates = LinkedHashSet<String>()
    headlineCandidates[family]?.forEach { candidates.add(it) }
    env.registry.metrics(family).filter { it.baselineEligible }.forEach { candidates.add(it.metricId) }

    for (metricId in candidates) {
        val series = recentSeries(env, metricId, windowDays = 12)
        val latest = series.lastOrNull()?.second ?: continue
        val baseline = runCatching { env.derivation.latestBaseline(metricId) }.getOrNull()
        return BodyPillar(
            family = family,
            metricId = metricId,
            latest = latest,
            values = series.takeLast(7).map { it.second },
            baseline = baseline,
        )
    }
    return null
}

/**
 * Recent daily-ish series for a metric, tried across the three stores it might live in: derived
 * rollups, interval records (latest per local day), then raw samples. Returns (epoch-millis,
 * value) points sorted ascending by time.
 */
private fun recentSeries(env: AppEnvironment, metricId: String, windowDays: Int): List<Pair<Long, Double>> {
    val now = env.now()
    val from = now - windowDays.toLong() * 86_400_000L
    val def = env.registry.definitionOrFallback(metricId)

    if (def.kind == MetricKind.DERIVED) {
        val pts = derivedSeries(env, metricId, from)
        if (pts.isNotEmpty()) return pts
    }

    val intervals = runCatching { env.measurements.intervalRecords(metricId, from, now) }.getOrDefault(emptyList())
    if (intervals.isNotEmpty()) {
        val byDay = LinkedHashMap<String, Pair<Long, Double>>()
        for (r in intervals) {
            val key = DayAttribution.localDayKey(r.startAt, r.tzId)
            val existing = byDay[key]
            if (existing != null && existing.first >= r.startAt) continue
            byDay[key] = r.startAt to r.value
        }
        val pts = byDay.keys.sorted().mapNotNull { byDay[it] }
        if (pts.isNotEmpty()) return pts
    }

    val raws = runCatching { env.measurements.rawSamples(metricId, from, now) }.getOrDefault(emptyList())
    if (raws.isNotEmpty()) {
        return raws.map { it.startAt to it.value }.sortedBy { it.first }
    }

    return derivedSeries(env, metricId, from)
}

private fun derivedSeries(env: AppEnvironment, metricId: String, from: Long): List<Pair<Long, Double>> {
    val values = runCatching { env.derivation.latestDerivedSeries(metricId) }.getOrDefault(emptyList())
    if (values.isEmpty()) return emptyList()
    val tz = TimeZone.getDefault().id
    return values
        .map { dv ->
            val key = if (dv.periodKey.startsWith("day:")) dv.periodKey.removePrefix("day:") else dv.periodKey
            val date = DayAttribution.dateFromDayKey(key, tz) ?: dv.computedAt
            date to dv.value
        }
        .filter { it.first >= from }
        .sortedBy { it.first }
}

// MARK: - Screen

private val pillarsHeader = LocalizedString(en = "Your systems", ar = "أنظمتك")
private val browseHeader = LocalizedString(en = "Browse everything", ar = "تصفّح كل شيء")

/**
 * "Your body" — the repository front door. Each family with data becomes a calm pillar that
 * leads into the universal metric detail; below, the tools that open the whole repository.
 * Mirror of the iOS `BodyScreen`.
 */
@Composable
fun BodyScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors

    var state by remember { mutableStateOf<LoadState<BodyData>>(LoadState.Loading) }
    var showAllMetrics by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val data = withContext(Dispatchers.IO) { loadBodyData(env) }
        state = LoadState.Loaded(data)
    }

    Box(modifier = Modifier.fillMaxSize().background(colors.background)) {
        StatefulContainer(state) { data ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(BadanSpace.s4),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
            ) {
                if (data.pillars.isNotEmpty()) {
                    SectionHeader(env.s(pillarsHeader))
                    data.pillars.forEach { pillar ->
                        BodyPillarCard(pillar) { nav.push(Route.MetricDetail(pillar.metricId)) }
                    }
                }

                SectionHeader(
                    title = env.s(browseHeader),
                    modifier = Modifier.padding(top = if (data.pillars.isNotEmpty()) BadanSpace.s2 else 0.dp),
                )
                BodyToolsCard(
                    showAllMetrics = showAllMetrics,
                    onToggleAllMetrics = { showAllMetrics = !showAllMetrics },
                    onSources = { nav.push(Route.Sources) },
                    onExport = { nav.push(Route.Export) },
                    onTimeline = { nav.push(Route.Timeline) },
                )

                if (showAllMetrics) {
                    BodyAllMetricsBrowser()
                }
            }
        }
    }
}

// MARK: - Pillar card

@Composable
private fun BodyPillarCard(pillar: BodyPillar, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    BadanCard(modifier = Modifier.clickable(onClick = onClick)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s4),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Icon(
                        imageVector = iconForKey(pillar.family.symbolName),
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(
                        text = env.s(pillar.family.displayName),
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                }

                Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                    Text(
                        text = env.format.heroValue(pillar.metricId, pillar.latest),
                        style = BadanType.numeralM,
                        color = colors.textPrimary,
                        modifier = Modifier.alignByBaseline(),
                    )
                    val unit = env.format.unitLabel(pillar.metricId)
                    if (!unit.isNullOrEmpty()) {
                        Text(
                            text = unit,
                            style = BadanType.bodyCompact,
                            color = colors.textSecondary,
                            modifier = Modifier.alignByBaseline(),
                        )
                    }
                }

                val (status, label) = pillarStatus(pillar)
                StatusChip(status = status, label = env.s(label))
            }

            if (pillar.values.size >= 2) {
                MetricSparkline(
                    values = pillar.values,
                    modifier = Modifier.width(76.dp).height(36.dp),
                )
            }

            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/**
 * Position over the personal band, never good/bad. A provisional or missing baseline stays
 * honest with a "still learning" info state.
 */
private fun pillarStatus(pillar: BodyPillar): Pair<ChipStatus, LocalizedString> {
    val baseline = pillar.baseline
    if (baseline != null && !baseline.provisional) {
        return when (baseline.position(pillar.latest)) {
            Baseline.Position.WITHIN -> ChipStatus.InBand to Loc.inYourRange
            Baseline.Position.ABOVE -> ChipStatus.Above to Loc.aboveYourRange
            Baseline.Position.BELOW -> ChipStatus.Below to Loc.belowYourRange
        }
    }
    return ChipStatus.Info to Loc.stillLearning
}

// MARK: - Repository tools

@Composable
private fun BodyToolsCard(
    showAllMetrics: Boolean,
    onToggleAllMetrics: () -> Unit,
    onSources: () -> Unit,
    onExport: () -> Unit,
    onTimeline: () -> Unit,
) {
    BadanCard(padding = 0.dp) {
        BodyToolRow(
            icon = Icons.Filled.GridView,
            title = Loc.allMetrics,
            trailing = if (showAllMetrics) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
            onClick = onToggleAllMetrics,
        )
        BodyToolDivider()
        BodyToolRow(
            icon = Icons.Filled.Sensors,
            title = Loc.dataSources,
            trailing = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            onClick = onSources,
        )
        BodyToolDivider()
        BodyToolRow(
            icon = Icons.Filled.IosShare,
            title = Loc.exportData,
            trailing = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            onClick = onExport,
        )
        BodyToolDivider()
        BodyToolRow(
            icon = Icons.Filled.History,
            title = Loc.timeline,
            trailing = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            onClick = onTimeline,
        )
    }
}

@Composable
private fun BodyToolRow(
    icon: ImageVector,
    title: LocalizedString,
    trailing: ImageVector,
    onClick: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = BadanSpace.cardPadding)
            .defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(24.dp),
        )
        Text(
            text = env.s(title),
            style = BadanType.body,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Icon(
            imageVector = trailing,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun BodyToolDivider() {
    val colors = BadanTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = BadanSpace.cardPadding)
            .height(1.dp)
            .background(colors.separator),
    )
}

// MARK: - All-metrics browser (inline)

private val noMatches = LocalizedString(en = "No matching metrics", ar = "لا مؤشرات مطابقة")

/**
 * The full ontology, searchable and grouped by family — raw catalog is never paywalled. Every
 * row leads to the same universal metric detail. Rendered inline under the tools card (the
 * Android navigation has no dedicated browser route); mirrors the iOS `BodyAllMetricsBrowser`.
 */
@Composable
private fun BodyAllMetricsBrowser() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors

    var query by remember { mutableStateOf("") }
    val results = if (query.isBlank()) env.registry.all else env.registry.search(query)
    val groups = results
        .groupBy { it.familyGroup }
        .toList()
        .sortedBy { MetricFamily.entries.indexOf(it.first) }

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        BadanCard {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                modifier = Modifier.fillMaxWidth(),
                singleLine = true,
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                placeholder = { Text(env.s(Loc.search)) },
            )
        }

        if (groups.isEmpty()) {
            Text(
                text = env.s(noMatches),
                style = BadanType.body,
                color = colors.textSecondary,
            )
        } else {
            groups.forEach { (family, metrics) ->
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                    Text(
                        text = env.s(family.displayName),
                        style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textSecondary,
                    )
                    BadanCard(padding = 0.dp) {
                        metrics.sortedBy { it.metricId }.forEachIndexed { index, def ->
                            if (index > 0) BodyToolDivider()
                            BodyMetricRow(def) { nav.push(Route.MetricDetail(def.metricId)) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun BodyMetricRow(def: MetricDefinition, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = BadanSpace.cardPadding, vertical = BadanSpace.s2)
            .defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(
                text = def.label(env.depth, env.language),
                style = BadanType.body,
                color = colors.textPrimary,
            )
            if (env.depth.showsPowerDetail) {
                Text(
                    text = def.metricId,
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}
