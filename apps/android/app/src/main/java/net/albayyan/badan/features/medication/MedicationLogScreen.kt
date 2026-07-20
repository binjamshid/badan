package net.albayyan.badan.features.medication

import androidx.compose.animation.Crossfade
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Redo
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberTimePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.designsystem.components.EmptyState
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.designsystem.components.iconForKey
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.MedicationRegimen
import net.albayyan.badan.domain.MedicationSchedule
import net.albayyan.badan.domain.SkipReason
import net.albayyan.badan.domain.ingestion.DayAttribution
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs

// MARK: - File-local strings (bilingual; wellness-safe; not in the shared catalog)

private val dueTodayLabel = LocalizedString(en = "Due today", ar = "مستحق اليوم")
private val takeAction = LocalizedString(en = "Take", ar = "تناول")
private val yourMedications = LocalizedString(en = "Your medications", ar = "أدويتك")
private val last7Days = LocalizedString(en = "Last 7 days", ar = "آخر ٧ أيام")
private val asNeededLabel = LocalizedString(en = "As needed", ar = "عند الحاجة")
private val dailyLabel = LocalizedString(en = "Daily", ar = "يومياً")
private val weeklyLabel = LocalizedString(en = "Weekly", ar = "أسبوعياً")
private val skipPrompt = LocalizedString(
    en = "No problem — pick a reason if you'd like.",
    ar = "لا بأس — اختر سبباً إن أردت.",
)
private val emptyTitle = LocalizedString(en = "No medications yet", ar = "لا أدوية بعد")
private val emptyBody = LocalizedString(
    en = "Add one to keep a calm record here. No pressure — skips count too.",
    ar = "أضِف دواءً لتحتفظ بسجلّ هادئ هنا. دون ضغط — التخطّي يُحسب أيضاً.",
)
private val addTime = LocalizedString(en = "Add a time", ar = "إضافة وقت")
private val timesLabel = LocalizedString(en = "Times", ar = "الأوقات")
private val namePlaceholder = LocalizedString(en = "e.g. Vitamin D", ar = "مثال: فيتامين د")
private val strengthPlaceholder = LocalizedString(en = "e.g. 1000 IU", ar = "مثال: ١٠٠٠ وحدة")
private val addedManually = LocalizedString(en = "Recorded by you", ar = "مسجَّل بواسطتك")
private val addTimeHint = LocalizedString(
    en = "Add at least one time to save.",
    ar = "أضف وقتاً واحداً على الأقل للحفظ.",
)
private val morningLabel = LocalizedString(en = "Morning", ar = "الصباح")
private val afternoonLabel = LocalizedString(en = "Afternoon", ar = "الظهيرة")
private val eveningLabel = LocalizedString(en = "Evening", ar = "المساء")

// MARK: - Read-model

private enum class SlotStatus { TAKEN, SKIPPED, PENDING }

private enum class DotKind { TAKEN, SKIPPED, PENDING, NONE }

private enum class AddMode { DAILY, AS_NEEDED }

/** A coarse time-of-day bucket, used to group the due list once it grows past a few slots. */
private enum class TimeOfDay(val label: LocalizedString) {
    MORNING(morningLabel),
    AFTERNOON(afternoonLabel),
    EVENING(eveningLabel),
}

private fun timeOfDayBucket(minutesOfDay: Int): TimeOfDay = when {
    minutesOfDay < 12 * 60 -> TimeOfDay.MORNING
    minutesOfDay < 17 * 60 -> TimeOfDay.AFTERNOON
    else -> TimeOfDay.EVENING
}

/** One expanded scheduled dose for today. */
private data class DueSlot(
    val id: String,
    val regimen: MedicationRegimen,
    val time: String,          // canonical "HH:mm"
    val displayTime: String,   // localized clock string
    val scheduledFor: Long,
    val minutesOfDay: Int,
    val status: SlotStatus,
    val skipReason: SkipReason?,
    val isOverdue: Boolean,
)

/** Everything the meds hub needs, gathered once so casual and power are two altitudes over it. */
private data class MedData(
    val regimens: List<MedicationRegimen>,
    val dueSlots: List<DueSlot>,
    val strips: Map<String, List<DotKind>>,   // regimenId -> 7 dots (oldest first)
    val weekdayLetters: List<String>,         // 7 narrow weekday letters (oldest first)
    val todayIndex: Int,                      // index of today within the strip (== 6)
    val hasPending: Boolean,
    val allResolved: Boolean,                 // there were slots and none pending
)

// MARK: - Screen

