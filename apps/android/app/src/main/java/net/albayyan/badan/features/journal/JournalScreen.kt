@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package net.albayyan.badan.features.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.EventNote
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.journal.BehaviorValueKind
import net.albayyan.badan.domain.journal.JournalEntry
import net.albayyan.badan.domain.journal.JournalLog
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.util.TimeZone

/**
 * EPIC-29 — the daily behaviour journal. **Chips, and as little else as possible.** Mirror of the
 * iOS `JournalScreen`.
 *
 * The design constraint is the one §16 names as this surface's friction risk: chore fatigue.
 * Everything here is shaped by it — one screen, no wizard, no date picker, a tap that writes
 * immediately, and a yesterday switch so the most common real case (remembering last night's coffee
 * this morning) is a first-class path rather than a correction flow.
 *
 * **A plain tap stores a boolean row, whatever shape the dictionary gives the behaviour.** Storing
 * the dictionary's shape would mean inventing the number: a tapped "Nap" chip does not tell BADAN
 * the nap was twenty minutes, and writing twenty would put a fabricated value into the user's own
 * exportable record. The row's existence IS the fact, `isPresent` is true, and the correlation
 * engine — which reads only `isPresent` — treats it identically to a counted one. Power depth is
 * where a real number gets attached, through the `−`/`+` stepper.
 *
 * **I7.** Every row written here is sensitive-plus and lands in `badan_sensitive.db` through
 * `JournalRepository`, which holds no main connection. This screen touches no main-database
 * repository at all, and when sensitive records are off it does not render the journal — it names
 * the reason instead of showing an empty screen.
 *
 * Every mutation follows one shape: **write, then reload the day.** The chips derive from stored
 * rows rather than from a selection set kept alongside them, so a failed write leaves the chip
 * visibly unchanged instead of showing a tag that was never saved.
 */
@Composable
fun JournalScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    val tz = remember { TimeZone.getDefault().id }

    var day by remember { mutableStateOf(JournalDayChoice.TODAY) }
    var data by remember { mutableStateOf<JournalDayData?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    var saveFailed by remember { mutableStateOf(false) }
    var reloadKey by remember { mutableStateOf(0) }
    var customTag by remember { mutableStateOf("") }

    val sensitiveOn = env.profile.sensitiveModulesEnabled

    LaunchedEffect(day, reloadKey, sensitiveOn) {
        if (!sensitiveOn) return@LaunchedEffect
        val loaded = withContext(Dispatchers.IO) { runCatching { loadJournalDay(env, day, tz) } }
        loadFailed = loaded.isFailure
        loaded.getOrNull()?.let { data = it }
    }

    // One shape for every write: perform it off the main thread, record whether it worked, then bump
    // the reload key so the chips re-read what is actually stored rather than an optimistic guess.
    val commit: (suspend () -> Unit) -> Unit = { work ->
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { work() } }
            saveFailed = result.isFailure
            reloadKey++
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(JournalStrings.title),
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
                actions = {
                    if (sensitiveOn) {
                        IconButton(onClick = { nav.push(Route.ContextStatuses) }) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.EventNote,
                                contentDescription = env.s(JournalStrings.contextTitle),
                                tint = colors.textPrimary,
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                    navigationIconContentColor = colors.textPrimary,
                    actionIconContentColor = colors.textPrimary,
                ),
            )
        },
    ) { innerPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(BadanSpace.s4),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
        ) {
            if (!sensitiveOn) {
                SensitiveOffCard()
                return@Column
            }

            TrustNote()
            DaySelector(day = day, onSelect = { day = it })
            Text(
                text = env.s(JournalStrings.untappedNote),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
            if (day.isRecall) {
                Text(
                    text = env.s(JournalStrings.recallNote),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
            if (loadFailed) {
                Text(
                    text = env.s(JournalStrings.loadFailed),
                    style = BadanType.bodyCompact,
                    color = colors.textPrimary,
                )
            }
            if (saveFailed) {
                Text(
                    text = env.s(JournalStrings.saveFailed),
                    style = BadanType.bodyCompact,
                    color = colors.textPrimary,
                )
            }

            data?.let { model ->
                TaggedCount(model.taggedCount)

                model.groups.forEach { group ->
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(group.heading))
                        FlowRow(
                            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                            verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                        ) {
                            group.chips.forEach { chip ->
                                BehaviorChip(chip = chip) {
                                    commit { toggleChip(env, chip, model.occurredAt, day, tz) }
                                }
                                // The amount affordance is power-only and appears only once the
                                // behaviour is tagged: a stepper on an untagged chip would be a
                                // second way to log, with a number attached, on the altitude that
                                // §16 says is chips-only.
                                if (env.depth.showsPowerDetail && chip.isOn && chip.offersAmount) {
                                    AmountStepper(chip = chip) { delta ->
                                        commit { stepAmount(env, chip, delta, model.occurredAt, day, tz) }
                                    }
                                }
                            }
                        }
                    }
                }

                OwnTagsSection(
                    entries = model.customEntries,
                    value = customTag,
                    onValueChange = { customTag = it },
                    onSubmit = {
                        val label = customTag.trim()
                        if (label.isNotEmpty()) {
                            customTag = ""
                            commit { insertCustomTag(env, label, model.occurredAt, day, tz) }
                        }
                    },
                    onRemove = { entry -> commit { env.journal.deleteEntry(entry.id, env.now()) } },
                )
            }
        }
    }
}

