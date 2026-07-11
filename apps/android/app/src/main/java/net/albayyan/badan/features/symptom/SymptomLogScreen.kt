@file:OptIn(ExperimentalMaterial3Api::class)

package net.albayyan.badan.features.symptom

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SelectableDates
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.ontology.SymptomDefinition
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

// MARK: - Screen-local bilingual strings
//
// Strings only the symptom-capture surface needs. Shared vocabulary comes from `Loc`; these fill
// the gaps with real Arabic. Wording is calm and non-judgmental — logging a symptom is never
// framed as a failure.
private object SymptomLogStrings {
    val privateNote = LocalizedString(
        en = "Private to you — just for your own record.",
        ar = "خاص بك — مجرّد سجلّك الشخصي.",
    )
    val noMatches = LocalizedString(en = "No matches", ar = "لا نتائج مطابقة")
    val change = LocalizedString(en = "Change", ar = "تغيير")
    val whenLabel = LocalizedString(en = "When", ar = "الوقت")
    val addTrigger = LocalizedString(en = "Add a trigger", ar = "أضف محفزاً")
    val details = LocalizedString(en = "Record details", ar = "تفاصيل السجل")
    val selfReport = LocalizedString(en = "Saved as a manual self-report.", ar = "محفوظ كإدخال ذاتي يدوي.")
    val deviceOnly = LocalizedString(en = "Stays on this device only.", ar = "يبقى على هذا الجهاز فقط.")
    val timeZone = LocalizedString(en = "Time zone", ar = "المنطقة الزمنية")

    fun logCustom(query: String): LocalizedString =
        LocalizedString(en = "Log “$query”", ar = "تسجيل «$query»")

    /** Bilingual label for a symptom-dictionary category key. */
    fun categoryName(key: String): LocalizedString = when (key) {
        "general" -> LocalizedString(en = "General", ar = "عام")
        "head" -> LocalizedString(en = "Head", ar = "الرأس")
        "digestive" -> LocalizedString(en = "Digestive", ar = "الجهاز الهضمي")
        "respiratory" -> LocalizedString(en = "Respiratory", ar = "الجهاز التنفسي")
        "musculoskeletal" -> LocalizedString(en = "Muscles & joints", ar = "العضلات والمفاصل")
        "mental" -> LocalizedString(en = "Mood & mind", ar = "المزاج والذهن")
        "sleep" -> LocalizedString(en = "Sleep", ar = "النوم")
        "skin" -> LocalizedString(en = "Skin", ar = "الجلد")
        else -> LocalizedString(en = key.replaceFirstChar { it.uppercase() }, ar = key)
    }

    /** A few gentle, optional trigger suggestions — free chips still allow anything. */
    val triggerSuggestions: List<LocalizedString> = listOf(
        LocalizedString(en = "Stress", ar = "توتر"),
        LocalizedString(en = "Poor sleep", ar = "سوء النوم"),
        LocalizedString(en = "Food", ar = "طعام"),
        LocalizedString(en = "Caffeine", ar = "كافيين"),
        LocalizedString(en = "Dehydration", ar = "جفاف"),
        LocalizedString(en = "Screen time", ar = "وقت الشاشة"),
        LocalizedString(en = "Weather", ar = "الطقس"),
    )
}

// MARK: - Choice model

/**
 * What the user is about to log: a canonical dictionary symptom, or a free-text custom label for
 * anything not listed.
 */
private sealed interface SymptomChoice {
    val displayName: LocalizedString
    val symptomId: String?
    val customLabel: String?

    data class Known(val def: SymptomDefinition) : SymptomChoice {
        override val displayName: LocalizedString get() = def.displayName
        override val symptomId: String get() = def.id
        override val customLabel: String? get() = null
    }

    data class Custom(val label: String) : SymptomChoice {
        override val displayName: LocalizedString get() = LocalizedString(en = label, ar = label)
        override val symptomId: String? get() = null
        override val customLabel: String get() = label
    }
}

// MARK: - Loaded data

/**
 * Everything the picker needs, gathered once: the distinct symptoms logged in the last 30 days
 * (for 2-tap re-log) plus the full dictionary grouped into category sections.
 */
private data class SymptomLogData(
    val recents: List<SymptomDefinition>,
    val categories: List<Pair<String, List<SymptomDefinition>>>,
)

