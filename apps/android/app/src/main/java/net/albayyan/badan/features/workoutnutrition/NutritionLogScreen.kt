package net.albayyan.badan.features.workoutnutrition

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Restaurant
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatBox
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

// MARK: - Screen-local bilingual strings
//
// Strings only the nutrition-capture surface needs; shared vocabulary comes from `Loc`. Wording
// is descriptive, never prescriptive — food is logged, not scored. `private` is file scope, so
// identical names in the sibling workout screen never collide.

private val nProtein = LocalizedString(en = "Protein", ar = "البروتين")
private val nOptionalDetails = LocalizedString(en = "Optional details", ar = "تفاصيل اختيارية")
private val nTodaysTotals = LocalizedString(en = "Today's totals", ar = "إجمالي اليوم")
private val nTodaysMeals = LocalizedString(en = "Today's meals", ar = "وجبات اليوم")
private val nNoneYet = LocalizedString(en = "Nothing logged today yet.", ar = "لم تُسجَّل وجبات اليوم بعد.")
private val nQuickTag = LocalizedString(en = "Quick", ar = "سريع")
private val nKcal = LocalizedString(en = "kcal", ar = "سعرة")
private val nGrams = LocalizedString(en = "g", ar = "جم")
private val nHighValueHint = LocalizedString(
    en = "That seems unusually high — worth double-checking.",
    ar = "هذا يبدو مرتفعاً بشكل غير معتاد — يستحق التأكد.",
)

// MARK: - Loaded data

private data class NutritionLogData(
    val meals: List<NutritionEntry>,
    val kcalTotal: Double,
    val proteinTotal: Double,
)

/** Load everything logged since the start of the local day and sum the day's energy/protein. */
private fun loadNutritionData(env: AppEnvironment): NutritionLogData {
    val now = env.now()
    val tz = TimeZone.getDefault().id
    val start = DayAttribution.startOfDay(now, tz)
    val all = runCatching { env.logging.nutrition(start, now) }.getOrDefault(emptyList())
    return NutritionLogData(
        meals = all,
        kcalTotal = all.mapNotNull { it.energyKcal }.sum(),
        proteinTotal = all.mapNotNull { it.proteinG }.sum(),
    )
}

private fun mealForHour(hour: Int): MealType = when (hour) {
    in 4..10 -> MealType.BREAKFAST
    in 11..15 -> MealType.LUNCH
    in 16..20 -> MealType.DINNER
    else -> MealType.SNACK
}

private fun hourOfMillis(millis: Long): Int =
    Calendar.getInstance().apply { timeInMillis = millis }.get(Calendar.HOUR_OF_DAY)

/**
 * If the user has, on a recent visit, manually corrected the hour-based meal guess for a similar
 * time of day, recall that choice instead of repeating the same guess every time. Falls back to
 * [currentGuess] when no such override is found in the last 30 days.
 */
private fun recalledMealType(env: AppEnvironment, currentGuess: MealType): MealType {
    val now = env.now()
    val from = now - 30L * 86_400_000L
    val history = runCatching { env.logging.nutrition(from, now) }.getOrDefault(emptyList())
    val override = history
        .filter { mealForHour(hourOfMillis(it.occurredAt)) == currentGuess && it.mealType != currentGuess }
        .maxByOrNull { it.occurredAt }
    return override?.mealType ?: currentGuess
}

// MARK: - Screen

