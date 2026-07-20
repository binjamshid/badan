package net.albayyan.badan.features.workoutnutrition

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.automirrored.filled.DirectionsBike
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Layers
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Straighten
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
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
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
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
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.ProvenanceRow
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.domain.ingestion.DayAttribution
import net.albayyan.badan.features.workouts.IngestedActivity
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

// MARK: - Screen-local bilingual strings
//
// Strings only the workout-capture surface needs; shared vocabulary comes from `Loc`. Framing
// stays neutral — activity is never moralized and a rest day is presented as valid, not a
// shortfall. `private` here is file scope, so identical names in the sibling nutrition screen
// never collide.

private val wOptionalDetails = LocalizedString(en = "Optional details", ar = "تفاصيل اختيارية")
private val wDistance = LocalizedString(en = "Distance", ar = "المسافة")
private val wRecentWorkouts = LocalizedString(en = "Recent workouts", ar = "التمارين الأخيرة")
private val wRecoverySub = LocalizedString(
    en = "Nothing logged today — rest is part of movement too.",
    ar = "لم تُسجَّل حركة اليوم — الراحة جزء من النشاط أيضاً.",
)
private val wNoneYet = LocalizedString(
    en = "No workouts in the last two weeks.",
    ar = "لا تمارين في الأسبوعين الماضيين.",
)
private val wEffortLight = LocalizedString(en = "Light", ar = "خفيف")
private val wEffortHard = LocalizedString(en = "Max effort", ar = "أقصى جهد")
private val wSavedManually = LocalizedString(en = "Saved as your own entry", ar = "يُحفَظ كإدخال منك")
private val wRpe = LocalizedString(en = "RPE", ar = "الجهد")
private val wKm = LocalizedString(en = "km", ar = "كم")
private val wKcal = LocalizedString(en = "kcal", ar = "سعرة")
private val wMeters = LocalizedString(en = "m", ar = "م")
private val wSeconds = LocalizedString(en = "s", ar = "ث")
private val wHighValueHint = LocalizedString(
    en = "That seems unusually high — worth double-checking.",
    ar = "هذا يبدو مرتفعاً بشكل غير معتاد — يستحق التأكد.",
)

// Unified-list vocabulary (EPIC-03). The list below is one list of workouts, not a "your entries"
// list with a "from your watch" list beside it: the user did one run, and which of the two paths
// it arrived by is provenance, not identity.
// An ingested row is marked by naming its writing app, not by a generic "From a device" pill: on
// Android the useful answer to "where did this come from" is which app, because several of them
// write the same metric.
private val wYourEntry = LocalizedString(en = "Your entry", ar = "إدخالك")
private val wShowSetAside = LocalizedString(en = "Show duplicates set aside", ar = "إظهار المكرّرات الموضوعة جانباً")
private val wHideSetAside = LocalizedString(en = "Hide duplicates set aside", ar = "إخفاء المكرّرات الموضوعة جانباً")
private val wSetAside = LocalizedString(en = "Set aside", ar = "موضوع جانباً")
private fun wSetAsideCount(n: Int) = LocalizedString(
    en = "$n duplicate(s) set aside, not deleted",
    ar = "$n نسخة مكرّرة موضوعة جانباً، ولم تُحذف",
)
private val wSetAsideExplainer = LocalizedString(
    en = "When two sources record the same session, BADAN shows one and sets the other aside. " +
        "Nothing is deleted, and you can open either one.",
    ar = "عندما يسجّل مصدران الجلسة نفسها، يعرض بدن واحدة ويضع الأخرى جانباً. لا يُحذف شيء، ويمكنك " +
        "فتح أي منهما.",
)
private fun wKeptOver(n: Int) = LocalizedString(
    en = "Kept over $n other recording(s)",
    ar = "احتُفظ بها بدل $n تسجيل آخر",
)
private val wOpenDetail = LocalizedString(en = "Open workout", ar = "فتح التمرين")

// MARK: - Activity model

/**
 * The quick-add activity types. [key] is the stable English key stored on the record (matching
 * seeded data); display is bilingual and mirror-safe. Faithful port of the iOS `WorkoutActivity`.
 */
