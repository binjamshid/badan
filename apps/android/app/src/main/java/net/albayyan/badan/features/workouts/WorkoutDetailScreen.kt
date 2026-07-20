package net.albayyan.badan.features.workouts

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.DirectionsBike
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.automirrored.filled.DirectionsWalk
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LayersClear
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Pool
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material.icons.filled.Terrain
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
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
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.ChartStyle
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.MetricChart
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.ProvenanceRow
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatBox
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.ReconciliationDecision
import net.albayyan.badan.domain.RoutePoint
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.WorkoutDetail
import net.albayyan.badan.domain.WorkoutRoute
import java.text.DateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale
import kotlin.math.cos
import kotlin.math.min

/**
 * One ingested workout, end to end (EPIC-03; the Compose mirror of iOS's `WorkoutDetailScreen`).
 *
 * Behavioural parity with iOS, not pixel parity: same data, same honesty rules, same altitudes,
 * laid out as Material/Compose rather than as a transliterated SwiftUI stack.
 *
 * Four sections, in the order a person actually asks about a workout: what it was (summary), what
 * my heart did (HR curve + time in intensity bands), where I went (route, only if consented), and
 * where this record came from (provenance + dedup lineage).
 *
 * Loading discipline: everything except the route's *points* is read in one IO pass. Route points
 * are the exception and are loaded only when the preview is expanded — a 10k-point trace is the
 * largest thing this screen can pull, it is location data, and a user who opened a workout to check
 * its duration should not have had their coordinates read off disk to satisfy that.
 */

// MARK: - Strings

private object WorkoutDetailStrings {
    val title = LocalizedString(en = "Workout", ar = "تمرين")
    val heartRate = LocalizedString(en = "Heart rate", ar = "معدل ضربات القلب")
    val intensity = LocalizedString(en = "Time in intensity bands", ar = "الوقت في نطاقات الشدة")
    val route = LocalizedString(en = "Route", ar = "المسار")
    val lineage = LocalizedString(en = "Where this came from", ar = "مصدر هذه البيانات")

    val duration = LocalizedString(en = "Duration", ar = "المدة")
    val energy = LocalizedString(en = "Energy", ar = "الطاقة")
    val distance = LocalizedString(en = "Distance", ar = "المسافة")
    val avgHr = LocalizedString(en = "Average heart rate", ar = "متوسط معدل القلب")
    val maxHr = LocalizedString(en = "Highest heart rate", ar = "أعلى معدل قلب")
    val elevation = LocalizedString(en = "Elevation gain", ar = "الارتفاع المكتسب")
    val metres = LocalizedString(en = "m", ar = "م")

    val notFound = LocalizedString(
        en = "This workout is no longer on this device.",
        ar = "لم يعد هذا التمرين موجوداً على هذا الجهاز.",
    )
    val loadFailed = LocalizedString(
        en = "Couldn't open this workout right now. Try again in a moment.",
        ar = "تعذّر فتح هذا التمرين الآن. حاول مرة أخرى بعد قليل.",
    )

    val noHeartRate = LocalizedString(
        en = "No heart-rate readings were recorded during this workout.",
        ar = "لم تُسجَّل قراءات لمعدل القلب أثناء هذا التمرين.",
    )
    val hrLinked = LocalizedString(
        en = "These are your own heart-rate readings from this time window — not a second copy stored with the workout.",
        ar = "هذه قراءاتك لمعدل القلب في هذه الفترة — وليست نسخة ثانية مخزّنة مع التمرين.",
    )

    val zonesNeedAge = LocalizedString(
        en = "Add your year of birth in Settings to see time spent in each intensity band.",
        ar = "أضِف سنة ميلادك في الإعدادات لعرض الوقت المستغرَق في كل نطاق شدة.",
    )
    val zonesMethod = LocalizedString(
        en = "Bands are a share of an age-based estimate (208 − 0.7 × age). It's a rough guide, not a fitness test.",
        ar = "النطاقات نسبة من تقدير قائم على العمر (٢٠٨ − ٠٫٧ × العمر). إنه دليل تقريبي وليس اختبار لياقة.",
    )