// MARK: - Screen

/**
 * Under-10-second symptom capture, pushed as its own screen. Pick from recents (2 taps) or search /
 * browse categories, set a calm severity, add optional triggers + a note, optionally backdate, then
 * save. Sensitive by nature — private, judgment-free, never alarming. Faithful port of the iOS
 * `SymptomLogView`; same dual-altitude (raw 0–10 value + provenance metadata only in power depth).
 */
@Composable
fun SymptomLogScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var state by remember { mutableStateOf<LoadState<SymptomLogData>>(LoadState.Loading) }
    var reloadKey by remember { mutableStateOf(0) }

    // Capture state
    var selection by remember { mutableStateOf<SymptomChoice?>(null) }
    var searchText by remember { mutableStateOf("") }
    var severity by remember { mutableStateOf(3f) }
    val triggers = remember { mutableStateListOf<String>() }
    var newTrigger by remember { mutableStateOf("") }
    var note by remember { mutableStateOf("") }
    var occurredAt by remember { mutableStateOf(env.now()) }
    var maxDate by remember { mutableStateOf(env.now()) }

    var showDatePicker by remember { mutableStateOf(false) }
    var showTimePicker by remember { mutableStateOf(false) }

    val tz = remember { TimeZone.getDefault().id }

    // Distinct recently-logged symptoms + the categorized dictionary; re-loaded when the language
    // changes (so labels stay honest) or after a save-and-add-another (so the just-logged symptom
    // becomes a 2-tap re-log). Sensitive reads run off the main thread.
    LaunchedEffect(reloadKey, env.language) {
        maxDate = env.now()
        state = LoadState.Loading
        state = withContext(Dispatchers.IO) { loadSymptomData(env) }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(Loc.logSymptom),
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
        ) {
            StatefulContainer(state) { data ->
                val choice = selection
                if (choice != null) {
                    CaptureForm(
                        choice = choice,
                        severity = severity,
                        onSeverityChange = { severity = it },
                        triggers = triggers,
                        newTrigger = newTrigger,
                        onNewTriggerChange = { newTrigger = it },
                        onAddTrigger = { addTrigger(triggers, it) },
                        onCommitTrigger = {
                            addTrigger(triggers, newTrigger)
                            newTrigger = ""
                        },
                        onRemoveTrigger = { triggers.remove(it) },
                        note = note,
                        onNoteChange = { note = it },
                        occurredAt = occurredAt,
                        onPickDate = { showDatePicker = true },
                        onPickTime = { showTimePicker = true },
                        onChangeSelection = { selection = null },
                        onSave = { addAnother ->
                            val entry = SymptomEntry(
                                id = Ulid.newId(),
                                symptomId = choice.symptomId,
                                customLabel = choice.customLabel,
                                severity = severity.roundToInt(),
                                occurredAt = occurredAt,
                                tzId = tz,
                                triggers = triggers.toList(),
                                note = note.trim().ifEmpty { null },
                                updatedAt = env.now(),
                                originDeviceId = env.deviceId,
                            )
                            scope.launch {
                                val ok = withContext(Dispatchers.IO) {
                                    runCatching { env.logging.insertSymptom(entry) }.isSuccess
                                }
                                // Stay calm and non-destructive; keep the form so nothing is lost.
                                if (!ok) return@launch
                                if (addAnother) {
                                    selection = null
                                    searchText = ""
                                    severity = 3f
                                    triggers.clear()
                                    newTrigger = ""
                                    note = ""
                                    occurredAt = env.now()
                                    reloadKey++ // refresh recents so the just-logged symptom is a 2-tap re-log
                                } else {
                                    nav.pop()
                                }
                            }
                        },
                    )
                } else {
                    Picker(
                        data = data,
                        searchText = searchText,
                        onSearchChange = { searchText = it },
                        onSelect = {
                            searchText = ""
                            selection = it
                        },
                    )
                }
            }
        }
    }

    // Backdate: date + time pickers, capped to "now" so a symptom can never land in the future.
    if (showDatePicker) {
        val cal = remember(maxDate) { Calendar.getInstance().apply { timeInMillis = maxDate } }
        val dpState = rememberDatePickerState(
            initialSelectedDateMillis = dateOnlyUtc(occurredAt),
            selectableDates = remember(maxDate) {
                PastOrTodaySelectableDates(dateOnlyUtc(maxDate), cal.get(Calendar.YEAR))
            },
        )
        DatePickerDialog(
            onDismissRequest = { showDatePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    dpState.selectedDateMillis?.let { picked ->
                        occurredAt = minOf(applyPickedDate(picked, occurredAt), maxDate)
                    }
                    showDatePicker = false
                }) { Text(env.s(Loc.save)) }
            },
            dismissButton = {
                TextButton(onClick = { showDatePicker = false }) { Text(env.s(Loc.cancel)) }
            },
        ) {
            DatePicker(state = dpState)
        }
    }

    if (showTimePicker) {
        val cal = remember(occurredAt) { Calendar.getInstance().apply { timeInMillis = occurredAt } }
        val tpState = rememberTimePickerState(
            initialHour = cal.get(Calendar.HOUR_OF_DAY),
            initialMinute = cal.get(Calendar.MINUTE),
            is24Hour = false,
        )
        AlertDialog(
            onDismissRequest = { showTimePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    occurredAt = minOf(applyPickedTime(tpState.hour, tpState.minute, occurredAt), maxDate)
                    showTimePicker = false
                }) { Text(env.s(Loc.save)) }
            },
            dismissButton = {
                TextButton(onClick = { showTimePicker = false }) { Text(env.s(Loc.cancel)) }
            },
            text = { TimePicker(state = tpState) },
        )
    }
}

