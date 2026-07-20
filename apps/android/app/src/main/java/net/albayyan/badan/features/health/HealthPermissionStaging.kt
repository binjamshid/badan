package net.albayyan.badan.features.health

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Scale
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.domain.PermissionState
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.platform.health.HcTypeMap
import net.albayyan.badan.platform.health.HealthConnectAdapter

/**
 * The staged Health Connect consent flow and the 30-day history disclosure, shared by onboarding
 * and the Sources screen (EPIC-02, plan §14/§16).
 *
 * Why this is one file rather than two copies: onboarding and Sources ask the *same* question in
 * two places, and the failure mode of duplicating it is not code size — it is the two copies
 * drifting until the app requests a different permission set depending on which screen the user
 * happened to tap. The permission set, the family order, the rationale copy and the per-family
 * `permission_states` rows are stated once here so that cannot happen.
 *
 * Two deliberate absences, both about location:
 *  * No family here maps to routes. Health Connect (connect-client 1.1.0) has no bulk
 *    route-read permission — a session's `exerciseRouteResult` is `ConsentRequired` until the user
 *    approves that specific route — so there is nothing to request in a bundle even if it were
 *    appropriate. BADAN's own route toggle lives on `RouteConsentScreen` and nowhere else, which
 *    is what keeps "did I ever agree to GPS?" answerable by pointing at one screen (plan §4
 *    rule 11).
 *  * Nothing here requests `READ_HEALTH_DATA_HISTORY`. That is why [BackfillHonestyCard] exists
 *    and says 30 days rather than apologising for a number it could have raised.
 */

// MARK: - Family presentation

/**
 * The order families are asked for, and it is not arbitrary: activity and sleep first because they
 * are what a user expects a health app to want and what makes the Home screen non-empty, then
 * vitals, then body, then workouts. A user who abandons the flow half-way therefore abandons it
 * holding the grants that make BADAN useful rather than the ones that make it complete.
 *
 * [HcTypeMap.Family] entry order is the *table*'s order (grouped for readability of the type map),
 * which is a different concern; deriving the ask order from it would couple a user-facing sequence
 * to the shape of a lookup table.
 */
val stagedPermissionFamilies: List<HcTypeMap.Family> = listOf(
    HcTypeMap.Family.ACTIVITY,
    HcTypeMap.Family.SLEEP,
    HcTypeMap.Family.VITALS,
    HcTypeMap.Family.BODY,
    HcTypeMap.Family.WORKOUT,
)

fun familyTitle(family: HcTypeMap.Family): LocalizedString = when (family) {
    HcTypeMap.Family.ACTIVITY -> LocalizedString(en = "Movement", ar = "الحركة")
    HcTypeMap.Family.SLEEP -> LocalizedString(en = "Sleep", ar = "النوم")
    HcTypeMap.Family.VITALS -> LocalizedString(en = "Vitals", ar = "المؤشرات الحيوية")
    HcTypeMap.Family.BODY -> LocalizedString(en = "Body measurements", ar = "قياسات الجسم")
    HcTypeMap.Family.WORKOUT -> LocalizedString(en = "Workouts", ar = "التمارين")
}

/**
 * What each bundle is for, in the user's terms.
 *
 * Written as "so that <thing you will see>" rather than as a list of record types, because the
 * question a permission dialog actually raises is "what do I lose if I say no", and a type list
 * answers a different one. Wellness-safe: no clinical claim, no implication that declining is a
 * mistake.
 */
fun familyRationale(family: HcTypeMap.Family): LocalizedString = when (family) {
    HcTypeMap.Family.ACTIVITY -> LocalizedString(
        en = "Steps, distance, floors and active energy — so your day has a shape you can look back on.",
        ar = "الخطوات والمسافة والطوابق والطاقة النشطة — كي يكون ليومك شكل يمكنك مراجعته.",
    )
    HcTypeMap.Family.SLEEP -> LocalizedString(
        en = "Sleep sessions and their stages — so \"last night\" is something BADAN can show you rather than ask you.",
        ar = "جلسات النوم ومراحلها — كي يعرض لك بدن \"الليلة الماضية\" بدل أن يسألك عنها.",
    )
    HcTypeMap.Family.VITALS -> LocalizedString(
        en = "Heart rate, resting heart rate, heart-rate variability, breathing rate, blood oxygen and skin-temperature change.",
        ar = "معدل ضربات القلب ومعدله أثناء الراحة وتغيّره، ومعدل التنفّس، وأكسجين الدم، وتغيّر حرارة الجلد.",
    )
    HcTypeMap.Family.BODY -> LocalizedString(
        en = "Weight, body fat, lean mass and VO₂ max — read from whichever app or scale records them.",
        ar = "الوزن ونسبة الدهون والكتلة الصافية وأقصى استهلاك للأكسجين — تُقرأ من التطبيق أو الميزان الذي يسجّلها.",
    )
    HcTypeMap.Family.WORKOUT -> LocalizedString(
        en = "Recorded exercise sessions. Their GPS routes are a separate choice and stay off until you turn them on.",
        ar = "جلسات التمرين المسجّلة. مسارات GPS خيار منفصل وتبقى متوقفة حتى تشغّلها بنفسك.",
    )
}

