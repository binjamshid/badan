package net.albayyan.badan.features.home

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
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
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.CalibrationProgress
import net.albayyan.badan.designsystem.components.CalibrationState
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.designsystem.components.ContextCaveatNote
import net.albayyan.badan.designsystem.components.DepthBadge
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.MetricSparkline
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.ProvisionalBadge
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatBox
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.Insight
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.TimelineEventType
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import net.albayyan.badan.domain.journal.ContextCaveats

/**
 * The flagship "Today" tab. Answers, at two altitudes over one model: how am I doing, why, and
 * what changed? Casual shows a calm readiness hero + a short narrative + a few tappable modules;
 * power keeps the same data but denser — deviation numbers, inline sparklines and a timeline
 * preview. Never moralizes state (no good/bad colour); out-of-band is one amber chip. Faithful
 * port of the iOS `HomeScreen`.
 */
@Composable
fun HomeScreen() {
    val env = LocalAppEnvironment.current
    var state by remember { mutableStateOf<LoadState<HomeData>>(LoadState.Loading) }

    // Reload when any altitude / gating preference the loader branches on changes. If we
    // already have data on screen, keep showing it during the reload instead of flashing back
    // to a full-screen spinner — only a first load (or a prior error/empty) shows Loading.
    LaunchedEffect(
        env.depth,
        env.language,
        env.profile.sensitiveModulesEnabled,
        env.profile.nutritionEnabled,
    ) {
        if (state !is LoadState.Loaded) {
            state = LoadState.Loading
        }
        state = withContext(Dispatchers.IO) { loadHomeData(env) }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(BadanTheme.colors.background),
    ) {
        StatefulContainer(state) { data ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = BadanSpace.s4, vertical = BadanSpace.s4),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
            ) {
                HomeHeader(data)
                if (env.depth.showsPowerDetail) HomePowerBody(data) else HomeCasualBody(data)
            }
        }
    }
}

// MARK: - Header

@Composable
private fun HomeHeader(data: HomeData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(
                text = env.s(env.greeting),
                style = BadanType.sectionTitle,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = longDate(data.date, env.language),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        DepthBadge(depth = env.depth, language = env.language)
    }
}

// MARK: - Casual body

@Composable
private fun HomeCasualBody(data: HomeData) {
    val env = LocalAppEnvironment.current
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
        // The hero now leads with the calm "how am I doing" sentence and follows it with the number
        // (plan §16), so no separate narrative card is needed here anymore.
        ReadinessHeroCard(data)
        data.effort?.let { EffortCard(effort = it, readiness = data.readiness) }

        if (moduleVisible(env, "sleep")) {
            data.sleep?.let { SleepModuleCard(it) }
        }
        if (moduleVisible(env, "activity")) {
            data.metric(MetricId.steps)?.let {
                MetricModuleCard(metric = it, secondary = data.metric(MetricId.activeEnergy))
            }
        }
        if (moduleVisible(env, "heart")) {
            data.metric(MetricId.restingHeartRate)?.let {
                MetricModuleCard(metric = it, secondary = data.metric(MetricId.hrv))
            }
        }
        HealthMonitorEntryCard()
        if (moduleVisible(env, "meds") && env.profile.sensitiveModulesEnabled && data.medsActive > 0) {
            MedsModuleCard(data)
        }
        data.topInsight?.let { InsightCard(it) }
    }
}

private fun moduleVisible(env: AppEnvironment, id: String): Boolean =
    env.profile.module(id)?.visible ?: true

// MARK: - Power body

