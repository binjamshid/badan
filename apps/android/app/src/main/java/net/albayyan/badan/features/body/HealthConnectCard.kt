package net.albayyan.badan.features.body

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.launch
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.platform.health.HealthAvailability
import net.albayyan.badan.platform.health.HealthConnectAdapter
import java.text.DateFormat
import java.util.Date
import java.util.Locale

private val hcTitle = LocalizedString(en = "Health Connect", ar = "هيلث كونكت")
private val hcConnectBody = LocalizedString(
    en = "Bring in your steps, heart rate, sleep and more from Health Connect. BADAN only reads — nothing leaves your device.",
    ar = "استورد خطواتك ومعدل نبضك ونومك والمزيد من هيلث كونكت. يقرأ بدن فقط — ولا يغادر أي شيء جهازك.",
)
private val hcConnect = LocalizedString(en = "Connect Health Connect", ar = "الاتصال بهيلث كونكت")
private val hcSyncNow = LocalizedString(en = "Sync now", ar = "المزامنة الآن")
private val hcConnected = LocalizedString(en = "Connected", ar = "متصل")
private val hcSyncing = LocalizedString(en = "Reading your data…", ar = "جارٍ قراءة بياناتك…")
private val hcNoData = LocalizedString(
    en = "Connected — no Health Connect data found yet. BADAN is showing its built-in demo data meanwhile.",
    ar = "متصل — لم يُعثر على بيانات في هيلث كونكت بعد. يعرض بدن بياناته التجريبية المدمجة في هذه الأثناء.",
)
private val hcDenied = LocalizedString(
    en = "Permission wasn't granted. You can try again anytime — BADAN keeps working with its built-in data.",
    ar = "لم يُمنح الإذن. يمكنك المحاولة مجدداً في أي وقت — ويواصل بدن العمل ببياناته المدمجة.",
)
private val hcUpdate = LocalizedString(en = "Set up Health Connect", ar = "إعداد هيلث كونكت")
private val hcUpdateBody = LocalizedString(
    en = "Health Connect needs to be set up on this device before BADAN can read from it.",
    ar = "يجب إعداد هيلث كونكت على هذا الجهاز قبل أن يتمكّن بدن من القراءة منه.",
)
private val hcUnsupported = LocalizedString(
    en = "Health Connect isn't available on this device. BADAN works fully on its own with your logs and demo data.",
    ar = "هيلث كونكت غير متوفّر على هذا الجهاز. يعمل بدن بالكامل بمفرده باستخدام سجلاتك والبيانات التجريبية.",
)
private val hcOpenSettings = LocalizedString(
    en = "Open Health Connect settings",
    ar = "فتح إعدادات هيلث كونكت",
)
private val hcSetupFailed = LocalizedString(
    en = "Couldn't open the Play Store or a browser. Health Connect may already be installed on this device.",
    ar = "تعذّر فتح متجر Play أو المتصفح. قد يكون هيلث كونكت مثبتاً بالفعل على هذا الجهاز.",
)
private fun lastSynced(time: String) = LocalizedString(
    en = "Last synced: $time",
    ar = "آخر مزامنة: $time",
)

private fun imported(count: Int) = LocalizedString(
    en = "Imported $count readings from Health Connect.",
    ar = "تم استيراد $count قراءة من هيلث كونكت.",
)

/**
 * The Health Connect connect surface: honest availability, a real staged-permission request, and a
 * sync that runs the same ingestion path as everything else. Never a dead end — every state offers
 * a next step and BADAN keeps working on its own data when Health Connect is absent or denied.
 */