fun familyIcon(family: HcTypeMap.Family): ImageVector = when (family) {
    HcTypeMap.Family.ACTIVITY -> Icons.AutoMirrored.Filled.DirectionsWalk
    HcTypeMap.Family.SLEEP -> Icons.Filled.Bedtime
    HcTypeMap.Family.VITALS -> Icons.Filled.MonitorHeart
    HcTypeMap.Family.BODY -> Icons.Filled.Scale
    HcTypeMap.Family.WORKOUT -> Icons.AutoMirrored.Filled.DirectionsRun
}

// MARK: - The staged request itself

/**
 * A one-bundle-at-a-time Health Connect request.
 *
 * Health Connect will happily accept all fifteen permissions in a single call, and that is exactly
 * what BADAN used to do from both entry points. The system sheet then presents an undifferentiated
 * wall of toggles with no statement of purpose attached to any of them, and the realistic outcomes
 * are "allow everything without reading" or "deny everything" — neither of which is consent in any
 * sense worth the word. Asking per family means each system sheet is preceded by one sentence
 * saying what that bundle is for, and a denial costs the user one family instead of the app.
 *
 * State lives here rather than in each screen so both call sites get the same re-entrancy
 * behaviour: [start] on an in-flight request is ignored rather than interleaving two queues
 * against one launcher.
 *
 * Known limitation, stated rather than papered over: the queue is `remember`ed, not saved. If the
 * process is killed while a system permission sheet is in front, the restored composable has an
 * empty queue and the delivered result is dropped, so the remaining families are never asked for
 * and that run writes no `permission_states` rows. The user's recovery is to tap Connect again,
 * and nothing is lost or misrecorded in the meantime — the rows BADAN writes always describe
 * grants the system actually reported. Making it survivable means moving the queue into saved
 * instance state and re-attaching the in-flight family, which is worth doing if the flow ever
 * grows past five sheets.
 */
class StagedPermissionRequest internal constructor() {
    /** Families still to be asked for; the head is the one currently on screen. */
    var queue by mutableStateOf<List<HcTypeMap.Family>>(emptyList())
        private set

    /** Union of everything granted across the stages of the current run. */
    private var accumulated: MutableSet<String> = mutableSetOf()

    /** Per-family outcome for the current run, for the caller's summary UI. */
    var outcomes by mutableStateOf<Map<HcTypeMap.Family, PermissionStatus>>(emptyMap())
        private set

    val current: HcTypeMap.Family? get() = queue.firstOrNull()
    val isRunning: Boolean get() = queue.isNotEmpty()

    /** How far through the run we are, for a "2 of 5"-style progress line. */
    var totalStages by mutableStateOf(0)
        private set

    val completedStages: Int get() = (totalStages - queue.size).coerceAtLeast(0)

    fun start(families: List<HcTypeMap.Family>) {
        if (isRunning || families.isEmpty()) return
        accumulated = mutableSetOf()
        outcomes = emptyMap()
        totalStages = families.size
        queue = families
    }

    internal fun recordAndAdvance(family: HcTypeMap.Family, granted: Set<String>) {
        val required = HcTypeMap.permissions(family)
        val status = when {
            required.isEmpty() -> PermissionStatus.NOT_REQUESTED
            granted.containsAll(required) -> PermissionStatus.GRANTED
            granted.any { it in required } -> PermissionStatus.PARTIAL
            else -> PermissionStatus.DENIED
        }
        accumulated.addAll(granted)
        outcomes = outcomes + (family to status)
        queue = queue.drop(1)
    }

    internal fun grantedSoFar(): Set<String> = accumulated.toSet()
}

/**
 * Wire a [StagedPermissionRequest] to a real Health Connect permission launcher.
 *
 * The launcher cannot be referenced from inside its own result callback, so the queue is advanced
 * in the callback and the *next* launch is driven by a [LaunchedEffect] keyed on the queue head.
 * That indirection is load-bearing, not stylistic: launching directly from the callback would run
 * inside the previous activity result's dispatch and Health Connect drops the second request.
 *
 * [onStageComplete] fires once per family with the persisted status, and [onComplete] once at the
 * end with every outcome — so a caller can update a row as it lands and still run a single
 * "now sync" step afterwards rather than one per bundle.
 */
