package net.albayyan.badan.features.loghub

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.core.Units
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.RawSample
import java.util.TimeZone

// MARK: - File-local strings (bilingual; not in the shared catalog)

private val quickAddTitle = LocalizedString(en = "Quick add", ar = "إضافة سريعة")
private val mlUnit = LocalizedString(en = "ml", ar = "مل")
private val storedManually = LocalizedString(en = "Saved as your own entry", ar = "يُحفَظ كإدخال منك")
private val justNow = LocalizedString(en = "just now", ar = "الآن")
private val customAmount = LocalizedString(en = "Custom amount", ar = "كمية مخصصة")
private val thisWeek = LocalizedString(en = "this week", ar = "هذا الأسبوع")
private val earlier = LocalizedString(en = "earlier", ar = "سابقًا")
private val quickTag = LocalizedString(en = "Quick", ar = "سريع")

// MARK: - Recents model

private enum class RecentKind { SYMPTOM, WORKOUT }

private data class RecentItem(
    val id: String,
    val label: String,
    val iconKey: String,
    val date: Long,
    val kind: RecentKind,
    /** How many times this label recurred within the recents window (30 days). */
    val count: Int,
)

private enum class LogSheet { WATER, WEIGHT }

/**
 * The Log tab. A grid of log types gated by the sensitive-modules / nutrition toggles that push
 * the four dedicated log editors, plus inline quick-add sheets for Water and Weight, and a
 * recents row of the last few symptom / workout entries surfaced as "log again" chips. Faithful
 * port of the iOS `LogHubScreen` — same gating, same dual-altitude (recents show a relative-time
 * detail only in power depth). Navigation tiles render immediately; recents load off-thread.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogHubScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var recents by remember { mutableStateOf<List<RecentItem>>(emptyList()) }
    var activeSheet by remember { mutableStateOf<LogSheet?>(null) }

    // Recents are a secondary surface: load them off the main thread and reveal the row only when
    // there is something to show. Re-runs if the sensitive gate or language changes so labels and
    // visibility stay honest. (The navigation tiles themselves never wait on data.)
    LaunchedEffect(env.profile.sensitiveModulesEnabled, env.language) {
        recents = withContext(Dispatchers.IO) { loadRecents(env) }
    }

    val logTypeCells = buildList<@Composable () -> Unit> {
        // Symptom & Medication are sensitive — hidden entirely when that module is off.
        if (env.profile.sensitiveModulesEnabled) {
            add { LogTile(title = env.s(Loc.logSymptom), iconKey = "healing") { nav.push(Route.SymptomLog) } }
            add { LogTile(title = env.s(Loc.logMedication), iconKey = "medication") { nav.push(Route.MedicationLog) } }
        }
        add { LogTile(title = env.s(Loc.logWorkout), iconKey = "directions_run") { nav.push(Route.WorkoutLog) } }
        if (env.profile.nutritionEnabled) {
            add { LogTile(title = env.s(Loc.logFood), iconKey = "restaurant") { nav.push(Route.NutritionLog) } }
        }
    }

    val quickAddCells = listOf<@Composable () -> Unit>(
        { LogTile(title = env.s(Loc.logWater), iconKey = "water_drop", isQuickAdd = true) { activeSheet = LogSheet.WATER } },
        { LogTile(title = env.s(Loc.logWeight), iconKey = "monitor_weight", isQuickAdd = true) { activeSheet = LogSheet.WEIGHT } },
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .verticalScroll(rememberScrollState())
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s6),
    ) {
        Text(
            text = env.s(Loc.logTitle),
            style = BadanType.sectionTitle.copy(fontSize = 28.sp),
            color = colors.textPrimary,
        )

        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(title = env.s(Loc.tabLog))
            TileGrid(cells = logTypeCells)
        }

        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(title = env.s(quickAddTitle))
            TileGrid(cells = quickAddCells)
        }

        if (recents.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(Loc.recents))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = BadanSpace.s1),
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    for (item in recents) {
                        // Time cue is always shown (coarse for casual/balanced, precise "N min
                        // ago" for power); a frequency cue is layered on at every depth so a
                        // recurring pattern reads differently from a one-off entry at a glance.
                        val timeLabel = if (env.depth.showsPowerDetail) {
                            relativeTime(env, item.date)
                        } else {
                            coarseRelativeTime(env, item.date)
                        }
                        val freqLabel = frequencyLabel(env, item.count)
                        RecentChip(
                            label = item.label,
                            iconKey = item.iconKey,
                            detail = listOfNotNull(timeLabel, freqLabel).joinToString(" · "),
                            onClick = {
                                when (item.kind) {
                                    RecentKind.SYMPTOM -> nav.push(Route.SymptomLog)
                                    RecentKind.WORKOUT -> nav.push(Route.WorkoutLog)
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    if (activeSheet != null) {
        val sheetState = rememberModalBottomSheetState()
        ModalBottomSheet(
            onDismissRequest = { activeSheet = null },
            sheetState = sheetState,
            containerColor = colors.background,
        ) {
            when (activeSheet) {
                LogSheet.WATER -> WaterQuickSheet(
                    onLog = { ml ->
                        scope.launch(Dispatchers.IO) { logWater(env, ml) }
                        activeSheet = null
                    },
                    onCancel = { activeSheet = null },
                )
                LogSheet.WEIGHT -> WeightQuickSheet(
                    onLog = { value ->
                        scope.launch(Dispatchers.IO) { logWeight(env, value) }
                        activeSheet = null
                    },
                    onCancel = { activeSheet = null },
                )
                null -> Unit
            }
        }
    }
}

// MARK: - Grid

/** Lays a list of tile cells out two-per-row, each cell taking an equal half-width. */
@Composable
private fun TileGrid(cells: List<@Composable () -> Unit>, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        for (row in cells.chunked(2)) {
            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                for (cell in row) {
                    Box(modifier = Modifier.weight(1f)) { cell() }
                }
                if (row.size == 1) {
                    Spacer(modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

// MARK: - Tiles & chips

@Composable
private fun LogTile(title: String, iconKey: String, isQuickAdd: Boolean = false, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard(
        modifier = Modifier
            .clip(RoundedCornerShape(BadanRadius.card))
            .clickable(onClick = onClick),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 92.dp),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Box(
                modifier = Modifier
                    .size(BadanSpace.touchMin)
                    .background(
                        color = colors.primary.copy(alpha = 0.12f),
                        shape = RoundedCornerShape(BadanRadius.control),
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = iconForKey(iconKey),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(22.dp),
                )
            }
            Text(
                text = title,
                style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            // Quick-add tiles open a compact sheet rather than a full-screen editor; a small
            // caption sets that expectation before the tap (screen-push tiles have none).
            if (isQuickAdd) {
                Text(
                    text = env.s(quickTag),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun RecentChip(
    label: String,
    iconKey: String,
    detail: String?,
    onClick: () -> Unit,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .clickable(onClick = onClick)
            .background(color = colors.surfaceElevated, shape = CircleShape)
            .border(width = 1.dp, color = colors.separator, shape = CircleShape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = iconForKey(iconKey),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(18.dp),
        )
        Column {
            Text(text = label, style = BadanType.chip, color = colors.textPrimary)
            if (detail != null) {
                Text(text = detail, style = BadanType.caption, color = colors.textSecondary)
            }
        }
    }
}

// MARK: - Quick-log sheets

@Composable
private fun WaterQuickSheet(onLog: (Double) -> Unit, onCancel: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val amounts = listOf(250.0, 500.0)

    // Custom amount, mirroring WeightQuickSheet's free-text pattern: presets cover the common
    // cases (a glass, a bottle) but a can (330ml) or a large bottle (750ml) has no preset.
    var customText by remember { mutableStateOf("") }
    val customParsed = remember(customText) {
        customText.replace(",", ".").trim().toDoubleOrNull()?.takeIf { it > 0.0 }
    }

    // Pre-fill with the most recently logged amount so a repeat entry starts from something
    // useful instead of blank, without clobbering anything the user has already typed.
    LaunchedEffect(Unit) {
        val last = withContext(Dispatchers.IO) { lastWaterMl(env) }
        if (last != null && customText.isEmpty()) {
            customText = trimmedNumber(last)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        SheetHeader(title = env.s(Loc.logWater), onCancel = onCancel)
        for (ml in amounts) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(BadanRadius.card))
                    .clickable { onLog(ml) }
                    .background(color = colors.surface, shape = RoundedCornerShape(BadanRadius.card))
                    .border(
                        width = 1.dp,
                        color = colors.separator,
                        shape = RoundedCornerShape(BadanRadius.card),
                    )
                    .heightIn(min = 60.dp)
                    .padding(horizontal = BadanSpace.s4),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = iconForKey("water_drop"),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = "+${env.format.integer(ml.toInt())} ${env.s(mlUnit)}",
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(BadanRadius.card))
                .background(color = colors.surface, shape = RoundedCornerShape(BadanRadius.card))
                .border(
                    width = 1.dp,
                    color = colors.separator,
                    shape = RoundedCornerShape(BadanRadius.card),
                )
                .heightIn(min = 60.dp)
                .padding(horizontal = BadanSpace.s4),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Box(modifier = Modifier.weight(1f)) {
                if (customText.isEmpty()) {
                    Text(
                        text = env.s(customAmount),
                        style = BadanType.numeralM,
                        color = colors.textSecondary.copy(alpha = 0.6f),
                    )
                }
                BasicTextField(
                    value = customText,
                    onValueChange = { customText = it },
                    textStyle = BadanType.numeralM.copy(color = colors.textPrimary),
                    singleLine = true,
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { customParsed?.let(onLog) }),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Text(text = env.s(mlUnit), style = BadanType.body, color = colors.textSecondary)
            TextButton(onClick = { customParsed?.let(onLog) }, enabled = customParsed != null) {
                Text(
                    text = env.s(Loc.add),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = if (customParsed != null) colors.primary else colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun WeightQuickSheet(onLog: (Double) -> Unit, onCancel: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    var text by remember { mutableStateOf("") }
    val parsed = remember(text) {
        text.replace(",", ".").trim().toDoubleOrNull()?.takeIf { it > 0.0 }
    }
    val focusRequester = remember { FocusRequester() }

    val canonicalUnit = env.registry.definitionOrFallback(MetricId.weight).canonicalUnit
    val unitLabel = env.format.unitLabel(MetricId.weight) ?: canonicalUnit

    // Auto-focus on open (one less tap on this "under-10-second" quick-log path) and pre-fill
    // with the last logged weight, without clobbering anything the user has already typed.
    LaunchedEffect(Unit) {
        focusRequester.requestFocus()
        val last = withContext(Dispatchers.IO) { lastWeightDisplayValue(env) }
        if (last != null && text.isEmpty()) {
            text = trimmedNumber(last)
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
    ) {
        SheetHeader(
            title = env.s(Loc.logWeight),
            onCancel = onCancel,
            confirmLabel = env.s(Loc.save),
            confirmEnabled = parsed != null,
            onConfirm = { parsed?.let(onLog) },
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(BadanRadius.card))
                .background(color = colors.surface, shape = RoundedCornerShape(BadanRadius.card))
                .border(
                    width = 1.dp,
                    color = colors.separator,
                    shape = RoundedCornerShape(BadanRadius.card),
                )
                .heightIn(min = 60.dp)
                .padding(horizontal = BadanSpace.s4),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Box(modifier = Modifier.weight(1f)) {
                if (text.isEmpty()) {
                    Text(
                        text = env.s(Loc.logWeight),
                        style = BadanType.numeralM,
                        color = colors.textSecondary.copy(alpha = 0.6f),
                    )
                }
                BasicTextField(
                    value = text,
                    onValueChange = { text = it },
                    textStyle = BadanType.numeralM.copy(color = colors.textPrimary),
                    singleLine = true,
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { parsed?.let(onLog) }),
                    modifier = Modifier
                        .fillMaxWidth()
                        .focusRequester(focusRequester),
                )
            }
            Text(text = unitLabel, style = BadanType.body, color = colors.textSecondary)
        }

        // Power altitude: name where this number will live (canonical unit + manual provenance).
        if (env.depth.showsPowerDetail) {
            Text(
                text = "${env.s(storedManually)} · $canonicalUnit",
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

/** A sheet title row with a leading Cancel action and an optional trailing confirm action. */
@Composable
private fun SheetHeader(
    title: String,
    onCancel: () -> Unit,
    confirmLabel: String? = null,
    confirmEnabled: Boolean = false,
    onConfirm: (() -> Unit)? = null,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        TextButton(onClick = onCancel) {
            Text(text = LocalAppEnvironment.current.s(Loc.cancel), style = BadanType.body, color = colors.textSecondary)
        }
        Text(
            text = title,
            style = BadanType.sectionTitle,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        if (confirmLabel != null && onConfirm != null) {
            TextButton(onClick = onConfirm, enabled = confirmEnabled) {
                Text(
                    text = confirmLabel,
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = if (confirmEnabled) colors.primary else colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Data loading & mutations (non-composable)

/** A single raw symptom/workout occurrence, before grouping into a recents chip. */
private data class RecentOccurrence(
    val id: String,
    val label: String,
    val iconKey: String,
    val date: Long,
    val kind: RecentKind,
)

/**
 * Recent symptom / workout entries from the last 30 days, surfaced as quick "log again" chips.
 * Selection blends recency with frequency (a recency-weighted count) rather than pure
 * most-recent-first, so a consistently repeated symptom/workout isn't crowded out of the row by
 * a single one-off logged slightly more recently.
 */
private fun loadRecents(env: AppEnvironment): List<RecentItem> {
    val now = env.now()
    val windowMillis = 30L * 86_400_000L
    val from = now - windowMillis

    val items = mutableListOf<RecentItem>()

    // Symptoms are sensitive — only touch that store when the module is enabled.
    if (env.profile.sensitiveModulesEnabled) {
        val occurrences = runCatching { env.logging.symptoms(from, now) }.getOrNull().orEmpty().map { s ->
            val label = env.symptoms.displayName(s.symptomId, s.customLabel).resolved(env.language)
            RecentOccurrence(id = s.id, label = label, iconKey = "healing", date = s.occurredAt, kind = RecentKind.SYMPTOM)
        }
        items += rankRecents(occurrences, now = now, windowMillis = windowMillis)
    }

    val workoutOccurrences = runCatching { env.logging.workouts(from, now) }.getOrNull().orEmpty().map { w ->
        RecentOccurrence(id = w.id, label = w.activityType, iconKey = "directions_run", date = w.startAt, kind = RecentKind.WORKOUT)
    }
    items += rankRecents(workoutOccurrences, now = now, windowMillis = windowMillis)

    return items.sortedByDescending { it.date }
}

/**
 * Groups occurrences by label, scores each group by recency-weighted count (recent + frequent
 * beats merely most-recent), and returns the top 3 as display-ready [RecentItem]s.
 */
private fun rankRecents(occurrences: List<RecentOccurrence>, now: Long, windowMillis: Long): List<RecentItem> {
    return occurrences
        .groupBy { it.label }
        .map { (label, group) ->
            val mostRecent = group.maxBy { it.date }
            val count = group.size
            val recency = (1.0 - (now - mostRecent.date).toDouble() / windowMillis).coerceIn(0.0, 1.0)
            val score = count + recency
            score to RecentItem(
                id = mostRecent.id,
                label = label,
                iconKey = mostRecent.iconKey,
                date = mostRecent.date,
                kind = mostRecent.kind,
                count = count,
            )
        }
        .sortedByDescending { it.first }
        .take(3)
        .map { it.second }
}

/** The most recently logged water amount (any meal-type entry with a water value), if any. */
private fun lastWaterMl(env: AppEnvironment): Double? {
    val now = env.now()
    val from = now - 90L * 86_400_000L
    return runCatching { env.logging.nutrition(from, now) }.getOrNull()
        ?.firstOrNull { (it.waterMl ?: 0.0) > 0.0 }
        ?.waterMl
}

/** The most recently logged weight, converted into the user's current display unit. */
private fun lastWeightDisplayValue(env: AppEnvironment): Double? {
    val def = env.registry.definitionOrFallback(MetricId.weight)
    val displayUnit = env.format.displayUnit(def)
    val now = env.now()
    val from = now - 365L * 86_400_000L
    val sample = runCatching { env.measurements.rawSamples(def.metricId, from, now) }.getOrNull()?.lastOrNull()
        ?: return null
    return if (sample.originalUnit == displayUnit) {
        sample.originalValue
    } else {
        Units.convert(sample.value, from = def.canonicalUnit, to = displayUnit)
    }
}

/** Formats a pre-fill value as plain text matching the quick-add fields' own parse rules. */
private fun trimmedNumber(value: Double): String {
    val rounded = kotlin.math.round(value * 10.0) / 10.0
    return if (rounded == rounded.toLong().toDouble()) {
        rounded.toLong().toString()
    } else {
        rounded.toString()
    }
}

private fun logWater(env: AppEnvironment, milliliters: Double) {
    val now = env.now()
    val entry = NutritionEntry(
        id = Ulid.newId(),
        description = env.s(Loc.logWater),
        mealType = MealType.DRINK,
        waterMl = milliliters,
        occurredAt = now,
        tzId = TimeZone.getDefault().id,
        updatedAt = now,
        originDeviceId = env.deviceId,
    )
    runCatching { env.logging.upsertNutrition(entry) }
}

private fun logWeight(env: AppEnvironment, displayValue: Double) {
    val def = env.registry.definitionOrFallback(MetricId.weight)
    val displayUnit = env.format.displayUnit(def)
    val canonicalValue = Units.toCanonical(displayValue, from = displayUnit, canonical = def.canonicalUnit)
    val now = env.now()
    val tz = TimeZone.getDefault().id
    val provenance = Provenance(
        sourceId = env.deviceId,
        deviceId = env.deviceId,
        ingestionPath = IngestionPath.MANUAL,
        measuredAt = now,
        measuredTimezone = tz,
        recordedAt = now,
        ingestedAt = now,
    )
    val sample = RawSample(
        id = Ulid.newId(),
        metricId = def.metricId,
        value = canonicalValue,
        unit = def.canonicalUnit,
        originalValue = displayValue,
        originalUnit = displayUnit,
        startAt = now,
        tzId = tz,
        provenance = provenance,
        updatedAt = now,
        originDeviceId = env.deviceId,
    )
    runCatching { env.measurements.upsertRawSample(sample) }
}

// MARK: - Relative time (recents chips)
//
// Convention: recents chips use relative phrasing ("5 min ago") rather than absolute timestamps
// because their entire purpose is answering "how recent is this suggestion" for fast re-logging —
// a "just happened" framing, not a historical record. Screens that show a durable log of past
// entries (Metric Detail, Workout/Nutrition rows, Provenance) use absolute timestamps instead,
// since those are records to be read precisely, not recency cues to act on. Power depth gets the
// precise granularity ("5 min ago" / "2 h ago"); casual/balanced depth gets a coarser bucket
// (today / this week / earlier) so the same "how recent" signal is legible without power-user detail.

/** A compact, bilingual "how long ago" label; precise granularity, shown at power depth. */
private fun relativeTime(env: AppEnvironment, millis: Long): String {
    val delta = (env.now() - millis).coerceAtLeast(0L)
    val minutes = delta / 60_000L
    val hours = delta / 3_600_000L
    val days = delta / 86_400_000L
    val ar = env.language == AppLanguage.AR
    return when {
        minutes < 1L -> env.s(justNow)
        hours < 1L -> {
            val n = env.format.integer(minutes.toInt())
            if (ar) "قبل $n د" else "$n min ago"
        }
        days < 1L -> {
            val n = env.format.integer(hours.toInt())
            if (ar) "قبل $n س" else "$n h ago"
        }
        else -> {
            val n = env.format.integer(days.toInt())
            if (ar) "قبل $n ي" else "$n d ago"
        }
    }
}

/** A coarse, bilingual "how long ago" bucket for casual/balanced depth: today / this week / earlier. */
private fun coarseRelativeTime(env: AppEnvironment, millis: Long): String {
    val delta = (env.now() - millis).coerceAtLeast(0L)
    val days = delta / 86_400_000L
    return when {
        days < 1L -> env.s(Loc.today)
        days < 7L -> env.s(thisWeek)
        else -> env.s(earlier)
    }
}

/** A lightweight "3×" recurrence cue; omitted for one-off items where it would add no signal. */
private fun frequencyLabel(env: AppEnvironment, count: Int): String? {
    if (count <= 1) return null
    return "${env.format.integer(count)}×"
}
