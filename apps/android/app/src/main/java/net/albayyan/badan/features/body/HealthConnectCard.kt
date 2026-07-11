package net.albayyan.badan.features.body

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.platform.health.HealthAvailability
import net.albayyan.badan.platform.health.HealthConnectAdapter

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

    val availability = remember { env.healthConnect.availability() }
    var granted by remember { mutableStateOf<Boolean?>(null) }
    var syncing by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<LocalizedString?>(null) }

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
                        message?.let { BodyText(env.s(it), colors.textSecondary) }
                        if (syncing) SyncingRow() else OutlinedButton(onClick = { runSync(scope, env) { s, m -> syncing = s; message = m } }) {
                            Text(env.s(hcSyncNow))
                        }
                    } else {
                        BodyText(env.s(hcConnectBody), colors.textSecondary)
                        message?.let { BodyText(env.s(it), colors.outOfBand) }
                        if (syncing) SyncingRow() else Button(onClick = { permissionLauncher.launch(HealthConnectAdapter.permissions) }) {
                            Text(env.s(hcConnect))
                        }
                    }
                }
                HealthAvailability.notInstalled -> {
                    BodyText(env.s(hcUpdateBody), colors.textSecondary)
                    Button(onClick = { openHealthConnectSetup(context) }) { Text(env.s(hcUpdate)) }
                }
                HealthAvailability.unsupported -> {
                    BodyText(env.s(hcUnsupported), colors.textSecondary)
                }
            }
        }
    }
}

@Composable
private fun BodyText(text: String, color: androidx.compose.ui.graphics.Color) {
    Text(text = text, style = BadanType.bodyCompact, color = color)
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

private fun openHealthConnectSetup(context: android.content.Context) {
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata"))
    val web = Intent(Intent.ACTION_VIEW, Uri.parse("https://play.google.com/store/apps/details?id=com.google.android.apps.healthdata"))
    runCatching { context.startActivity(market) }.recoverCatching { context.startActivity(web) }
}
