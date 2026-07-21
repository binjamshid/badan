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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.domain.hydration.HydrationLedger

// MARK: - Custom-log sheet

/**
 * The fuller logging path (§16.1 "custom sheet"): a free amount, a drink from the built-in catalog,
 * and an optional note. Doubles as the edit surface — passing [editing] pre-fills every field and
 * turns the primary action into a revision (an append that supersedes, never a mutate; I2) plus a
 * Delete affordance.
 *
 * Volume is parsed through `HydrationLedger.parseVolumeMl`, so Eastern/Extended Arabic-Indic digits
 * and the Arabic decimal separator all resolve to canonical mL exactly as iOS does (the §7A.1
 * Arabic-numeral requirement). A non-positive or unparseable amount simply leaves the action
 * disabled — a drink with no volume is a mistake, not a log.
 */
@Composable
fun HydrationCustomSheet(
    editing: HydrationEntry?,
    onCommit: () -> Unit,
    onDeleted: () -> Unit,
    onCancel: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    // Selected drink (built-in catalog). Defaults to the editing entry's beverage, else water.
    var beverageId by remember { mutableStateOf(editing?.beverageId ?: "water") }
    val selectedBeverage = env.beverages.beverage(beverageId) ?: env.beverages.water

    var amountText by remember {
        mutableStateOf(
            editing?.let { trimmedMl(it.volumeMl) } ?: selectedBeverage.defaultVolumeMl?.let { trimmedMl(it) } ?: "",
        )
    }
    var noteText by remember { mutableStateOf(editing?.note ?: "") }

    val parsed = remember(amountText) { HydrationLedger.parseVolumeMl(amountText) }
    val focusRequester = remember { FocusRequester() }

    // Auto-focus the amount on a fresh log (one less tap on the quick path); an edit lands on its
    // existing values without stealing focus.
    LaunchedEffect(Unit) {
        if (editing == null) focusRequester.requestFocus()
    }

    fun commit() {
        val ml = parsed ?: return
        val note = noteText.trim().takeIf { it.isNotEmpty() }
        val fluid = selectedBeverage.fluidType
        val bev = selectedBeverage.id.takeUnless { it == "water" }
        scope.launch {
            withContext(Dispatchers.IO) {
                if (editing != null) {
                    HydrationData.revise(
                        env = env, live = editing, volumeMl = ml, fluidType = fluid,
                        beverageId = bev, note = note,
                    )
                } else {
                    HydrationData.log(
                        env = env, volumeMl = ml, fluidType = fluid, beverageId = bev, note = note,
                    )
                }
            }
            onCommit()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
    ) {
        SheetHeader(
            title = env.s(if (editing != null) Loc.edit else HydrationStrings.addADrink),
            onCancel = onCancel,
            confirmLabel = env.s(if (editing != null) Loc.save else Loc.add),
            confirmEnabled = parsed != null,
            onConfirm = { commit() },
        )

        // Amount (Arabic-numeral aware).
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
            FieldLabel(env.s(HydrationStrings.customAmount))
            Row(
                modifier = fieldBox(colors),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Box(modifier = Modifier.weight(1f)) {
                    if (amountText.isEmpty()) {
                        Text(
                            text = env.s(HydrationStrings.customAmount),
                            style = BadanType.numeralM,
                            color = colors.textSecondary.copy(alpha = 0.6f),
                        )
                    }
                    BasicTextField(
                        value = amountText,
                        onValueChange = { amountText = it },
                        textStyle = BadanType.numeralM.copy(color = colors.textPrimary),
                        singleLine = true,
                        cursorBrush = SolidColor(colors.primary),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { commit() }),
                        modifier = Modifier
                            .fillMaxWidth()
                            .focusRequester(focusRequester),
                    )
                }
                Text(text = env.s(HydrationStrings.ml), style = BadanType.body, color = colors.textSecondary)
            }
        }

        // Drink picker — selecting a drink sets the type, and (when the amount is still empty)
        // seeds the field with that drink's default volume. Never a hydration weight — a 200 mL
        // coffee is logged as 200 mL, identical to water (§7A.1).
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            FieldLabel(env.s(HydrationStrings.drink))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                for (beverage in env.beverages.all) {
                    DrinkPill(
                        label = env.s(beverage.displayName),
                        selected = beverage.id == beverageId,
                        onClick = {
                            beverageId = beverage.id
                            if (amountText.isBlank()) {
                                beverage.defaultVolumeMl?.let { amountText = trimmedMl(it) }
                            }
                        },
                    )
                }
            }
        }

        // Optional note. Redacted from the default export (§7A.1) — a small caption says so at power
        // depth so the user knows where a note does and doesn't travel.
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
            FieldLabel(env.s(HydrationStrings.noteOptional))
            Row(
                modifier = fieldBox(colors),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(modifier = Modifier.weight(1f)) {
                    if (noteText.isEmpty()) {
                        Text(
                            text = env.s(HydrationStrings.noteOptional),
                            style = BadanType.body,
                            color = colors.textSecondary.copy(alpha = 0.6f),
                        )
                    }
                    BasicTextField(
                        value = noteText,
                        onValueChange = { noteText = it },
                        textStyle = BadanType.body.copy(color = colors.textPrimary),
                        singleLine = true,
                        cursorBrush = SolidColor(colors.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            if (env.depth.showsPowerDetail) {
                Text(
                    text = env.s(notePrivacyHint),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }

        // Delete — only when editing an existing drink. Removes the whole chain (I3: tombstoned,
        // never hard-deleted), worded plainly.
        if (editing != null) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .clickable {
                        scope.launch {
                            withContext(Dispatchers.IO) { HydrationData.delete(env, editing) }
                            onDeleted()
                        }
                    }
                    .heightIn(min = BadanSpace.touchMin)
                    .padding(horizontal = BadanSpace.s3),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.DeleteOutline,
                    contentDescription = null,
                    tint = colors.critical,
                    modifier = Modifier.size(20.dp),
                )
                Text(text = env.s(Loc.delete), style = BadanType.body, color = colors.critical)
            }
        }

        Spacer(modifier = Modifier.size(BadanSpace.s2))
    }
}

