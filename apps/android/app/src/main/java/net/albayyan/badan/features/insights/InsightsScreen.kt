package net.albayyan.badan.features.insights

import androidx.compose.animation.core.animateFloatAsState
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.ThumbDown
import androidx.compose.material.icons.filled.ThumbUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
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
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.designsystem.components.EmptyState
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.Insight
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs

/**
 * The interpretation feed. A calm, deterministic account of "what changed" and "why we're saying
 * it" — never diagnostic, never moralized. A weekly summary card sits on top (sleep + resting
 * heart rate against each personal band), then the recent insight cards with 👍/👎 feedback and,
 * at power depth, a "Why am I seeing this?" disclosure. Everything is worked out on-device with
 * fixed rules; there is no AI in this version, and a footer says so. Faithful port of the iOS
 * `InsightsScreen`.
 */
@Composable
fun InsightsScreen() {
    val env = LocalAppEnvironment.current
    val scope = rememberCoroutineScope()
    val haptic = LocalHapticFeedback.current
    var state by remember { mutableStateOf<LoadState<InsightsData>>(LoadState.Loading) }
    // Per-insight feedback lives in its own small map keyed by insight id, so a tap mutates
    // exactly one entry instead of copying the whole insight list through the top-level
    // LoadState (which would invalidate recomposition-skipping for every card). PERF-230.
    val feedbackOverrides = remember { mutableStateMapOf<String, Int>() }

    // Reload when altitude (delta detail) or language (labels / value formatting) changes.
    LaunchedEffect(env.depth, env.language) {
        state = LoadState.Loading
        state = withContext(Dispatchers.IO) { loadInsights(env) }
    }

    // Persist the tap optimistically, then reflect it locally. Tapping the already-selected thumb
    // clears it. The DB write runs off the main thread.
    val handleFeedback: (String, Int) -> Unit = handler@{ id, value ->
        val loaded = state as? LoadState.Loaded<InsightsData> ?: return@handler
        val data = loaded.value
        val insight = data.insights.firstOrNull { it.id == id } ?: return@handler
        val current = feedbackOverrides[id] ?: insight.feedback ?: 0
        val newValue = if (current == value) 0 else value
        // A light haptic tick confirms the tap registered — the icon-color change alone is subtle. UIUX-248.
        haptic.performHapticFeedback(HapticFeedbackType.TextHandleMove)
        feedbackOverrides[id] = newValue
        scope.launch(Dispatchers.IO) { runCatching { env.insightsRepo.setFeedback(id, newValue) } }
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
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
            ) {
                if (data.weekly.isNotEmpty()) {
                    WeeklyCard(data.weekly)
                }

                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(env.s(InsightsStrings.feedTitle))
                    if (data.insights.isEmpty()) {
                        EmptyFeedCard()
                    } else {
                        data.insights.forEach { insight ->
                            FeedCard(
                                insight = insight,
                                feedback = feedbackOverrides[insight.id] ?: insight.feedback,
                            ) { value -> handleFeedback(insight.id, value) }
                        }
                    }
                }

                FooterNote()
            }
        }
    }
}

// MARK: - Weekly summary ("what changed")

@Composable
private fun WeeklyCard(changes: List<WeeklyChange>) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(env.s(InsightsStrings.weeklyTitle))
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                Text(
                    text = env.s(InsightsStrings.weeklySubtitle),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
                changes.forEachIndexed { index, change ->
                    if (index > 0) Separator()
                    WeeklyRow(change)
                }
            }
        }
    }
}

@Composable
private fun WeeklyRow(change: WeeklyChange) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin)
            .clickable { nav.push(Route.MetricDetail(change.metricId)) },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = iconForKey(change.familySymbol),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(22.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = change.label,
                style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                Text(
                    text = change.valueText,
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
                change.deltaText?.let { delta ->
                    Text(text = delta, style = BadanType.caption, color = colors.textSecondary)
                }
            }
        }
        WeeklyStatusChip(change)
    }
}

@Composable
private fun WeeklyStatusChip(change: WeeklyChange) {
    val env = LocalAppEnvironment.current
    val position = change.position
    if (change.stillLearning || position == null) {
        StatusChip(status = ChipStatus.Info, label = env.s(Loc.stillLearning))
    } else {
        StatusChip(position = position, label = env.s(rangeLabel(position)))
    }
}

// MARK: - Insight feed card

@Composable
private fun FeedCard(insight: Insight, feedback: Int?, onFeedback: (Int) -> Unit) {
    val env = LocalAppEnvironment.current
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SentenceRow(insight)
            Separator()
            FeedbackRow(feedback = feedback, onFeedback = onFeedback)
            if (env.depth.showsPowerDetail) {
                WhyDisclosure(insight)
            }
        }
    }
}

