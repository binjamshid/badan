package net.albayyan.badan.features.body

import android.util.Log
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanColors
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.MetricFamily
import net.albayyan.badan.domain.PermissionState
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceStatus
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.features.health.BackfillHonestyCard
import net.albayyan.badan.features.health.familyIcon
import net.albayyan.badan.features.health.familyRationale
import net.albayyan.badan.features.health.familyTitle
import net.albayyan.badan.features.health.rememberStagedPermissionRequest
import net.albayyan.badan.features.health.stagedPermissionFamilies
import net.albayyan.badan.ontology.SensorQualityLevel
import net.albayyan.badan.ontology.SensorQualityMap
import net.albayyan.badan.platform.health.HcTypeMap
import net.albayyan.badan.platform.health.HealthConnectAdapter
import java.text.DateFormat
import java.util.Date
import java.util.Locale

// MARK: - Model

/**
 * A source paired with the devices that have delivered through it.
 *
 * [sourceClassId] is resolved once at load time rather than per recomposition, mirroring how iOS's
 * `SourcesViewModel.fetch` resolves it off the main actor: the classification walks every device
 * name for every source, which is cheap but has no business running on every frame.
 */
private data class SourcesSourceInfo(
    val source: Source,
    val devices: List<Device>,
    val sourceClassId: String,
)

/**
 * One writer in the priority list.
 *
 * [packageName] is the identity the dedup engine actually keys on — `Source.platformBundleId` for
 * a Health Connect writer, which `HealthConnectAdapter.sourceDescriptors` sets to the writing app's
 * package. It is carried separately from the display name because two installed apps can present
 * near-identical labels ("Health", "Health Sync") and the package is the only thing that
 * distinguishes them; an editor keyed on display name would silently reorder the wrong app.
 */
private data class WriterInfo(
    val source: Source,
    val packageName: String,
    val effectivePriority: Int,
    val hasUserOverride: Boolean,
)

private data class SourcesData(
    val sources: List<SourcesSourceInfo>,
    val permissionStores: List<String>,                       // stable order
    val permissionsByStore: Map<String, List<PermissionState>>,
    /** Per-family Health Connect consent, every family present whether or not it was ever asked. */
    val familyStatus: Map<HcTypeMap.Family, PermissionStatus>,
    /** Health Connect writers, highest effective priority first. */
    val writers: List<WriterInfo>,
)

// MARK: - Loading (mirror of iOS SourcesViewModel)

/** Wellness-safe by default; raw exception text is reserved for power depth, mirroring
 *  `ExportScreen`'s altitude-gated error detail (never a stack-trace-style string for casual users). */
private val sourcesLoadFailed = LocalizedString(
    en = "Couldn't load your sources right now. Try again in a moment.",
    ar = "تعذّر تحميل مصادرك الآن. حاول مرة أخرى بعد قليل.",
)

private fun loadSources(env: AppEnvironment, quality: SensorQualityMap): LoadState<SourcesData> =
    try {
        val sources = env.catalog.sources()
        val infos = sources.map { source ->
            val devices = env.catalog.devices(source.id)
            SourcesSourceInfo(source, devices, quality.classId(source, devices))
        }
        val permissions = env.catalog.permissions()

        // Family rows are rendered by their own matrix below, so they are pulled out of the
        // generic per-store listing rather than appearing twice under two different labels.
        val familyCodes = HcTypeMap.Family.entries.map { it.code }.toSet()
        val generic = permissions.filterNot {
            it.store == HealthConnectAdapter.anchorStore && it.platformType in familyCodes
        }
        val grouped = generic.groupBy { it.store }
        val stores = grouped.keys.sorted()

        val storedByFamily = permissions
            .filter { it.store == HealthConnectAdapter.anchorStore }
            .associateBy { it.platformType }
        // Every family is present in the map, defaulting to NOT_REQUESTED. A family BADAN has
        // never asked about is a real, answerable state ("we haven't asked, so nothing from here
        // is arriving"), and omitting the row would leave the user to infer it from an absence.
        val familyStatus = HcTypeMap.Family.entries.associateWith { family ->
            storedByFamily[family.code]?.status ?: PermissionStatus.NOT_REQUESTED
        }

        val overrides = env.writerPriorityOverrides()
        val writers = sources
            .filter { it.type == SourceType.HEALTH_CONNECT }
            .map { source ->
                val pkg = source.platformBundleId ?: source.id
                WriterInfo(
                    source = source,
                    packageName = pkg,
                    // Computed without `deviceBonus`: the device class lives on the Health Connect
                    // metadata inside the adapter and is not persisted on `Source`, so it cannot be
                    // recovered here. That makes the number below the *baseline*, which is why the
                    // editor shows an order rather than a score and the copy says the automatic
                    // device adjustment exists — see `priorityDefaultOrderNote`. Once the user sets
                    // an order, overrides replace the computed value outright
                    // (`HcTypeMap.writerPriority` returns the override before touching the bonus),
                    // so from that point what is shown and what is applied are the same thing.
                    effectivePriority = HcTypeMap.writerPriority(pkg, deviceType = null, overrides = overrides),
                    hasUserOverride = overrides.containsKey(pkg),
                )
            }
            .sortedWith(compareByDescending<WriterInfo> { it.effectivePriority }.thenBy { it.packageName })

        if (infos.isEmpty() && permissions.isEmpty()) {
            LoadState.Empty(env.s(Loc.nothingYet))
        } else {
            LoadState.Loaded(SourcesData(infos, stores, grouped, familyStatus, writers))
        }
    } catch (t: Throwable) {
        LoadState.Error(if (env.depth.showsPowerDetail) t.toString() else env.s(sourcesLoadFailed))
    }