    val routeOff = LocalizedString(
        en = "Route reading is off, so BADAN didn't copy the path for this workout.",
        ar = "قراءة المسار متوقفة، لذا لم ينسخ بدن مسار هذا التمرين.",
    )
    val routeOffAction = LocalizedString(en = "About workout routes", ar = "عن مسارات التمارين")
    val routeNone = LocalizedString(
        en = "No route was recorded for this workout, or Health Connect hasn't released it.",
        ar = "لم يُسجَّل مسار لهذا التمرين، أو لم يُتِحه هيلث كونكت.",
    )
    val routeShow = LocalizedString(en = "Show route", ar = "عرض المسار")
    val routeHide = LocalizedString(en = "Hide route", ar = "إخفاء المسار")
    fun routePoints(n: Int) = LocalizedString(en = "$n points", ar = "$n نقطة")
    val routeOffline = LocalizedString(
        en = "Drawn from the points on your device. No map is downloaded.",
        ar = "مرسوم من النقاط الموجودة على جهازك. لا يُنزَّل أي مخطط.",
    )
    fun routeDescription(points: Int) = LocalizedString(
        en = "Route outline drawn from $points recorded points.",
        ar = "رسم تخطيطي للمسار من $points نقطة مسجّلة.",
    )

    val setAsideTitle = LocalizedString(en = "Set aside as a duplicate", ar = "وُضع جانباً كنسخة مكرّرة")
    fun setAsideBody(rule: String, other: String) = LocalizedString(
        en = "BADAN kept the version from $other for this time window and set this one aside. " +
            "Nothing was deleted — rule $rule.",
        ar = "احتفظ بدن بنسخة $other لهذه الفترة ووضع هذه جانباً. لم يُحذف شيء — القاعدة $rule.",
    )
    fun keptOver(count: Int) = LocalizedString(
        en = "Kept over $count other recording(s) of the same session.",
        ar = "احتُفظ بها بدل $count تسجيل آخر للجلسة نفسها.",
    )
    val overlapLabel = LocalizedString(en = "Overlap", ar = "التداخل")
    val restore = LocalizedString(en = "Bring this back into the list", ar = "أعِد هذه إلى القائمة")
    val restoreCaveat = LocalizedString(
        en = "It reappears now. A later sync may set it aside again while the other source ranks " +
            "higher — change source priority in Data sources to make it stick.",
        ar = "ستظهر الآن. قد تضعها مزامنة لاحقة جانباً مجدداً ما دام المصدر الآخر أعلى ترتيباً — " +
            "غيّر أولوية المصادر من \"مصادر البيانات\" ليثبت الأمر.",
    )
    val restored = LocalizedString(en = "Brought back into the list.", ar = "أُعيدت إلى القائمة.")
}

// MARK: - Ingested activity vocabulary

/**
 * The shared exercise codes `HealthConnectAdapter.activityTypeCode` emits, given bilingual names
 * and glyphs.
 *
 * `internal` and top-level rather than private to this file because the unified workout list needs
 * the identical mapping — a run that reads "Running" in the list and "hc_type_56" on the detail is
 * the kind of split-brain labelling that a second private copy guarantees eventually.
 *
 * Unknown codes (including the deliberate `hc_type_<n>` fallback for exercise types with no
 * cross-platform counterpart) are shown verbatim rather than coerced to "Other": the adapter went
 * out of its way to preserve the number, and flattening it here would throw away the one clue a
 * user has about what their watch actually recorded.
 */
