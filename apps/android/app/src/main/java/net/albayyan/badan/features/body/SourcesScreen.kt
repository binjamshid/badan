package net.albayyan.badan.features.body

import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
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
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.RemoveCircle
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Watch
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.domain.Device
import net.albayyan.badan.domain.PermissionState
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.SourceStatus
import net.albayyan.badan.domain.SourceType
import net.albayyan.badan.platform.health.HealthConnectAdapter
import java.text.DateFormat
import java.util.Date
import java.util.Locale

// MARK: - Model

/** A source paired with the devices that have delivered through it. */
private data class SourcesSourceInfo(val source: Source, val devices: List<Device>)

private data class SourcesData(
    val sources: List<SourcesSourceInfo>,
    val permissionStores: List<String>,                       // stable order
    val permissionsByStore: Map<String, List<PermissionState>>,
)

// MARK: - Loading (mirror of iOS SourcesViewModel)

/** Wellness-safe by default; raw exception text is reserved for power depth, mirroring
 *  `ExportScreen`'s altitude-gated error detail (never a stack-trace-style string for casual users). */
private val sourcesLoadFailed = LocalizedString(
    en = "Couldn't load your sources right now. Try again in a moment.",
    ar = "تعذّر تحميل مصادرك الآن. حاول مرة أخرى بعد قليل.",
)

private fun loadSources(env: AppEnvironment): LoadState<SourcesData> =
    try {
        val sources = env.catalog.sources()
        val infos = sources.map { SourcesSourceInfo(it, env.catalog.devices(it.id)) }
        val permissions = env.catalog.permissions()
        val grouped = permissions.groupBy { it.store }
        val stores = grouped.keys.sorted()

        if (infos.isEmpty() && permissions.isEmpty()) {
            LoadState.Empty(env.s(Loc.nothingYet))
        } else {
            LoadState.Loaded(SourcesData(infos, stores, grouped))
        }
    } catch (t: Throwable) {
        LoadState.Error(if (env.depth.showsPowerDetail) t.toString() else env.s(sourcesLoadFailed))
    }

// MARK: - Screen

private val connectHeader = LocalizedString(en = "Connect a source", ar = "ربط مصدر")
private val permissionsHeader = LocalizedString(en = "Permissions", ar = "الأذونات")
private val devicesLabel = LocalizedString(en = "Devices", ar = "الأجهزة")
private val noPermissions = LocalizedString(en = "No permissions requested yet.", ar = "لم تُطلب أي أذونات بعد.")
private val priorityTitle = LocalizedString(en = "How duplicates are settled", ar = "كيف تُسوّى النسخ المكرّرة")
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

    var state by remember { mutableStateOf<LoadState<SourcesData>>(LoadState.Loading) }
    suspend fun reload() {
        state = withContext(Dispatchers.IO) { loadSources(env) }
    }
    LaunchedEffect(Unit) { reload() }

    // Lets a "Grant" action on a NOT_REQUESTED permission row (EASE-275) trigger the same
    // Health Connect permission flow as the card above, without reaching into HealthConnectCard's
    // own internal state — an independent launcher for the same contract.
    val permissionLauncher = rememberLauncherForActivityResult(
        contract = HealthConnectAdapter.requestPermissionsContract()
    ) { grantedSet ->
        scope.launch {
            env.recordHealthConnectPermissions(grantedSet)
            reload()
        }
    }

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
                    SourcesPermissionCard(data, onGrantHealthConnect = { permissionLauncher.launch(HealthConnectAdapter.permissions) })
                }

                if (env.depth.showsPowerDetail) {
                    SourcesPriorityNote()
                }
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

// MARK: - Priority note (power)

@Composable
private fun SourcesPriorityNote() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            Icon(
                imageVector = Icons.Filled.Info,
                contentDescription = null,
                tint = colors.info,
                modifier = Modifier.size(20.dp),
            )
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                Text(
                    text = env.s(priorityTitle),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = env.s(priorityNote),
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
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
        PermissionStatus.NOT_REQUESTED -> colors.textSecondary to Icons.Filled.HelpOutline
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
