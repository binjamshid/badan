package net.albayyan.badan.features.body

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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
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
        LoadState.Error(t.toString())
    }

// MARK: - Screen

private val permissionsHeader = LocalizedString(en = "Permissions", ar = "الأذونات")
private val devicesLabel = LocalizedString(en = "Devices", ar = "الأجهزة")
private val noPermissions = LocalizedString(en = "No permissions requested yet.", ar = "لم تُطلب أي أذونات بعد.")
private val priorityTitle = LocalizedString(en = "How duplicates are settled", ar = "كيف تُسوّى النسخ المكرّرة")
private val priorityNote = LocalizedString(
    en = "When two sources report the same reading, BADAN keeps the one from the higher-priority source (for example a wrist device over a phone) and quietly sets the other aside. Nothing is deleted — the setting-aside can be reversed.",
    ar = "عندما يُبلّغ مصدران عن القراءة نفسها، يحتفظ بدن بالقراءة من المصدر الأعلى أولوية (مثل جهاز المعصم مقابل الهاتف) ويضع الأخرى جانباً بهدوء. لا يُحذف شيء — ويمكن التراجع عن وضعها جانباً.",
)

/**
 * Data sources — where every number comes from. Read-only and calm: what is connected, which
 * devices have delivered, and how each permission stands. Power adds the honest note about how
 * source priority breaks duplicate ties. Mirror of the iOS `SourcesScreen`.
 */
@Composable
fun SourcesScreen() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors

    var state by remember { mutableStateOf<LoadState<SourcesData>>(LoadState.Loading) }
    LaunchedEffect(Unit) {
        state = withContext(Dispatchers.IO) { loadSources(env) }
    }

    Box(modifier = Modifier.fillMaxSize().background(colors.background)) {
        StatefulContainer(state) { data ->
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(BadanSpace.s4),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
            ) {
                if (data.sources.isNotEmpty()) {
                    SectionHeader(env.s(Loc.dataSources))
                    data.sources.forEach { SourcesSourceCard(it) }
                }

                SectionHeader(
                    title = env.s(permissionsHeader),
                    modifier = Modifier.padding(top = if (data.sources.isNotEmpty()) BadanSpace.s2 else 0.dp),
                )
                SourcesPermissionCard(data)

                if (env.depth.showsPowerDetail) {
                    SourcesPriorityNote()
                }
            }
        }
    }
}

// MARK: - Source card

private val connectedLabel = LocalizedString(en = "Connected", ar = "تاريخ الاتصال")
private val lastDeliveryLabel = LocalizedString(en = "Last delivery", ar = "آخر تسليم")
private val bundleLabel = LocalizedString(en = "Bundle", ar = "الحزمة")
private val lastSeenLabel = LocalizedString(en = "Last seen", ar = "آخر ظهور")

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
                SourceStatusPill(info.source.status)
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
                info.devices.forEach { DeviceRow(it) }
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
        }
    }
}

// MARK: - Permission card

@Composable
private fun SourcesPermissionCard(data: SourcesData) {
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
                                PermissionPill(permission.status)
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
        val humanized = humanize(platformType)
        LocalizedString(en = humanized, ar = humanized)
    }
}

/** "sleepAnalysis" -> "Sleep analysis": split camelCase and capitalize the first word. */
private fun humanize(token: String): String {
    val sb = StringBuilder()
    token.forEachIndexed { index, c ->
        if (index > 0 && c.isUpperCase()) sb.append(' ')
        sb.append(c)
    }
    val out = sb.toString()
    if (out.isEmpty()) return out
    return out.substring(0, 1).uppercase() + out.substring(1).lowercase()
}

private fun formatDateTime(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val formatter = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale)
    return formatter.format(Date(millis))
}