internal object IngestedActivity {
    private val names: Map<String, LocalizedString> = mapOf(
        "running" to LocalizedString(en = "Running", ar = "جري"),
        "running_indoor" to LocalizedString(en = "Treadmill run", ar = "جري على جهاز المشي"),
        "walking" to LocalizedString(en = "Walking", ar = "مشي"),
        "hiking" to LocalizedString(en = "Hiking", ar = "مشي في الطبيعة"),
        "cycling" to LocalizedString(en = "Cycling", ar = "دراجة"),
        "cycling_indoor" to LocalizedString(en = "Indoor cycling", ar = "دراجة ثابتة"),
        "swimming_pool" to LocalizedString(en = "Pool swim", ar = "سباحة في المسبح"),
        "swimming_open_water" to LocalizedString(en = "Open-water swim", ar = "سباحة في المياه المفتوحة"),
        "strength_training" to LocalizedString(en = "Strength training", ar = "تدريب قوة"),
        "weightlifting" to LocalizedString(en = "Weightlifting", ar = "رفع أثقال"),
        "calisthenics" to LocalizedString(en = "Calisthenics", ar = "تمارين الجسم"),
        "hiit" to LocalizedString(en = "Interval training", ar = "تدريب متقطّع"),
        "yoga" to LocalizedString(en = "Yoga", ar = "يوغا"),
        "pilates" to LocalizedString(en = "Pilates", ar = "بيلاتس"),
        "rowing" to LocalizedString(en = "Rowing", ar = "تجديف"),
        "rowing_indoor" to LocalizedString(en = "Indoor rowing", ar = "تجديف داخلي"),
        "elliptical" to LocalizedString(en = "Elliptical", ar = "جهاز إهليلجي"),
        "stair_climbing" to LocalizedString(en = "Stair climbing", ar = "صعود الدرج"),
        "dance" to LocalizedString(en = "Dancing", ar = "رقص"),
        "boxing" to LocalizedString(en = "Boxing", ar = "ملاكمة"),
        "gymnastics" to LocalizedString(en = "Gymnastics", ar = "جمباز"),
        "badminton" to LocalizedString(en = "Badminton", ar = "ريشة طائرة"),
        "baseball" to LocalizedString(en = "Baseball", ar = "بيسبول"),
        "basketball" to LocalizedString(en = "Basketball", ar = "كرة سلة"),
        "cricket" to LocalizedString(en = "Cricket", ar = "كريكيت"),
        "golf" to LocalizedString(en = "Golf", ar = "غولف"),
        "skiing" to LocalizedString(en = "Skiing", ar = "تزلّج"),
        "soccer" to LocalizedString(en = "Football", ar = "كرة قدم"),
        "tennis" to LocalizedString(en = "Tennis", ar = "تنس"),
        "volleyball" to LocalizedString(en = "Volleyball", ar = "كرة طائرة"),
        "other" to LocalizedString(en = "Workout", ar = "تمرين"),
    )

    fun label(code: String?): LocalizedString {
        if (code.isNullOrBlank()) return WorkoutDetailStrings.title
        return names[code] ?: LocalizedString(en = code, ar = code)
    }

    fun icon(code: String?): ImageVector = when (code) {
        "running", "running_indoor" -> Icons.AutoMirrored.Filled.DirectionsRun
        "walking" -> Icons.AutoMirrored.Filled.DirectionsWalk
        "hiking" -> Icons.Filled.Terrain
        "cycling", "cycling_indoor" -> Icons.AutoMirrored.Filled.DirectionsBike
        "swimming_pool", "swimming_open_water" -> Icons.Filled.Pool
        "strength_training", "weightlifting", "calisthenics", "hiit" -> Icons.Filled.FitnessCenter
        "yoga", "pilates" -> Icons.Filled.SelfImprovement
        else -> Icons.Filled.FitnessCenter
    }
}

// MARK: - Intensity bands

/**
 * One intensity band and the time spent in it.
 *
 * "Band", never "zone-4 threshold work": these are a share of an age-based maximum, which is a
 * population estimate with a standard deviation around ±10 bpm. Naming them after training
 * prescriptions would dress that estimate up as a measurement, which plan §4 rule 9 forbids
 * ("directional bands, not false-precision absolutes").
 */
private data class IntensityBand(
    val label: LocalizedString,
    val lowPct: Int,
    val highPct: Int,
    val seconds: Double,
)

private val bandLabels = listOf(
    LocalizedString(en = "Very light", ar = "خفيف جداً"),
    LocalizedString(en = "Light", ar = "خفيف"),
    LocalizedString(en = "Moderate", ar = "متوسط"),
    LocalizedString(en = "Hard", ar = "شديد"),
    LocalizedString(en = "Very hard", ar = "شديد جداً"),
)

/**
 * The longest gap between two heart-rate samples that is still treated as continuous.
 *
 * Time in a band is attributed by holding each sample's value until the next one arrives, which is
 * the only thing point samples support. Without a cap, a watch that stops reporting for twenty
 * minutes mid-ride would credit every one of those minutes to whatever band the last reading
 * happened to fall in — a fabricated twenty minutes of "very hard" produced entirely by a sensor
 * dropout. Beyond the cap the gap is simply not counted, so the bands under-report rather than
 * invent.
 */
private const val MAX_HR_SAMPLE_GAP_SECONDS = 120.0

/**
 * Age-predicted maximum heart rate, Tanaka et al. (2001): 208 − 0.7 × age.
 *
 * Chosen over the folk "220 − age" deliberately. Both are estimates, but 220 − age systematically
 * over-predicts for younger adults and under-predicts past about 40, which would shift every band
 * boundary in the same direction for a whole cohort of users. Tanaka is the better-validated of
 * the two and is the formula named in the copy, so what is shown and what is computed match.
 */