private enum class WorkoutActivity(val key: String, val label: LocalizedString, val icon: ImageVector) {
    RUN("Run", LocalizedString(en = "Run", ar = "جري"), Icons.AutoMirrored.Filled.DirectionsRun),
    WALK("Walk", LocalizedString(en = "Walk", ar = "مشي"), Icons.AutoMirrored.Filled.DirectionsWalk),
    STRENGTH("Strength", LocalizedString(en = "Strength", ar = "قوة"), Icons.Filled.FitnessCenter),
    CYCLE("Cycle", LocalizedString(en = "Cycle", ar = "دراجة"), Icons.AutoMirrored.Filled.DirectionsBike),
    OTHER("Other", LocalizedString(en = "Other", ar = "أخرى"), Icons.Filled.SelfImprovement);

    companion object {
        private fun fromKey(raw: String): WorkoutActivity? = entries.firstOrNull { it.key == raw }

        /** Bilingual label for a stored activity string; falls back to the raw value verbatim. */
        fun labelForStored(raw: String): LocalizedString = fromKey(raw)?.label ?: LocalizedString(en = raw, ar = raw)

        fun iconForStored(raw: String): ImageVector = fromKey(raw)?.icon ?: Icons.Filled.FitnessCenter
    }
}

// MARK: - Unified recent list (EPIC-03)

/**
 * One row in the recent list, whichever way the workout arrived.
 *
 * Manual entries and ingested sessions live in two different tables with two different shapes and
 * genuinely different capabilities — only the ingested side has a heart-rate series, a route, or a
 * dedup decision attached — so they are modelled as two cases rather than flattened into a lowest
 * common denominator that would throw the ingested side's detail away before it reached the screen.
 * What is unified is the *list*, not the record.
 */
private sealed interface UnifiedWorkout {
    val startAt: Long

    data class Manual(val entry: WorkoutEntry) : UnifiedWorkout {
        override val startAt: Long get() = entry.startAt
    }

    data class Ingested(
        val session: Session,
        val sourceName: String,
        /** Count of other recordings this one won against, from `SessionDetail.mergedFrom`. */
        val keptOver: Int,
    ) : UnifiedWorkout {
        override val startAt: Long get() = session.startAt
        val isSetAside: Boolean get() = session.provenance.isSuppressed
        val activityCode: String? get() = session.detail.workout?.activityType
    }
}

private data class WorkoutLogData(
    val recent: List<UnifiedWorkout>,
    val loggedToday: Boolean,
    /** How many rows in the window are dedup-suppressed, whether or not they are being shown. */
    val setAsideCount: Int,
)

/**
 * Load the last two weeks of workouts from both paths and note whether anything is attributed
 * to today.
 *
 * [includeSetAside] controls only whether suppressed *sessions* are returned as rows;
 * [WorkoutLogData.setAsideCount] is computed from the full set either way, so the "n set aside"
 * affordance can exist before the user has asked to see them. Manual entries are never suppressed
 * — `workout_entries` has no `suppressed_by` column and `IngestionPipeline.dedupWorkouts`
 * deliberately reconciles ingested sessions against each other only — so a manual twin of an
 * ingested run stays visible beside it. That is the safe direction and is worth knowing before
 * anyone "fixes" the apparent double: hiding a row the user typed is a bigger error than showing
 * two.
 */
private fun loadWorkoutData(env: AppEnvironment, includeSetAside: Boolean): WorkoutLogData {
    val now = env.now()
    val tz = TimeZone.getDefault().id
    val from = now - 14L * 86_400_000L

    val manual = runCatching { env.logging.workouts(from, now) }.getOrDefault(emptyList())

    val sourceNames = runCatching { env.catalog.sources().associate { it.id to it.displayName } }
        .getOrDefault(emptyMap())
    val allSessions = runCatching {
        env.measurements.sessions(SessionKind.WORKOUT, from, now, includeSuppressed = true)
    }.getOrDefault(emptyList())
    val setAsideCount = allSessions.count { it.provenance.isSuppressed }
    val sessions = allSessions
        .filter { includeSetAside || !it.provenance.isSuppressed }
        .map {
            UnifiedWorkout.Ingested(
                session = it,
                sourceName = sourceNames[it.provenance.sourceId] ?: it.provenance.sourceId,
                keptOver = it.detail.mergedFrom.size,
            )
        }

    val rows: List<UnifiedWorkout> = (manual.map { UnifiedWorkout.Manual(it) } + sessions)
        .sortedByDescending { it.startAt }

    val startOfToday = DayAttribution.startOfDay(now, tz)
    return WorkoutLogData(
        recent = rows,
        // "Did I move today" is answered by either path. Before the unified list this only ever
        // consulted manual entries, so a user whose watch recorded a 10k was still shown the
        // "nothing logged today" recovery card.
        loggedToday = rows.any { it.startAt >= startOfToday },
        setAsideCount = setAsideCount,
    )
}