// The localized interpretation, tappable through to the metric it concerns.
@Composable
private fun SentenceRow(insight: Insight) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val metricId = insight.metricIds.firstOrNull()
    val familySymbol = metricId
        ?.let { env.registry.definitionOrFallback(it).familyGroup.symbolName }
        ?: "auto_awesome"

    val rowModifier = if (metricId != null) {
        Modifier.clickable { nav.push(Route.MetricDetail(metricId)) }
    } else {
        Modifier
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .then(rowModifier),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = iconForKey(familySymbol),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(22.dp),
        )
        Text(
            text = env.s(insight.renderedText),
            style = BadanType.body,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        if (metricId != null) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun FeedbackRow(feedback: Int?, onFeedback: (Int) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val current = feedback ?: 0
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = env.s(InsightsStrings.helpful),
            style = BadanType.caption,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
        FeedbackButton(
            selected = current == 1,
            icon = Icons.Filled.ThumbUp,
            a11y = InsightsStrings.thumbsUp,
            onClick = { onFeedback(1) },
        )
        FeedbackButton(
            selected = current == -1,
            icon = Icons.Filled.ThumbDown,
            a11y = InsightsStrings.thumbsDown,
            onClick = { onFeedback(-1) },
        )
    }
}

@Composable
private fun FeedbackButton(
    selected: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    a11y: LocalizedString,
    onClick: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val background = if (selected) colors.primary.copy(alpha = 0.12f) else Color.Transparent
    Box(
        modifier = Modifier
            .size(BadanSpace.touchMin)
            .clip(CircleShape)
            .background(background)
            .clickable(onClickLabel = env.s(a11y)) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = env.s(a11y),
            tint = if (selected) colors.primary else colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

// MARK: - "Why am I seeing this?" (power depth)

@Composable
private fun WhyDisclosure(insight: Insight) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BadanSpace.touchMin)
                .clickable { expanded = !expanded },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Text(
                text = env.s(InsightsStrings.whyTitle),
                style = BadanType.chip.copy(fontWeight = FontWeight.Medium),
                color = colors.primary,
                modifier = Modifier.weight(1f),
            )
            // Single chevron rotated 180° on expand rather than swapping two icons — smoother
            // Material expand/collapse affordance. UIUX-285.
            val chevronRotation by animateFloatAsState(
                targetValue = if (expanded) 180f else 0f,
                label = "whyChevron",
            )
            Icon(
                imageVector = Icons.Filled.ExpandMore,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier
                    .size(20.dp)
                    .rotate(chevronRotation),
            )
        }
        if (expanded) {
            Column(
                modifier = Modifier.padding(top = BadanSpace.s2),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                DetailRow(env.s(InsightsStrings.templateLabel), insight.templateId)
                DetailRow(env.s(Loc.contributingRecords), env.format.integer(insight.evidenceRefs.size))
                DetailRow(env.s(InsightsStrings.generatedLabel), generatedText(insight.generatedAt, env.language))
            }
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(text = label, style = BadanType.caption, color = colors.textSecondary)
        Spacer(modifier = Modifier.weight(1f))
        // Identifiers/timestamps read left-to-right in both languages.
        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
            Text(
                text = value,
                style = BadanType.monospaceDigits(BadanType.caption),
                color = colors.textPrimary,
                textAlign = TextAlign.End,
            )
        }
    }
}

// MARK: - Empty feed + footer

@Composable
private fun EmptyFeedCard() {
    val env = LocalAppEnvironment.current
    BadanCard {
        EmptyState(
            icon = Icons.Filled.AutoAwesome,
            title = env.s(InsightsStrings.emptyTitle),
            message = env.s(InsightsStrings.emptyMessage),
        )
    }
}

@Composable
private fun FooterNote() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = BadanSpace.s1),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Lock,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = env.s(InsightsStrings.footerNote),
            style = BadanType.caption,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
    }
}

// MARK: - Shared bits

@Composable
private fun Separator() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(BadanTheme.colors.separator),
    )
}

private fun rangeLabel(position: Baseline.Position): LocalizedString = when (position) {
    Baseline.Position.WITHIN -> Loc.inYourRange
    Baseline.Position.ABOVE -> Loc.aboveYourRange
    Baseline.Position.BELOW -> Loc.belowYourRange
}

private fun generatedText(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date(millis))
}

// MARK: - Data model

/** One row of the weekly summary: a metric's latest value placed against its personal band. */
private data class WeeklyChange(
    val metricId: String,
    val familySymbol: String,
    val label: String,
    val position: Baseline.Position?,   // null while still learning
    val stillLearning: Boolean,
    val valueText: String,
    val deltaText: String?,             // power depth only
)