@Composable
private fun HomePowerBody(data: HomeData) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
        ReadinessHeroCard(data)
        data.effort?.let { EffortCard(effort = it, readiness = data.readiness) }

        if (data.metrics.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(LocalizedString(en = "Snapshot", ar = "لمحة"))) {
                    Text(
                        text = env.s(Loc.seeAll),
                        style = BadanType.chip,
                        color = colors.primary,
                        modifier = Modifier
                            .heightIn(min = BadanSpace.touchMin)
                            .wrapContentHeight(Alignment.CenterVertically)
                            .clickable { nav.selectTab(BODY_TAB) },
                    )
                }
                MetricGrid(data.metrics)
            }
        }

        data.sleep?.let { SleepModuleCard(it) }
        HealthMonitorEntryCard()
        if (env.profile.sensitiveModulesEnabled && data.medsActive > 0) {
            MedsModuleCard(data)
        }
        data.topInsight?.let { InsightCard(it) }
        if (data.recentEvents.isNotEmpty()) {
            TimelinePreviewCard(data.recentEvents)
        }
    }
}

// MARK: - Readiness hero

@Composable
private fun ReadinessHeroCard(data: HomeData) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val readiness = data.readiness
    // The score is tappable to its anatomy; the calibration state isn't a score yet, so it doesn't
    // pretend to open one.
    val cardModifier = if (readiness != null) {
        Modifier.clickable { nav.push(Route.MetricDetail(MetricId.readinessScore)) }
    } else {
        Modifier
    }
    BadanCard(modifier = cardModifier) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            if (readiness != null) {
                // Sentence leads, number follows (plan §16 daily-view rule): the plain-language read
                // sits above the figure so the score never becomes the first, fixated-on thing.
                Text(
                    text = env.s(data.narrative),
                    style = BadanType.body,
                    color = colors.textPrimary,
                )
                StatBox(
                    value = env.format.integer(readiness.value.roundToInt()),
                    label = env.s(Loc.readiness),
                    unit = "/ ${env.format.integer(100)}",
                )
                val showAlgorithm = env.depth.showsPowerDetail
                if (readiness.provisional || data.readinessReducedInput || showAlgorithm) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        if (readiness.provisional) ProvisionalBadge(language = env.language)
                        // Reduced-input is labelled DISTINCTLY, never silently degraded (plan §18).
                        if (data.readinessReducedInput) {
                            PillLabel(
                                text = env.s(HomeScoreStrings.reducedSignals),
                                icon = Icons.Filled.Functions,
                                tint = colors.outOfBand,
                            )
                        }
                        if (showAlgorithm) {
                            PillLabel(
                                text = "${readiness.algorithmId} · ${readiness.algorithmVersion}",
                                icon = Icons.Filled.Functions,
                            )
                        }
                    }
                }
                // EPIC-29: "computed while you were travelling". Renders nothing on an ordinary day.
                // The score itself is unchanged — the engine capped this row's confidence and
                // nothing else (see `ReadinessResult`).
                ContextCaveatNote(caveats = data.readinessContextCaveats, language = env.language)
            } else {
                Text(
                    text = env.s(Loc.readiness),
                    style = BadanType.sectionTitle,
                    color = colors.textPrimary,
                )
                // Honest cold start: show how far calibration has come, not a guessed number.
                CalibrationState(
                    progress = data.readinessCalibration ?: CalibrationProgress(nPoints = 0, windowDays = 14),
                    language = env.language,
                    arabicDigits = env.profile.arabicDigits,
                )
            }
        }
    }
}

// MARK: - Effort

@Composable
private fun EffortCard(effort: HomeEffortSummary, readiness: DerivedValue?) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.MetricDetail(effort.metricId)) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            if (effort.isReducedInput) {
                // The sparse-HR (phone-only) day: a labelled activity load, never a shaming zero.
                Text(
                    text = env.s(HomeScoreStrings.activityLoadLead),
                    style = BadanType.body,
                    color = colors.textPrimary,
                )
                StatBox(
                    value = env.format.number(effort.value, 0),
                    label = env.s(HomeScoreStrings.activityLoad),
                    unit = effort.unit,
                    chip = { StatusChip(status = ChipStatus.Info, label = env.s(HomeScoreStrings.reducedSignals)) },
                )
            } else {
                // Zone-based Effort. Guidance leads (wellness-safe, tied to Readiness), number follows.
                Text(
                    text = env.s(effortGuidance(readiness)),
                    style = BadanType.body,
                    color = colors.textPrimary,
                )
                StatBox(
                    value = env.format.integer(effort.value.roundToInt()),
                    label = env.s(Loc.effort),
                    unit = "/ ${env.format.integer(100)}",
                )
                if (effort.provisional) ProvisionalBadge(language = env.language)
            }
        }
    }
}