// MARK: - Screen

private val connectHeader = LocalizedString(en = "Connect a source", ar = "ربط مصدر")
private val permissionsHeader = LocalizedString(en = "Permissions", ar = "الأذونات")
private val devicesLabel = LocalizedString(en = "Devices", ar = "الأجهزة")
private val noPermissions = LocalizedString(en = "No permissions requested yet.", ar = "لم تُطلب أي أذونات بعد.")
private val priorityNote = LocalizedString(
    en = "When two sources report the same reading, BADAN keeps the one from the higher-priority source (for example a wrist device over a phone) and quietly sets the other aside. Nothing is deleted — the setting-aside can be reversed.",
    ar = "عندما يُبلّغ مصدران عن القراءة نفسها، يحتفظ بدن بالقراءة من المصدر الأعلى أولوية (مثل جهاز المعصم مقابل الهاتف) ويضع الأخرى جانباً بهدوء. لا يُحذف شيء — ويمكن التراجع عن وضعها جانباً.",
)
private val jumpToHealthConnect = LocalizedString(en = "Health Connect", ar = "هيلث كونكت")
private val jumpToSources = LocalizedString(en = "Sources", ar = "المصادر")
private val jumpToPermissions = LocalizedString(en = "Permissions", ar = "الأذونات")

/**
 * Data sources — where every number comes from. Read-only and calm: what is connected, which
 * devices have delivered, and how each permission stands. Power adds the honest note about how
 * source priority breaks duplicate ties. Mirror of the iOS `SourcesScreen`.
 */
@Composable
fun SourcesScreen() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    // The shared sensor-quality contract, read straight from assets rather than through
    // AppEnvironment (see `SensorQualityMap.from`). One process-wide instance of an immutable
    // bundled file; `remember` here only avoids re-resolving the singleton on recomposition.
    val context = LocalContext.current
    val quality = remember(context) { SensorQualityMap.from(context.assets) }

    var state by remember { mutableStateOf<LoadState<SourcesData>>(LoadState.Loading) }
    suspend fun reload() {
        state = withContext(Dispatchers.IO) { loadSources(env, quality) }
    }
    LaunchedEffect(Unit) { reload() }

    // Lets a "Grant" action on a NOT_REQUESTED permission row (EASE-275) trigger the Health Connect
    // permission flow without reaching into HealthConnectCard's own internal state.
    //
    // Now staged rather than blanket (EPIC-02): a Grant on the "Sleep" row asks for sleep, not for
    // all fifteen types. The previous behaviour meant a user who had deliberately declined body
    // measurements and later wanted sleep was re-asked for everything they had already refused,
    // which reads as the app not having listened the first time.
    val staged = rememberStagedPermissionRequest(
        onComplete = { scope.launch { reload() } },
    )

    val scrollState = rememberScrollState()
    var healthConnectAnchor by remember { mutableStateOf(0) }
    var sourcesAnchor by remember { mutableStateOf(0) }
    var permissionsAnchor by remember { mutableStateOf(0) }

    Box(modifier = Modifier.fillMaxSize().background(colors.background)) {
        StatefulContainer(state) { data ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(scrollState)
                    .padding(BadanSpace.s4),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
            ) {
                // A small jump menu so a screen with several sources/devices/permissions doesn't
                // demand a fully linear scroll every visit (EASE-263).
                SourcesJumpMenu(
                    showSources = data.sources.isNotEmpty(),
                    onJumpToHealthConnect = { scope.launch { scrollState.animateScrollTo(healthConnectAnchor) } },
                    onJumpToSources = { scope.launch { scrollState.animateScrollTo(sourcesAnchor) } },
                    onJumpToPermissions = { scope.launch { scrollState.animateScrollTo(permissionsAnchor) } },
                )

                Column(
                    modifier = Modifier.onGloballyPositioned {
                        healthConnectAnchor = (it.positionInParent().y + scrollState.value).toInt()
                    },
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
                ) {
                    SectionHeader(env.s(connectHeader))
                    HealthConnectCard()
                    // The 30-day disclosure sits with the connect surface, not buried in a
                    // footnote: it is the single most likely cause of "why does BADAN only show me
                    // last month", and the answer has to be adjacent to the thing that caused it.
                    BackfillHonestyCard()
                }

                if (data.sources.isNotEmpty()) {
                    Column(
                        modifier = Modifier.onGloballyPositioned {
                            sourcesAnchor = (it.positionInParent().y + scrollState.value).toInt()
                        },
                        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
                    ) {
                        SectionHeader(
                            title = env.s(Loc.dataSources),
                            modifier = Modifier.padding(top = BadanSpace.s2),
                        )
                        data.sources.forEach { SourcesSourceCard(it) }
                    }
                }

                Column(
                    modifier = Modifier.onGloballyPositioned {
                        permissionsAnchor = (it.positionInParent().y + scrollState.value).toInt()
                    },
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
                ) {
                    SectionHeader(
                        title = env.s(permissionsHeader),
                        modifier = Modifier.padding(top = if (data.sources.isNotEmpty()) BadanSpace.s2 else 0.dp),
                    )
                    SourcesFamilyPermissionCard(
                        data = data,
                        busy = staged.isRunning,
                        onGrantFamily = { family -> staged.start(listOf(family)) },
                        onGrantAll = { staged.start(stagedPermissionFamilies) },
                    )
                    if (data.permissionStores.isNotEmpty()) {
                        SourcesPermissionCard(
                            data = data,
                            onGrantHealthConnect = { staged.start(stagedPermissionFamilies) },
                        )
                    }
                }

                SourcesPriorityCard(
                    writers = data.writers,
                    editable = env.depth.showsPowerDetail,
                    onReorder = { reordered ->
                        scope.launch {
                            withContext(Dispatchers.IO) {
                                runCatching { env.setWriterPriorityOverrides(reordered) }
                            }
                            reload()
                        }
                    },
                    onReset = {
                        scope.launch {
                            withContext(Dispatchers.IO) {
                                runCatching { env.setWriterPriorityOverrides(emptyMap()) }
                            }
                            reload()
                        }
                    },
                )
            }
        }
    }
}