private data class InsightsData(
    val weekly: List<WeeklyChange>,
    val insights: List<Insight>,
)

// MARK: - Loader (runs off the main thread)

private fun loadInsights(env: AppEnvironment): LoadState<InsightsData> {
    return try {
        val weekly = weeklyChanges(env)
        val insights = env.insightsRepo.recent(limit = 20)
        if (weekly.isEmpty() && insights.isEmpty()) {
            LoadState.Empty(env.s(InsightsStrings.emptyTitle))
        } else {
            LoadState.Loaded(InsightsData(weekly = weekly, insights = insights))
        }
    } catch (t: Throwable) {
        LoadState.Error(t.toString())
    }
}

private fun weeklyChanges(env: AppEnvironment): List<WeeklyChange> {
    val now = env.now()
    val tz = TimeZone.getDefault().id
    val out = mutableListOf<WeeklyChange>()
    sleepSeconds(env, now, tz)?.let { seconds ->
        out.add(makeChange(env, MetricId.timeAsleep, seconds))
    }
    env.measurements.latestInterval(MetricId.restingHeartRate)?.let { rhr ->
        out.add(makeChange(env, MetricId.restingHeartRate, rhr.value))
    }
    return out
}

private fun sleepSeconds(env: AppEnvironment, now: Long, tz: String): Double? {
    val localNight = DayAttribution.localNight(sessionEndMillis = now, tz = tz)
    env.measurements.primarySleep(localNight)?.let { session ->
        return session.detail.timeAsleepSeconds ?: session.durationSeconds
    }
    env.measurements.latestInterval(MetricId.timeAsleep)?.let { interval ->
        return interval.value
    }
    return null
}

private fun makeChange(env: AppEnvironment, metricId: String, value: Double): WeeklyChange {
    val def = env.registry.definitionOrFallback(metricId)
    val baseline = runCatching { env.derivation.latestBaseline(metricId) }.getOrNull()
    val stillLearning = baseline?.provisional ?: true
    val position = baseline?.position(of = value)
    val delta = if (env.depth.showsPowerDetail && baseline != null && !stillLearning) {
        signedDelta(env, metricId, value, baseline.center)
    } else {
        null
    }
    return WeeklyChange(
        metricId = metricId,
        familySymbol = def.familyGroup.symbolName,
        label = def.label(env.depth, env.language),
        position = if (stillLearning) null else position,
        stillLearning = stillLearning,
        valueText = env.format.full(metricId, value),
        deltaText = delta,
    )
}

private fun signedDelta(env: AppEnvironment, metricId: String, value: Double, center: Double): String {
    val delta = value - center
    val sign = if (delta >= 0) "+" else "−"
    val magnitude = env.format.full(metricId, abs(delta))
    return "$sign$magnitude · ${env.s(InsightsStrings.vsUsual)}"
}

// MARK: - Strings (bilingual, wellness-safe)

private object InsightsStrings {
    val weeklyTitle = LocalizedString(en = "This week", ar = "هذا الأسبوع")
    val weeklySubtitle = LocalizedString(
        en = "What changed against your usual range.",
        ar = "ما الذي تغيّر مقارنةً بنطاقك المعتاد.",
    )
    val feedTitle = LocalizedString(en = "Recent insights", ar = "أحدث الملاحظات")
    val helpful = LocalizedString(en = "Was this helpful?", ar = "هل كان هذا مفيداً؟")
    val thumbsUp = LocalizedString(en = "Helpful", ar = "مفيد")
    val thumbsDown = LocalizedString(en = "Not helpful", ar = "غير مفيد")
    val whyTitle = LocalizedString(en = "Why am I seeing this?", ar = "لماذا أرى هذا؟")
    val templateLabel = LocalizedString(en = "Template", ar = "القالب")
    val generatedLabel = LocalizedString(en = "Generated", ar = "تاريخ الإنشاء")
    val vsUsual = LocalizedString(en = "vs your usual", ar = "مقارنةً بالمعتاد")
    val emptyTitle = LocalizedString(en = "No insights yet", ar = "لا ملاحظات بعد")
    val emptyMessage = LocalizedString(
        en = "As your data builds up, gentle observations will appear here.",
        ar = "مع تراكم بياناتك، ستظهر هنا ملاحظات لطيفة.",
    )
    val footerNote = LocalizedString(
        en = "Insights are worked out on your device with fixed rules — no AI, and nothing leaves your phone.",
        ar = "تُحسَب الملاحظات على جهازك بقواعد ثابتة — بلا ذكاء اصطناعي، ولا يغادر أي شيء هاتفك.",
    )
}