// MARK: - Health Monitor entry

@Composable
private fun HealthMonitorEntryCard() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.HealthMonitor) },
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = Icons.Filled.MonitorHeart,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(24.dp),
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = env.s(HomeScoreStrings.healthMonitorTitle),
                    style = BadanType.body,
                    color = colors.textPrimary,
                )
                Text(
                    text = env.s(HomeScoreStrings.healthMonitorSubtitle),
                    style = BadanType.caption,
                    color = colors.textSecondary,
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

// MARK: - Sleep module

@Composable
private fun SleepModuleCard(sleep: HomeSleepSummary) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val chip: (@Composable () -> Unit)? = sleep.position?.let { p ->
        { StatusChip(position = p, label = env.s(rangeLabel(p))) }
    }
    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.MetricDetail(MetricId.timeAsleep)) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            ModuleHeaderRow(iconKey = MetricFamily.SLEEP.symbolName, title = env.s(Loc.lastNight))
            StatBox(
                value = env.format.duration(sleep.seconds),
                label = env.s(MetricFamily.SLEEP.displayName),
                chip = chip,
            )
            // Sleep performance vs your estimated need (EPIC-24) when the engine has produced one.
            // Capped at 100% on this calm summary; the detail carries the full nuance.
            sleep.performancePercent?.let { pct ->
                val colors = BadanTheme.colors
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(
                        text = env.s(HomeScoreStrings.sleepPerformance),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = "${env.format.number(pct.coerceAtMost(100.0), 0)}%",
                        style = BadanType.monospaceDigits(BadanType.bodyCompact),
                        color = colors.textPrimary,
                    )
                }
            }
            if (env.depth.showsPowerDetail && sleep.spark.size >= 2) {
                MetricSparkline(values = sleep.spark, modifier = Modifier.height(36.dp))
            }
        }
    }
}

// MARK: - Generic metric module (casual)

@Composable
private fun MetricModuleCard(metric: HomeKeyMetric, secondary: HomeKeyMetric?) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val chip: (@Composable () -> Unit)? = metric.position?.let { p ->
        { StatusChip(position = p, label = env.s(rangeLabel(p))) }
    }
    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.MetricDetail(metric.metricId)) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            ModuleHeaderRow(iconKey = metric.familySymbol, title = metric.label)
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s4),
                verticalAlignment = Alignment.Top,
            ) {
                StatBox(
                    value = metric.heroValue,
                    label = metric.label,
                    unit = metric.unit,
                    chip = chip,
                )
                if (secondary != null) {
                    Spacer(Modifier.weight(1f))
                    Column(
                        horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                    ) {
                        Row(
                            verticalAlignment = Alignment.Bottom,
                            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                        ) {
                            Text(
                                text = secondary.heroValue,
                                style = BadanType.numeralM,
                                color = colors.textPrimary,
                            )
                            secondary.unit?.let {
                                Text(
                                    text = it,
                                    style = BadanType.caption,
                                    color = colors.textSecondary,
                                )
                            }
                        }
                        Text(
                            text = secondary.label,
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Metric grid (power)

@Composable
private fun MetricGrid(metrics: List<HomeKeyMetric>) {
    // A manual two-column grid — a LazyVGrid cannot nest inside the screen's vertical scroll.
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        metrics.chunked(2).forEach { row ->
            if (row.size == 1) {
                // Lone trailing card: span the full row width instead of leaving an empty
                // half-width gap.
                MetricGridCell(row[0])
            } else {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
                ) {
                    row.forEach { metric ->
                        Box(modifier = Modifier.weight(1f)) { MetricGridCell(metric) }
                    }
                }
            }
        }
    }
}

@Composable
private fun MetricGridCell(metric: HomeKeyMetric) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.MetricDetail(metric.metricId)) },
        padding = BadanSpace.s3,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Text(
                text = metric.label,
                style = BadanType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(
                verticalAlignment = Alignment.Bottom,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = metric.heroValue,
                    style = BadanType.numeralM,
                    color = colors.textPrimary,
                )
                metric.unit?.let {
                    Text(
                        text = it,
                        style = BadanType.caption,
                        color = colors.textSecondary,
                        modifier = Modifier.padding(bottom = 2.dp),
                    )
                }
            }
            metric.position?.let { StatusChip(position = it, label = env.s(rangeLabel(it))) }
            metric.deltaText?.let {
                Text(text = it, style = BadanType.caption, color = colors.textSecondary)
            }
            if (metric.spark.size >= 2) {
                MetricSparkline(values = metric.spark, modifier = Modifier.height(28.dp))
            }
        }
    }
}