// MARK: - Picker (choose a symptom)

@Composable
private fun Picker(
    data: SymptomLogData,
    searchText: String,
    onSearchChange: (String) -> Unit,
    onSelect: (SymptomChoice) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
        Text(
            text = env.s(SymptomLogStrings.privateNote),
            style = BadanType.caption,
            color = colors.textSecondary,
        )

        SearchField(value = searchText, onValueChange = onSearchChange)

        val query = searchText.trim()
        if (query.isNotEmpty()) {
            SearchResults(query = query, onSelect = onSelect)
        } else {
            if (data.recents.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(Loc.recents))
                    ChipRow {
                        for (def in data.recents) {
                            SymptomChip(title = env.s(def.displayName), icon = Icons.Filled.Refresh) {
                                onSelect(SymptomChoice.Known(def))
                            }
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
                for ((key, items) in data.categories) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(SymptomLogStrings.categoryName(key)))
                        ChipRow {
                            for (def in items) {
                                SymptomChip(title = env.s(def.displayName)) {
                                    onSelect(SymptomChoice.Known(def))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SearchResults(query: String, onSelect: (SymptomChoice) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val results = env.symptoms.search(query)
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        for (def in results) {
            ResultRow(
                name = env.s(def.displayName),
                category = env.s(SymptomLogStrings.categoryName(def.category)),
                onClick = { onSelect(SymptomChoice.Known(def)) },
            )
        }
        if (results.isEmpty()) {
            Text(
                text = env.s(SymptomLogStrings.noMatches),
                style = BadanType.caption,
                color = colors.textSecondary,
                modifier = Modifier.padding(vertical = BadanSpace.s1),
            )
        }
        // Free-text custom label — anything not in the dictionary is still loggable.
        CustomResultRow(
            label = env.s(SymptomLogStrings.logCustom(query)),
            onClick = { onSelect(SymptomChoice.Custom(query)) },
        )
    }
}

// MARK: - Capture form

@Composable
private fun CaptureForm(
    choice: SymptomChoice,
    severity: Float,
    onSeverityChange: (Float) -> Unit,
    triggers: List<String>,
    newTrigger: String,
    onNewTriggerChange: (String) -> Unit,
    onAddTrigger: (String) -> Unit,
    onCommitTrigger: () -> Unit,
    onRemoveTrigger: (String) -> Unit,
    note: String,
    onNoteChange: (String) -> Unit,
    occurredAt: Long,
    onPickDate: () -> Unit,
    onPickTime: () -> Unit,
    onChangeSelection: () -> Unit,
    onSave: (Boolean) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val power = env.depth.showsPowerDetail
    val sev = severity.roundToInt()
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
        SelectedHeader(choice = choice, onChange = onChangeSelection)
        SeverityCard(severity = severity, sev = sev, power = power, onSeverityChange = onSeverityChange)
        TriggersCard(
            triggers = triggers,
            newTrigger = newTrigger,
            onNewTriggerChange = onNewTriggerChange,
            onAddTrigger = onAddTrigger,
            onCommitTrigger = onCommitTrigger,
            onRemoveTrigger = onRemoveTrigger,
        )
        NoteCard(note = note, onNoteChange = onNoteChange)
        WhenCard(occurredAt = occurredAt, onPickDate = onPickDate, onPickTime = onPickTime)
        if (power) MetadataCard()
        SaveButtons(onSave = onSave)
    }
}

@Composable
private fun SelectedHeader(choice: SymptomChoice, onChange: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            verticalAlignment = Alignment.Top,
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = env.s(SymptomLogStrings.privateNote),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
                Text(
                    text = env.s(choice.displayName),
                    style = BadanType.sectionTitle,
                    color = colors.textPrimary,
                )
            }
            TextButton(onClick = onChange) {
                Text(
                    text = env.s(SymptomLogStrings.change),
                    style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                    color = colors.primary,
                )
            }
        }
    }
}

@Composable
private fun SeverityCard(severity: Float, sev: Int, power: Boolean, onSeverityChange: (Float) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    // Never red. Calm primary for most of the range; a subtle amber only at the top so the scale
    // reads without moralizing.
    val tint = if (sev >= 7) colors.outOfBand else colors.primary
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(
                title = env.s(Loc.severity),
                trailing = if (power) {
                    {
                        // Raw 0–10 value is a power-only affordance.
                        Text(
                            text = "${env.format.integer(sev)}/${env.format.integer(10)}",
                            style = BadanType.monospaceDigits(BadanType.chip),
                            color = colors.textSecondary,
                        )
                    }
                } else null,
            )
            Text(
                text = env.s(severityDescriptor(sev)),
                style = BadanType.sectionTitle,
                color = tint,
            )
            Slider(
                value = severity,
                onValueChange = onSeverityChange,
                valueRange = 0f..10f,
                steps = 9,
                colors = SliderDefaults.colors(
                    thumbColor = tint,
                    activeTrackColor = tint,
                    inactiveTrackColor = colors.separator,
                ),
            )
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(text = env.s(Loc.mild), style = BadanType.caption, color = colors.textSecondary)
                Text(text = env.s(Loc.moderate), style = BadanType.caption, color = colors.textSecondary)
                Text(text = env.s(Loc.severe), style = BadanType.caption, color = colors.textSecondary)
            }
        }
    }
}

