package net.albayyan.badan.features.metricdetail

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.ChartStyle
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.MetricChart
import net.albayyan.badan.designsystem.components.ProvenanceRow
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatBox
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.ChartHint
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.InputManifest
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.MetricDefinition
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ReconciliationDecision
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

// MARK: - Strings local to this surface

/**
 * Strings that only the metric-detail surface needs. Everything user-facing is bilingual;
 * shared vocabulary comes from [Loc], these fill the gaps with real Arabic. Mirror of the iOS
 * `MetricDetailStrings`.
 */
private object MetricDetailStrings {
    val trend = LocalizedString(en = "Trend", ar = "الاتجاه")
    val period = LocalizedString(en = "Period", ar = "الفترة")
    val recentValues = LocalizedString(en = "Recent values", ar = "القيم الأخيرة")
    val method = LocalizedString(en = "Method & units", ar = "الطريقة والوحدات")
    val unit = LocalizedString(en = "Unit", ar = "الوحدة")
    val howWorkedOut = LocalizedString(en = "How this was worked out", ar = "كيف تم حساب هذا")
}

// MARK: - Loaded data

/**
 * Everything the detail needs, gathered once so casual and power are two altitudes over the same
 * query result rather than two different loads. Mirror of the iOS `MetricDetailData`.
 */
data class MetricDetailData(
    val def: MetricDefinition,
    val baseline: Baseline?,
    val intervals: List<IntervalRecord>,        // ascending by start
    val derived: List<DerivedValue>,            // ascending by period
    val latestDerivedValue: DerivedValue?,      // most recent, for the anatomy manifest
    val manifest: InputManifest?,
    val sourceNames: Map<String, String>,       // sourceId -> display name
    val recentDedup: List<ReconciliationDecision>, // populated only for sleep.time_asleep
) {
    /** The chart reads derived values when there is no raw interval series (composites). */
    val usesDerivedSeries: Boolean get() = intervals.isEmpty() && derived.isNotEmpty()

    /** The full canonical series (ascending) as (epoch-millis, value) pairs. */
    fun fullSeries(tz: String): List<Pair<Long, Double>> {
        if (intervals.isNotEmpty()) return intervals.map { it.startAt to it.value }
        return derived.map { (periodDate(it.periodKey, tz) ?: it.computedAt) to it.value }
    }

    private fun periodDate(key: String, tz: String): Long? {
        val idx = key.indexOf("day:")
        if (idx < 0) return null
        return DayAttribution.dateFromDayKey(key.substring(idx + 4), tz)
    }
}

// MARK: - Load

/**
 * Gather the metric's baseline, chart series, lineage and (for composites) its manifest — off the
 * main thread. Mirror of the iOS `MetricDetailViewModel.load`.
 */
private suspend fun loadMetricDetail(env: AppEnvironment, metricId: String): LoadState<MetricDetailData> {
    val tz = TimeZone.getDefault().id
    return try {
        withContext(Dispatchers.IO) {
            val def = env.registry.definitionOrFallback(metricId)
            val from = env.now() - 90L * 86_400_000L

            val intervals = env.measurements.intervalRecords(metricId = metricId, from = from, to = env.now())
            val derivedSeries = env.derivation.latestDerivedSeries(metricId)
            val baseline = env.derivation.latestBaseline(metricId)

            // The single most recent derived value drives the anatomy manifest.
            val latestDerived = derivedSeries.maxByOrNull { it.computedAt }
            val manifest = latestDerived?.inputManifestId?.let { env.derivation.manifest(it) }

            val sourceNames = env.catalog.sources().associate { it.id to it.displayName }

            // Only sleep time-asleep surfaces the dedup decision (one kept, one suppressed).
            val dedup = if (metricId == MetricId.timeAsleep) env.reconciliation.recent(6) else emptyList()

            val data = MetricDetailData(
                def = def, baseline = baseline, intervals = intervals, derived = derivedSeries,
                latestDerivedValue = latestDerived, manifest = manifest, sourceNames = sourceNames,
                recentDedup = dedup,
            )

            if (data.fullSeries(tz).isEmpty()) {
                LoadState.Empty(env.s(Loc.noDataMetric))
            } else {
                LoadState.Loaded(data)
            }
        }
    } catch (t: Throwable) {
        LoadState.Error(t.toString())
    }
}

// MARK: - Screen