/**
 * The non-punitive medication hub. Today's scheduled doses expand into calm Take / Skip rows;
 * overdue reads as a neutral "Still due" (never red); skips are a first-class, outline-styled
 * choice with an optional reason. Below: your regimens with a 7-day dot strip. A pushed detail
 * route (owns its own top bar + back). Faithful port of the iOS `MedicationLogView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MedicationLogScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var state by remember { mutableStateOf<LoadState<MedData>>(LoadState.Loading) }
    var reloadToken by remember { mutableIntStateOf(0) }
    var showingAdd by remember { mutableStateOf(false) }
    // The slot currently showing its skip-reason chips.
    var skippingSlotId by remember { mutableStateOf<String?>(null) }
    // A resolved slot the user re-opened to change their choice.
    var editingSlotId by remember { mutableStateOf<String?>(null) }

    // Reload whenever a presentation preference (language / digits / depth) changes so every
    // pre-formatted clock string re-localizes, and whenever a mutation bumps the token.
    LaunchedEffect(env.profile, reloadToken) {
        state = loadMedData(env)
    }

    // A write is non-punitive and always reflects the latest choice: persist off the main thread,
    // then bump the token to re-read the calm view.
    fun runWrite(after: () -> Unit = {}, work: () -> Unit) {
        scope.launch {
            withContext(Dispatchers.IO) { runCatching { work() } }
            after()
            reloadToken++
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(Loc.logMedication),
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
                    IconButton(onClick = { showingAdd = true }) {
                        Icon(
                            imageVector = Icons.Filled.Add,
                            contentDescription = env.s(Loc.addMedication),
                            tint = colors.primary,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.background,
                    titleContentColor = colors.textPrimary,
                    navigationIconContentColor = colors.textPrimary,
                    actionIconContentColor = colors.primary,
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
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s6),
        ) {
            StatefulContainer(state) { data ->
                MedicationContent(
                    data = data,
                    skippingSlotId = skippingSlotId,
                    editingSlotId = editingSlotId,
                    onTakeAll = { slots ->
                        skippingSlotId = null
                        editingSlotId = null
                        runWrite {
                            slots.filter { it.status == SlotStatus.PENDING }.forEach {
                                recordAdherence(env, it.regimen.id, it.scheduledFor, it.time, AdherenceKind.TAKEN, null)
                            }
                        }
                    },
                    onTake = { slot ->
                        editingSlotId = null
                        runWrite {
                            recordAdherence(env, slot.regimen.id, slot.scheduledFor, slot.time, AdherenceKind.TAKEN, null)
                        }
                    },
                    onStartSkip = { id -> skippingSlotId = id },
                    onCancelSkip = { skippingSlotId = null },
                    onSkip = { slot, reason ->
                        runWrite(after = { skippingSlotId = null; editingSlotId = null }) {
                            recordAdherence(env, slot.regimen.id, slot.scheduledFor, slot.time, AdherenceKind.SKIPPED, reason)
                        }
                    },
                    onStartEdit = { id ->
                        editingSlotId = id
                        skippingSlotId = null
                    },
                    onAdd = { showingAdd = true },
                )
            }
        }
    }

    if (showingAdd) {
        val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet(
            onDismissRequest = { showingAdd = false },
            sheetState = sheetState,
            containerColor = colors.background,
        ) {
            AddMedicationSheetContent(
                onCancel = { showingAdd = false },
                onSave = { name, strength, schedule ->
                    runWrite { addRegimen(env, name, strength, schedule) }
                    showingAdd = false
                },
            )
        }
    }
}

// MARK: - Loaded body

@Composable
private fun MedicationContent(
    data: MedData,
    skippingSlotId: String?,
    editingSlotId: String?,
    onTakeAll: (List<DueSlot>) -> Unit,
    onTake: (DueSlot) -> Unit,
    onStartSkip: (String) -> Unit,
    onCancelSkip: () -> Unit,
    onSkip: (DueSlot, SkipReason) -> Unit,
    onStartEdit: (String) -> Unit,
    onAdd: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s6)) {
        if (data.regimens.isEmpty()) {
            MedEmptyState(onAdd)
        } else {
            if (data.dueSlots.isNotEmpty()) {
                DueSection(
                    data = data,
                    skippingSlotId = skippingSlotId,
                    editingSlotId = editingSlotId,
                    onTakeAll = onTakeAll,
                    onTake = onTake,
                    onStartSkip = onStartSkip,
                    onCancelSkip = onCancelSkip,
                    onSkip = onSkip,
                    onStartEdit = onStartEdit,
                )
            }
            RegimensSection(data)
        }
        BoundaryFooter()
    }
}

// MARK: - Due section

@Composable
private fun DueSection(
    data: MedData,
    skippingSlotId: String?,
    editingSlotId: String?,
    onTakeAll: (List<DueSlot>) -> Unit,
    onTake: (DueSlot) -> Unit,
    onStartSkip: (String) -> Unit,
    onCancelSkip: () -> Unit,
    onSkip: (DueSlot, SkipReason) -> Unit,
    onStartEdit: (String) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(
            title = env.s(dueTodayLabel),
            trailing = if (data.hasPending) {
                {
                    Box(
                        modifier = Modifier
                            .clip(RoundedCornerShape(BadanRadius.chip))
                            .clickable { onTakeAll(data.dueSlots) }
                            .heightIn(min = BadanSpace.touchMin)
                            .padding(horizontal = BadanSpace.s2),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = env.s(Loc.takeAll),
                            style = BadanType.bodyCompact.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.primary,
                        )
                    }
                }
            } else {
                null
            },
        )

        if (data.allResolved) {
            AllDoneBanner()
        }

        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            // Past a handful of concurrent due slots, group by time-of-day so a busy regimen
            // list stays scannable; below that threshold a flat list reads fine on its own.
            if (data.dueSlots.size > 4) {
                TimeOfDay.entries.forEach { bucket ->
                    val slotsInBucket = data.dueSlots.filter { timeOfDayBucket(it.minutesOfDay) == bucket }
                    if (slotsInBucket.isNotEmpty()) {
                        Text(
                            text = env.s(bucket.label),
                            style = BadanType.chip,
                            color = colors.textSecondary,
                        )
                        slotsInBucket.forEach { slot ->
                            DueSlotCard(
                                slot = slot,
                                skippingSlotId = skippingSlotId,
                                editingSlotId = editingSlotId,
                                onTake = onTake,
                                onStartSkip = onStartSkip,
                                onCancelSkip = onCancelSkip,
                                onSkip = onSkip,
                                onStartEdit = onStartEdit,
                            )
                        }
                    }
                }
            } else {
                data.dueSlots.forEach { slot ->
                    DueSlotCard(
                        slot = slot,
                        skippingSlotId = skippingSlotId,
                        editingSlotId = editingSlotId,
                        onTake = onTake,
                        onStartSkip = onStartSkip,
                        onCancelSkip = onCancelSkip,
                        onSkip = onSkip,
                        onStartEdit = onStartEdit,
                    )
                }
            }
        }
    }
}

@Composable
private fun AllDoneBanner() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = colors.inBand,
                modifier = Modifier.size(22.dp),
            )
            Text(
                text = env.s(Loc.allDone),
                style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            Spacer(modifier = Modifier.weight(1f))
        }
    }
}

@Composable
private fun DueSlotCard(
    slot: DueSlot,
    skippingSlotId: String?,
    editingSlotId: String?,
    onTake: (DueSlot) -> Unit,
    onStartSkip: (String) -> Unit,
    onCancelSkip: () -> Unit,
    onSkip: (DueSlot, SkipReason) -> Unit,
    onStartEdit: (String) -> Unit,
) {
    val colors = BadanTheme.colors
    val showActions = slot.status == SlotStatus.PENDING || editingSlotId == slot.id
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                verticalAlignment = Alignment.Top,
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Text(
                        text = slot.regimen.name,
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        val strength = slot.regimen.strength
                        if (!strength.isNullOrEmpty()) {
                            Text(text = strength, style = BadanType.caption, color = colors.textSecondary)
                        }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Schedule,
                                contentDescription = null,
                                tint = colors.textSecondary,
                                modifier = Modifier.size(14.dp),
                            )
                            Text(text = slot.displayTime, style = BadanType.caption, color = colors.textSecondary)
                        }
                    }
                }
                StatusTrailing(slot = slot, onStartEdit = onStartEdit)
            }

            if (showActions) {
                Crossfade(targetState = skippingSlotId == slot.id, label = "medActionsSwap") { skipping ->
                    if (skipping) {
                        SkipReasonPicker(slot = slot, onCancelSkip = onCancelSkip, onSkip = onSkip)
                    } else {
                        ActionRow(slot = slot, onTake = onTake, onStartSkip = onStartSkip)
                    }
                }
            }
        }
    }
}

/**
 * The right-side status marker: a completion chip, a calm skip outline, or a neutral "still due" —
 * never red, never alarming. A resolved marker is tappable to re-open the choice (records replace
 * cleanly), matching the non-punitive "change your mind" model.
 */