@Composable
private fun SourcesJumpMenu(
    showSources: Boolean,
    onJumpToHealthConnect: () -> Unit,
    onJumpToSources: () -> Unit,
    onJumpToPermissions: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        TextButton(onClick = onJumpToHealthConnect) { Text(env.s(jumpToHealthConnect)) }
        if (showSources) {
            TextButton(onClick = onJumpToSources) { Text(env.s(jumpToSources)) }
        }
        TextButton(onClick = onJumpToPermissions) { Text(env.s(jumpToPermissions)) }
    }
}

// MARK: - Source card

private val connectedLabel = LocalizedString(en = "Connected", ar = "تاريخ الاتصال")
private val lastDeliveryLabel = LocalizedString(en = "Last delivery", ar = "آخر تسليم")
private val bundleLabel = LocalizedString(en = "Bundle", ar = "الحزمة")
private val lastSeenLabel = LocalizedString(en = "Last seen", ar = "آخر ظهور")
private val deviceActiveLabel = LocalizedString(en = "Active", ar = "نشط")
private val deviceInactiveLabel = LocalizedString(en = "Inactive", ar = "غير نشط")
private val showLessDevices = LocalizedString(en = "Show less", ar = "عرض أقل")
private fun showMoreDevices(count: Int) = LocalizedString(en = "Show $count more", ar = "عرض $count أخرى")

/** A source's own device list stays short by default once it grows past a handful, rather than
 *  scrolling on unbounded (EASE-274). */
private const val DEVICES_COLLAPSED_LIMIT = 3

@Composable
private fun SourcesSourceCard(info: SourcesSourceInfo) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = sourceIcon(info.source.type),
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(28.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Text(
                        text = info.source.displayName,
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = env.s(sourceTypeLabel(info.source.type)),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                    // The writing app's package, shown for Health Connect sources at every
                    // altitude rather than only in power mode (where the generic `Bundle` line
                    // below still repeats it for other source types).
                    //
                    // On Android this is not a technical curiosity: Health Connect hands BADAN one
                    // row per *writing app*, several of which routinely write the same metric, and
                    // their user-visible labels are frequently indistinguishable ("Health",
                    // "Health Sync", "Health Connect"). The package is the only identifier that is
                    // unique, and `HealthConnectAdapter.writerLabel` already falls back to it when
                    // an app has been uninstalled — so it is also the label that survives.
                    if (info.source.type == SourceType.HEALTH_CONNECT) {
                        info.source.platformBundleId
                            ?.takeIf { it != info.source.displayName }
                            ?.let { pkg ->
                                Text(
                                    text = pkg,
                                    style = BadanType.caption,
                                    color = colors.textSecondary,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                    }
                }
                Box(modifier = Modifier.widthIn(min = 96.dp), contentAlignment = Alignment.CenterEnd) {
                    SourceStatusPill(info.source.status)
                }
            }

            if (env.depth.showsPowerDetail) {
                info.source.connectedAt?.let { DetailLine(connectedLabel, formatDateTime(it, env.language)) }
                info.source.lastDeliveryAt?.let { DetailLine(lastDeliveryLabel, formatDateTime(it, env.language)) }
                info.source.platformBundleId?.let { DetailLine(bundleLabel, it) }
            }

            // Above the device list, matching iOS: "what kind of sensor is this" frames the
            // devices that follow, where below them it would read as a footnote to the last row.
            SourcesSensorQualitySection(info.sourceClassId)

            if (info.devices.isNotEmpty()) {
                Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(colors.separator))
                Text(
                    text = env.s(devicesLabel),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
                var devicesExpanded by remember(info.source.id) { mutableStateOf(false) }
                val hiddenCount = info.devices.size - DEVICES_COLLAPSED_LIMIT
                val visibleDevices = if (!devicesExpanded && hiddenCount > 0) {
                    info.devices.take(DEVICES_COLLAPSED_LIMIT)
                } else {
                    info.devices
                }
                visibleDevices.forEach { DeviceRow(it) }
                if (hiddenCount > 0) {
                    TextButton(onClick = { devicesExpanded = !devicesExpanded }) {
                        Text(env.s(if (devicesExpanded) showLessDevices else showMoreDevices(hiddenCount)))
                    }
                }
            }
        }
    }
}