// MARK: - Screen

/**
 * Under-10-second workout capture, pushed as its own screen. Pick an activity, set duration and
 * perceived effort, optionally add energy + distance, then save. Recent workouts sit below; when
 * nothing is logged today a calm "recovery day" note stands in — never a nag. Effort is neutral
 * (one calm tint, never red/green). Faithful port of the iOS `WorkoutLogView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkoutLogScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    val power = env.depth.showsPowerDetail

    // Capture state — altitude and activity persist across saves; measurements are cleared.
    var activity by remember { mutableStateOf(WorkoutActivity.RUN) }
    var minutes by remember { mutableStateOf(30) }
    var rpe by remember { mutableStateOf(5f) }
    var kcalText by remember { mutableStateOf("") }
    var distanceText by remember { mutableStateOf("") }

    // Direct numeric entry for duration — tapping the numeral opens a small text field so a long
    // workout doesn't require dozens of ±5-minute stepper taps.
    var editingDuration by remember { mutableStateOf(false) }
    var durationInput by remember { mutableStateOf("") }
    val durationFocusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    fun commitDuration() {
        durationInput.toIntOrNull()?.let { minutes = it.coerceIn(1, 360) }
        editingDuration = false
    }

    // Recent list (secondary surface) — loaded off the main thread, like the sibling log surfaces.
    var recent by remember { mutableStateOf<List<UnifiedWorkout>>(emptyList()) }
    var loggedToday by remember { mutableStateOf(false) }
    var setAsideCount by remember { mutableStateOf(0) }
    var showSetAside by remember { mutableStateOf(false) }

    suspend fun refresh() {
        val data = withContext(Dispatchers.IO) { loadWorkoutData(env, includeSetAside = showSetAside) }
        recent = data.recent
        loggedToday = data.loggedToday
        setAsideCount = data.setAsideCount
    }

    // Keyed on the filter so toggling "show set aside" re-queries rather than filtering a stale
    // in-memory list — the suppressed rows were never fetched, so there is nothing to filter.
    LaunchedEffect(showSetAside) { refresh() }

    LaunchedEffect(Unit) {
        // Pre-fill duration/effort from the most recent *manual* entry for this activity type, so a
        // habitual routine doesn't need re-adjusting from the generic defaults every visit.
        // Deliberately not seeded from ingested sessions: those record what a device measured, and
        // pre-filling a manual form from them would invite the user to save a second, hand-typed
        // copy of a workout BADAN already has.
        val manual = withContext(Dispatchers.IO) {
            runCatching { env.logging.workouts(env.now() - 14L * 86_400_000L, env.now()) }
                .getOrDefault(emptyList())
        }
        manual.filter { it.activityType == activity.key }
            .maxByOrNull { it.startAt }
            ?.let { last ->
                minutes = (last.durationSeconds / 60.0).roundToInt().coerceIn(1, 360)
                last.perceivedEffort?.let { rpe = it.toFloat().coerceIn(1f, 10f) }
            }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(Loc.logWorkout),
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
            // Activity picker.
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(Loc.activityType))
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                            .padding(vertical = BadanSpace.s1),
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        for (option in WorkoutActivity.entries) {
                            SelectPill(
                                selected = option == activity,
                                icon = option.icon,
                                label = env.s(option.label),
                                onClick = { activity = option },
                            )
                        }
                    }
                }
            }

            // Duration.
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    val durationTrailing: (@Composable () -> Unit)? = if (power) {
                        {
                            // Raw seconds are a power-only affordance.
                            Text(
                                text = "${env.format.integer(minutes * 60)} ${env.s(wSeconds)}",
                                style = BadanType.monospaceDigits(BadanType.chip),
                                color = colors.textSecondary,
                            )
                        }
                    } else {
                        null
                    }
                    SectionHeader(title = env.s(Loc.duration), trailing = durationTrailing)
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = BadanSpace.touchMin),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        if (editingDuration) {
                            BasicTextField(
                                value = durationInput,
                                onValueChange = { durationInput = it.filter(Char::isDigit).take(3) },
                                textStyle = BadanType.numeralM.copy(color = colors.textPrimary),
                                singleLine = true,
                                cursorBrush = SolidColor(colors.primary),
                                keyboardOptions = KeyboardOptions(
                                    keyboardType = KeyboardType.Number,
                                    imeAction = ImeAction.Done,
                                ),
                                keyboardActions = KeyboardActions(onDone = {
                                    commitDuration()
                                    focusManager.clearFocus()
                                }),
                                modifier = Modifier
                                    .width(72.dp)
                                    .focusRequester(durationFocusRequester)
                                    .onFocusChanged { if (!it.isFocused && editingDuration) commitDuration() },
                            )
                            LaunchedEffect(Unit) { durationFocusRequester.requestFocus() }
                        } else {
                            Text(
                                text = env.format.duration(minutes.toDouble() * 60, "min"),
                                style = BadanType.numeralM,
                                color = colors.textPrimary,
                                modifier = Modifier.clickable {
                                    durationInput = minutes.toString()
                                    editingDuration = true
                                },
                            )
                        }
                        Spacer(modifier = Modifier.weight(1f))
                        StepButton(icon = Icons.Filled.Remove, onClick = { minutes = (minutes - 5).coerceAtLeast(1) })
                        StepButton(icon = Icons.Filled.Add, onClick = { minutes = (minutes + 5).coerceAtMost(360) })
                    }
                }
            }

            // Perceived effort (RPE). Neutral single tint — never a good/bad hue.
            BadanCard {
                val value = rpe.roundToInt()
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(
                        title = env.s(Loc.effort),
                        trailing = {
                            Text(
                                text = "${env.s(wRpe)} ${env.format.integer(value)} / ${env.format.integer(10)}",
                                style = BadanType.monospaceDigits(BadanType.chip),
                                color = colors.textSecondary,
                            )
                        },
                    )
                    Slider(
                        value = rpe,
                        onValueChange = { rpe = it },
                        valueRange = 1f..10f,
                        steps = 8,
                        colors = SliderDefaults.colors(
                            thumbColor = colors.primary,
                            activeTrackColor = colors.primary,
                            inactiveTrackColor = colors.separator,
                            activeTickColor = Color.Transparent,
                            inactiveTickColor = Color.Transparent,
                        ),
                    )
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(text = env.s(wEffortLight), style = BadanType.caption, color = colors.textSecondary)
                        Spacer(modifier = Modifier.weight(1f))
                        Text(text = env.s(wEffortHard), style = BadanType.caption, color = colors.textSecondary)
                    }
                }
            }

            // Optional energy + distance.
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(wOptionalDetails))
                    NumberField(
                        icon = Icons.Filled.LocalFireDepartment,
                        placeholder = env.s(Loc.calories),
                        value = kcalText,
                        onValueChange = { kcalText = it },
                        unit = env.s(wKcal),
                        warning = parseDecimal(kcalText)?.takeIf { it > 5000.0 }?.let { env.s(wHighValueHint) },
                    )
                    HorizontalDivider(color = colors.separator)
                    NumberField(
                        icon = Icons.Filled.Straighten,
                        placeholder = env.s(wDistance),
                        value = distanceText,
                        onValueChange = { distanceText = it },
                        unit = env.s(wKm),
                        warning = parseDecimal(distanceText)?.takeIf { it > 200.0 }?.let { env.s(wHighValueHint) },
                    )
                    if (power) {
                        Text(
                            text = env.s(wSavedManually),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            // Save.
            PrimaryButton(label = env.s(Loc.save)) {
                val now = env.now()
                val entry = WorkoutEntry(
                    id = Ulid.newId(),
                    activityType = activity.key,
                    startAt = now - minutes.toLong() * 60_000L,
                    endAt = now,
                    tzId = TimeZone.getDefault().id,
                    energyKcal = parseDecimal(kcalText),
                    distanceM = parseDecimal(distanceText)?.let { it * 1000.0 },
                    perceivedEffort = rpe.roundToInt(),
                    ingestionPath = IngestionPath.MANUAL,
                    updatedAt = now,
                    originDeviceId = env.deviceId,
                )
                // Keep the altitude and activity; clear the one-off measurements.
                kcalText = ""
                distanceText = ""
                scope.launch {
                    withContext(Dispatchers.IO) { runCatching { env.logging.upsertWorkout(entry) } }
                    refresh()
                }
            }

            // Recent workouts — one list over both paths (manual + ingested sessions).
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(wRecentWorkouts))
                if (!loggedToday) {
                    RecoveryCard()
                }

                // The set-aside affordance is shown whenever duplicates exist, at every altitude.
                // Dedup is not a power-user detail: it is the difference between "BADAN lost my
                // run" and "BADAN is showing one of the two copies of it", and a casual user is
                // more likely to need that sentence, not less.
                if (setAsideCount > 0) {
                    SetAsideBar(
                        count = setAsideCount,
                        expanded = showSetAside,
                        onToggle = { showSetAside = !showSetAside },
                    )
                }

                if (recent.isEmpty()) {
                    if (loggedToday) {
                        Text(text = env.s(wNoneYet), style = BadanType.caption, color = colors.textSecondary)
                    }
                } else {
                    for (workout in recent) {
                        when (workout) {
                            is UnifiedWorkout.Manual -> WorkoutRow(workout = workout.entry, power = power)
                            is UnifiedWorkout.Ingested -> IngestedWorkoutRow(
                                row = workout,
                                power = power,
                                onOpen = { nav.push(Route.WorkoutDetail(workout.session.id)) },
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Recent + recovery

@Composable
private fun RecoveryCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Box(
                modifier = Modifier
                    .size(BadanSpace.touchMin)
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .background(colors.primary.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Filled.Eco,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(22.dp),
                )
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = env.s(Loc.recoveryDay),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = env.s(wRecoverySub),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun WorkoutRow(workout: WorkoutEntry, power: Boolean) {
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
                    imageVector = WorkoutActivity.iconForStored(workout.activityType),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    text = env.s(WorkoutActivity.labelForStored(workout.activityType)),
                    style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                )
                Spacer(modifier = Modifier.weight(1f))
                Text(
                    text = env.format.duration(workout.durationSeconds, "min"),
                    style = BadanType.monospaceDigits(BadanType.bodyCompact),
                    color = colors.textSecondary,
                )
            }

            // The chip row is now unconditional, because it always carries at least the
            // "Your entry" marker. In a list that mixes hand-logged and device-recorded workouts,
            // which one you are looking at has to be legible without opening anything — otherwise a
            // manual row sitting next to its device twin reads as BADAN having duplicated a record.
            Row(
                // Scrollable: with the marker pill added, a workout carrying effort + energy +
                // distance is four pills wide and clipped on a narrow phone at large Dynamic Type.
                modifier = Modifier.horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                PillLabel(text = env.s(wYourEntry), icon = Icons.Filled.Edit)
                workout.perceivedEffort?.let {
                    PillLabel(text = "${env.s(wRpe)} ${env.format.integer(it)}", icon = Icons.Filled.Speed)
                }
                workout.energyKcal?.let {
                    PillLabel(
                        text = "${env.format.integer(it.roundToInt())} ${env.s(wKcal)}",
                        icon = Icons.Filled.LocalFireDepartment,
                    )
                }
                workout.distanceM?.let {
                    PillLabel(
                        text = "${env.format.number(it / 1000.0, 1)} ${env.s(wKm)}",
                        icon = Icons.Filled.Straighten,
                    )
                }
            }

            Text(
                text = dateTimeText(workout.startAt, env.language.localeTag),
                style = BadanType.caption,
                color = colors.textSecondary,
            )

            if (power) {
                // Separate the user-facing summary above from the technical detail below.
                HorizontalDivider(color = colors.separator)
                // Power altitude: raw canonical values + lineage.
                val parts = buildList {
                    add("${env.format.integer(workout.durationSeconds.roundToInt())} ${env.s(wSeconds)}")
                    workout.distanceM?.let { add("${env.format.integer(it.roundToInt())} ${env.s(wMeters)}") }
                }
                Text(
                    text = parts.joinToString(" · "),
                    style = BadanType.monospaceDigits(BadanType.caption),
                    color = colors.textSecondary,
                )
                ProvenanceRow(
                    sourceName = env.s(wSavedManually),
                    ingestionPath = workout.ingestionPath,
                    timestampMillis = workout.startAt,
                    language = env.language,
                )
            }
        }
    }
}

// MARK: - Ingested workouts (EPIC-03)

/**
 * The "n duplicates set aside" bar.
 *
 * Deliberately worded as *set aside* everywhere, never as removed, hidden, ignored or cleaned up.
 * I3 is that dedup suppresses and never deletes, and the words on screen are the only part of that
 * invariant the user ever meets — a bar reading "3 duplicates removed" would make the database's
 * honesty invisible and the app's behaviour look destructive.
 */
