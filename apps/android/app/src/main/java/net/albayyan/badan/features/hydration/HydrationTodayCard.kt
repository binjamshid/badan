package net.albayyan.badan.features.hydration

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
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
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.hydration.HydrationEntry
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import kotlin.math.roundToInt

// MARK: - UI-state types

/** The transient "Added 500 mL from Bottle" confirmation, carrying the exact row to Undo. */
data class HydrationConfirmation(val entry: HydrationEntry, val message: LocalizedString)

/** Which hydration bottom sheet is open (custom-log — new or editing — or goal settings). */
sealed interface HydrationSheet {
    data class Custom(val editing: HydrationEntry?) : HydrationSheet
    data object Goal : HydrationSheet
}

/** Whole-mL display of a stored volume — hydration is logged and shown in whole millilitres. */
private fun mlText(format: net.albayyan.badan.app.ValueFormatter, ml: Double): String =
    format.integer(ml.roundToInt())

// MARK: - Section (stateful entry point used by LogHub)

/**
 * The whole hydration surface for the Log tab: the Today card, the observational weekly card, and
 * the custom-log / goal sheets — or, when the user has hidden the module, a single calm "Hydration
 * is hidden · Show" row. Owns its own load/refresh + sheet + confirmation state so LogHub only has
 * to place it. Faithful behavioural mirror of the iOS hydration surface; Material/Compose idiom.
 *
 * Hiding is non-destructive (§7A.1 "hideable without deletion"): the flag lives on the presentation
 * profile exactly like `nutritionEnabled`, so the ledger, goals and summaries are all untouched and
 * "Show" brings the same data straight back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HydrationSection() {
    val env = LocalAppEnvironment.current
    val scope = rememberCoroutineScope()

    if (!env.profile.hydrationEnabled) {
        HydrationHiddenNotice(onShow = { env.update { it.copy(hydrationEnabled = true) } })
        return
    }

    var today by remember { mutableStateOf(HydrationTodayState.empty) }
    var week by remember { mutableStateOf(HydrationWeek(emptyList())) }
    var activeSheet by remember { mutableStateOf<HydrationSheet?>(null) }
    var confirmation by remember { mutableStateOf<HydrationConfirmation?>(null) }

    suspend fun refresh() {
        today = loadTodayAsync(env)
        week = loadWeekAsync(env)
    }

    // Reload when the language flips (labels/weekday names) and on first composition.
    LaunchedEffect(env.language) { refresh() }

    // The confirmation is a courtesy, not a modal: it fades itself after a few seconds so it never
    // becomes a sticky banner demanding dismissal. Undo stays reachable in the entries list too.
    LaunchedEffect(confirmation) {
        if (confirmation != null) {
            delay(6_000)
            confirmation = null
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
        HydrationTodayCard(
            state = today,
            confirmation = confirmation,
            onLogFavorite = { favorite ->
                scope.launch {
                    val entry = withContext(Dispatchers.IO) { HydrationData.logFavorite(env, favorite) }
                    val beverage = env.beverages.beverage(favorite.beverageId)
                    confirmation = HydrationConfirmation(
                        entry = entry,
                        message = HydrationStrings.addedFrom(
                            amount = mlText(env.format, favorite.volumeMl),
                            unit = env.s(HydrationStrings.ml),
                            container = env.s(favorite.name),
                            beverage = beverage?.takeIf { it.id != "water" }?.let { env.s(it.displayName) },
                        ),
                    )
                    refresh()
                }
            },
            onCustom = { activeSheet = HydrationSheet.Custom(editing = null) },
            onOpenEntry = { activeSheet = HydrationSheet.Custom(editing = it) },
            onUndo = { c ->
                scope.launch {
                    withContext(Dispatchers.IO) { HydrationData.undo(env, c.entry) }
                    confirmation = null
                    refresh()
                }
            },
            onOpenGoal = { activeSheet = HydrationSheet.Goal },
            onHide = { env.update { it.copy(hydrationEnabled = false) } },
        )

        // The weekly card is observational and appears once there is anything to observe — never an
        // empty seven-bar skeleton nagging the user to fill it.
        if (week.anyLogs) {
            HydrationWeeklyCard(week)
        }
    }

    val sheet = activeSheet
    if (sheet != null) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { activeSheet = null },
            sheetState = sheetState,
            containerColor = BadanTheme.colors.background,
        ) {
            when (sheet) {
                is HydrationSheet.Custom -> HydrationCustomSheet(
                    editing = sheet.editing,
                    onCommit = {
                        activeSheet = null
                        confirmation = null
                        scope.launch { refresh() }
                    },
                    onDeleted = {
                        activeSheet = null
                        confirmation = null
                        scope.launch { refresh() }
                    },
                    onCancel = { activeSheet = null },
                )
                HydrationSheet.Goal -> HydrationGoalSheet(
                    onSaved = {
                        activeSheet = null
                        scope.launch { refresh() }
                    },
                    onCancel = { activeSheet = null },
                )
            }
        }
    }
}

// MARK: - Today card

@Composable
private fun HydrationTodayCard(
    state: HydrationTodayState,
    confirmation: HydrationConfirmation?,
    onLogFavorite: (HydrationFavorite) -> Unit,
    onCustom: () -> Unit,
    onOpenEntry: (HydrationEntry) -> Unit,
    onUndo: (HydrationConfirmation) -> Unit,
    onOpenGoal: () -> Unit,
    onHide: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            // Header: title + overflow (goal settings / hide). SectionHeader mirrors correctly RTL.
            SectionHeader(
                title = env.s(HydrationStrings.waterToday),
                trailing = { OverflowMenu(onOpenGoal = onOpenGoal, onHide = onHide) },
            )

            HydrationProgressBlock(progress = state.progress)

            // Favorites — one-tap logging (≤2 actions). The custom chip opens the fuller sheet.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(vertical = BadanSpace.s1),
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                for (favorite in state.favorites) {
                    FavoriteChip(favorite = favorite, onClick = { onLogFavorite(favorite) })
                }
                CustomChip(onClick = onCustom)
            }

            // Transient confirmation with Undo, right where the eye already is after a tap.
            if (confirmation != null) {
                ConfirmationRow(confirmation = confirmation, onUndo = { onUndo(confirmation) })
            }

            // Today's entries — tap a row to edit or delete it.
            if (state.entries.isEmpty()) {
                Text(
                    text = env.s(HydrationStrings.nothingYet),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                    for (entry in state.entries) {
                        EntryRow(entry = entry, onClick = { onOpenEntry(entry) })
                    }
                }
            }
        }
    }
}

@Composable
private fun OverflowMenu(onOpenGoal: () -> Unit, onHide: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { expanded = true }) {
            Icon(
                imageVector = Icons.Filled.MoreVert,
                contentDescription = env.s(moreOptions),
                tint = colors.textSecondary,
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            DropdownMenuItem(
                text = { Text(env.s(HydrationStrings.goalSettings)) },
                onClick = { expanded = false; onOpenGoal() },
            )
            DropdownMenuItem(
                text = { Text(env.s(HydrationStrings.hideModule)) },
                onClick = { expanded = false; onHide() },
            )
        }
    }
}

/**
 * The calm progress block. With a goal: a gentle single-tint bar (never green/red, never a >100%
 * overflow) plus "1,250 / 2,000 mL". Without a goal — the equal-status default — just the logged
 * total, with no bar and no percentage, because a percentage-of-nothing is the streak-guilt framing
 * §7A.1 rejects.
 */