@Composable
fun rememberStagedPermissionRequest(
    onStageComplete: (HcTypeMap.Family, PermissionStatus) -> Unit = { _, _ -> },
    onComplete: (Map<HcTypeMap.Family, PermissionStatus>) -> Unit = {},
): StagedPermissionRequest {
    val env = LocalAppEnvironment.current
    val scope = rememberCoroutineScope()
    val request = remember { StagedPermissionRequest() }

    // Captured before the callback runs: `request.current` has already advanced by the time the
    // completion branch below inspects it, so the family a result belongs to must be read at
    // launch time, not at result time.
    var inFlight by remember { mutableStateOf<HcTypeMap.Family?>(null) }

    val launcher = rememberLauncherForActivityResult(
        contract = HealthConnectAdapter.requestPermissionsContract(),
    ) { granted ->
        val family = inFlight ?: return@rememberLauncherForActivityResult
        inFlight = null
        request.recordAndAdvance(family, granted)
        val status = request.outcomes[family] ?: PermissionStatus.NOT_REQUESTED
        scope.launch {
            withContext(Dispatchers.IO) { persistFamilyStatus(env, family, status) }
            onStageComplete(family, status)
            if (!request.isRunning) {
                // Recorded against the full permission set, so the app-wide "connected" state and
                // the background schedule reflect the union of the stages rather than the last one.
                env.recordHealthConnectPermissions(request.grantedSoFar())
                onComplete(request.outcomes)
            }
        }
    }

    val head = request.current
    LaunchedEffect(head) {
        if (head != null && inFlight == null) {
            inFlight = head
            launcher.launch(HcTypeMap.permissions(head))
        }
    }

    return request
}

/**
 * Persist one family's outcome as its own `permission_states` row.
 *
 * Keyed by the family code rather than by each record type: the row exists to answer "which parts
 * of my health data has BADAN been allowed to read", and fifteen rows saying the same thing five
 * times over is a worse answer than five. `AppEnvironment.recordHealthConnectPermissions` still
 * writes its own aggregate `health` row; these sit beside it and are what the Sources screen
 * renders per family.
 */
private fun persistFamilyStatus(env: AppEnvironment, family: HcTypeMap.Family, status: PermissionStatus) {
    runCatching {
        env.catalog.upsertPermission(
            PermissionState(
                store = HealthConnectAdapter.anchorStore,
                platformType = family.code,
                status = status,
                lastCheckedAt = env.now(),
            ),
        )
    }
}

// MARK: - Family picker

/**
 * The opt-in list shown before the system sheets. Every family starts selected — the user is here
 * because they asked to connect — but each one is individually removable, which is the whole point
 * of staging: "everything except my weight" is a coherent thing to want and used to be
 * unexpressible.
 */