@Composable
private fun SetAsideBar(count: Int, expanded: Boolean, onToggle: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.Layers,
                    contentDescription = null,
                    tint = colors.info,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    text = env.s(wSetAsideCount(count)),
                    style = BadanType.bodyCompact,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
            }
            Text(
                text = env.s(wSetAsideExplainer),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
            Box(
                modifier = Modifier
                    .heightIn(min = BadanSpace.touchMin)
                    .clickable(onClick = onToggle),
                contentAlignment = Alignment.CenterStart,
            ) {
                Text(
                    text = env.s(if (expanded) wHideSetAside else wShowSetAside),
                    style = BadanType.body,
                    color = colors.primary,
                )
            }
        }
    }
}

/**
 * One ingested workout session in the recent list.
 *
 * A set-aside row is rendered at reduced opacity with a "Set aside" pill, and stays fully tappable
 * — dimming communicates "this is the copy BADAN isn't counting", while remaining reachable is what
 * keeps the suppression inspectable and therefore reversible. A row that were merely greyed out and
 * inert would be a deletion with extra steps.
 */
@Composable
private fun IngestedWorkoutRow(row: UnifiedWorkout.Ingested, power: Boolean, onOpen: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val dim = if (row.isSetAside) 0.6f else 1f

    BadanCard(modifier = Modifier.clickable(onClickLabel = env.s(wOpenDetail), onClick = onOpen)) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = IngestedActivity.icon(row.activityCode),
                    contentDescription = null,
                    tint = colors.primary.copy(alpha = dim),
                    modifier = Modifier.size(20.dp),
                )
                Text(
                    text = env.s(IngestedActivity.label(row.activityCode)),
                    style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                    color = colors.textPrimary.copy(alpha = dim),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = env.format.duration(row.session.durationSeconds, "min"),
                    style = BadanType.monospaceDigits(BadanType.bodyCompact),
                    color = colors.textSecondary.copy(alpha = dim),
                )
            }

            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                // The originating app is named on the row itself, not only in the detail: on
                // Android several apps writing the same metric is the normal configuration, so
                // "which app said this" is list-level information, not a drill-down.
                PillLabel(text = row.sourceName, icon = Icons.Filled.Smartphone)
                if (row.isSetAside) {
                    PillLabel(
                        text = env.s(wSetAside),
                        icon = Icons.Filled.VisibilityOff,
                        tint = colors.outOfBand,
                    )
                }
                if (row.keptOver > 0) {
                    PillLabel(text = env.s(wKeptOver(row.keptOver)), icon = Icons.Filled.Layers)
                }
            }

            Text(
                text = dateTimeText(row.session.startAt, env.language.localeTag),
                style = BadanType.caption,
                color = colors.textSecondary.copy(alpha = dim),
            )

            if (power) {
                HorizontalDivider(color = colors.separator)
                ProvenanceRow(
                    sourceName = row.sourceName,
                    ingestionPath = row.session.provenance.ingestionPath,
                    timestampMillis = row.session.provenance.ingestedAt,
                    language = env.language,
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
    // If this pill starts (or becomes) selected off-screen, scroll the row to reveal it.
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
private fun StepButton(icon: ImageVector, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Box(
        modifier = Modifier
            .size(BadanSpace.touchMin)
            .clip(shape)
            .clickable(onClick = onClick)
            .background(color = colors.surfaceElevated, shape = shape)
            .border(width = 1.dp, color = colors.separator, shape = shape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(20.dp),
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

private fun dateTimeText(millis: Long, localeTag: String): String {
    val locale = Locale.forLanguageTag(localeTag)
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date(millis))
}