@Composable
private fun TriggersCard(
    triggers: List<String>,
    newTrigger: String,
    onNewTriggerChange: (String) -> Unit,
    onAddTrigger: (String) -> Unit,
    onCommitTrigger: () -> Unit,
    onRemoveTrigger: (String) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(title = env.s(Loc.triggers))

            if (triggers.isNotEmpty()) {
                ChipRow {
                    for (trigger in triggers) {
                        RemovableChip(text = trigger) { onRemoveTrigger(trigger) }
                    }
                }
            }

            val suggestions = SymptomLogStrings.triggerSuggestions
                .map { env.s(it) }
                .filter { it !in triggers }
            if (suggestions.isNotEmpty()) {
                ChipRow {
                    for (label in suggestions) {
                        SymptomChip(title = label, icon = Icons.Filled.Add) { onAddTrigger(label) }
                    }
                }
            }

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
                    if (newTrigger.isEmpty()) {
                        Text(
                            text = env.s(SymptomLogStrings.addTrigger),
                            style = BadanType.body,
                            color = colors.textSecondary,
                        )
                    }
                    BasicTextField(
                        value = newTrigger,
                        onValueChange = onNewTriggerChange,
                        textStyle = BadanType.body.copy(color = colors.textPrimary),
                        singleLine = true,
                        cursorBrush = SolidColor(colors.primary),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { onCommitTrigger() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                val canAdd = newTrigger.trim().isNotEmpty()
                TextButton(onClick = onCommitTrigger, enabled = canAdd) {
                    Text(
                        text = env.s(Loc.add),
                        style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                        color = if (canAdd) colors.primary else colors.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
private fun NoteCard(note: String, onNoteChange: (String) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Box(modifier = Modifier.fillMaxWidth()) {
            if (note.isEmpty()) {
                Text(
                    text = env.s(Loc.notePlaceholder),
                    style = BadanType.body,
                    color = colors.textSecondary,
                )
            }
            BasicTextField(
                value = note,
                onValueChange = onNoteChange,
                textStyle = BadanType.body.copy(color = colors.textPrimary),
                maxLines = 4,
                cursorBrush = SolidColor(colors.primary),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun WhenCard(occurredAt: Long, onPickDate: () -> Unit, onPickTime: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BadanSpace.touchMin),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = Icons.Filled.Schedule,
                contentDescription = null,
                tint = colors.textSecondary,
                modifier = Modifier.size(20.dp),
            )
            Text(
                text = env.s(SymptomLogStrings.whenLabel),
                style = BadanType.body,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            SymptomChip(title = formatDate(occurredAt, env.language), onClick = onPickDate)
            SymptomChip(title = formatTime(occurredAt, env.language), onClick = onPickTime)
        }
    }
}

@Composable
private fun MetadataCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val tz = remember { TimeZone.getDefault().id }
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            SectionHeader(title = env.s(SymptomLogStrings.details))
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = BadanSpace.s7),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Text(
                    text = env.s(SymptomLogStrings.timeZone),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                Text(text = tz, style = BadanType.bodyCompact, color = colors.textPrimary)
            }
            Text(
                text = env.s(SymptomLogStrings.selfReport),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
            Text(
                text = env.s(SymptomLogStrings.deviceOnly),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

@Composable
private fun SaveButtons(onSave: (Boolean) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .clickable { onSave(false) }
                .background(colors.primary, shape)
                .heightIn(min = BadanSpace.touchMin)
                .padding(horizontal = BadanSpace.s4),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = env.s(Loc.save),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = Color.White,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                .clickable { onSave(true) }
                .background(colors.surface, shape)
                .border(1.dp, colors.separator, shape)
                .heightIn(min = BadanSpace.touchMin)
                .padding(horizontal = BadanSpace.s4),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = env.s(Loc.saveAndAddAnother),
                style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                color = colors.primary,
            )
        }
    }
}

// MARK: - Reusable pieces

/** A horizontally-scrolling chip strip; mirrors correctly under RTL via Compose auto-mirroring. */
@Composable
private fun ChipRow(content: @Composable () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(vertical = BadanSpace.s1),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        content()
    }
}

@Composable
private fun SymptomChip(
    title: String,
    icon: ImageVector? = null,
    selected: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    val content = if (selected) Color.White else colors.textPrimary
    Row(
        modifier = Modifier
            .clip(shape)
            .clickable(onClick = onClick)
            .background(if (selected) colors.primary else colors.surface, shape)
            .then(if (selected) Modifier else Modifier.border(1.dp, colors.separator, shape))
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        if (icon != null) {
            Icon(imageVector = icon, contentDescription = null, tint = content, modifier = Modifier.size(16.dp))
        }
        Text(text = title, style = BadanType.chip, color = content, maxLines = 1)
    }
}

@Composable
private fun RemovableChip(text: String, onRemove: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    Row(
        modifier = Modifier
            .clip(shape)
            .clickable(onClick = onRemove)
            .background(colors.primary.copy(alpha = 0.12f), shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Text(text = text, style = BadanType.chip, color = colors.primary, maxLines = 1)
        Icon(
            imageVector = Icons.Filled.Close,
            contentDescription = "${env.s(Loc.delete)} $text",
            tint = colors.primary,
            modifier = Modifier.size(14.dp),
        )
    }
}

@Composable
private fun SearchField(value: String, onValueChange: (String) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surface, shape)
            .border(1.dp, colors.separator, shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(start = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        Box(modifier = Modifier.weight(1f)) {
            if (value.isEmpty()) {
                Text(text = env.s(Loc.chooseSymptom), style = BadanType.body, color = colors.textSecondary)
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = BadanType.body.copy(color = colors.textPrimary),
                singleLine = true,
                cursorBrush = SolidColor(colors.primary),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (value.isNotEmpty()) {
            IconButton(onClick = { onValueChange("") }) {
                Icon(
                    imageVector = Icons.Filled.Close,
                    contentDescription = env.s(Loc.close),
                    tint = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun ResultRow(name: String, category: String, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick)
            .background(colors.surface, shape)
            .border(1.dp, colors.separator, shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Text(text = name, style = BadanType.body, color = colors.textPrimary, modifier = Modifier.weight(1f))
        Text(text = category, style = BadanType.caption, color = colors.textSecondary)
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun CustomResultRow(label: String, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick)
            .background(colors.surface, shape)
            .border(1.dp, colors.separator, shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.cardPadding),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = Icons.Filled.AddCircle,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(20.dp),
        )
        Text(text = label, style = BadanType.body, color = colors.primary, modifier = Modifier.weight(1f))
    }
}

// MARK: - Non-composable helpers

/** Distinct recently-logged symptoms (most recent first) + the categorized dictionary. */
private fun loadSymptomData(env: AppEnvironment): LoadState<SymptomLogData> = runCatching {
    val now = env.now()
    val from = now - 30L * 86_400_000L
    val recentEntries = env.logging.symptoms(from, now)

    val seen = LinkedHashSet<String>()
    val recents = mutableListOf<SymptomDefinition>()
    for (entry in recentEntries) {
        val id = entry.symptomId ?: continue
        if (id in seen) continue
        val def = env.symptoms.definition(id) ?: continue
        seen.add(id)
        recents.add(def)
    }

    val categories = env.symptoms.categories.map { key -> key to env.symptoms.inCategory(key) }

    if (recents.isEmpty() && categories.isEmpty()) {
        LoadState.Empty(env.s(Loc.chooseSymptom))
    } else {
        LoadState.Loaded(SymptomLogData(recents = recents, categories = categories))
    }
}.getOrElse { LoadState.Error(it.toString()) }

private fun addTrigger(triggers: MutableList<String>, value: String) {
    val trimmed = value.trim()
    if (trimmed.isEmpty() || trimmed in triggers) return
    triggers.add(trimmed)
}

private fun severityDescriptor(value: Int): LocalizedString = when {
    value <= 3 -> Loc.mild
    value <= 6 -> Loc.moderate
    else -> Loc.severe
}

// MARK: - Backdate helpers

/** The UTC-midnight of the local calendar date at [localMillis] — the value space a Compose date picker uses. */
private fun dateOnlyUtc(localMillis: Long): Long {
    val local = Calendar.getInstance().apply { timeInMillis = localMillis }
    return Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
        clear()
        set(local.get(Calendar.YEAR), local.get(Calendar.MONTH), local.get(Calendar.DAY_OF_MONTH))
    }.timeInMillis
}

/** Combine a UTC calendar date picked from the date picker with the existing local time-of-day. */
private fun applyPickedDate(pickedUtcMillis: Long, currentLocal: Long): Long {
    val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = pickedUtcMillis }
    return Calendar.getInstance().apply {
        timeInMillis = currentLocal
        set(Calendar.YEAR, utc.get(Calendar.YEAR))
        set(Calendar.MONTH, utc.get(Calendar.MONTH))
        set(Calendar.DAY_OF_MONTH, utc.get(Calendar.DAY_OF_MONTH))
    }.timeInMillis
}

/** Combine a picked local time-of-day with the existing calendar date. */
private fun applyPickedTime(hour: Int, minute: Int, currentLocal: Long): Long =
    Calendar.getInstance().apply {
        timeInMillis = currentLocal
        set(Calendar.HOUR_OF_DAY, hour)
        set(Calendar.MINUTE, minute)
        set(Calendar.SECOND, 0)
        set(Calendar.MILLISECOND, 0)
    }.timeInMillis

private fun formatDate(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "EEEEdMMM")
    return SimpleDateFormat(pattern, locale).apply { timeZone = TimeZone.getDefault() }.format(Date(millis))
}

private fun formatTime(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "jm")
    return SimpleDateFormat(pattern, locale).apply { timeZone = TimeZone.getDefault() }.format(Date(millis))
}

/** Disallows any calendar date after "now" so a backdated symptom can never land in the future. */
private class PastOrTodaySelectableDates(
    private val maxDateUtc: Long,
    private val maxYear: Int,
) : SelectableDates {
    override fun isSelectableDate(utcTimeMillis: Long): Boolean = utcTimeMillis <= maxDateUtc
    override fun isSelectableYear(year: Int): Boolean = year <= maxYear
}