// MARK: - Sensor quality (shared contract, mirror of iOS SourcesSensorQualitySection)

private val sensorQualityHeader = LocalizedString(
    en = "What this sensor is good at",
    ar = "ما يجيده هذا المستشعر",
)

/**
 * Families worth labelling, in the order the Sources screen reads best. Deliberately not
 * `MetricFamily.entries`: subjective/symptom/medication entries describe things a person types,
 * where "sensor quality" is a category error.
 */
private val sensorQualityFamilies = listOf(
    MetricFamily.HEART,
    MetricFamily.SLEEP,
    MetricFamily.ACTIVITY,
    MetricFamily.RESPIRATORY,
    MetricFamily.BODY,
)

/**
 * What kind of sensor this source is, and what that means per family (audit finding #6 — the
 * Android side of `packages/contracts/sensor_quality.json`, which was bundled and CI-gated here
 * with nothing to read it).
 *
 * **This is an honesty label, never a ranking or a gate.** Nothing here suppresses, hides, reorders
 * or downweights a reading — duplicates are settled by [SourcesPriorityCard]'s writer order and the
 * dedup journal (I3/I4), and raw data is never paywalled. A `low` label says what the sensor class
 * does, not how much the person should trust their own body.
 *
 * Only families this class actually produces are listed. `UNSUPPORTED` rows are dropped rather than
 * shown as a wall of "not from this device": a smart scale would otherwise render four negative
 * rows and one useful one, which reads as a fault report about hardware that is working exactly as
 * designed.
 */
@Composable
private fun SourcesSensorQualitySection(sourceClassId: String) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val quality = remember(context) { SensorQualityMap.from(context.assets) }

    val sourceClass = quality.sourceClass(sourceClassId) ?: return
    val rows = remember(sourceClassId, quality) {
        sensorQualityFamilies
            .map { it to quality.level(sourceClassId, it) }
            .filter { it.second != SensorQualityLevel.UNSUPPORTED }
    }
    if (rows.isEmpty()) return

    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(colors.separator))
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = env.s(sensorQualityHeader),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        Text(
            text = env.s(sourceClass.displayName),
            style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
            color = colors.textPrimary,
        )
        if (env.depth.showsPowerDetail) {
            Text(
                text = env.s(sourceClass.explainer),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        rows.forEach { (family, level) ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = BadanSpace.touchMin)
                    // One phrase per family instead of a label stop and a chip stop, matching how
                    // iOS combines the two with `.accessibilityElement(children: .combine)`.
                    .semantics(mergeDescendants = true) {
                        contentDescription = "${env.s(family.displayName)}, ${env.s(level.label)}"
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Text(
                    text = env.s(family.displayName),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                    modifier = Modifier.weight(1f),
                )
                PillLabel(
                    text = env.s(level.label),
                    icon = sensorQualityIcon(level),
                    tint = sensorQualityTint(level, colors),
                )
            }
        }
    }
}

/**
 * Colour is never the only signal (design-system rule) — every level pairs its tint with a distinct
 * glyph, and the chip always shows its text label too. `ShowChart` is taken from the auto-mirrored
 * set so the trend line runs the reading direction in Arabic.
 */
private fun sensorQualityIcon(level: SensorQualityLevel): ImageVector = when (level) {
    SensorQualityLevel.HIGH -> Icons.Filled.Verified
    SensorQualityLevel.MEDIUM -> Icons.AutoMirrored.Filled.ShowChart
    SensorQualityLevel.LOW -> Icons.Filled.Functions
    SensorQualityLevel.UNSUPPORTED -> Icons.Filled.RemoveCircle
}

/**
 * `LOW`/`UNSUPPORTED` share the ONE calm amber the design system reserves for "outside the
 * ordinary" — never `critical`, which stays permanently unused. A sensor telling you less than
 * another sensor is not an alarm.
 *
 * Resolved here rather than on [SensorQualityLevel] itself because on Android the ontology layer
 * stays presentation-free (`MetricFamily` carries a `symbolName` key, not an `ImageVector`); iOS
 * puts the SwiftUI `Color` on the enum because its ontology types already import SwiftUI.
 */
