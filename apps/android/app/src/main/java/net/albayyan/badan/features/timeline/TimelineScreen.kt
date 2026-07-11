package net.albayyan.badan.features.timeline

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.EmptyState
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.TimelineEvent
import net.albayyan.badan.domain.TimelineEventType
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * The unified chronological spine: sleep, workouts, meds, symptoms, meals, notes and body
 * measurements gathered into one calm, day-grouped feed (see [TimelineAssembler]). Casual shows
 * simple rows; power adds multi-select type filters and a subtle per-row provenance hint. Same
 * data, two altitudes. Faithful port of the iOS `TimelineScreen`.
 */
@Composable
fun TimelineScreen() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    var state by remember { mutableStateOf<LoadState<List<TimelineEvent>>>(LoadState.Loading) }
    // Power-only, multi-select type filters. Persist across re-localizing reloads (a power
    // affordance); casual always shows the full spine.
    val selectedTypes = remember { mutableStateListOf<TimelineEventType>() }

    // Reload the assembled read-model whenever a presentation preference (language, digits,
    // units, depth) changes so every pre-formatted value re-localizes. The prior content stays
    // on screen while the new one assembles, so re-localizing never flashes a spinner.
    LaunchedEffect(env.profile) {
        val result = withContext(Dispatchers.IO) {
            runCatching { TimelineAssembler(env).assemble() }
        }
        state = result.fold(
            onSuccess = { events ->
                if (events.isEmpty()) LoadState.Empty(env.s(Loc.noEventsInRange))
                else LoadState.Loaded(events)
            },
            onFailure = { LoadState.Error(it.message ?: it.toString()) },
        )
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
    ) {
        StatefulContainer(state) { events ->
            TimelineLoaded(events = events, selectedTypes = selectedTypes)
        }
    }
}

// MARK: - Loaded content

@Composable
private fun TimelineLoaded(
    events: List<TimelineEvent>,
    selectedTypes: SnapshotStateList<TimelineEventType>,
) {
    val env = LocalAppEnvironment.current
    val power = env.depth.showsPowerDetail
    // Filters are a power affordance; casual always shows the full spine.
    val active = if (power) selectedTypes.toSet() else emptySet()
    val visible = if (active.isEmpty()) events else events.filter { it.type in active }
    val days = groupByDay(visible)

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
    ) {
        if (power) {
            item(key = "filters") { FilterBar(events = events, selection = selectedTypes) }
        }
        if (days.isEmpty()) {
            item(key = "filtered-empty") {
                FilteredEmptyState(onClear = { selectedTypes.clear() })
            }
        } else {
            items(days, key = { it.key }) { day -> DaySection(day) }
            item(key = "history-start") { HistoryStartFooter() }
        }
    }
}

// MARK: - Day sections & rows

@Composable
private fun DaySection(day: TimelineDay) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(env.s(dayLabel(day.key, env)))
        BadanCard {
            day.events.forEachIndexed { index, event ->
                if (index > 0) {
                    HorizontalDivider(
                        modifier = Modifier.padding(vertical = BadanSpace.s2),
                        thickness = 1.dp,
                        color = colors.separator,
                    )
                }
                EventRow(event)
            }
        }
    }
}

@Composable
private fun EventRow(event: TimelineEvent) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val valueStyle = BadanType.bodyCompact.copy(
        fontWeight = FontWeight.Medium,
        fontFeatureSettings = "tnum",
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier.size(28.dp),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = iconForKey(event.symbolName),
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }

        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(
                text = env.s(event.title),
                style = BadanType.body,
                color = colors.textPrimary,
            )
            event.subtitle?.let { subtitle ->
                Text(
                    text = env.s(subtitle),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
            // Power-only: a quiet line naming where this row came from.
            if (env.depth.showsPowerDetail) {
                event.ingestionPath?.let { path ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Circle,
                            contentDescription = null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(8.dp),
                        )
                        Text(
                            text = env.s(path.displayLabel),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }
        }

        Column(
            horizontalAlignment = Alignment.End,
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            event.valueText?.let { value ->
                Text(
                    text = value,
                    style = valueStyle,
                    color = colors.textPrimary,
                    textAlign = TextAlign.End,
                )
            }
            Text(
                text = timeText(event.occurredAt, event.tzId, env),
                style = BadanType.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.End,
            )
        }
    }
}

// MARK: - Filters (power only)