private fun estimatedMaxHr(age: Int): Double = 208.0 - 0.7 * age

private fun computeBands(series: List<Pair<Long, Double>>, maxHr: Double): List<IntensityBand> {
    val seconds = DoubleArray(5)
    for (i in 0 until series.size - 1) {
        val gap = (series[i + 1].first - series[i].first) / 1000.0
        if (gap <= 0.0 || gap > MAX_HR_SAMPLE_GAP_SECONDS) continue
        val pct = series[i].second / maxHr * 100.0
        // Below 50 % clamps into the first band and above 100 % into the last: a reading outside
        // the modelled range is still a real reading, and dropping it would make the band totals
        // silently disagree with the workout's own duration.
        val index = when {
            pct < 60.0 -> 0
            pct < 70.0 -> 1
            pct < 80.0 -> 2
            pct < 90.0 -> 3
            else -> 4
        }
        seconds[index] += gap
    }
    return bandLabels.mapIndexed { index, label ->
        IntensityBand(
            label = label,
            lowPct = 50 + index * 10,
            highPct = 60 + index * 10,
            seconds = seconds[index],
        )
    }
}

// MARK: - Loaded data

private data class MergedSibling(val sessionId: String, val sourceName: String)

private data class WorkoutDetailData(
    val session: Session,
    val workout: WorkoutDetail?,
    val sourceName: String,
    /** Ascending (epoch-millis, bpm). Empty when the workout carried no heart-rate readings. */
    val hrSeries: List<Pair<Long, Double>>,
    val bands: List<IntensityBand>,
    val hasAge: Boolean,
    val routeConsentOn: Boolean,
    val route: WorkoutRoute?,
    /** Set when *this* session lost a dedup decision. */
    val suppressedBy: ReconciliationDecision?,
    val suppressedByWinnerName: String?,
    /** Set when this session won: the recordings it was kept over. */
    val mergedFrom: List<MergedSibling>,
)

private fun loadWorkoutDetail(env: AppEnvironment, sessionId: String): LoadState<WorkoutDetailData> = try {
    val session = env.measurements.session(sessionId)
    if (session == null || session.kind != SessionKind.WORKOUT || session.deletedAt != null) {
        LoadState.Empty(env.s(WorkoutDetailStrings.notFound))
    } else {
        val sourceNames = env.catalog.sources().associate { it.id to it.displayName }
        val hrSeries = env.measurements
            .rawSamples(MetricId.heartRate, session.startAt, session.endAt)
            .map { it.startAt to it.value }

        val age = env.catalog.userProfile()?.birthYear?.let { year ->
            Calendar.getInstance().apply { timeInMillis = env.now() }.get(Calendar.YEAR) - year
        }?.takeIf { it in 5..120 }
        val bands = if (age != null && hrSeries.size >= 2) {
            computeBands(hrSeries, estimatedMaxHr(age))
        } else {
            emptyList()
        }

        val consent = env.isRouteCaptureEnabled
        // Route *metadata* only. `points()` is not called here — see the class doc.
        val route = if (consent) {
            runCatching { env.routes.routes(session.id).firstOrNull() }.getOrNull()
        } else {
            null
        }

        val decision = session.provenance.suppressedBy?.let {
            runCatching { env.reconciliation.forSuppressed(session.id) }.getOrNull()
        }
        val winnerName = session.provenance.suppressedBy
            ?.let { env.measurements.session(it) }
            ?.let { sourceNames[it.provenance.sourceId] ?: it.provenance.sourceId }

        val merged = session.detail.mergedFrom.mapNotNull { id ->
            val sibling = env.measurements.session(id) ?: return@mapNotNull null
            MergedSibling(id, sourceNames[sibling.provenance.sourceId] ?: sibling.provenance.sourceId)
        }

        LoadState.Loaded(
            WorkoutDetailData(
                session = session,
                workout = session.detail.workout,
                sourceName = sourceNames[session.provenance.sourceId] ?: session.provenance.sourceId,
                hrSeries = hrSeries,
                bands = bands,
                hasAge = age != null,
                routeConsentOn = consent,
                route = route,
                suppressedBy = decision,
                suppressedByWinnerName = winnerName,
                mergedFrom = merged,
            ),
        )
    }
} catch (t: Throwable) {
    // Wellness-safe by default; raw exception text stays power-only, matching SourcesScreen.
    LoadState.Error(if (env.depth.showsPowerDetail) t.toString() else env.s(WorkoutDetailStrings.loadFailed))
}