// MARK: - Goal sheet

/**
 * Tracking-goal settings. The two choices are rendered with equal visual weight — "Track without a
 * goal" is not styled as "off" or "none selected", it is a first-class option a person picks on
 * purpose (§7A.1: no-goal is an equal-status default, never nagged). Saving writes a `NONE` goal
 * row (or a manual target) and re-snapshots today so the change is honest going forward without
 * rewriting past days.
 */
@Composable
fun HydrationGoalSheet(onSaved: () -> Unit, onCancel: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    // Preselect from the current active goal. Default to no-goal — the equal-status default — when
    // there is no goal yet, rather than defaulting a person into a target they never chose.
    var wantsGoal by remember { mutableStateOf(false) }
    var targetText by remember { mutableStateOf("") }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        val goal = withContext(Dispatchers.IO) { HydrationData.activeGoal(env) }
        if (goal != null && goal.hasTarget) {
            wantsGoal = true
            targetText = trimmedMl(goal.targetMl ?: 0.0)
        }
        loaded = true
    }

    val parsedTarget = remember(targetText) { HydrationLedger.parseVolumeMl(targetText) }
    // Saving is allowed for no-goal always; for a manual goal only once a positive amount is entered.
    val canSave = loaded && (!wantsGoal || parsedTarget != null)

    fun save() {
        if (!canSave) return
        scope.launch {
            withContext(Dispatchers.IO) {
                if (wantsGoal) {
                    HydrationData.setGoal(env, HydrationGoalKind.MANUAL, parsedTarget)
                } else {
                    HydrationData.setGoal(env, HydrationGoalKind.NONE, null)
                }
            }
            onSaved()
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
    ) {
        SheetHeader(
            title = env.s(HydrationStrings.goalTitle),
            onCancel = onCancel,
            confirmLabel = env.s(Loc.save),
            confirmEnabled = canSave,
            onConfirm = { save() },
        )

        GoalOption(
            title = env.s(HydrationStrings.noGoalOption),
            detail = env.s(HydrationStrings.noGoalDetail),
            selected = !wantsGoal,
            onClick = { wantsGoal = false },
        )

        GoalOption(
            title = env.s(HydrationStrings.manualGoalOption),
            detail = env.s(HydrationStrings.manualGoalDetail),
            selected = wantsGoal,
            onClick = { wantsGoal = true },
        )

        if (wantsGoal) {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                FieldLabel(env.s(HydrationStrings.dailyTarget))
                Row(
                    modifier = fieldBox(colors),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Box(modifier = Modifier.weight(1f)) {
                        if (targetText.isEmpty()) {
                            Text(
                                text = env.s(HydrationStrings.dailyTarget),
                                style = BadanType.numeralM,
                                color = colors.textSecondary.copy(alpha = 0.6f),
                            )
                        }
                        BasicTextField(
                            value = targetText,
                            onValueChange = { targetText = it },
                            textStyle = BadanType.numeralM.copy(color = colors.textPrimary),
                            singleLine = true,
                            cursorBrush = SolidColor(colors.primary),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal, imeAction = ImeAction.Done),
                            keyboardActions = KeyboardActions(onDone = { save() }),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                    Text(text = env.s(HydrationStrings.ml), style = BadanType.body, color = colors.textSecondary)
                }
            }
        }

        Spacer(modifier = Modifier.size(BadanSpace.s2))
    }
}