@Composable
private fun HydrationProgressBlock(progress: HydrationProgress) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val unit = env.s(HydrationStrings.ml)

    when (progress) {
        is HydrationProgress.NoGoal -> {
            Text(
                text = env.s(HydrationStrings.totalLine(mlText(env.format, progress.totalMl), unit)),
                style = BadanType.numeralM,
                color = colors.textPrimary,
            )
        }
        is HydrationProgress.WithGoal -> {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                Text(
                    text = env.s(
                        HydrationStrings.goalLine(
                            amount = mlText(env.format, progress.totalMl),
                            target = mlText(env.format, progress.targetMl),
                            unit = unit,
                        ),
                    ),
                    style = BadanType.numeralM,
                    color = colors.textPrimary,
                )
                CalmProgressBar(fraction = progress.barFraction)
            }
        }
    }
}

/** A single-tint rounded progress track. Drawn by hand (two Boxes) to keep the exact calm look. */
@Composable
private fun CalmProgressBar(fraction: Float) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(shape)
            .background(colors.surfaceElevated),
    ) {
        // fillMaxWidth(fraction) mirrors under RTL automatically (fills from the start edge).
        Box(
            modifier = Modifier
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .fillMaxHeight()
                .clip(shape)
                .background(colors.primary),
        )
    }
}

@Composable
private fun FavoriteChip(favorite: HydrationFavorite, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    val label = "${env.s(favorite.name)} · ${mlText(env.format, favorite.volumeMl)} ${env.s(HydrationStrings.ml)}"
    Row(
        modifier = Modifier
            .clip(shape)
            .clickable(onClick = onClick)
            .background(color = colors.surface, shape = shape)
            .border(width = 1.dp, color = colors.separator, shape = shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = iconForKey("water_drop"),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(18.dp),
        )
        Text(text = label, style = BadanType.chip, color = colors.textPrimary)
    }
}

@Composable
private fun CustomChip(onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    Row(
        modifier = Modifier
            .clip(shape)
            .clickable(onClick = onClick)
            .background(color = colors.primary.copy(alpha = 0.12f), shape = shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Add,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(18.dp),
        )
        Text(text = env.s(HydrationStrings.customAmount), style = BadanType.chip, color = colors.primary)
    }
}