// MARK: - Meds module

@Composable
private fun MedsModuleCard(data: HomeData) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    BadanCard(
        modifier = Modifier.clickable { nav.push(Route.MedicationLog) },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            ModuleHeaderRow(
                iconKey = MetricFamily.MEDICATIONS.symbolName,
                title = env.s(MetricFamily.MEDICATIONS.displayName),
            )
            if (data.medsDue > 0) {
                StatBox(
                    value = env.format.integer(data.medsDue),
                    label = env.s(Loc.medsDue),
                    chip = { StatusChip(status = ChipStatus.Info, label = env.s(Loc.stillDue)) },
                )
            } else {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Icon(
                        imageVector = Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = colors.inBand,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(
                        text = env.s(Loc.allDone),
                        style = BadanType.body,
                        color = colors.textPrimary,
                    )
                }
            }
        }
    }
}

// MARK: - Insight card

@Composable
private fun InsightCard(insight: Insight) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.AutoAwesome,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    text = env.s(Loc.tabInsights),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
            Text(
                text = env.s(insight.renderedText),
                style = BadanType.body,
                color = colors.textPrimary,
            )
            Row(
                modifier = Modifier
                    .heightIn(min = BadanSpace.touchMin)
                    .clickable { nav.selectTab(INSIGHTS_TAB) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = env.s(Loc.why),
                    style = BadanType.chip.copy(fontWeight = FontWeight.Medium),
                    color = colors.primary,
                )
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
    }
}

// MARK: - Timeline preview (power)