@Composable
private fun FilterBar(
    events: List<TimelineEvent>,
    selection: SnapshotStateList<TimelineEventType>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Row(
            modifier = Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            presentTypes(events).forEach { type ->
                FilterChip(type = type, selection = selection)
            }
        }
        if (selection.isNotEmpty()) {
            ClearFiltersLink(onClick = { selection.clear() }, alignment = Alignment.CenterStart)
        }
    }
}

@Composable
private fun FilterChip(
    type: TimelineEventType,
    selection: SnapshotStateList<TimelineEventType>,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val isOn = type in selection
    val fg = if (isOn) Color.White else colors.textSecondary
    Row(
        modifier = Modifier
            .heightIn(min = BadanSpace.touchMin)
            .clip(RoundedCornerShape(BadanRadius.chip))
            .background(if (isOn) colors.primary else colors.surfaceElevated)
            .clickable {
                if (isOn) selection.remove(type) else selection.add(type)
            }
            .padding(horizontal = BadanSpace.s3, vertical = BadanSpace.s2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Icon(
            imageVector = iconForKey(type.symbolName),
            contentDescription = null,
            tint = fg,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = env.s(type.displayName),
            style = BadanType.chip,
            color = fg,
        )
    }
}

// MARK: - Empty & footer surfaces

@Composable
private fun FilteredEmptyState(onClear: () -> Unit) {
    val env = LocalAppEnvironment.current
    EmptyState(
        icon = Icons.Filled.FilterList,
        title = env.s(Loc.noEventsInRange),
        message = "",
    ) {
        ClearFiltersLink(onClick = onClear, alignment = Alignment.Center)
    }
}

@Composable
private fun ClearFiltersLink(onClick: () -> Unit, alignment: Alignment) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Box(
        modifier = Modifier
            .heightIn(min = BadanSpace.touchMin)
            .clickable(onClick = onClick),
        contentAlignment = alignment,
    ) {
        Text(
            text = env.s(Loc.clearFilters),
            style = BadanType.chip.copy(fontWeight = FontWeight.Medium),
            color = colors.primary,
        )
    }
}

@Composable
private fun HistoryStartFooter() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = BadanSpace.s2),
        horizontalArrangement = Arrangement.Center,
    ) {
        Text(
            text = env.s(Loc.historyStart),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

// MARK: - Grouping & formatting helpers

/** A day's worth of events, newest day first, newest event first within the day. */
private data class TimelineDay(val key: String, val events: List<TimelineEvent>)

private fun groupByDay(events: List<TimelineEvent>): List<TimelineDay> {
    val buckets = LinkedHashMap<String, MutableList<TimelineEvent>>()
    for (event in events) {   // already sorted newest-first
        val key = DayAttribution.localDayKey(event.occurredAt, event.tzId)
        buckets.getOrPut(key) { mutableListOf() }.add(event)
    }
    // "YYYY-MM-DD" sorts chronologically as a string; descending = newest day first.
    return buckets.keys.sortedDescending().map { TimelineDay(it, buckets[it] ?: emptyList()) }
}

private fun presentTypes(events: List<TimelineEvent>): List<TimelineEventType> {
    val present = events.mapTo(HashSet()) { it.type }
    return TimelineEventType.entries.filter { it in present }
}

private fun dayLabel(key: String, env: AppEnvironment): LocalizedString {
    val tz = TimeZone.getDefault().id
    val todayKey = DayAttribution.localDayKey(env.now(), tz)
    val yesterdayKey = DayAttribution.localDayKey(DayAttribution.addingDays(-1, env.now(), tz), tz)
    if (key == todayKey) return Loc.today
    if (key == yesterdayKey) return LocalizedString(en = "Yesterday", ar = "أمس")
    val millis = DayAttribution.dateFromDayKey(key, tz) ?: return LocalizedString(en = key, ar = key)
    return LocalizedString(
        en = formattedDate(millis, AppLanguage.EN, tz),
        ar = formattedDate(millis, AppLanguage.AR, tz),
    )
}

private fun formattedDate(millis: Long, language: AppLanguage, tz: String): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "EEEEdMMM")
    val formatter = SimpleDateFormat(pattern, locale)
    formatter.timeZone = TimeZone.getTimeZone(tz)
    return formatter.format(Date(millis))
}

private fun timeText(millis: Long, tz: String, env: AppEnvironment): String {
    val locale = Locale.forLanguageTag(env.language.localeTag)
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "jm")
    val formatter = SimpleDateFormat(pattern, locale)
    formatter.timeZone = TimeZone.getTimeZone(tz)
    return formatter.format(Date(millis))
}