/**
 * The universal metric detail — one grammar for every metric. Casual shows a hero value, a status
 * word, a calm chart and a plain explainer; power adds a period selector, a values table,
 * provenance lineage, a method note and the "how this was worked out" anatomy sheet. Mirror of the
 * iOS `MetricDetailScreen`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MetricDetailScreen(metricId: String) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors

    var state by remember(metricId) { mutableStateOf<LoadState<MetricDetailData>>(LoadState.Loading) }
    var periodDays by remember(metricId) { mutableIntStateOf(30) }
    var showAnatomy by remember(metricId) { mutableStateOf(false) }

    LaunchedEffect(metricId) {
        state = loadMetricDetail(env, metricId)
    }

    val title = env.s(env.registry.definitionOrFallback(metricId).displayName)

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = title,
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
            ) {
                StatefulContainer(state) { data ->
                    MetricDetailContent(
                        data = data,
                        periodDays = periodDays,
                        onPeriodChange = { periodDays = it },
                        onShowAnatomy = { showAnatomy = true },
                    )
                }
            }

            val loaded = state as? LoadState.Loaded<MetricDetailData>
            if (showAnatomy && loaded != null) {
                ModalBottomSheet(
                    onDismissRequest = { showAnatomy = false },
                    sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
                    containerColor = colors.background,
                ) {
                    MetricAnatomySheet(data = loaded.value, onClose = { showAnatomy = false })
                }
            }
        }
    }
}

// MARK: - Body composition

@Composable
private fun MetricDetailContent(
    data: MetricDetailData,
    periodDays: Int,
    onPeriodChange: (Int) -> Unit,
    onShowAnatomy: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val tz = remember { TimeZone.getDefault().id }
    val power = env.depth.showsPowerDetail
    val fullSeries = data.fullSeries(tz)
    val latest = fullSeries.lastOrNull()
    val chartDays = if (power) periodDays else 30

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
        HeaderCard(data, latest)
        ChartCard(data, days = chartDays, tz = tz)

        if (power) {
            PeriodSelector(periodDays, onPeriodChange)
            ValuesTableCard(seriesWithin(chartDays, fullSeries, env.now()), data)
            LineageCard(data)
            MethodCard(data)
            AnatomyButton(onShowAnatomy)
        } else {
            ExplainerCard(data)
        }
    }
}

// MARK: - Header

@Composable
private fun HeaderCard(data: MetricDetailData, latest: Pair<Long, Double>?) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            if (latest != null) {
                StatBox(
                    value = env.format.heroValue(data.def.metricId, latest.second),
                    label = data.def.label(env.depth, env.language),
                    unit = env.format.unitLabel(data.def.metricId),
                    chip = { StatusChipFor(latest.second, data.baseline) },
                )
                Text(
                    text = dateText(latest.first, env.language),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            } else {
                Text(
                    text = data.def.label(env.depth, env.language),
                    style = BadanType.sectionTitle,
                    color = colors.textPrimary,
                )
            }
        }
    }
}

@Composable
private fun StatusChipFor(value: Double, baseline: Baseline?) {
    val env = LocalAppEnvironment.current
    if (baseline == null || baseline.provisional) {
        StatusChip(status = ChipStatus.Info, label = env.s(Loc.stillLearning))
        return
    }
    val position = baseline.position(value)
    val label = when (position) {
        Baseline.Position.WITHIN -> Loc.inYourRange
        Baseline.Position.ABOVE -> Loc.aboveYourRange
        Baseline.Position.BELOW -> Loc.belowYourRange
    }
    StatusChip(position = position, label = env.s(label))
}

// MARK: - Chart

@Composable
private fun ChartCard(data: MetricDetailData, days: Int, tz: String) {
    val env = LocalAppEnvironment.current
    val points = seriesWithin(days, data.fullSeries(tz), env.now())
    val provisional = data.baseline?.provisional ?: true
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(
                title = env.s(MetricDetailStrings.trend),
                trailing = if (provisional) {
                    { ProvisionalBadge(env.language) }
                } else {
                    null
                },
            )
            MetricChart(
                series = points,
                style = if (data.def.chartHint == ChartHint.BAR) ChartStyle.Bar else ChartStyle.Line,
                band = data.baseline?.let { it.bandLow to it.bandHigh },
                modifier = Modifier.height(200.dp),
            )
        }
    }
}

// MARK: - Casual explainer

@Composable
private fun ExplainerCard(data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val explainer = data.def.explainerEn
    if (!explainer.isNullOrEmpty()) {
        BadanCard {
            Text(
                text = env.s(LocalizedString(en = explainer, ar = data.def.nameAr)),
                style = BadanType.body,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Power: period selector

@Composable
private fun PeriodSelector(selected: Int, onChange: (Int) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = env.s(MetricDetailStrings.period),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(BadanRadius.control))
                .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.control)),
        ) {
            periodOptions.forEach { option ->
                val isSelected = option == selected
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .heightIn(min = BadanSpace.touchMin)
                        .background(if (isSelected) colors.primary.copy(alpha = 0.14f) else colors.surface)
                        .clickable { onChange(option) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = env.format.integer(option),
                        style = BadanType.monospaceDigits(BadanType.bodyCompact),
                        color = if (isSelected) colors.primary else colors.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

// MARK: - Power: values table

@Composable
private fun ValuesTableCard(points: List<Pair<Long, Double>>, data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(MetricDetailStrings.recentValues))
            val rows = points.reversed().take(14)
            rows.forEach { point ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(
                        text = dateText(point.first, env.language),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = env.format.full(data.def.metricId, point.second),
                        style = BadanType.monospaceDigits(BadanType.bodyCompact),
                        color = colors.textPrimary,
                    )
                }
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(1.dp)
                        .background(colors.separator),
                )
            }
        }
    }
}

// MARK: - Power: provenance lineage

@Composable
private fun LineageCard(data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    val entries = lineage(env, data)
    if (entries.isNotEmpty()) {
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(env.s(Loc.provenance))
                entries.forEach { entry ->
                    ProvenanceRow(
                        sourceName = entry.sourceName,
                        ingestionPath = entry.ingestionPath,
                        timestampMillis = entry.timestamp,
                        language = env.language,
                    )
                }
            }
        }
    }
}

// MARK: - Power: method / unit note

@Composable
private fun MethodCard(data: MetricDetailData) {
    val env = LocalAppEnvironment.current
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(env.s(MetricDetailStrings.method))
            NoteRow(
                label = env.s(MetricDetailStrings.unit),
                value = env.format.unitLabel(data.def.metricId) ?: data.def.canonicalUnit,
            )
            methodString(data)?.let { method ->
                NoteRow(label = env.s(Loc.algorithm), value = method)
            }
        }
    }
}

@Composable
private fun NoteRow(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(text = label, style = BadanType.bodyCompact, color = colors.textSecondary)
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            style = BadanType.monospaceDigits(BadanType.bodyCompact),
            color = colors.textPrimary,
            textAlign = TextAlign.End,
        )
    }
}

// MARK: - Power: anatomy button

@Composable
private fun AnatomyButton(onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin)
            .clip(shape)
            .background(colors.surface)
            .border(1.dp, colors.separator, shape)
            .clickable { onClick() }
            .padding(horizontal = BadanSpace.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Functions,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(20.dp),
        )
        Text(
            text = env.s(MetricDetailStrings.howWorkedOut),
            style = BadanType.body,
            color = colors.primary,
        )
        Spacer(modifier = Modifier.weight(1f))
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

// MARK: - Helpers

private val periodOptions = listOf(7, 30, 90)

private fun seriesWithin(days: Int, full: List<Pair<Long, Double>>, nowMillis: Long): List<Pair<Long, Double>> {
    val cutoff = nowMillis - days.toLong() * 86_400_000L
    return full.filter { it.first >= cutoff }
}

/** A uniform lineage row model so raw records and computed values render the same shape. */
private data class LineageEntry(
    val id: String,
    val sourceName: String,
    val ingestionPath: IngestionPath,
    val timestamp: Long,
)

private fun lineage(env: AppEnvironment, data: MetricDetailData): List<LineageEntry> {
    if (data.intervals.isNotEmpty()) {
        return data.intervals.takeLast(8).reversed().map { r ->
            LineageEntry(
                id = r.id,
                sourceName = data.sourceNames[r.provenance.sourceId] ?: r.provenance.sourceId,
                ingestionPath = r.provenance.ingestionPath,
                timestamp = r.provenance.measuredAt,
            )
        }
    }
    return data.derived.takeLast(8).reversed().map { d ->
        LineageEntry(
            id = d.id,
            sourceName = env.s(data.def.displayName),
            ingestionPath = IngestionPath.DERIVED,
            timestamp = d.computedAt,
        )
    }
}

private fun methodString(data: MetricDetailData): String? {
    data.latestDerivedValue?.let { return "${it.algorithmId}@${it.algorithmVersion}" }
    return data.baseline?.algorithmVersion
}

private fun dateText(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    return DateFormat.getDateInstance(DateFormat.MEDIUM, locale).format(Date(millis))
}