// MARK: - Screen

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkoutDetailScreen(sessionId: String) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var state by remember(sessionId) { mutableStateOf<LoadState<WorkoutDetailData>>(LoadState.Loading) }
    var restoredNotice by remember(sessionId) { mutableStateOf(false) }

    suspend fun reload() {
        state = withContext(Dispatchers.IO) { loadWorkoutDetail(env, sessionId) }
    }
    LaunchedEffect(sessionId) { reload() }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            val loaded = (state as? LoadState.Loaded)?.value
            TopAppBar(
                title = {
                    Text(
                        text = env.s(IngestedActivity.label(loaded?.workout?.activityType)),
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
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            StatefulContainer(state) { data ->
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState())
                        .padding(BadanSpace.s4),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
                ) {
                    // The suppression notice leads, because if this record has been set aside that
                    // is the first thing that explains why the numbers below might not match what
                    // another app shows.
                    if (data.suppressedBy != null || data.session.provenance.isSuppressed) {
                        SetAsideCard(
                            decision = data.suppressedBy,
                            winnerName = data.suppressedByWinnerName,
                            restored = restoredNotice,
                            onRestore = {
                                scope.launch {
                                    withContext(Dispatchers.IO) {
                                        runCatching {
                                            val now = env.now()
                                            env.measurements.setSuppressed("sessions", data.session.id, null, now)
                                            data.suppressedBy?.let { env.reconciliation.markReversed(it.id, now) }
                                        }
                                    }
                                    restoredNotice = true
                                    reload()
                                }
                            },
                        )
                    }

                    WorkoutSummaryCard(data)
                    HeartRateSection(data)
                    IntensitySection(data)
                    RouteSection(data)
                    LineageSection(data)
                }
            }
        }
    }
}

// MARK: - Summary

@Composable
private fun WorkoutSummaryCard(data: WorkoutDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val totals = data.workout?.totals

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = IngestedActivity.icon(data.workout?.activityType),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(28.dp),
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = env.s(IngestedActivity.label(data.workout?.activityType)),
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = formatDateTime(data.session.startAt, env.language.localeTag),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }

            StatBox(
                value = env.format.duration(data.session.durationSeconds, "h"),
                label = env.s(WorkoutDetailStrings.duration),
            )

            // Every total is nullable and a null is rendered as an absent row, never as a zero.
            // "0 kcal" is a claim the source never made; showing nothing is the truth.
            val rows = buildList {
                totals?.energyKj?.let {
                    add(env.s(WorkoutDetailStrings.energy) to env.format.full(MetricId.activeEnergy, it))
                }
                totals?.distanceM?.let {
                    add(env.s(WorkoutDetailStrings.distance) to env.format.full(MetricId.distance, it))
                }
                totals?.avgHrBpm?.let {
                    add(env.s(WorkoutDetailStrings.avgHr) to env.format.full(MetricId.heartRate, it))
                }
                totals?.maxHrBpm?.let {
                    add(env.s(WorkoutDetailStrings.maxHr) to env.format.full(MetricId.heartRate, it))
                }
                totals?.elevationGainM?.let {
                    add(
                        env.s(WorkoutDetailStrings.elevation) to
                            "${env.format.number(it, 0)} ${env.s(WorkoutDetailStrings.metres)}",
                    )
                }
            }
            if (rows.isNotEmpty()) {
                HorizontalDivider(color = colors.separator)
                rows.forEach { (label, value) -> DetailLine(label, value) }
            }
        }
    }
}

@Composable
private fun DetailLine(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = label,
            style = BadanType.bodyCompact,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = value,
            style = BadanType.monospaceDigits(BadanType.bodyCompact),
            color = colors.textPrimary,
        )
    }
}

// MARK: - Heart rate