private fun sensorQualityTint(level: SensorQualityLevel, colors: BadanColors): Color = when (level) {
    SensorQualityLevel.HIGH -> colors.inBand
    SensorQualityLevel.MEDIUM -> colors.textSecondary
    SensorQualityLevel.LOW, SensorQualityLevel.UNSUPPORTED -> colors.outOfBand
}

@Composable
private fun DetailLine(label: LocalizedString, value: String) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = env.s(label),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            style = BadanType.caption,
            color = colors.textPrimary,
            textAlign = TextAlign.End,
        )
    }
}

@Composable
private fun DeviceRow(device: Device) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = deviceIcon(device),
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(
                text = device.name,
                style = BadanType.bodyCompact,
                color = colors.textPrimary,
            )
            if (env.depth.showsPowerDetail) {
                device.model?.let {
                    Text(text = it, style = BadanType.caption, color = colors.textSecondary)
                }
            }
        }
        if (env.depth.showsPowerDetail) {
            Column(
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = env.s(lastSeenLabel),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
                Text(
                    text = formatDateTime(device.lastSeen, env.language),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        } else {
            // Casual altitude still deserves a basic recency signal — whether a device is actively
            // contributing data isn't power-only detail (UIUX-291). The exact timestamp stays power-gated.
            DeviceRecencyPill(device.lastSeen)
        }
    }
}

private const val DEVICE_ACTIVE_WINDOW_MILLIS = 3L * 24 * 60 * 60 * 1000 // 3 days

@Composable
private fun DeviceRecencyPill(lastSeen: Long) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val isActive = env.now() - lastSeen < DEVICE_ACTIVE_WINDOW_MILLIS
    if (isActive) {
        PillLabel(text = env.s(deviceActiveLabel), icon = Icons.Filled.CheckCircle, tint = colors.primary)
    } else {
        PillLabel(text = env.s(deviceInactiveLabel), icon = Icons.Filled.RemoveCircle, tint = colors.textSecondary)
    }
}

// MARK: - Permission card

private val grantLabel = LocalizedString(en = "Grant", ar = "منح")