@Composable
private fun ConfirmationRow(confirmation: HydrationConfirmation, onUndo: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.primary.copy(alpha = 0.10f))
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3, vertical = BadanSpace.s2),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = env.s(confirmation.message),
            style = BadanType.bodyCompact,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        Row(
            modifier = Modifier
                .clip(CircleShape)
                .clickable(onClick = onUndo)
                .padding(horizontal = BadanSpace.s2, vertical = BadanSpace.s1),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.Undo,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = env.s(HydrationStrings.undo),
                style = BadanType.chip.copy(fontWeight = FontWeight.SemiBold),
                color = colors.primary,
            )
        }
    }
}

@Composable
private fun EntryRow(entry: HydrationEntry, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val name = env.beverages.displayName(entry.beverageId, entry.fluidType)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClickLabel = env.s(Loc.edit), onClick = onClick)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s2, vertical = BadanSpace.s1),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = iconForKey("water_drop"),
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(18.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(text = env.s(name), style = BadanType.body, color = colors.textPrimary, maxLines = 1)
            Text(
                text = timeText(entry.occurredAt, env.language.localeTag) +
                    if (entry.isRevised) " · ${env.s(edited)}" else "",
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        Text(
            text = "${mlText(env.format, entry.volumeMl)} ${env.s(HydrationStrings.ml)}",
            style = BadanType.monospaceDigits(BadanType.bodyCompact),
            color = colors.textSecondary,
        )
    }
}

// MARK: - Weekly observational card

/**
 * The observational weekly card: seven day-bars and one honest count sentence ("You logged drinks
 * on 5 of the last 7 days"). No streaks, no adherence percentage, no red/green — a record of what
 * was logged, not a scoreboard. The reassurance line encodes §7A.1 directly: an empty day is a day
 * without an entry, not a day without a drink.
 */
@Composable
private fun HydrationWeeklyCard(week: HydrationWeek) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(title = env.s(HydrationStrings.thisWeek))

            Text(
                text = env.s(
                    HydrationStrings.daysLogged(
                        days = env.format.integer(week.daysWithLogs),
                        of = env.format.integer(week.span),
                    ),
                ),
                style = BadanType.body,
                color = colors.textPrimary,
            )

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                for (day in week.days) {
                    WeekDayBar(day = day, maxMl = week.maxMl, modifier = Modifier.weight(1f))
                }
            }

            Text(
                text = env.s(HydrationStrings.weeklyReassurance),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun WeekDayBar(day: HydrationWeekDay, maxMl: Double, modifier: Modifier = Modifier) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val fraction = if (maxMl > 0.0) (day.totalMl / maxMl).coerceIn(0.0, 1.0).toFloat() else 0f
    // A logged day gets primary; today is the fuller tint; an empty day is just the track.
    val fillColor = when {
        !day.hasLog -> colors.separator
        day.isToday -> colors.primary
        else -> colors.primary.copy(alpha = 0.55f)
    }
    val description = "${day.label}: ${mlText(env.format, day.totalMl)} ${env.s(HydrationStrings.ml)}"
    Column(
        modifier = modifier.semantics { contentDescription = description },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Box(
            modifier = Modifier
                .width(20.dp)
                .height(56.dp)
                .clip(RoundedCornerShape(BadanRadius.chip))
                .background(colors.surfaceElevated),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    // A logged-but-tiny day still shows a visible sliver, never an invisible bar.
                    .fillMaxHeight(if (day.hasLog) fraction.coerceAtLeast(0.12f) else 0f)
                    .clip(RoundedCornerShape(BadanRadius.chip))
                    .background(fillColor),
            )
        }
        Text(
            text = day.label,
            style = BadanType.caption,
            color = if (day.isToday) colors.textPrimary else colors.textSecondary,
            maxLines = 1,
        )
    }
}

// MARK: - Hidden notice (re-enable path)

/**
 * Shown in place of the whole surface when the module is hidden. The one affordance — "Show" —
 * restores it; the explainer makes the non-destructive promise explicit so hiding never reads as
 * deleting.
 */
@Composable
private fun HydrationHiddenNotice(onShow: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Text(
                    text = env.s(HydrationStrings.hiddenNotice),
                    style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(BadanRadius.chip))
                        .clickable(onClick = onShow)
                        .heightIn(min = BadanSpace.touchMin)
                        .padding(horizontal = BadanSpace.s3),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = env.s(HydrationStrings.showModule),
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.primary,
                    )
                }
            }
            Text(
                text = env.s(HydrationStrings.hiddenExplainer),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Local strings / helpers

private val edited = LocalizedString(en = "edited", ar = "مُعدّل")
private val moreOptions = LocalizedString(en = "More options", ar = "خيارات إضافية")

/** The local clock time of an entry, for today's list (a precise, actionable "when"). */
private fun timeText(millis: Long, localeTag: String): String {
    val locale = Locale.forLanguageTag(localeTag)
    return DateFormat.getTimeInstance(DateFormat.SHORT, locale).format(Date(millis))
}