@Composable
private fun HeartRateSection(data: WorkoutDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    SectionHeader(title = env.s(WorkoutDetailStrings.heartRate))
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            if (data.hrSeries.size < 2) {
                Text(
                    text = env.s(WorkoutDetailStrings.noHeartRate),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
            } else {
                MetricChart(
                    series = data.hrSeries,
                    style = ChartStyle.Line,
                    language = env.language,
                )
                if (env.depth.showsPowerDetail) {
                    // The linkage rule, stated where it can be doubted: the pipeline links HR to a
                    // workout by time window rather than copying samples into the session, so the
                    // curve is the raw series and there is exactly one copy of it in the database.
                    Text(
                        text = env.s(WorkoutDetailStrings.hrLinked),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

// MARK: - Intensity bands

@Composable
private fun IntensitySection(data: WorkoutDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    if (data.hrSeries.size < 2) return

    SectionHeader(title = env.s(WorkoutDetailStrings.intensity))
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            if (!data.hasAge || data.bands.isEmpty()) {
                // No fabricated default age. Without a birth year there is no defensible maximum,
                // and a band chart drawn against a guessed one is worse than no chart: it looks
                // like a measurement.
                Text(
                    text = env.s(WorkoutDetailStrings.zonesNeedAge),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
            } else {
                val longest = data.bands.maxOf { it.seconds }.coerceAtLeast(1.0)
                data.bands.forEach { band -> IntensityBar(band, longest) }
                Text(
                    text = env.s(WorkoutDetailStrings.zonesMethod),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun IntensityBar(band: IntensityBand, longestSeconds: Double) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val fraction = (band.seconds / longestSeconds).coerceIn(0.0, 1.0).toFloat()
    // One hue, graduated alpha. A red-to-green intensity ramp would read as good/bad, and BADAN's
    // colour rule is that status hue never moralizes — harder is not worse and not better.
    val alpha = 0.30f + 0.14f * band.lowPct.let { (it - 50) / 10 }.toFloat()

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Text(
                text = env.s(band.label),
                style = BadanType.caption,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(
                // The first and last bands are open-ended and are labelled that way. `computeBands`
                // clamps anything under 60 % into band 0 and anything at or over 90 % into band 4,
                // so printing "50–60%" against a bucket that also holds a 45 % reading would be a
                // range the numbers beside it contradict.
                text = when (band.lowPct) {
                    50 -> "< ${env.format.integer(60)}%"
                    90 -> "${env.format.integer(90)}%+"
                    else -> "${env.format.integer(band.lowPct)}–${env.format.integer(band.highPct)}%"
                },
                style = BadanType.monospaceDigits(BadanType.caption),
                color = colors.textSecondary,
            )
            Text(
                text = env.format.duration(band.seconds, "min"),
                style = BadanType.monospaceDigits(BadanType.caption),
                color = colors.textPrimary,
            )
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .background(colors.surfaceElevated, RoundedCornerShape(BadanRadius.chip)),
        ) {
            if (fraction > 0f) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(fraction)
                        .height(8.dp)
                        .background(colors.primary.copy(alpha = alpha), RoundedCornerShape(BadanRadius.chip)),
                )
            }
        }
    }
}

// MARK: - Route

@Composable
private fun RouteSection(data: WorkoutDetailData) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var expanded by remember(data.session.id) { mutableStateOf(false) }
    var points by remember(data.session.id) { mutableStateOf<List<RoutePoint>?>(null) }
    var loading by remember(data.session.id) { mutableStateOf(false) }

    SectionHeader(title = env.s(WorkoutDetailStrings.route))
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            when {
                !data.routeConsentOn -> {
                    Row(
                        verticalAlignment = Alignment.Top,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.LayersClear,
                            contentDescription = null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = env.s(WorkoutDetailStrings.routeOff),
                            style = BadanType.bodyCompact,
                            color = colors.textSecondary,
                        )
                    }
                    // The affordance points at the consent screen rather than flipping the toggle
                    // here. Location consent is granted where it is explained, never as a side
                    // effect of tapping something on a workout.
                    Box(
                        modifier = Modifier
                            .heightIn(min = BadanSpace.touchMin)
                            .clickable { nav.push(Route.RouteConsent) },
                        contentAlignment = Alignment.CenterStart,
                    ) {
                        Text(
                            text = env.s(WorkoutDetailStrings.routeOffAction),
                            style = BadanType.body,
                            color = colors.primary,
                        )
                    }
                }

                data.route == null -> Text(
                    text = env.s(WorkoutDetailStrings.routeNone),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )

                else -> {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Icon(
                            imageVector = Icons.Filled.Map,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(18.dp),
                        )
                        PillLabel(text = env.s(WorkoutDetailStrings.routePoints(data.route.pointCount)))
                        Box(modifier = Modifier.weight(1f))
                        Box(
                            modifier = Modifier
                                .heightIn(min = BadanSpace.touchMin)
                                .clickable {
                                    if (expanded) {
                                        // Collapsing drops the coordinates rather than caching
                                        // them: "hide the route" should mean the points are no
                                        // longer in memory, not that they are one recomposition
                                        // away from being drawn again.
                                        expanded = false
                                        points = null
                                    } else {
                                        expanded = true
                                        if (points == null && !loading) {
                                            loading = true
                                            scope.launch {
                                                val loaded = withContext(Dispatchers.IO) {
                                                    runCatching { env.routes.points(data.route.id) }
                                                        .getOrDefault(emptyList())
                                                }
                                                points = loaded
                                                loading = false
                                            }
                                        }
                                    }
                                },
                            contentAlignment = Alignment.CenterEnd,
                        ) {
                            Text(
                                text = env.s(
                                    if (expanded) WorkoutDetailStrings.routeHide else WorkoutDetailStrings.routeShow,
                                ),
                                style = BadanType.body,
                                color = colors.primary,
                            )
                        }
                    }

                    if (expanded) {
                        when {
                            loading -> Box(
                                modifier = Modifier.fillMaxWidth().padding(BadanSpace.s5),
                                contentAlignment = Alignment.Center,
                            ) {
                                CircularProgressIndicator(color = colors.primary)
                            }

                            !points.isNullOrEmpty() -> {
                                RoutePreview(points!!)
                                Text(
                                    text = env.s(WorkoutDetailStrings.routeOffline),
                                    style = BadanType.caption,
                                    color = colors.textSecondary,
                                )
                            }

                            else -> Text(
                                text = env.s(WorkoutDetailStrings.routeNone),
                                style = BadanType.bodyCompact,
                                color = colors.textSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

/**
 * The route preview, drawn with Compose Canvas.
 *
 * **Why not maps-compose.** The plan names maps-compose for this preview and it is the right call
 * for a full-screen map, but it is not a dependency of this module and adding one is a
 * `build.gradle.kts` change outside this change's scope. More to the point, the two properties the
 * plan actually asked for — *lazy* and *offline-tolerant* — are strictly better served here: a
 * Google Maps tile layer needs network on first render, an API key, and Play Services, and would
 * show a grey void on a phone in airplane mode, which is exactly the phone a user has just
 * finished a run with. A trace drawn from local points renders identically online and offline, and
 * sends the user's coordinates to nobody. When maps-compose does land, this stays as the offline
 * fallback rather than being deleted.
 *
 * **Projection.** Equirectangular with a cos(latitude) correction on longitude, scaled to fit.
 * Correct enough that a route looks like itself at preview size; deliberately not Web Mercator,
 * because without tiles to align to there is nothing Mercator would buy and its distortion is
 * worse at the latitudes BADAN's first users live at.
 */
@Composable
private fun RoutePreview(points: List<RoutePoint>) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val description = env.s(WorkoutDetailStrings.routeDescription(points.size))

    // Layout direction is pinned LTR for the same reason MetricChart pins it: Canvas coordinates
    // are absolute, and a mirrored geographic trace would be a different route, not a mirrored one.
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1.6f)
                .background(colors.surfaceElevated, RoundedCornerShape(BadanRadius.control))
                .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.control))
                // The description states the shape and the count and never the coordinates: a
                // screen reader announcing a start latitude out loud would defeat the entire point
                // of routes being consent-gated.
                .semantics { contentDescription = description },
        ) {
            Canvas(modifier = Modifier.fillMaxSize().padding(BadanSpace.s3)) {
                if (points.size < 2) return@Canvas

                val meanLatRad = Math.toRadians(points.sumOf { it.lat } / points.size)
                val xs = points.map { it.lon * cos(meanLatRad) }
                val ys = points.map { it.lat }
                val minX = xs.min()
                val maxX = xs.max()
                val minY = ys.min()
                val maxY = ys.max()
                val spanX = (maxX - minX).takeIf { it > 0.0 } ?: 1e-6
                val spanY = (maxY - minY).takeIf { it > 0.0 } ?: 1e-6

                // One scale for both axes so the trace keeps its true aspect ratio — stretching a
                // route to fill the box would turn an out-and-back into a loop.
                val scale = min(size.width / spanX, size.height / spanY)
                val offsetX = (size.width - spanX * scale) / 2.0
                val offsetY = (size.height - spanY * scale) / 2.0

                fun project(index: Int): Offset = Offset(
                    x = (offsetX + (xs[index] - minX) * scale).toFloat(),
                    // Latitude grows north, screen y grows down.
                    y = (offsetY + (maxY - ys[index]) * scale).toFloat(),
                )

                val path = Path()
                val first = project(0)
                path.moveTo(first.x, first.y)
                for (i in 1 until points.size) {
                    val p = project(i)
                    path.lineTo(p.x, p.y)
                }
                drawPath(
                    path = path,
                    color = colors.primary,
                    style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round),
                )
                drawCircle(color = colors.inBand, radius = 5.dp.toPx(), center = first)
                drawCircle(color = colors.info, radius = 5.dp.toPx(), center = project(points.size - 1))
            }
        }
    }
}

// MARK: - Lineage

@Composable
private fun SetAsideCard(
    decision: ReconciliationDecision?,
    winnerName: String?,
    restored: Boolean,
    onRestore: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.VisibilityOff,
                    contentDescription = null,
                    tint = colors.outOfBand,
                    modifier = Modifier.size(20.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                    Text(
                        text = env.s(WorkoutDetailStrings.setAsideTitle),
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = env.s(
                            WorkoutDetailStrings.setAsideBody(
                                rule = decision?.rule ?: "workout.session_overlap.v1",
                                other = winnerName ?: env.s(Loc.dataSources),
                            ),
                        ),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                    Text(
                        text = env.s(Loc.reversible),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }

            decision?.detail?.get("overlap_pct")?.let { overlap ->
                if (env.depth.showsPowerDetail) {
                    DetailLine(env.s(WorkoutDetailStrings.overlapLabel), "$overlap%")
                }
            }

            if (restored) {
                Text(
                    text = env.s(WorkoutDetailStrings.restored),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            } else {
                Box(
                    modifier = Modifier
                        .heightIn(min = BadanSpace.touchMin)
                        .clickable(onClick = onRestore),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.Undo,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(18.dp),
                        )
                        Text(
                            text = env.s(WorkoutDetailStrings.restore),
                            style = BadanType.body,
                            color = colors.primary,
                        )
                    }
                }
                // Said before the tap, not after. The reversal is real and journalled, but the next
                // sync re-runs `workout.session_overlap.v1` against the same source priorities and
                // will reach the same conclusion — so promising permanence here would be a lie the
                // user discovers an hour later. Naming the durable lever (priority) in the same
                // breath is what turns this from a caveat into an instruction.
                Text(
                    text = env.s(WorkoutDetailStrings.restoreCaveat),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun LineageSection(data: WorkoutDetailData) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    SectionHeader(title = env.s(WorkoutDetailStrings.lineage))
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            ProvenanceRow(
                sourceName = data.sourceName,
                ingestionPath = data.session.provenance.ingestionPath,
                timestampMillis = data.session.provenance.ingestedAt,
                language = env.language,
            )

            if (data.mergedFrom.isNotEmpty()) {
                HorizontalDivider(color = colors.separator)
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Info,
                        contentDescription = null,
                        tint = colors.info,
                        modifier = Modifier.size(18.dp),
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                        Text(
                            text = env.s(WorkoutDetailStrings.keptOver(data.mergedFrom.size)),
                            style = BadanType.bodyCompact,
                            color = colors.textPrimary,
                        )
                        data.mergedFrom.forEach { sibling ->
                            Text(
                                text = sibling.sourceName,
                                style = BadanType.caption,
                                color = colors.textSecondary,
                            )
                        }
                        Text(
                            text = env.s(Loc.reversible),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            if (env.depth.showsPowerDetail) {
                HorizontalDivider(color = colors.separator)
                val p = data.session.provenance
                DetailLine("source_id", p.sourceId)
                p.externalId?.let { DetailLine("external_id", it) }
                p.deviceId?.let { DetailLine("device", it) }
                DetailLine("measured_tz", p.measuredTimezone)
                if (p.qualityFlags.isNotEmpty()) {
                    DetailLine("quality_flags", p.qualityFlags.joinToString(", ") { it.code })
                }
            }
        }
    }
}

// MARK: - Helpers

private fun formatDateTime(millis: Long, localeTag: String): String {
    val locale = Locale.forLanguageTag(localeTag)
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date(millis))
}