@Composable
private fun SourcesPermissionCard(data: SourcesData, onGrantHealthConnect: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    BadanCard {
        if (data.permissionStores.isEmpty()) {
            Text(
                text = env.s(noPermissions),
                style = BadanType.body,
                color = colors.textSecondary,
            )
        } else {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
                data.permissionStores.forEach { store ->
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        Text(
                            text = env.s(storeLabel(store)),
                            style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.textSecondary,
                        )
                        (data.permissionsByStore[store] ?: emptyList()).forEach { permission ->
                            Row(
                                modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = BadanSpace.touchMin),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                            ) {
                                Text(
                                    text = env.s(permissionTypeLabel(permission.platformType)),
                                    style = BadanType.bodyCompact,
                                    color = colors.textPrimary,
                                    modifier = Modifier.weight(1f),
                                )
                                // A gap the user can act on exactly where they see it, rather than only
                                // via the Health Connect card scrolled far above (EASE-275).
                                if (permission.status == PermissionStatus.NOT_REQUESTED && store == "healthConnect") {
                                    TextButton(onClick = onGrantHealthConnect) {
                                        Text(env.s(grantLabel))
                                    }
                                }
                                // A fixed-width trailing column keeps every status pill aligned to the
                                // same right edge regardless of label length (UIUX-233).
                                Box(modifier = Modifier.widthIn(min = 116.dp), contentAlignment = Alignment.CenterEnd) {
                                    PermissionPill(permission.status)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Per-family permission matrix (EPIC-02)

private val familyPermissionsHeader = LocalizedString(
    en = "What BADAN may read",
    ar = "ما يُسمح لبدن بقراءته",
)
private val familyPermissionsNote = LocalizedString(
    en = "Each kind of data is asked for on its own. Turning one down doesn't affect the others.",
    ar = "يُطلب كل نوع من البيانات على حدة. رفض أحدها لا يؤثر على البقية.",
)
private val grantAllRemaining = LocalizedString(en = "Ask for the rest", ar = "اطلب البقية")
private val askingNow = LocalizedString(en = "Asking…", ar = "جارٍ الطلب…")

/**
 * The five consent families and where each one stands.
 *
 * Rendered whole, always — including families that have never been asked about. §16's permission
 * recovery requirement is that the surface "explains exactly which family is off and what stops
 * working", which is impossible from a list that only contains the families that happen to have a
 * stored row.
 */
@Composable
private fun SourcesFamilyPermissionCard(
    data: SourcesData,
    busy: Boolean,
    onGrantFamily: (HcTypeMap.Family) -> Unit,
    onGrantAll: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val missing = stagedPermissionFamilies.filter {
        data.familyStatus[it] != PermissionStatus.GRANTED
    }

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Text(
                text = env.s(familyPermissionsHeader),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
            )
            Text(
                text = env.s(familyPermissionsNote),
                style = BadanType.caption,
                color = colors.textSecondary,
            )

            stagedPermissionFamilies.forEach { family ->
                val status = data.familyStatus[family] ?: PermissionStatus.NOT_REQUESTED
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                    Row(
                        modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = BadanSpace.touchMin),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Icon(
                            imageVector = familyIcon(family),
                            contentDescription = null,
                            tint = colors.textSecondary,
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            text = env.s(familyTitle(family)),
                            style = BadanType.bodyCompact,
                            color = colors.textPrimary,
                            modifier = Modifier.weight(1f),
                        )
                        if (status != PermissionStatus.GRANTED && !busy) {
                            TextButton(onClick = { onGrantFamily(family) }) { Text(env.s(grantLabel)) }
                        }
                        Box(modifier = Modifier.widthIn(min = 116.dp), contentAlignment = Alignment.CenterEnd) {
                            PermissionPill(status)
                        }
                    }
                    // What stops working, stated only where something has in fact stopped. Printing
                    // the consequence beside a granted family would be noise; printing it beside a
                    // declined one is the whole point of the row.
                    if (status != PermissionStatus.GRANTED) {
                        Text(
                            text = env.s(familyRationale(family)),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            if (busy) {
                Text(text = env.s(askingNow), style = BadanType.caption, color = colors.textSecondary)
            } else if (missing.size > 1) {
                TextButton(onClick = onGrantAll) { Text(env.s(grantAllRemaining)) }
            }
        }
    }
}

// MARK: - Source priority (multi-writer disambiguation)

private val priorityOrderTitle = LocalizedString(
    en = "Which source wins",
    ar = "أي مصدر يُقدَّم",
)
private val priorityScopeNote = LocalizedString(
    en = "This order settles duplicates for movement, sleep, vitals, body measurements and workouts.",
    ar = "يُحدّد هذا الترتيب المكرّرات في الحركة والنوم والمؤشرات الحيوية وقياسات الجسم والتمارين.",
)

/**
 * The one honest caveat this editor has to carry, and the reason it is one list rather than five.
 * See [SourcesPriorityCard]'s doc.
 */
private val prioritySingleScaleNote = LocalizedString(
    en = "One order covers everything a source writes — BADAN can't yet rank an app higher for " +
        "sleep than for steps.",
    ar = "ترتيب واحد يشمل كل ما يكتبه المصدر — لا يستطيع بدن بعدُ تقديم تطبيق في النوم دون الخطوات.",
)
private val priorityDefaultOrderNote = LocalizedString(
    en = "Starting order. A wrist device is nudged above a phone app automatically; set your own " +
        "order to decide it yourself.",
    ar = "الترتيب المبدئي. يُقدَّم جهاز المعصم تلقائياً على تطبيق الهاتف؛ اضبط ترتيبك الخاص لتقرّر بنفسك.",
)
private val priorityYourOrderNote = LocalizedString(
    en = "Your order. It's used exactly as shown.",
    ar = "ترتيبك أنت. يُستخدم كما هو معروض تماماً.",
)
private val priorityEffectNote = LocalizedString(
    en = "Changing the order re-settles duplicates on the next sync. Nothing is deleted — a record " +
        "set aside can come back.",
    ar = "تغيير الترتيب يُعيد تسوية المكرّرات في المزامنة التالية. لا يُحذف شيء — ويمكن أن يعود أي " +
        "سجل وُضع جانباً.",
)
private val priorityResetLabel = LocalizedString(en = "Use the default order", ar = "استخدام الترتيب الافتراضي")
private val priorityMoveUp = LocalizedString(en = "Move up", ar = "تحريك لأعلى")
private val priorityMoveDown = LocalizedString(en = "Move down", ar = "تحريك لأسفل")
private val prioritySingleWriter = LocalizedString(
    en = "Only one app is writing to Health Connect right now, so there is nothing to settle.",
    ar = "يكتب تطبيق واحد فقط إلى هيلث كونكت حالياً، فلا شيء يحتاج إلى تسوية.",
)

/**
 * Source priority, editable (plan §16 "Data-source & provenance explorer", EPIC-02 risks:
 * "provenance shows package id, priority editable").
 *
 * **Why one list and not five.** The plan's wording is a per-family priority editor, and the
 * surface is organised around families for exactly that reason — the scope line names the five
 * families this order governs. What it does *not* do is offer five independent orders, and that is
 * a deliberate refusal rather than an omission:
 *
 *  1. `DedupLite.reconcile`'s `priorityForSource` lambda takes a source id and nothing else. Making
 *     it per-family changes a reconciliation rule shared with iOS, which is a cross-platform
 *     contract change (`HcTypeMap.writerPriority` documents the same deferral from the data side).
 *  2. Nothing in `sources`/`devices` records *which* families a writer has actually delivered, so
 *     the per-family lists would be five copies of the same list of every writer.
 *
 * A five-tab editor writing into a single per-writer scale would look like it worked and quietly
 * apply the last tab the user touched to everything. Shipping one list plus the sentence explaining
 * the limit is the honest version of the same capability, and it is the version whose behaviour a
 * user can predict.
 *
 * **Order, not numbers.** The editor moves rows rather than exposing the integer scale. Reordering
 * writes an explicit override for *every* writer in the list, which matters because
 * `HcTypeMap.writerPriority` treats an override as absolute — so after one edit the displayed order
 * is exactly the applied order, with no invisible device bonus left to reshuffle it.
 */
@Composable
private fun SourcesPriorityCard(
    writers: List<WriterInfo>,
    editable: Boolean,
    onReorder: (Map<String, Int>) -> Unit,
    onReset: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    if (writers.isEmpty()) return

    val hasOverrides = writers.any { it.hasUserOverride }

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(priorityOrderTitle), modifier = Modifier.padding(top = BadanSpace.s2))
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                Text(
                    text = env.s(priorityNote),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
                Text(
                    text = env.s(priorityScopeNote),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )

                if (writers.size < 2) {
                    Text(
                        text = env.s(prioritySingleWriter),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                } else {
                    Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(colors.separator))
                    writers.forEachIndexed { index, writer ->
                        WriterPriorityRow(
                            writer = writer,
                            rank = index + 1,
                            editable = editable,
                            canMoveUp = index > 0,
                            canMoveDown = index < writers.lastIndex,
                            onMove = { delta ->
                                val reordered = writers.toMutableList()
                                val target = index + delta
                                if (target in reordered.indices) {
                                    val moved = reordered.removeAt(index)
                                    reordered.add(target, moved)
                                    onReorder(priorityScale(reordered))
                                }
                            },
                        )
                    }

                    Text(
                        text = env.s(if (hasOverrides) priorityYourOrderNote else priorityDefaultOrderNote),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                    if (editable) {
                        Text(
                            text = env.s(prioritySingleScaleNote),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                        // The I3 promise, restated at the exact moment the user is about to change
                        // something that will set records aside.
                        Text(
                            text = env.s(priorityEffectNote),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                        if (hasOverrides) {
                            TextButton(onClick = onReset) { Text(env.s(priorityResetLabel)) }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Turn a display order into the integer scale the dedup engine reads.
 *
 * Descending from a high base in steps of 10: high enough that a user-set order always outranks the
 * unknown-writer default (30) so a newly-appearing app cannot leapfrog an explicit choice, and
 * spaced so a future insertion between two rows does not require rewriting the whole map. Every
 * writer in the list gets a value, including the ones that did not move — a partial map would leave
 * the untouched writers on their computed baseline and produce an order the user never asked for.
 */
private fun priorityScale(ordered: List<WriterInfo>): Map<String, Int> {
    val base = 100
    return ordered.mapIndexed { index, writer -> writer.packageName to (base - index * 10) }.toMap()
}

@Composable
private fun WriterPriorityRow(
    writer: WriterInfo,
    rank: Int,
    editable: Boolean,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onMove: (Int) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = env.format.integer(rank),
            style = BadanType.monospaceDigits(BadanType.bodyCompact),
            color = colors.textSecondary,
            modifier = Modifier.widthIn(min = 24.dp),
        )
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(
                text = writer.source.displayName,
                style = BadanType.bodyCompact,
                color = colors.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // The package id, at every altitude and not only in power mode. This is the Android
            // story: several apps write the same metric, their display labels are often
            // indistinguishable, and the package is the only identifier that is guaranteed unique.
            // Hiding it behind an altitude switch would make the list unusable in exactly the
            // multi-writer setup it exists for.
            Text(
                text = writer.packageName,
                style = BadanType.caption,
                color = colors.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (editable) {
            IconButton(onClick = { onMove(-1) }, enabled = canMoveUp) {
                Icon(
                    imageVector = Icons.Filled.KeyboardArrowUp,
                    contentDescription = env.s(priorityMoveUp),
                    tint = if (canMoveUp) colors.primary else colors.separator,
                )
            }
            IconButton(onClick = { onMove(1) }, enabled = canMoveDown) {
                Icon(
                    imageVector = Icons.Filled.KeyboardArrowDown,
                    contentDescription = env.s(priorityMoveDown),
                    tint = if (canMoveDown) colors.primary else colors.separator,
                )
            }
        }
    }
}

// MARK: - Status / permission pills

@Composable
private fun SourceStatusPill(status: SourceStatus) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val (label, tint, icon) = when (status) {
        SourceStatus.ACTIVE ->
            Triple(LocalizedString(en = "Active", ar = "نشط"), colors.primary, Icons.Filled.CheckCircle)
        SourceStatus.REVOKED ->
            Triple(LocalizedString(en = "Turned off", ar = "متوقف"), colors.outOfBand, Icons.Filled.RemoveCircle)
        SourceStatus.HIDDEN ->
            Triple(LocalizedString(en = "Hidden", ar = "مخفي"), colors.textSecondary, Icons.Filled.VisibilityOff)
    }
    PillLabel(text = env.s(label), icon = icon, tint = tint)
}

@Composable
private fun PermissionPill(status: PermissionStatus) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val (tint, icon) = when (status) {
        PermissionStatus.GRANTED -> colors.primary to Icons.Filled.CheckCircle
        PermissionStatus.PARTIAL -> colors.info to Icons.Filled.Contrast
        PermissionStatus.DENIED -> colors.outOfBand to Icons.Filled.Cancel
        PermissionStatus.REVOKED -> colors.textSecondary to Icons.Filled.RemoveCircle
        PermissionStatus.NOT_REQUESTED -> colors.textSecondary to Icons.AutoMirrored.Filled.HelpOutline
    }
    PillLabel(text = env.s(status.displayLabel), icon = icon, tint = tint)
}

// MARK: - Presentation helpers

private fun sourceIcon(type: SourceType): ImageVector = when (type) {
    SourceType.HEALTHKIT -> Icons.Filled.Favorite
    SourceType.HEALTH_CONNECT -> Icons.Filled.MonitorHeart
    SourceType.MANUAL -> Icons.Filled.Edit
    SourceType.FILE_IMPORT -> Icons.Filled.Download
    SourceType.VENDOR -> Icons.Filled.Link
}

private fun sourceTypeLabel(type: SourceType): LocalizedString = when (type) {
    SourceType.HEALTHKIT -> LocalizedString(en = "Apple Health", ar = "صحة آبل")
    SourceType.HEALTH_CONNECT -> LocalizedString(en = "Health Connect", ar = "هيلث كونكت")
    SourceType.MANUAL -> LocalizedString(en = "Entered by you", ar = "إدخال يدوي")
    SourceType.FILE_IMPORT -> LocalizedString(en = "Imported file", ar = "ملف مستورد")
    SourceType.VENDOR -> LocalizedString(en = "Connected service", ar = "خدمة متصلة")
}

private fun deviceIcon(device: Device): ImageVector {
    val hay = (device.name + " " + (device.model ?: "")).lowercase()
    return when {
        hay.contains("watch") -> Icons.Filled.Watch
        hay.contains("phone") -> Icons.Filled.Smartphone
        hay.contains("ring") -> Icons.Filled.Circle
        hay.contains("band") -> Icons.Filled.Sensors
        else -> Icons.Filled.Sensors
    }
}

private fun storeLabel(store: String): LocalizedString = when (store) {
    "healthkit" -> LocalizedString(en = "Apple Health", ar = "صحة آبل")
    "healthConnect" -> LocalizedString(en = "Health Connect", ar = "هيلث كونكت")
    else -> LocalizedString(en = store, ar = store)
}

/**
 * Friendly, bilingual names for the common platform data types; unknown technical tokens fall
 * back to a humanized form of the identifier.
 */
private fun permissionTypeLabel(platformType: String): LocalizedString = when (platformType) {
    // The aggregate row `AppEnvironment.recordHealthConnectPermissions` writes, alongside the
    // per-family rows the staged flow writes. Named explicitly so it doesn't fall through to the
    // unmapped-type warning below on every single load.
    "health" -> LocalizedString(en = "All health data", ar = "كل البيانات الصحية")
    "sleepAnalysis" -> LocalizedString(en = "Sleep", ar = "النوم")
    "heartRate" -> LocalizedString(en = "Heart rate", ar = "معدل ضربات القلب")
    "restingHeartRate" -> LocalizedString(en = "Resting heart rate", ar = "معدل القلب أثناء الراحة")
    "heartRateVariabilitySDNN", "hrv" -> LocalizedString(en = "Heart rate variability", ar = "تغيّر معدل القلب")
    "stepCount", "steps" -> LocalizedString(en = "Steps", ar = "الخطوات")
    "activeEnergyBurned", "activeEnergy" -> LocalizedString(en = "Active energy", ar = "الطاقة النشطة")
    "distanceWalkingRunning", "distance" -> LocalizedString(en = "Distance", ar = "المسافة")
    "respiratoryRate" -> LocalizedString(en = "Respiratory rate", ar = "معدل التنفّس")
    "oxygenSaturation", "spo2" -> LocalizedString(en = "Blood oxygen", ar = "أكسجين الدم")
    "bodyMass", "weight" -> LocalizedString(en = "Weight", ar = "الوزن")
    else -> {
        // Not yet in the explicit lookup table above — log it so it can be added, and fall back to
        // a best-effort humanized label rather than a garbled one (EASE-285).
        Log.w("SourcesScreen", "Unmapped Health Connect permission type: $platformType")
        val humanized = humanize(platformType)
        LocalizedString(en = humanized, ar = humanized)
    }
}

/** Splits camelCase *and* acronym boundaries, e.g. "heartRateVariabilitySDNN" -> "Heart rate
 *  variability SDNN" (acronyms like "SDNN" are kept intact rather than lowercased). */
private val humanizeWordBoundary = Regex("(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")

private fun humanize(token: String): String {
    if (token.isEmpty()) return token
    val words = humanizeWordBoundary.split(token).filter { it.isNotEmpty() }
    return words.mapIndexed { index, word ->
        val isAcronym = word.length > 1 && word.all { it.isUpperCase() }
        when {
            isAcronym -> word
            index == 0 -> word.replaceFirstChar { it.uppercase() }
            else -> word.lowercase()
        }
    }.joinToString(" ")
}

private fun formatDateTime(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val formatter = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale)
    return formatter.format(Date(millis))
}