@Composable
fun FamilyBundlePicker(
    selected: Set<HcTypeMap.Family>,
    onToggle: (HcTypeMap.Family) -> Unit,
    modifier: Modifier = Modifier,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        stagedPermissionFamilies.forEach { family ->
            val isOn = family in selected
            val shape = RoundedCornerShape(BadanRadius.control)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(min = BadanSpace.touchMin)
                    .background(colors.surface, shape)
                    .border(
                        width = if (isOn) 1.5.dp else 1.dp,
                        color = if (isOn) colors.primary else colors.separator,
                        shape = shape,
                    )
                    .clickable(
                        role = Role.Checkbox,
                        onClickLabel = env.s(familyTitle(family)),
                    ) { onToggle(family) }
                    .padding(BadanSpace.s3),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = familyIcon(family),
                    contentDescription = null,
                    tint = if (isOn) colors.primary else colors.textSecondary,
                    modifier = Modifier.size(22.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Text(
                        text = env.s(familyTitle(family)),
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = env.s(familyRationale(family)),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
                Icon(
                    // Checkbox glyphs rather than a Switch: this is a multi-select list, and a row
                    // of switches reads as five independent settings that take effect now instead
                    // of five items in one request about to happen.
                    imageVector = if (isOn) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
                    contentDescription = null,
                    tint = if (isOn) colors.primary else colors.separator,
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

/** "Asking about sleep — 2 of 5", so a five-sheet sequence never feels like a malfunction. */
fun stageProgressLabel(family: HcTypeMap.Family, completed: Int, total: Int): LocalizedString {
    val title = familyTitle(family)
    return LocalizedString(
        en = "Asking about ${title.en.lowercase()} — ${completed + 1} of $total",
        ar = "طلب إذن ${title.ar} — ${completed + 1} من $total",
    )
}

// MARK: - 30-day history honesty (Phase-0 exit criterion)

private val backfillTitle = LocalizedString(
    en = "How far back BADAN can read",
    ar = "إلى أي مدى يستطيع بدن القراءة",
)

/**
 * The banner text. It states the limit as a fact about Health Connect and then says what BADAN
 * does about it — no apology, no "unfortunately", and no wording that could be read as data having
 * been lost. What is older is not gone; it is in the app that recorded it.
 */
private fun backfillBody(days: Int) = LocalizedString(
    en = "Health Connect shares the last $days days of history with other apps. BADAN reads all of " +
        "it, and keeps everything from then on. Anything older stays in the app that recorded it — " +
        "it hasn't been lost.",
    ar = "يشارك هيلث كونكت آخر $days يوماً من السجل مع التطبيقات الأخرى. يقرأ بدن هذه الفترة كاملة، " +
        "ويحتفظ بكل ما يأتي بعدها. أما ما هو أقدم فيبقى في التطبيق الذي سجّله — ولم يُفقد.",
)

private val backfillPerTypeHeader = LocalizedString(
    en = "Per data type, from the last sync",
    ar = "لكل نوع بيانات، من آخر مزامنة",
)

private val backfillIncremental = LocalizedString(en = "changes only", ar = "التغييرات فقط")
private val backfillFullWindow = LocalizedString(en = "full window", ar = "النافذة الكاملة")

private fun backfillDaysLabel(days: Int) = LocalizedString(en = "$days days", ar = "$days يوماً")

/**
 * The 30-day disclosure (plan §14, Phase-0 exit criterion; an Android-specific obligation with no
 * iOS counterpart — HealthKit serves whatever the store holds).
 *
 * Casual altitude gets the sentence. Power adds the per-type table from the *last actual sync*
 * (`HealthStorePort.backfillWindows`), which is why the two are not the same claim: the sentence is
 * what BADAN knows statically from `HcTypeMap.achievableWindowDays`, the table is what the last
 * read genuinely covered, including whether it was an incremental changes-token read or a full
 * re-read. Before any sync has run in this process the table is empty and only the sentence shows —
 * which is correct, not a gap: there is no honest per-type report to give yet.
 */
@Composable
fun BackfillHonestyCard(modifier: Modifier = Modifier) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val power = env.depth.showsPowerDetail

    // Cheap: reads an in-memory map on the adapter, no IPC and no Health Connect client creation
    // beyond the lazy the screen has already forced by rendering availability.
    val windows = remember(power) {
        if (!power) emptyList() else runCatching { env.healthConnect.backfillWindows() }.getOrDefault(emptyList())
    }

    BadanCard(modifier = modifier) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = Icons.Filled.History,
                contentDescription = null,
                tint = colors.info,
                modifier = Modifier.size(20.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                Text(
                    text = env.s(backfillTitle),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = env.s(backfillBody(HcTypeMap.defaultHistoryWindowDays)),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )

                if (windows.isNotEmpty()) {
                    Text(
                        text = env.s(backfillPerTypeHeader),
                        style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textSecondary,
                        modifier = Modifier.padding(top = BadanSpace.s1),
                    )
                    windows.forEach { window ->
                        val days = ((window.end - window.achievableStart) / MILLIS_PER_DAY).toInt()
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                        ) {
                            Text(
                                text = window.platformType,
                                style = BadanType.caption,
                                color = colors.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Text(
                                text = env.s(backfillDaysLabel(days)) + " · " +
                                    env.s(if (window.incremental) backfillIncremental else backfillFullWindow),
                                style = BadanType.monospaceDigits(BadanType.caption),
                                color = colors.textSecondary,
                            )
                        }
                    }
                } else if (power) {
                    // Power altitude with nothing to report is itself worth saying, so the absent
                    // table doesn't read as a rendering failure.
                    Text(
                        text = env.s(backfillNoSyncYet),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

private val backfillNoSyncYet = LocalizedString(
    en = "Per-type detail appears after the first sync in this session.",
    ar = "تظهر التفاصيل لكل نوع بعد أول مزامنة في هذه الجلسة.",
)

private const val MILLIS_PER_DAY = 24L * 60 * 60 * 1000

// MARK: - Box used by callers that need a bare bordered container

/** A quiet bordered container for inline notices that are not full cards. */
@Composable
fun InlineNotice(text: String, modifier: Modifier = Modifier, icon: ImageVector? = null) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(colors.info.copy(alpha = 0.10f), shape)
            .padding(BadanSpace.s3),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.info,
                modifier = Modifier.size(16.dp),
            )
        }
        Box(modifier = Modifier.weight(1f)) {
            Text(text = text, style = BadanType.caption, color = colors.textSecondary)
        }
    }
}