/**
 * Under-10-second food capture, pushed as its own screen. Describe what you ate, pick a meal,
 * optionally add energy + protein (or flip "quick calories" to log honestly-low-detail), then
 * save. Today's meals and a plain totals bar sit below. Descriptive, calm, never judgmental.
 * Faithful port of the iOS `NutritionLogView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NutritionLogScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    val power = env.depth.showsPowerDetail

    // Capture state. The initial meal is chosen once from the current hour; meal + quick-toggle
    // persist across saves, the description and measurements are cleared.
    val initialMeal = remember {
        mealForHour(Calendar.getInstance().apply { timeInMillis = env.now() }.get(Calendar.HOUR_OF_DAY))
    }
    var descriptionText by remember { mutableStateOf("") }
    var mealType by remember { mutableStateOf(initialMeal) }
    var kcalText by remember { mutableStateOf("") }
    var proteinText by remember { mutableStateOf("") }
    var quickCalories by remember { mutableStateOf(false) }

    var meals by remember { mutableStateOf<List<NutritionEntry>>(emptyList()) }
    var kcalTotal by remember { mutableStateOf(0.0) }
    var proteinTotal by remember { mutableStateOf(0.0) }

    LaunchedEffect(Unit) {
        val data = withContext(Dispatchers.IO) { loadNutritionData(env) }
        meals = data.meals
        kcalTotal = data.kcalTotal
        proteinTotal = data.proteinTotal
        // Prefer a previously-overridden meal type for this time of day over the raw hour guess,
        // but never stomp a choice the user already made while this was loading.
        val recalled = withContext(Dispatchers.IO) { recalledMealType(env, initialMeal) }
        if (mealType == initialMeal) mealType = recalled
    }

    val canSave = descriptionText.trim().isNotEmpty()

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(Loc.logFood),
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(BadanSpace.s4),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
        ) {
            // What did you eat.
            BadanCard {
                Box(modifier = Modifier.fillMaxWidth()) {
                    if (descriptionText.isEmpty()) {
                        Text(
                            text = env.s(Loc.describeFood),
                            style = BadanType.body,
                            color = colors.textSecondary.copy(alpha = 0.6f),
                        )
                    }
                    BasicTextField(
                        value = descriptionText,
                        onValueChange = { descriptionText = it },
                        textStyle = BadanType.body.copy(color = colors.textPrimary),
                        maxLines = 3,
                        cursorBrush = SolidColor(colors.primary),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            // Meal type.
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(Loc.mealType))
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(vertical = BadanSpace.s1),
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        for (option in MealType.entries) {
                            SelectPill(
                                selected = option == mealType,
                                icon = iconForKey(option.symbolName),
                                label = env.s(option.displayName),
                                onClick = { mealType = option },
                            )
                        }
                    }
                }
            }

            // Quick-calories toggle. Honestly flags a low-detail entry rather than hiding it.
            BadanCard {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(
                        text = env.s(Loc.quickCalories),
                        style = BadanType.body,
                        color = colors.textPrimary,
                        modifier = Modifier.weight(1f),
                    )
                    Switch(
                        checked = quickCalories,
                        onCheckedChange = {
                            quickCalories = it
                            // Turning quick-calories on drops the protein value at save time —
                            // clear it visibly so the field never shows a number that silently
                            // stops being recorded.
                            if (it) proteinText = ""
                        },
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = colors.onPrimary,
                            checkedTrackColor = colors.primary,
                            checkedBorderColor = colors.primary,
                        ),
                    )
                }
            }

            // Optional macros, or the quick-energy shorthand. Animated so the height/content swap
            // triggered by the toggle just above reads as a transition, not an abrupt jump.
            Column(modifier = Modifier.animateContentSize()) {
                if (!quickCalories) {
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            SectionHeader(title = env.s(nOptionalDetails))
                            NumberField(
                                icon = Icons.Filled.LocalFireDepartment,
                                placeholder = env.s(Loc.calories),
                                value = kcalText,
                                onValueChange = { kcalText = it },
                                unit = env.s(nKcal),
                                warning = parseDecimal(kcalText)?.takeIf { it > 5000.0 }?.let { env.s(nHighValueHint) },
                            )
                            HorizontalDivider(color = colors.separator)
                            NumberField(
                                icon = Icons.Filled.Restaurant,
                                placeholder = env.s(nProtein),
                                value = proteinText,
                                onValueChange = { proteinText = it },
                                unit = env.s(nGrams),
                                warning = parseDecimal(proteinText)?.takeIf { it > 300.0 }?.let { env.s(nHighValueHint) },
                            )
                            if (power) {
                                Text(
                                    text = env.s(IngestionPath.MANUAL.displayLabel),
                                    style = BadanType.caption,
                                    color = colors.textSecondary,
                                )
                            }
                        }
                    }
                } else {
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                            NumberField(
                                icon = Icons.Filled.LocalFireDepartment,
                                placeholder = env.s(Loc.calories),
                                value = kcalText,
                                onValueChange = { kcalText = it },
                                unit = env.s(nKcal),
                                warning = parseDecimal(kcalText)?.takeIf { it > 5000.0 }?.let { env.s(nHighValueHint) },
                            )
                            Text(
                                text = env.s(Loc.quickCalories),
                                style = BadanType.caption,
                                color = colors.textSecondary,
                            )
                        }
                    }
                }
            }

            // Save.
            PrimaryButton(label = env.s(Loc.save), enabled = canSave) {
                val now = env.now()
                val entry = NutritionEntry(
                    id = Ulid.newId(),
                    description = descriptionText.trim(),
                    mealType = mealType,
                    energyKcal = parseDecimal(kcalText),
                    proteinG = if (quickCalories) null else parseDecimal(proteinText),
                    lowDetail = quickCalories,
                    occurredAt = now,
                    tzId = TimeZone.getDefault().id,
                    updatedAt = now,
                    originDeviceId = env.deviceId,
                )
                descriptionText = ""
                kcalText = ""
                proteinText = ""
                scope.launch {
                    withContext(Dispatchers.IO) { runCatching { env.logging.upsertNutrition(entry) } }
                    val data = withContext(Dispatchers.IO) { loadNutritionData(env) }
                    meals = data.meals
                    kcalTotal = data.kcalTotal
                    proteinTotal = data.proteinTotal
                }
            }

            // Today's totals — plain arithmetic, no scoring.
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(nTodaysTotals))
                BadanCard {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.Top,
                    ) {
                        StatBox(
                            value = env.format.integer(kcalTotal.roundToInt()),
                            label = env.s(Loc.calories),
                            unit = env.s(nKcal),
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        Box(
                            modifier = Modifier
                                .width(1.dp)
                                .height(44.dp)
                                .background(colors.separator),
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        StatBox(
                            value = env.format.integer(proteinTotal.roundToInt()),
                            label = env.s(nProtein),
                            unit = env.s(nGrams),
                        )
                    }
                }
            }

            // Today's meals.
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(nTodaysMeals))
                if (meals.isEmpty()) {
                    Text(text = env.s(nNoneYet), style = BadanType.caption, color = colors.textSecondary)
                } else {
                    for (meal in meals) {
                        MealRow(meal = meal, power = power)
                    }
                }
            }
        }
    }
}

// MARK: - Meal row

@Composable
private fun MealRow(meal: NutritionEntry, power: Boolean) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = iconForKey(meal.mealType.symbolName),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Text(
                        text = meal.description,
                        style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = env.s(meal.mealType.displayName),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
                Text(
                    text = timeText(meal.occurredAt, env.language.localeTag),
                    style = BadanType.monospaceDigits(BadanType.caption),
                    color = colors.textSecondary,
                )
            }

            val hasChips = meal.energyKcal != null || (meal.proteinG ?: 0.0) > 0.0 || meal.lowDetail
            if (hasChips) {
                Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                    meal.energyKcal?.let {
                        PillLabel(
                            text = "${env.format.integer(it.roundToInt())} ${env.s(nKcal)}",
                            icon = Icons.Filled.LocalFireDepartment,
                        )
                    }
                    meal.proteinG?.takeIf { it > 0.0 }?.let {
                        PillLabel(
                            text = "${env.format.integer(it.roundToInt())} ${env.s(nGrams)}",
                            icon = Icons.Filled.Restaurant,
                        )
                    }
                    // "Quick calories" is flagged honestly, not hidden.
                    if (meal.lowDetail) {
                        PillLabel(text = env.s(nQuickTag), icon = Icons.Filled.Bolt, tint = colors.info)
                    }
                }
            }

            if (power) {
                // Separate the user-facing summary above from the technical detail below.
                HorizontalDivider(color = colors.separator)
                Text(
                    text = env.s(IngestionPath.MANUAL.displayLabel),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Shared controls

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SelectPill(selected: Boolean, icon: ImageVector, label: String, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    val bringIntoViewRequester = remember { BringIntoViewRequester() }
    // If this pill starts (or becomes) selected off-screen, scroll the row to reveal it — an
    // auto-picked meal type should never be invisible to the user.
    LaunchedEffect(selected) {
        if (selected) bringIntoViewRequester.bringIntoView()
    }
    Row(
        modifier = Modifier
            .bringIntoViewRequester(bringIntoViewRequester)
            .clip(shape)
            .clickable(onClick = onClick)
            .background(color = if (selected) colors.primary else colors.surface, shape = shape)
            .border(
                width = 1.dp,
                color = if (selected) Color.Transparent else colors.separator,
                shape = shape,
            )
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = if (selected) colors.onPrimary else colors.textPrimary,
            modifier = Modifier.size(18.dp),
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
private fun NumberField(
    icon: ImageVector,
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
    unit: String,
    warning: String? = null,
) {
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BadanSpace.touchMin),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(20.dp),
            )
            Box(modifier = Modifier.weight(1f)) {
                if (value.isEmpty()) {
                    Text(
                        text = placeholder,
                        style = BadanType.body,
                        color = colors.textSecondary.copy(alpha = 0.6f),
                    )
                }
                BasicTextField(
                    value = value,
                    onValueChange = onValueChange,
                    textStyle = BadanType.body.copy(color = colors.textPrimary),
                    singleLine = true,
                    cursorBrush = SolidColor(colors.primary),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Text(text = unit, style = BadanType.body, color = colors.textSecondary)
        }
        // Soft, non-blocking sanity hint — never disables save, never moralizes.
        if (warning != null) {
            Text(text = warning, style = BadanType.caption, color = colors.outOfBand)
        }
    }
}

@Composable
private fun PrimaryButton(label: String, enabled: Boolean = true, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(enabled = enabled, onClick = onClick)
            .background(color = colors.primary.copy(alpha = if (enabled) 1f else 0.4f), shape = shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(BadanSpace.s2),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
            color = colors.onPrimary,
        )
    }
}

// MARK: - Helpers

/** Parse a decimal the user typed (comma or dot). Zero is a valid explicit value; negatives are not. */
private fun parseDecimal(text: String): Double? =
    text.replace(",", ".").trim().toDoubleOrNull()?.takeIf { it >= 0.0 }

private fun timeText(millis: Long, localeTag: String): String {
    val locale = Locale.forLanguageTag(localeTag)
    return DateFormat.getTimeInstance(DateFormat.SHORT, locale).format(Date(millis))
}