// MARK: - Header pieces

@Composable
private fun TrustNote() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
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
            text = env.s(JournalStrings.trust),
            style = BadanType.caption,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * Today / Yesterday. A radio group rather than tabs, because the choice changes which day the next
 * tap is FILED under — a selection, not navigation, and a screen reader should announce it that way.
 */
@Composable
private fun DaySelector(day: JournalDayChoice, onSelect: (JournalDayChoice) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        // A visible label rather than a semantics-only one: a two-option control with no heading is
        // ambiguous for everyone, and a screen reader focuses the individual options rather than
        // their container, so a hidden group label would go unread anyway.
        Text(
            text = env.s(JournalStrings.dayPickerLabel),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(colors.surfaceElevated, shape)
                .border(1.dp, colors.separator, shape)
                .padding(BadanSpace.s1)
                .selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            JournalDayChoice.entries.forEach { option ->
                val selected = option == day
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(shape)
                        .selectable(selected = selected, role = Role.RadioButton) { onSelect(option) }
                        .background(if (selected) colors.primary.copy(alpha = 0.14f) else Color.Transparent, shape)
                        .heightIn(min = BadanSpace.touchMin),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = env.s(option.displayName),
                        style = BadanType.body.copy(
                            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                        ),
                        color = if (selected) colors.primary else colors.textSecondary,
                    )
                }
            }
        }
    }
}

/** A plain count. No target, no streak — the journal records, it does not score the journaling. */
@Composable
private fun TaggedCount(count: Int) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    if (count == 0) {
        Text(
            text = env.s(JournalStrings.nothingTaggedYet),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    } else {
        PillLabel(
            text = env.s(JournalStrings.taggedCount.filling(mapOf("n" to env.format.integer(count)))),
        )
    }
}

// MARK: - Chips

/**
 * One behaviour chip, with **switch semantics** (§16's accessibility requirement for this surface):
 * a screen reader announces the behaviour's name, whether it is logged, and toggling it off is the
 * same gesture as toggling it on.
 *
 * `toggleable` merges its descendants, so the visible label IS the spoken label — which is why the
 * recorded amount is written into the label text rather than drawn as a separate badge. The check
 * glyph is decorative and contributes nothing.
 */