@Composable
private fun StatusTrailing(slot: DueSlot, onStartEdit: (String) -> Unit) {
    val env = LocalAppEnvironment.current
    when (slot.status) {
        SlotStatus.TAKEN ->
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(BadanRadius.chip))
                    .clickable { onStartEdit(slot.id) },
            ) {
                StatusChip(status = ChipStatus.InBand, label = env.s(Loc.taken))
            }

        SlotStatus.SKIPPED ->
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(BadanRadius.chip))
                    .clickable { onStartEdit(slot.id) },
            ) {
                SkippedPill(reason = slot.skipReason)
            }

        SlotStatus.PENDING ->
            if (slot.isOverdue) {
                PillLabel(text = env.s(Loc.stillDue), icon = Icons.Filled.Schedule)
            }
    }
}

@Composable
private fun SkippedPill(reason: SkipReason?) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val text = if (reason != null) {
        "${env.s(Loc.skipped)} · ${env.s(reason.displayLabel)}"
    } else {
        env.s(Loc.skipped)
    }
    PillLabel(text = text, icon = Icons.AutoMirrored.Filled.Redo, tint = colors.textSecondary)
}

@Composable
private fun ActionRow(slot: DueSlot, onTake: (DueSlot) -> Unit, onStartSkip: (String) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val onPrimary = colors.onPrimary
    // Capped and centered so the pair doesn't stretch into oversized pills on large-screen
    // devices; on a typical phone the cap exceeds the available width, so nothing changes.
    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Row(
            modifier = Modifier.widthIn(max = 440.dp),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .background(colors.primary)
                    .clickable { onTake(slot) }
                    .heightIn(min = BadanSpace.touchMin),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = env.s(takeAction),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = onPrimary,
                )
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .background(colors.surfaceElevated)
                    .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.control))
                    .clickable { onStartSkip(slot.id) }
                    .heightIn(min = BadanSpace.touchMin),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = env.s(Loc.skip_),
                    style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun SkipReasonPicker(slot: DueSlot, onCancelSkip: () -> Unit, onSkip: (DueSlot, SkipReason) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(text = env.s(skipPrompt), style = BadanType.caption, color = colors.textSecondary)
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            SkipReason.entries.forEach { reason ->
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(BadanRadius.chip))
                        .background(colors.surfaceElevated)
                        .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.chip))
                        .clickable { onSkip(slot, reason) }
                        .heightIn(min = BadanSpace.touchMin)
                        .padding(horizontal = BadanSpace.s3),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(text = env.s(reason.displayLabel), style = BadanType.chip, color = colors.textPrimary)
                }
            }
        }
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(BadanRadius.chip))
                .clickable { onCancelSkip() }
                .heightIn(min = BadanSpace.touchMin),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(text = env.s(Loc.cancel), style = BadanType.bodyCompact, color = colors.textSecondary)
        }
    }
}