@Composable
fun HealthConnectCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // Recomputed on resume so returning from the Play Store (after installing Health Connect)
    // reflects the new availability without requiring a full navigation away-and-back. (OPT-226)
    var availability by remember { mutableStateOf(env.healthConnect.availability()) }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                availability = env.healthConnect.availability()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    var granted by remember { mutableStateOf<Boolean?>(null) }
    var syncing by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<LocalizedString?>(null) }

    val syncPrefs = remember { context.getSharedPreferences("badan.health_connect_card", android.content.Context.MODE_PRIVATE) }
    var lastSyncedAt by remember {
        mutableStateOf(syncPrefs.getLong(LAST_SYNCED_KEY, -1L).takeIf { it > 0 })
    }
    fun markSynced() {
        val now = env.now()
        lastSyncedAt = now
        syncPrefs.edit().putLong(LAST_SYNCED_KEY, now).apply()
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = HealthConnectAdapter.requestPermissionsContract()
    ) { grantedSet ->
        scope.launch {
            env.recordHealthConnectPermissions(grantedSet)
            val ok = grantedSet.containsAll(HealthConnectAdapter.permissions)
            granted = ok
            if (ok) {
                syncing = true
                val summary = env.syncHealthConnect()
                syncing = false
                markSynced()
                val count = summary?.let { it.samples + it.intervals + it.sessions } ?: 0
                message = if (count > 0) imported(count) else hcNoData
            } else {
                message = hcDenied
            }
        }
    }

    LaunchedEffect(availability) {
        if (availability == HealthAvailability.available) granted = env.healthConnect.hasAllPermissions()
    }

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(Icons.Filled.MonitorHeart, null, tint = colors.primary, modifier = Modifier.size(28.dp))
                Text(
                    text = env.s(hcTitle),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                if (granted == true) {
                    Icon(Icons.Filled.CheckCircle, null, tint = colors.inBand, modifier = Modifier.size(20.dp))
                }
            }

            when (availability) {
                HealthAvailability.available -> {
                    if (granted == true) {
                        message?.let { BodyText(env.s(it), colors.textSecondary, Icons.Filled.Info) }
                        lastSyncedAt?.let {
                            BodyText(env.s(lastSynced(formatSyncTime(it, env.language))), colors.textSecondary)
                        }
                        if (syncing) {
                            SyncingRow()
                        } else {
                            OutlinedButton(onClick = {
                                runSync(scope, env) { s, m -> syncing = s; message = m; if (!s) markSynced() }
                            }) {
                                Text(env.s(hcSyncNow))
                            }
                        }
                    } else {
                        BodyText(env.s(hcConnectBody), colors.textSecondary)
                        message?.let { BodyText(env.s(it), colors.outOfBand, Icons.Filled.WarningAmber) }
                        if (syncing) {
                            SyncingRow()
                        } else {
                            Button(onClick = { permissionLauncher.launch(HealthConnectAdapter.permissions) }) {
                                Text(env.s(hcConnect))
                            }
                            // A denial frequently means Health Connect will no longer show the system
                            // prompt on retry; the working recovery path is the OS permission screen.
                            if (message == hcDenied) {
                                OutlinedButton(onClick = { openHealthConnectPermissionSettings(context, env) }) {
                                    Text(env.s(hcOpenSettings))
                                }
                            }
                        }
                    }
                }
                HealthAvailability.notInstalled -> {
                    BodyText(env.s(hcUpdateBody), colors.textSecondary)
                    Button(onClick = { openHealthConnectSetup(context, env) }) { Text(env.s(hcUpdate)) }
                }
                HealthAvailability.unsupported -> {
                    BodyText(env.s(hcUnsupported), colors.textSecondary)
                }
            }
        }
    }
}

private const val LAST_SYNCED_KEY = "last_synced_at_millis"

@Composable
private fun BodyText(text: String, color: androidx.compose.ui.graphics.Color, icon: ImageVector? = null) {
    if (icon != null) {
        Row(
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Icon(icon, null, tint = color, modifier = Modifier.size(16.dp))
            Text(text = text, style = BadanType.bodyCompact, color = color)
        }
    } else {
        Text(text = text, style = BadanType.bodyCompact, color = color)
    }
}

private fun formatSyncTime(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val formatter = DateFormat.getTimeInstance(DateFormat.SHORT, locale)
    return formatter.format(Date(millis))
}

@Composable
private fun SyncingRow() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = colors.primary)
        Text(env.s(hcSyncing), style = BadanType.bodyCompact, color = colors.textSecondary)
    }
}

private fun runSync(
    scope: kotlinx.coroutines.CoroutineScope,
    env: net.albayyan.badan.app.AppEnvironment,
    update: (Boolean, LocalizedString?) -> Unit,
) {
    scope.launch {
        update(true, null)
        val summary = env.syncHealthConnect()
        val count = summary?.let { it.samples + it.intervals + it.sessions } ?: 0
        update(false, if (count > 0) imported(count) else hcNoData)
    }
}

private fun openHealthConnectSetup(context: android.content.Context, env: AppEnvironment) {
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata"))
    val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata"))
    val opened = runCatching { context.startActivity(market) }.recoverCatching { context.startActivity(web) }.isSuccess
    if (!opened) {
        Toast.makeText(context, env.s(hcSetupFailed), Toast.LENGTH_SHORT).show()
    }
}

/** Same action Health Connect's own client library resolves internally: the platform's built-in
 *  settings screen on Android 14+, the provider app's own settings before that. */
private fun healthConnectSettingsAction(): String =
    if (android.os.Build.VERSION.SDK_INT >= 34) "android.health.connect.action.HEALTH_HOME_SETTINGS"
    else "androidx.health.ACTION_HEALTH_CONNECT_SETTINGS"

/** Opens Health Connect's own app UI, where a user can manage per-app permissions directly — the
 *  working recovery path once the in-app system prompt stops reappearing after a denial. */
private fun openHealthConnectPermissionSettings(context: android.content.Context, env: AppEnvironment) {
    val opened = runCatching {
        context.startActivity(Intent(healthConnectSettingsAction()))
    }.isSuccess
    if (!opened) {
        Toast.makeText(context, env.s(hcSetupFailed), Toast.LENGTH_SHORT).show()
    }
}