@Composable
private fun BehaviorChip(chip: JournalChip, onToggle: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    val on = chip.isOn
    val state = env.s(if (on) JournalStrings.logged else JournalStrings.notLogged)
    Row(
        modifier = Modifier
            .clip(shape)
            .toggleable(value = on, role = Role.Switch, onValueChange = { onToggle() })
            .semantics { stateDescription = state }
            .background(if (on) colors.primary.copy(alpha = 0.14f) else colors.surface, shape)
            .border(1.dp, if (on) colors.primary else colors.separator, shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        if (on) {
            Icon(
                imageVector = Icons.Filled.Check,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(
            text = chipLabel(env, chip),
            style = BadanType.chip,
            color = if (on) colors.primary else colors.textPrimary,
            maxLines = 1,
        )
    }
}

/** "Caffeine", "Caffeine · 2", "Nap · 20 min" — the amount is part of the label, never a bare glyph. */
private fun chipLabel(env: AppEnvironment, chip: JournalChip): String {
    val name = env.s(chip.behavior.displayName)
    val amount = chip.amount ?: return name
    val unit = chip.amountUnit?.let { env.s(it) }
    val value = env.format.number(amount, 0)
    return if (unit.isNullOrEmpty()) "$name · $value" else "$name · $value $unit"
}

/**
 * The power-depth amount control: `−`, the recorded value, `+`. Two separate touch targets with
 * their own labels rather than controls nested inside the chip's toggle, which would give one
 * accessibility node three conflicting actions.
 *
 * Stepping to zero or below removes the tag rather than storing a zero. An explicit zero is a real
 * assertion in this model ("no coffee today", which lands in the *without* arm), and a stepper
 * bottoming out is not the same statement as making it.
 */
@Composable
private fun AmountStepper(chip: JournalChip, onStep: (Double) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    val unit = chip.amountUnit?.let { env.s(it) } ?: env.s(JournalStrings.times)
    Row(
        modifier = Modifier
            .clip(shape)
            .background(colors.surfaceElevated, shape)
            .border(1.dp, colors.separator, shape)
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconButton(onClick = { onStep(-chip.amountStep) }) {
            Icon(
                imageVector = Icons.Filled.Remove,
                contentDescription = "${env.s(JournalStrings.decreaseAmount)} ${env.s(chip.behavior.displayName)}",
                tint = colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }
        Text(
            text = chip.amount?.let { "${env.format.number(it, 0)} $unit" } ?: env.s(JournalStrings.amount),
            style = BadanType.monospaceDigits(BadanType.chip),
            color = colors.textPrimary,
            maxLines = 1,
            modifier = Modifier.widthIn(min = 56.dp),
        )
        IconButton(onClick = { onStep(chip.amountStep) }) {
            Icon(
                imageVector = Icons.Filled.Add,
                contentDescription = "${env.s(JournalStrings.increaseAmount)} ${env.s(chip.behavior.displayName)}",
                tint = colors.primary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

// MARK: - Own tags

/**
 * Free-text tags. The ADD field is power-depth (§16: casual is chips only), but any tags that exist
 * are listed at every altitude — hiding a user's own records because they switched to a simpler view
 * would be the app deciding what they are allowed to see of their own data.
 */
@Composable
private fun OwnTagsSection(
    entries: List<JournalEntry>,
    value: String,
    onValueChange: (String) -> Unit,
    onSubmit: () -> Unit,
    onRemove: (JournalEntry) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val power = env.depth.showsPowerDetail
    if (!power && entries.isEmpty()) return

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(title = env.s(JournalStrings.ownTagsTitle))

            entries.forEach { entry ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(
                        text = entry.customLabel.orEmpty(),
                        style = BadanType.bodyCompact,
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    IconButton(onClick = { onRemove(entry) }) {
                        Icon(
                            imageVector = Icons.Filled.Close,
                            contentDescription = "${env.s(Loc.delete)} ${entry.customLabel.orEmpty()}",
                            tint = colors.textSecondary,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                }
            }

            if (power) {
                val shape = RoundedCornerShape(BadanRadius.control)
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(shape)
                        .background(colors.surfaceElevated, shape)
                        .heightIn(min = BadanSpace.touchMin)
                        .padding(horizontal = BadanSpace.s3),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Box(modifier = Modifier.weight(1f)) {
                        if (value.isEmpty()) {
                            Text(
                                text = env.s(JournalStrings.ownTagPlaceholder),
                                style = BadanType.body,
                                color = colors.textSecondary,
                            )
                        }
                        BasicTextField(
                            value = value,
                            onValueChange = onValueChange,
                            textStyle = BadanType.body.copy(color = colors.textPrimary),
                            singleLine = true,
                            cursorBrush = SolidColor(colors.primary),
                            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = { onSubmit() }),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    val canAdd = value.trim().isNotEmpty()
                    TextButton(onClick = onSubmit, enabled = canAdd) {
                        Text(
                            text = env.s(Loc.add),
                            style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                            color = if (canAdd) colors.primary else colors.textSecondary,
                        )
                    }
                }
                Text(
                    text = env.s(JournalStrings.ownTagsNote),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Sensitive gate

@Composable
private fun SensitiveOffCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Text(
                text = env.s(JournalStrings.sensitiveOffTitle),
                style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            Text(
                text = env.s(JournalStrings.sensitiveOffMessage),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Data + I/O (non-composable)

/**
 * One day as the screen shows it. [occurredAt] is the instant a tap files an entry at — `now` for
 * today, the same wall-clock time on the previous local day for yesterday.
 */
internal data class JournalDayData(
    val day: JournalDayChoice,
    val occurredAt: Long,
    val groups: List<JournalChipGroup>,
    val customEntries: List<JournalEntry>,
    val taggedCount: Int,
)

/**
 * Read the selected day's live entries and rebuild the chips.
 *
 * The window query is widened to the whole local day and then filtered on each row's own `dayKey()`.
 * Both steps are needed: the query is what an index can serve, and the filter is what makes the day
 * boundary agree with the correlation engine's — an entry carries the timezone it was recorded in,
 * so a row logged in Riyadh and read in London belongs to the Riyadh day, exactly as
 * `CorrelationEngine` buckets it.
 */
private fun loadJournalDay(env: AppEnvironment, day: JournalDayChoice, tz: String): JournalDayData {
    val reference = day.occurredAt(env.now(), tz)
    val dayStart = DayAttribution.startOfDay(reference, tz)
    val dayEnd = DayAttribution.addingDays(1, dayStart, tz)
    val dayKey = DayAttribution.localDayKey(dayStart, tz)
    val rows = env.journal.entries(dayStart, dayEnd).filter { it.dayKey() == dayKey }
    val chips = JournalDayBuilder.chips(env.behaviors.all, rows)
    val customEntries = JournalDayBuilder.customEntries(rows)
    return JournalDayData(
        day = day,
        occurredAt = reference,
        groups = JournalDayBuilder.groups(chips),
        customEntries = customEntries,
        taggedCount = JournalDayBuilder.taggedCount(chips, customEntries),
    )
}

/**
 * Tap a chip: tag the behaviour, or take the tag back.
 *
 * Untagging is a tombstone, not a hard delete: what the user first said stays recoverable, and a
 * synced peer learns the tag went away rather than inferring it from absence.
 */
private fun toggleChip(
    env: AppEnvironment,
    chip: JournalChip,
    occurredAt: Long,
    day: JournalDayChoice,
    tz: String,
) {
    val existing = chip.entry
    if (existing != null) {
        env.journal.deleteEntry(existing.id, env.now())
    } else {
        // BOOLEAN whatever the dictionary says this behaviour's shape is — see the type doc: a tap
        // asserts that it happened, and nothing more.
        env.journal.insertEntry(
            makeEntry(
                env = env, behaviorId = chip.behavior.id, customLabel = null,
                valueKind = BehaviorValueKind.BOOLEAN, value = null, unit = null,
                occurredAt = occurredAt, day = day, tz = tz,
            ),
        )
    }
}

/**
 * Move a count/quantity chip's amount by one step — the power-depth affordance.
 *
 * A correction is a new row plus a tombstone on the old one, never an in-place edit, so "the user
 * first said two, then said three" stays inspectable. The corrected row keeps the day's instant, not
 * "now", so stepping an amount never moves when the user said the behaviour happened.
 */
private fun stepAmount(
    env: AppEnvironment,
    chip: JournalChip,
    delta: Double,
    occurredAt: Long,
    day: JournalDayChoice,
    tz: String,
) {
    if (!chip.offersAmount) return
    val now = env.now()
    val target = (chip.amount ?: 0.0) + delta
    if (target <= 0.0) {
        chip.entry?.let { env.journal.deleteEntry(it.id, now) }
        return
    }
    chip.entry?.let { env.journal.deleteEntry(it.id, now) }
    env.journal.insertEntry(
        makeEntry(
            env = env, behaviorId = chip.behavior.id, customLabel = null,
            valueKind = chip.behavior.valueKind, value = target,
            unit = if (chip.behavior.valueKind == BehaviorValueKind.QUANTITY) chip.behavior.unit else null,
            occurredAt = chip.entry?.occurredAt ?: occurredAt, day = day, tz = tz,
        ),
    )
}

/**
 * Log a behaviour the dictionary doesn't name. Stored as `customLabel` with no `behaviorId` — the
 * two are mutually exclusive on the entity, and keeping the user's own words out of the dictionary
 * key space is what stops a free-text tag from ever being mistaken for a curated one.
 */
private fun insertCustomTag(
    env: AppEnvironment,
    label: String,
    occurredAt: Long,
    day: JournalDayChoice,
    tz: String,
) {
    env.journal.insertEntry(
        makeEntry(
            env = env, behaviorId = null, customLabel = label,
            valueKind = BehaviorValueKind.BOOLEAN, value = null, unit = null,
            occurredAt = occurredAt, day = day, tz = tz,
        ),
    )
}

/**
 * Build the row. The two builders differ only in intent at the call site and in the instant they
 * file under — `recalledEntry` keeps `recordedAt` honest about when it was typed, which is what
 * makes `isRecalled` derivable instead of a stored flag someone has to remember to set.
 */
private fun makeEntry(
    env: AppEnvironment,
    behaviorId: String?,
    customLabel: String?,
    valueKind: BehaviorValueKind,
    value: Double?,
    unit: String?,
    occurredAt: Long,
    day: JournalDayChoice,
    tz: String,
): JournalEntry {
    val now = env.now()
    val id = Ulid.newId()
    return if (day.isRecall) {
        JournalLog.recalledEntry(
            id = id, behaviorId = behaviorId, customLabel = customLabel, valueKind = valueKind,
            value = value, unit = unit, occurredAt = occurredAt, tzId = tz,
            sourceId = env.deviceId, deviceId = env.deviceId, now = now, originDeviceId = env.deviceId,
        )
    } else {
        JournalLog.entry(
            id = id, behaviorId = behaviorId, customLabel = customLabel, valueKind = valueKind,
            value = value, unit = unit, occurredAt = occurredAt, tzId = tz,
            sourceId = env.deviceId, deviceId = env.deviceId, now = now, originDeviceId = env.deviceId,
        )
    }
}