// MARK: - Shared sheet controls

/** A sheet title row: leading Cancel, centred title, optional trailing confirm. Mirrors RTL. */
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

@Composable
private fun FieldLabel(text: String) {
    Text(text = text, style = BadanType.caption, color = BadanTheme.colors.textSecondary)
}

private fun fieldBox(colors: net.albayyan.badan.designsystem.BadanColors): Modifier = Modifier
    .fillMaxWidth()
    .clip(RoundedCornerShape(BadanRadius.card))
    .background(colors.surface, RoundedCornerShape(BadanRadius.card))
    .border(width = 1.dp, color = colors.separator, shape = RoundedCornerShape(BadanRadius.card))
    .heightIn(min = 56.dp)
    .padding(horizontal = BadanSpace.s4, vertical = BadanSpace.s2)

@Composable
private fun DrinkPill(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    Row(
        modifier = Modifier
            .clip(shape)
            .clickable(onClick = onClick)
            .background(color = if (selected) colors.primary else colors.surface, shape = shape)
            .border(width = 1.dp, color = if (selected) Color.Transparent else colors.separator, shape = shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Icon(
            imageVector = iconForKey("water_drop"),
            contentDescription = null,
            tint = if (selected) colors.onPrimary else colors.primary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = label,
            style = BadanType.chip,
            color = if (selected) colors.onPrimary else colors.textPrimary,
            maxLines = 1,
        )
    }
}

@Composable
private fun GoalOption(title: String, detail: String, selected: Boolean, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick)
            .background(if (selected) colors.primary.copy(alpha = 0.10f) else colors.surface, shape)
            .border(
                width = 1.dp,
                color = if (selected) colors.primary else colors.separator,
                shape = shape,
            )
            .padding(BadanSpace.s4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        // A radio-style mark: a filled check when chosen, an empty ring otherwise. Both options
        // carry the same weight — neither reads as the "real" choice.
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(if (selected) colors.primary else Color.Transparent)
                .border(
                    width = if (selected) 0.dp else 1.5.dp,
                    color = if (selected) Color.Transparent else colors.separator,
                    shape = RoundedCornerShape(11.dp),
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (selected) {
                Icon(
                    imageVector = Icons.Filled.Check,
                    contentDescription = null,
                    tint = colors.onPrimary,
                    modifier = Modifier.size(14.dp),
                )
            }
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(text = title, style = BadanType.body.copy(fontWeight = FontWeight.SemiBold), color = colors.textPrimary)
            Text(text = detail, style = BadanType.caption, color = colors.textSecondary)
        }
    }
}

// MARK: - Local strings / helpers

private val notePrivacyHint = LocalizedString(
    en = "Notes stay on your device and are left out of the default export.",
    ar = "تبقى الملاحظات على جهازك وتُستثنى من التصدير الافتراضي.",
)

/** Whole-mL text for pre-filling a field (no unit) — hydration is entered in whole millilitres. */
private fun trimmedMl(ml: Double): String = ml.toLong().toString()