@Composable
private fun TimelinePreviewCard(events: List<HomeEvent>) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(Loc.timeline)) {
            Text(
                text = env.s(Loc.seeAll),
                style = BadanType.chip,
                color = colors.primary,
                modifier = Modifier
                    .heightIn(min = BadanSpace.touchMin)
                    .wrapContentHeight(Alignment.CenterVertically)
                    .clickable { nav.push(Route.Timeline) },
            )
        }
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                events.forEachIndexed { index, event ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
                    ) {
                        Icon(
                            imageVector = iconForKey(event.type.symbolName),
                            contentDescription = null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(22.dp),
                        )
                        Column(
                            modifier = Modifier.weight(1f),
                            verticalArrangement = Arrangement.spacedBy(2.dp),
                        ) {
                            Text(
                                text = env.s(event.type.displayName),
                                style = BadanType.bodyCompact,
                                color = colors.textPrimary,
                            )
                            val detail = event.detail
                            if (!detail.isNullOrEmpty()) {
                                Text(
                                    text = detail,
                                    style = BadanType.caption,
                                    color = colors.textSecondary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        Text(
                            text = eventTimeText(event.occurredAt, env.language),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                    if (index < events.size - 1) {
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
    }
}

// MARK: - Shared module header

@Composable
private fun ModuleHeaderRow(iconKey: String, title: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = iconForKey(iconKey),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(20.dp),
        )
        Text(
            text = title,
            style = BadanType.caption,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(18.dp),
        )
    }
}

// MARK: - Shared label helper

private fun rangeLabel(position: Baseline.Position): LocalizedString = when (position) {
    Baseline.Position.WITHIN -> Loc.inYourRange
    Baseline.Position.ABOVE -> Loc.aboveYourRange
    Baseline.Position.BELOW -> Loc.belowYourRange
}

// MARK: - Date/time helpers

private fun longDate(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    return DateFormat.getDateInstance(DateFormat.LONG, locale).format(Date(millis))
}

private fun eventTimeText(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val date = Date(millis)
    val weekday = SimpleDateFormat("EEE", locale).format(date)
    val time = DateFormat.getTimeInstance(DateFormat.SHORT, locale).format(date)
    return "$weekday $time"
}

// MARK: - Data model

// @Immutable: every field is a val assigned once at construction from freshly-built
// lists/values (never mutated afterward), so these are safe to promise as stable to the
// Compose compiler even though `List` itself is not inferred stable (see PERF-213).
@Immutable
data class HomeKeyMetric(
    val metricId: String,
    val label: String,
    val heroValue: String,
    val unit: String?,
    val position: Baseline.Position?,
    val deltaText: String?,
    val spark: List<Double>,
    val familySymbol: String,
)

@Immutable
data class HomeSleepSummary(
    val seconds: Double,
    val position: Baseline.Position?,
    val spark: List<Double>,
    /** Last night's sleep-performance % (EPIC-24), if the sleep engine has produced one. */
    val performancePercent: Double? = null,
)

/**
 * The daily Effort score for the hero card (EPIC-26). [isReducedInput] is true for the labelled
 * activity-load variant a sparse-HR (phone-only) day produces — a distinct, honest thing, never a
 * shaming zero-score. Carried as a flag rather than inferred in the view so the card labels it once,
 * consistently.
 */
@Immutable
data class HomeEffortSummary(
    val value: Double,
    val provisional: Boolean,
    val isReducedInput: Boolean,
    /** The derived row's own unit: `score_0_100` for a zone-based day, an activity unit otherwise. */
    val unit: String,
    val metricId: String,
)

@Immutable
data class HomeEvent(
    val id: String,
    val type: TimelineEventType,
    val occurredAt: Long,
    val detail: String?,
)

@Immutable
data class HomeData(
    val date: Long,
    val readiness: DerivedValue?,
    /** True when the latest Readiness score was computed without the HRV anchor (reduced-input). */
    val readinessReducedInput: Boolean,
    /** Cold-start calibration progress shown in place of a Readiness score that can't render yet. */
    val readinessCalibration: CalibrationProgress?,
    /**
     * EPIC-29 (plan §18). The caveat sentences for any period the user marked over the day the shown
     * Readiness value belongs to — "computed while you were travelling". Empty on an ordinary day,
     * which is the common case, and empty whenever sensitive records are switched off (a caveat names
     * a circumstance, so it is sensitive-plus text; the confidence cap the engine already applied is
     * a bare number and stays). Resolved at load time, never carried on the derived row.
     */
    val readinessContextCaveats: List<LocalizedString> = emptyList(),
    val narrative: LocalizedString,
    val effort: HomeEffortSummary?,
    val sleep: HomeSleepSummary?,
    val metrics: List<HomeKeyMetric>,
    val medsDue: Int,
    val medsActive: Int,
    val topInsight: Insight?,
    val recentEvents: List<HomeEvent>,
) {
    fun metric(id: String): HomeKeyMetric? = metrics.firstOrNull { it.metricId == id }
}

// MARK: - Loader (runs off the main thread)

private const val DAY_MS = 86_400_000L
private const val BODY_TAB = 1
private const val INSIGHTS_TAB = 3

private fun loadHomeData(env: AppEnvironment): LoadState<HomeData> {
    val tz = TimeZone.getDefault().id
    val now = env.now()
    return try {
        val readiness = latestReadiness(env, now, tz)
        val readinessReduced = readiness?.let { readinessReducedInput(env, it) } ?: false
        // When Readiness can't render yet, show how far its anchor (RHR) has calibrated — the honest
        // cold-start wait, not a guessed number (plan §16/§18).
        val readinessCalibration = if (readiness == null) {
            CalibrationProgress.from(env.derivation.latestBaseline(MetricId.restingHeartRate), windowDaysFallback = 14)
        } else {
            null
        }
        // EPIC-29: the note beside the score, resolved from the sensitive store at load time rather
        // than stored on the row (see [ContextCaveats]). Skipped entirely — not merely hidden — when
        // sensitive records are off, so the read never happens either.
        val readinessCaveats = if (readiness != null && env.profile.sensitiveModulesEnabled) {
            ContextCaveats.forPeriodKey(readiness.periodKey, tz, env.contextAnnotations)
        } else {
            emptyList()
        }
        val effort = latestEffort(env, now, tz)
        val sleep = loadSleep(env, now, tz)
        val metrics = loadMetrics(env, now)
        val (medsDue, medsActive) = loadMeds(env, now, tz)
        val insight = env.insightsRepo.recent(limit = 1).firstOrNull()
        val events = if (env.depth.showsPowerDetail) loadEvents(env, now) else emptyList()

        val hasAny = readiness != null || effort != null || sleep != null || metrics.isNotEmpty() ||
            medsActive > 0 || insight != null
        if (!hasAny) {
            LoadState.Empty(env.s(Loc.nothingYet))
        } else {
            LoadState.Loaded(
                HomeData(
                    date = now,
                    readiness = readiness,
                    readinessReducedInput = readinessReduced,
                    readinessCalibration = readinessCalibration,
                    readinessContextCaveats = readinessCaveats,
                    narrative = narrative(readiness),
                    effort = effort,
                    sleep = sleep,
                    metrics = metrics,
                    medsDue = medsDue,
                    medsActive = medsActive,
                    topInsight = insight,
                    recentEvents = events,
                ),
            )
        }
    } catch (t: Throwable) {
        LoadState.Error(env.s(homeLoadErrorMessage))
    }
}

// A calm, wellness-safe fallback shown in place of a raw exception message (see UIUX-249).
private val homeLoadErrorMessage = LocalizedString(
    en = "Something didn't load. Try again.",
    ar = "لم يتم تحميل شيء ما. حاول مرة أخرى.",
)

// Readiness — walk back up to four days for the latest daily score.
private fun latestReadiness(env: AppEnvironment, now: Long, tz: String): DerivedValue? {
    for (offset in 0 until 4) {
        val day = now - offset.toLong() * DAY_MS
        val key = DayAttribution.dayPeriodKey(day, tz)
        env.derivation.latestDerived(metricId = MetricId.readinessScore, periodKey = key)?.let { return it }
    }
    return null
}

/**
 * Whether the latest Readiness score was computed without the HRV anchor — read straight from its own
 * input manifest (the records that actually fed it) rather than a stored flag, so it stays true to the
 * lineage. A manifest that failed to load reads as "not reduced" (the calm default): the hero simply
 * omits the label rather than asserting a degradation it can't prove.
 */
private fun readinessReducedInput(env: AppEnvironment, readiness: DerivedValue): Boolean {
    val manifestId = readiness.inputManifestId ?: return false
    val manifest = env.derivation.manifest(manifestId) ?: return false
    return manifest.inputs.none { it.metricId == MetricId.hrv }
}

// Effort — walk back up to four days for the latest daily Effort score, zone-based or the labelled
// activity-load variant (distinguished by its unit, never by a magic value).
private fun latestEffort(env: AppEnvironment, now: Long, tz: String): HomeEffortSummary? {
    for (offset in 0 until 4) {
        val day = now - offset.toLong() * DAY_MS
        val key = DayAttribution.dayPeriodKey(day, tz)
        val dv = env.derivation.latestDerived(metricId = MetricId.effortDay, periodKey = key) ?: continue
        return HomeEffortSummary(
            value = dv.value,
            provisional = dv.provisional,
            isReducedInput = dv.unit != "score_0_100",
            unit = dv.unit,
            metricId = dv.metricId,
        )
    }
    return null
}

// Sleep — last night's time-asleep + its personal-band position + a 14-day spark.
private fun loadSleep(env: AppEnvironment, now: Long, tz: String): HomeSleepSummary? {
    val localNight = DayAttribution.localNight(sessionEndMillis = now, tz = tz)
    var seconds: Double? = null
    val session = env.measurements.primarySleep(localNight)
    if (session != null) {
        seconds = session.detail.timeAsleepSeconds ?: session.durationSeconds
    } else {
        env.measurements.latestInterval(MetricId.timeAsleep)?.let { seconds = it.value }
    }
    val resolved = seconds ?: return null

    val baseline = env.derivation.latestBaseline(MetricId.timeAsleep)
    val position = baseline?.position(of = resolved)

    val from = now - 14L * DAY_MS
    val spark = env.measurements
        .sessions(kind = SessionKind.SLEEP_PRIMARY, from = from, to = now)
        .sortedBy { it.startAt }
        .map { it.detail.timeAsleepSeconds ?: it.durationSeconds }

    // Last night's sleep-performance % (EPIC-24), keyed on the same local night. Absent until the
    // sleep engine has a personal duration baseline — the card just omits it then, never a zero.
    val performance = env.derivation.latestDerived(MetricId.sleepPerformance, "day:$localNight")?.value

    return HomeSleepSummary(seconds = resolved, position = position, spark = spark, performancePercent = performance)
}

// Key metrics — rhr / hrv / steps / active energy, each with baseline position + spark.
private fun loadMetrics(env: AppEnvironment, now: Long): List<HomeKeyMetric> {
    val ids = listOf(MetricId.restingHeartRate, MetricId.hrv, MetricId.steps, MetricId.activeEnergy)
    val from = now - 14L * DAY_MS
    val result = mutableListOf<HomeKeyMetric>()
    for (id in ids) {
        val latest = env.measurements.latestInterval(id) ?: continue
        val def = env.registry.definitionOrFallback(id)
        val baseline = env.derivation.latestBaseline(id)
        val position = baseline?.position(of = latest.value)
        val spark = env.measurements.intervalRecords(id, from = from, to = now).map { it.value }
        val delta = if (env.depth.showsPowerDetail && baseline != null) {
            signedDelta(env, id, latest.value, baseline.center)
        } else {
            null
        }
        result.add(
            HomeKeyMetric(
                metricId = id,
                label = def.label(env.depth, env.language),
                heroValue = env.format.heroValue(id, latest.value),
                unit = env.format.unitLabel(id),
                position = position,
                deltaText = delta,
                spark = spark,
                familySymbol = def.familyGroup.symbolName,
            ),
        )
    }
    return result
}

private fun signedDelta(env: AppEnvironment, metricId: String, value: Double, center: Double): String {
    val delta = value - center
    val sign = if (delta >= 0) "+" else "−"
    val magnitude = env.format.heroValue(metricId, abs(delta))
    val vs = LocalizedString(en = "vs your median", ar = "مقارنة بمتوسطك")
    val unit = env.format.unitLabel(metricId)
    return if (unit != null) {
        "$sign$magnitude $unit · ${env.s(vs)}"
    } else {
        "$sign$magnitude · ${env.s(vs)}"
    }
}

// Meds — how many scheduled doses today remain unhandled, and how many regimens are active.
private fun loadMeds(env: AppEnvironment, now: Long, tz: String): Pair<Int, Int> {
    val active = env.logging.regimens(activeOnly = true)
    val weekday = mondayBasedWeekday(now, tz)
    val scheduledToday = active.sumOf { it.schedule.dueTimes(onWeekday = weekday).size }

    val dayStart = DayAttribution.startOfDay(now, tz)
    val dayEnd = DayAttribution.addingDays(1, dayStart, tz)
    val handled = env.logging.adherence(from = dayStart, to = dayEnd).size

    val due = max(0, scheduledToday - handled)
    return Pair(due, active.size)
}

private fun mondayBasedWeekday(millis: Long, tz: String): Int {
    val cal = GregorianCalendar(TimeZone.getTimeZone(tz))
    cal.timeInMillis = millis
    val sundayBased = cal.get(Calendar.DAY_OF_WEEK) // 1 = Sunday ... 7 = Saturday
    return ((sundayBased + 5) % 7) + 1 // 1 = Monday ... 7 = Sunday
}

// Recent events (power timeline preview) — last seven days across logs, newest four.
private fun loadEvents(env: AppEnvironment, now: Long): List<HomeEvent> {
    val from = now - 7L * DAY_MS
    val events = mutableListOf<HomeEvent>()

    runCatching { env.logging.workouts(from, now) }.getOrNull()?.forEach { w ->
        events.add(HomeEvent("w:${w.id}", TimelineEventType.WORKOUT, w.startAt, w.activityType))
    }
    runCatching { env.logging.notes(from, now) }.getOrNull()?.forEach { n ->
        events.add(HomeEvent("n:${n.id}", TimelineEventType.NOTE, n.occurredAt, n.text))
    }
    if (env.profile.nutritionEnabled) {
        runCatching { env.logging.nutrition(from, now) }.getOrNull()?.forEach { m ->
            events.add(HomeEvent("m:${m.id}", TimelineEventType.MEAL, m.occurredAt, m.description))
        }
    }
    if (env.profile.sensitiveModulesEnabled) {
        runCatching { env.logging.symptoms(from, now) }.getOrNull()?.forEach { s ->
            events.add(HomeEvent("s:${s.id}", TimelineEventType.SYMPTOM, s.occurredAt, null))
        }
        runCatching { env.logging.adherence(from, now) }.getOrNull()?.forEach { d ->
            events.add(HomeEvent("a:${d.id}", TimelineEventType.MEDICATION, d.occurredAt, null))
        }
    }

    return events.sortedByDescending { it.occurredAt }.take(4)
}

// Narrative — one calm sentence keyed to the readiness band (never moralizing).
private fun narrative(readiness: DerivedValue?): LocalizedString {
    if (readiness == null) {
        return LocalizedString(en = "Here's your day at a glance.", ar = "إليك يومك بلمحة.")
    }
    return when {
        readiness.value >= 66 ->
            LocalizedString(en = "You're rested and steady today.", ar = "أنت مرتاح ومستقر اليوم.")
        readiness.value >= 45 ->
            LocalizedString(en = "You're in a balanced place today.", ar = "أنت في حالة متوازنة اليوم.")
        else ->
            LocalizedString(en = "A gentler pace may suit you today.", ar = "قد تناسبك وتيرة ألطف اليوم.")
    }
}

// `effortGuidance` (the Readiness-linked Effort sentence) lives in `HomeScoreModel.kt` so a JVM unit
// test asserts the copy without loading this Compose file.

/**
 * Strings for the Phase-2 score cards (Readiness reduced-input, Effort, the Health Monitor entry, the
 * sleep-performance line). Bilingual with real Arabic; wellness-safe.
 */
private object HomeScoreStrings {
    val reducedSignals = LocalizedString(en = "Fewer signals", ar = "إشارات أقل")
    val activityLoad = LocalizedString(en = "Activity load", ar = "حِمل النشاط")
    val activityLoadLead = LocalizedString(
        en = "Estimated from your movement — no continuous heart rate today.",
        ar = "مُقدّر من حركتك — لا يوجد معدل ضربات قلب مستمر اليوم.",
    )
    val sleepPerformance = LocalizedString(en = "Sleep performance", ar = "أداء النوم")
    val healthMonitorTitle = LocalizedString(en = "Health Monitor", ar = "مراقب الصحة")
    val healthMonitorSubtitle = LocalizedString(
        en = "Your vitals against your usual range",
        ar = "علاماتك الحيوية مقارنةً بنطاقك المعتاد",
    )
}