// MARK: - Regimens section

@Composable
private fun RegimensSection(data: MedData) {
    val env = LocalAppEnvironment.current
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(yourMedications))
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            data.regimens.forEach { regimen -> RegimenCard(regimen = regimen, data = data) }
        }
    }
}

@Composable
private fun RegimenCard(regimen: MedicationRegimen, data: MedData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
                verticalAlignment = Alignment.Top,
            ) {
                Box(
                    modifier = Modifier
                        .size(BadanSpace.touchMin)
                        .clip(RoundedCornerShape(BadanRadius.control))
                        .background(colors.primary.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = iconForKey("medication"),
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
                        text = regimen.name,
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        val strength = regimen.strength
                        if (!strength.isNullOrEmpty()) {
                            Text(text = strength, style = BadanType.caption, color = colors.textSecondary)
                        }
                        Text(
                            text = scheduleText(env, regimen.schedule),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            AdherenceStrip(regimenId = regimen.id, data = data)

            // Power altitude: name the technical schedule and where the record lives.
            if (env.depth.showsPowerDetail) {
                Text(
                    text = "${scheduleDetail(regimen.schedule)} · ${env.s(addedManually)}",
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun AdherenceStrip(regimenId: String, data: MedData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val dots = data.strips[regimenId] ?: List(7) { DotKind.NONE }
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
        Text(text = env.s(last7Days), style = BadanType.caption, color = colors.textSecondary)
        Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            dots.forEachIndexed { index, kind ->
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    AdherenceDot(kind)
                    if (env.depth.showsPowerDetail && index < data.weekdayLetters.size) {
                        Text(
                            text = data.weekdayLetters[index],
                            style = TextStyle(
                                fontSize = 10.sp,
                                fontWeight = if (index == data.todayIndex) FontWeight.Bold else FontWeight.Normal,
                            ),
                            color = if (index == data.todayIndex) colors.primary else colors.textSecondary,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AdherenceDot(kind: DotKind) {
    val colors = BadanTheme.colors
    val base = Modifier
        .size(11.dp)
        .clip(CircleShape)
    when (kind) {
        DotKind.TAKEN -> Box(base.background(colors.primary))
        DotKind.SKIPPED -> Box(base.border(1.5.dp, colors.textSecondary, CircleShape))
        DotKind.PENDING -> Box(base.background(colors.textSecondary.copy(alpha = 0.22f)))
        // Fully transparent so an unscheduled day recedes rather than competing with SKIPPED's
        // outline — the two states were hard to tell apart at 11dp, especially in dark mode.
        DotKind.NONE -> Box(base.background(Color.Transparent))
    }
}

// MARK: - Empty & footer

@Composable
private fun MedEmptyState(onAdd: () -> Unit) {
    val env = LocalAppEnvironment.current
    EmptyState(
        icon = iconForKey("medication"),
        title = env.s(emptyTitle),
        message = env.s(emptyBody),
    ) {
        FilledPrimaryButton(label = env.s(Loc.addMedication), onClick = onAdd)
    }
}

/** Scope-of-service disclaimer, given the same tinted-icon treatment as `ExportScreen`'s
 * `SensitiveNote` so it reads as a deliberate boundary statement rather than blending into
 * ordinary caption text. */
@Composable
private fun BoundaryFooter() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = BadanSpace.s2)
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.info.copy(alpha = 0.10f))
            .padding(BadanSpace.s3),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = Icons.Filled.Info,
            contentDescription = null,
            tint = colors.info,
            modifier = Modifier.size(18.dp),
        )
        Text(
            text = env.s(Loc.medsBoundary),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

// MARK: - Add medication sheet

/**
 * A calm "add medication" flow. Records name, optional strength and a schedule (as-needed or daily
 * times). No dosing guidance — BADAN records, it never prescribes. Mirror of the iOS
 * `AddMedicationSheet`.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun AddMedicationSheetContent(
    onCancel: () -> Unit,
    onSave: (String, String?, MedicationSchedule) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    var name by remember { mutableStateOf("") }
    var strength by remember { mutableStateOf("") }
    var mode by remember { mutableStateOf(AddMode.DAILY) }
    val times = remember { mutableStateListOf("09:00") }
    var showTimePicker by remember { mutableStateOf(false) }

    val canSave = name.trim().isNotEmpty() && (mode == AddMode.AS_NEEDED || times.isNotEmpty())

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
    ) {
        // Header: Cancel / title / Save.
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            TextButton(onClick = onCancel) {
                Text(text = env.s(Loc.cancel), style = BadanType.body, color = colors.textSecondary)
            }
            Text(
                text = env.s(Loc.addMedication),
                style = BadanType.sectionTitle,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            TextButton(
                onClick = {
                    val trimmedName = name.trim()
                    if (trimmedName.isNotEmpty()) {
                        val trimmedStrength = strength.trim()
                        val schedule: MedicationSchedule =
                            if (mode == AddMode.DAILY && times.isNotEmpty()) {
                                MedicationSchedule.Daily(times.sorted())
                            } else {
                                MedicationSchedule.AsNeeded
                            }
                        onSave(trimmedName, trimmedStrength.ifEmpty { null }, schedule)
                    }
                },
                enabled = canSave,
            ) {
                Text(
                    text = env.s(Loc.save),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = if (canSave) colors.primary else colors.textSecondary,
                )
            }
        }

        LabeledField(
            label = env.s(Loc.medicationName),
            value = name,
            placeholder = env.s(namePlaceholder),
            capitalizeWords = true,
            onValueChange = { name = it },
        )
        LabeledField(
            label = env.s(Loc.strength),
            value = strength,
            placeholder = env.s(strengthPlaceholder),
            capitalizeWords = false,
            onValueChange = { strength = it },
        )

        // Schedule editor.
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Text(text = env.s(Loc.schedule), style = BadanType.chip, color = colors.textSecondary)
            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                ModeButton(
                    label = env.s(dailyLabel),
                    selected = mode == AddMode.DAILY,
                    modifier = Modifier.weight(1f),
                ) { mode = AddMode.DAILY }
                ModeButton(
                    label = env.s(asNeededLabel),
                    selected = mode == AddMode.AS_NEEDED,
                    modifier = Modifier.weight(1f),
                ) { mode = AddMode.AS_NEEDED }
            }

            if (mode == AddMode.DAILY) {
                Text(text = env.s(timesLabel), style = BadanType.caption, color = colors.textSecondary)

                if (times.isNotEmpty()) {
                    val tz = remember { TimeZone.getDefault().id }
                    val clock = remember(env.language, tz) { clockFormatter(env.language, tz) }
                    val startOfToday = remember(tz) { DayAttribution.startOfDay(env.now(), tz) }
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        times.forEach { t ->
                            val display = clock.format(Date(slotDate(t, startOfToday, tz)))
                            TimeChip(display = display, onRemove = { times.remove(t) })
                        }
                    }
                } else {
                    // Explain the otherwise-silent disabled Save state rather than leaving the
                    // user to guess why a Daily schedule with no times won't let them proceed.
                    Text(
                        text = env.s(addTimeHint),
                        style = BadanType.caption,
                        color = colors.outOfBand,
                    )
                }

                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(BadanRadius.chip))
                        .clickable { showTimePicker = true }
                        .heightIn(min = BadanSpace.touchMin)
                        .padding(horizontal = BadanSpace.s2),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.AddCircle,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            text = env.s(addTime),
                            style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                            color = colors.primary,
                        )
                    }
                }
            }
        }
    }

    if (showTimePicker) {
        val (suggestedHour, suggestedMinute) = suggestedNextTime(times)
        val timeState = rememberTimePickerState(initialHour = suggestedHour, initialMinute = suggestedMinute)
        AlertDialog(
            onDismissRequest = { showTimePicker = false },
            confirmButton = {
                TextButton(onClick = {
                    val canonical = canonicalTime(timeState.hour, timeState.minute)
                    if (!times.contains(canonical)) {
                        times.add(canonical)
                        times.sort()
                    }
                    showTimePicker = false
                }) {
                    Text(text = env.s(Loc.add), color = colors.primary)
                }
            },
            dismissButton = {
                TextButton(onClick = { showTimePicker = false }) {
                    Text(text = env.s(Loc.cancel), color = colors.textSecondary)
                }
            },
            text = { TimePicker(state = timeState) },
            containerColor = colors.surface,
        )
    }
}

@Composable
private fun ModeButton(label: String, selected: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(if (selected) colors.primary.copy(alpha = 0.14f) else colors.surface)
            .border(
                width = if (selected) 1.5.dp else 1.dp,
                color = if (selected) colors.primary else colors.separator,
                shape = RoundedCornerShape(BadanRadius.control),
            )
            .clickable(onClick = onClick)
            .heightIn(min = BadanSpace.touchMin),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = FontWeight.Medium),
            color = if (selected) colors.primary else colors.textSecondary,
        )
    }
}

@Composable
private fun TimeChip(display: String, onRemove: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .clip(CircleShape)
            .background(colors.surfaceElevated, CircleShape)
            .border(1.dp, colors.separator, CircleShape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Text(text = display, style = BadanType.chip, color = colors.textPrimary)
        Box(
            modifier = Modifier
                .clip(CircleShape)
                .clickable { onRemove() },
        ) {
            Icon(
                imageVector = Icons.Filled.Cancel,
                contentDescription = env.s(Loc.delete),
                tint = colors.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun LabeledField(
    label: String,
    value: String,
    placeholder: String,
    capitalizeWords: Boolean,
    onValueChange: (String) -> Unit,
) {
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(text = label, style = BadanType.chip, color = colors.textSecondary)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(BadanRadius.control))
                .background(colors.surface)
                .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.control))
                .heightIn(min = 52.dp)
                .padding(horizontal = BadanSpace.s4),
            contentAlignment = Alignment.CenterStart,
        ) {
            if (value.isEmpty()) {
                // 0.6 stacked on top of the already-muted textSecondary failed WCAG AA contrast
                // (~2.6:1 light / ~3.3:1 dark, both below the 4.5:1 minimum for normal text);
                // 0.9 clears 4.5:1 in both themes while still reading as a placeholder.
                Text(
                    text = placeholder,
                    style = BadanType.body,
                    color = colors.textSecondary.copy(alpha = 0.9f),
                )
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = BadanType.body.copy(color = colors.textPrimary),
                singleLine = true,
                cursorBrush = SolidColor(colors.primary),
                keyboardOptions = KeyboardOptions(
                    capitalization = if (capitalizeWords) KeyboardCapitalization.Words else KeyboardCapitalization.None,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

@Composable
private fun FilledPrimaryButton(label: String, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    val onPrimary = colors.onPrimary
    Box(
        modifier = modifier
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.primary)
            .clickable(onClick = onClick)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s5),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
            color = onPrimary,
        )
    }
}

// MARK: - Data loading & mutations (non-composable)

/**
 * Build today's due list from active regimens' schedule slots minus today's adherence, plus a
 * 7-day dot strip per regimen — off the main thread. Mirror of the iOS
 * `MedicationLogViewModel.load`.
 */
private suspend fun loadMedData(env: AppEnvironment): LoadState<MedData> {
    val tz = TimeZone.getDefault().id
    return try {
        withContext(Dispatchers.IO) {
            val now = env.now()
            val startOfToday = DayAttribution.startOfDay(now, tz)
            val weekStart = DayAttribution.addingDays(-6, startOfToday, tz)

            val regimens = env.logging.regimens(activeOnly = true)
            val todaysAdherence = env.logging.adherence(startOfToday, now)
            val weekAdherence = env.logging.adherence(weekStart, now)

            val clock = clockFormatter(env.language, tz)

            // --- Today's due slots (expanded per active regimen) ---
            val slots = mutableListOf<DueSlot>()
            val isoToday = isoWeekday(now, tz)
            for (regimen in regimens) {
                val times = regimen.schedule.dueTimes(isoToday).sorted()
                if (times.isEmpty()) continue

                // Descriptors (canonical time, slot instant, minutes-of-day) and this regimen's
                // events for today (latest first).
                val descs = times.map { t -> Triple(t, slotDate(t, startOfToday, tz), minutesOfDay(t)) }
                val events = todaysAdherence
                    .filter { it.regimenId == regimen.id }
                    .sortedByDescending { it.occurredAt }

                // Assign each event to its nearest still-unclaimed slot (latest events claim first).
                val assigned = HashMap<Int, AdherenceEvent>()
                for (e in events) {
                    val emin = minutesOfDayOf(e.scheduledFor ?: e.occurredAt, tz)
                    var best: Int? = null
                    var bestDist = Int.MAX_VALUE
                    descs.forEachIndexed { i, s ->
                        if (!assigned.containsKey(i)) {
                            val dist = abs(s.third - emin)
                            if (dist < bestDist) {
                                bestDist = dist
                                best = i
                            }
                        }
                    }
                    best?.let { assigned[it] = e }
                }

                descs.forEachIndexed { i, s ->
                    val ev = assigned[i]
                    val status = when (ev?.kind) {
                        AdherenceKind.TAKEN, AdherenceKind.LATE -> SlotStatus.TAKEN
                        AdherenceKind.SKIPPED -> SlotStatus.SKIPPED
                        else -> SlotStatus.PENDING
                    }
                    slots.add(
                        DueSlot(
                            id = "${regimen.id}|${s.first}",
                            regimen = regimen,
                            time = s.first,
                            displayTime = clock.format(Date(s.second)),
                            scheduledFor = s.second,
                            minutesOfDay = s.third,
                            status = status,
                            skipReason = ev?.skipReason,
                            isOverdue = status == SlotStatus.PENDING && s.second < now,
                        ),
                    )
                }
            }
            slots.sortBy { it.minutesOfDay }

            // --- 7-day adherence strip per regimen ---
            val counts = HashMap<String, HashMap<String, IntArray>>()   // regimenId -> dayKey -> [taken, skipped]
            for (e in weekAdherence) {
                val key = DayAttribution.localDayKey(e.scheduledFor ?: e.occurredAt, tz)
                val byDay = counts.getOrPut(e.regimenId) { HashMap() }
                val cell = byDay.getOrPut(key) { intArrayOf(0, 0) }
                when (e.kind) {
                    AdherenceKind.TAKEN, AdherenceKind.LATE -> cell[0]++
                    AdherenceKind.SKIPPED -> cell[1]++
                }
            }

            val days = (0 until 7).map { DayAttribution.addingDays(-(6 - it), startOfToday, tz) }
            val letterFormatter = narrowWeekdayFormatter(env.language, tz)
            val weekdayLetters = days.map { letterFormatter.format(Date(it)) }

            val strips = HashMap<String, List<DotKind>>()
            for (regimen in regimens) {
                strips[regimen.id] = days.map { day ->
                    val key = DayAttribution.localDayKey(day, tz)
                    val scheduled = regimen.schedule.dueTimes(isoWeekday(day, tz)).size
                    val cell = counts[regimen.id]?.get(key)
                    val taken = cell?.get(0) ?: 0
                    val skipped = cell?.get(1) ?: 0
                    when {
                        taken > 0 -> DotKind.TAKEN
                        skipped > 0 -> DotKind.SKIPPED
                        scheduled > 0 -> DotKind.PENDING
                        else -> DotKind.NONE
                    }
                }
            }

            val hasPending = slots.any { it.status == SlotStatus.PENDING }
            LoadState.Loaded(
                MedData(
                    regimens = regimens,
                    dueSlots = slots,
                    strips = strips,
                    weekdayLetters = weekdayLetters,
                    todayIndex = 6,
                    hasPending = hasPending,
                    allResolved = slots.isNotEmpty() && !hasPending,
                ),
            )
        }
    } catch (t: Throwable) {
        LoadState.Error(t.toString())
    }
}

/**
 * Record a take/skip. A deterministic id per (regimen, day, slot) means changing your mind
 * replaces the row cleanly (INSERT OR REPLACE). Mirror of the iOS `record`.
 */
private fun recordAdherence(
    env: AppEnvironment,
    regimenId: String,
    scheduledFor: Long,
    time: String,
    kind: AdherenceKind,
    reason: SkipReason?,
) {
    val now = env.now()
    val tz = TimeZone.getDefault().id
    val dayKey = DayAttribution.localDayKey(scheduledFor, tz)
    val event = AdherenceEvent(
        id = "adh-$regimenId-$dayKey-$time",
        regimenId = regimenId,
        kind = kind,
        scheduledFor = scheduledFor,
        occurredAt = now,
        tzId = tz,
        skipReason = reason,
        updatedAt = now,
        originDeviceId = env.deviceId,
    )
    env.logging.insertAdherence(event)
}

private fun addRegimen(env: AppEnvironment, name: String, strength: String?, schedule: MedicationSchedule) {
    val now = env.now()
    val regimen = MedicationRegimen(
        id = Ulid.newId(),
        name = name,
        strength = strength,
        schedule = schedule,
        startedAt = now,
        updatedAt = now,
        originDeviceId = env.deviceId,
    )
    env.logging.upsertRegimen(regimen)
}

// MARK: - Schedule text

private fun scheduleText(env: AppEnvironment, schedule: MedicationSchedule): String = when (schedule) {
    is MedicationSchedule.AsNeeded -> env.s(asNeededLabel)
    is MedicationSchedule.Daily -> "${env.s(dailyLabel)} · ${schedule.times.sorted().joinToString(", ")}"
    is MedicationSchedule.Weekly -> "${env.s(weeklyLabel)} · ${schedule.times.sorted().joinToString(", ")}"
}

private fun scheduleDetail(schedule: MedicationSchedule): String = when (schedule) {
    is MedicationSchedule.AsNeeded -> "asNeeded"
    is MedicationSchedule.Daily -> "daily(${schedule.times.sorted().joinToString(",")})"
    is MedicationSchedule.Weekly ->
        "weekly(${schedule.days.joinToString(",")}; ${schedule.times.sorted().joinToString(",")})"
}

// MARK: - Calendar & time helpers

/** ISO weekday (1 = Monday ... 7 = Sunday) from a `Calendar`'s 1 = Sunday component. */
private fun isoWeekday(millis: Long, tz: String): Int {
    val c = GregorianCalendar(TimeZone.getTimeZone(tz))
    c.timeInMillis = millis
    val w = c.get(Calendar.DAY_OF_WEEK)
    return ((w + 5) % 7) + 1
}

private fun minutesOfDay(time: String): Int {
    val parts = time.split(":").mapNotNull { it.trim().toIntOrNull() }
    val h = parts.getOrNull(0) ?: 0
    val m = parts.getOrNull(1) ?: 0
    return h * 60 + m
}

private fun minutesOfDayOf(millis: Long, tz: String): Int {
    val c = GregorianCalendar(TimeZone.getTimeZone(tz))
    c.timeInMillis = millis
    return c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)
}

private fun slotDate(time: String, dayStartMillis: Long, tz: String): Long {
    val parts = time.split(":").mapNotNull { it.trim().toIntOrNull() }
    val h = parts.getOrNull(0) ?: 0
    val m = parts.getOrNull(1) ?: 0
    val c = GregorianCalendar(TimeZone.getTimeZone(tz))
    c.timeInMillis = dayStartMillis
    c.set(Calendar.HOUR_OF_DAY, h)
    c.set(Calendar.MINUTE, m)
    c.set(Calendar.SECOND, 0)
    c.set(Calendar.MILLISECOND, 0)
    return c.timeInMillis
}

/** A stable "HH:mm" in 24h form regardless of display locale. */
private fun canonicalTime(hour: Int, minute: Int): String =
    String.format(Locale.US, "%02d:%02d", hour, minute)

/**
 * A sensible default for the "add a time" picker: the current time-of-day if no times have been
 * added yet, otherwise the latest added time plus a typical dosing interval (wrapping past
 * midnight) — so adding a 2nd or 3rd daily dose doesn't always land back on a fixed hour.
 */
private fun suggestedNextTime(times: List<String>): Pair<Int, Int> {
    if (times.isEmpty()) {
        val c = Calendar.getInstance()
        return c.get(Calendar.HOUR_OF_DAY) to c.get(Calendar.MINUTE)
    }
    val typicalIntervalMinutes = 4 * 60
    val last = times.sorted().last()
    val totalMinutes = (minutesOfDay(last) + typicalIntervalMinutes) % (24 * 60)
    return (totalMinutes / 60) to (totalMinutes % 60)
}

private fun clockFormatter(language: AppLanguage, tz: String): SimpleDateFormat {
    val locale = Locale.forLanguageTag(language.localeTag)
    val pattern = android.text.format.DateFormat.getBestDateTimePattern(locale, "jm")
    return SimpleDateFormat(pattern, locale).apply { timeZone = TimeZone.getTimeZone(tz) }
}

private fun narrowWeekdayFormatter(language: AppLanguage, tz: String): SimpleDateFormat {
    val locale = Locale.forLanguageTag(language.localeTag)
    return SimpleDateFormat("EEEEE", locale).apply { timeZone = TimeZone.getTimeZone(tz) }
}
