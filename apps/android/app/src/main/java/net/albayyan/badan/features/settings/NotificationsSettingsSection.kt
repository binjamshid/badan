package net.albayyan.badan.features.settings

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.NotificationQuietHours
import net.albayyan.badan.platform.notifications.NotificationClass
import net.albayyan.badan.platform.notifications.NotificationClassCopy

/**
 * EPIC-32 — Settings → "Summaries & reminders". The Android mirror of iOS's
 * `NotificationsSettingsScreen` summaries section: every budgeted notification class, individually
 * opt-in and shipping OFF (the existing convention), plus the shared quiet-hours window.
 *
 * Three things this surface is careful to say honestly rather than imply:
 *
 *  1. **The ≤2/day budget is a ceiling, not a setting.** It is stated
 *     ([NotificationClassCopy.dailyBudgetNote]) and there is no control to raise it — the whole
 *     point of the budget is to protect the user from notification fatigue, so exposing it as a
 *     preference would defeat it.
 *  2. **Timed delivery is best-effort.** WorkManager's delay is a minimum and Doze can push a wake
 *     later, so the section says so (plan §4 rule 10) instead of implying a wall-clock promise.
 *  3. **Android delivers no medication reminders.** iOS has a med-reminder scheduler and EPIC-32
 *     extends it; Android has none (standing parity debt), so there is no medication toggle here
 *     and the absence is explained rather than left as a mystery.
 *
 * Turning a class on is what requests `POST_NOTIFICATIONS` — a contextual, explicit user action,
 * never something the app asks for at launch. A denial leaves the class OFF (the switch visibly
 * reverts, since it reads the persisted value) and says why; it never re-prompts, because Android
 * stops showing the dialog after two refusals and a toggle that silently does nothing would be the
 * exact failure this section exists to prevent.
 */
@Composable
fun NotificationsSettingsSection() {
    val env = LocalAppEnvironment.current

    // Whether BADAN may actually post right now (permission granted AND notifications not switched
    // off for the app). Re-read on every resume, because the user can change either in system
    // settings while the app is backgrounded and nothing calls back into the app when they do.
    var canPost by remember { mutableStateOf(env.notificationScheduler.canPost()) }
    var permissionRefused by remember { mutableStateOf(false) }
    // The class whose toggle triggered the permission prompt, applied only on a grant.
    var awaitingPermissionFor by remember { mutableStateOf<NotificationClass?>(null) }

    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                canPost = env.notificationScheduler.canPost()
                if (canPost) permissionRefused = false
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val cls = awaitingPermissionFor
        awaitingPermissionFor = null
        canPost = env.notificationScheduler.canPost()
        if (granted && canPost && cls != null) {
            env.setNotificationClassEnabled(cls, true)
        } else {
            // Nothing is persisted on a refusal: the class stays off, so the switch reverts and the
            // app never claims an opt-in it cannot honour.
            permissionRefused = true
        }
    }

    /**
     * Turning a class on: ask for permission first when it is missing, and only persist the opt-in
     * once BADAN can actually post. Turning off always persists immediately — the user can always
     * withdraw consent, permission state or not.
     */
    fun setEnabled(cls: NotificationClass, enabled: Boolean) {
        if (!enabled) {
            env.setNotificationClassEnabled(cls, false)
            return
        }
        if (canPost) {
            permissionRefused = false
            env.setNotificationClassEnabled(cls, true)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            awaitingPermissionFor = cls
            permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            // Below API 33 there is no runtime permission to request — notifications are off for
            // BADAN in system settings, which only the user can undo. Say so instead of toggling.
            permissionRefused = true
        }
    }

    val anyOn = NotificationClass.userFacing.any { env.isNotificationClassEnabled(it) }

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(NotificationClassCopy.sectionHeader))
        BadanCard {
            NotificationClass.userFacing.forEachIndexed { index, cls ->
                val (label, hint) = NotificationClassCopy.settingsRow(cls)
                NotificationToggleRow(
                    title = env.s(label),
                    subtitle = env.s(hint),
                    checked = env.isNotificationClassEnabled(cls),
                    onCheckedChange = { setEnabled(cls, it) },
                )
                if (index < NotificationClass.userFacing.lastIndex) NotificationDivider()
            }

            if (anyOn) {
                NotificationDivider()
                QuietHoursRow(
                    quietHours = env.profile.notifications.quietHours,
                    onChange = { env.setNotificationQuietHours(it) },
                )
                NotificationNote(env.s(NotificationClassCopy.dailyBudgetNote(env.profile.arabicDigits)))
                NotificationNote(env.s(NotificationClassCopy.schedulingHonestyNote))
            }

            if (!canPost) {
                NotificationDivider()
                NotificationNote(
                    text = env.s(
                        if (permissionRefused) NotificationClassCopy.permissionDeniedNote
                        else NotificationClassCopy.systemOffNote,
                    ),
                    warning = true,
                )
            }

            NotificationDivider()
            NotificationNote(env.s(NotificationClassCopy.medsNotOnAndroidNote))
        }
    }
}

// MARK: - Quiet hours

/**
 * The shared quiet-hours window, as two hour menus. Hour granularity (not minutes) because that is
 * the granularity the preference is stored and evaluated at — offering minutes would imply a
 * precision the engine does not honour. `from` is inclusive and `to` exclusive; picking the same
 * hour for both means "no quiet hours", which is what the engine does with a collapsed window.
 */
@Composable
private fun QuietHoursRow(
    quietHours: NotificationQuietHours,
    onChange: (NotificationQuietHours) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
        Text(env.s(QuietCopy.title), style = BadanType.body, color = colors.textPrimary)
        Text(env.s(QuietCopy.hint), style = BadanType.caption, color = colors.textSecondary)
        Row(
            modifier = Modifier.padding(top = BadanSpace.s1),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s4),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HourMenu(
                label = env.s(QuietCopy.from),
                hour = quietHours.startHour,
                onPick = { onChange(quietHours.copy(startHour = it)) },
            )
            HourMenu(
                label = env.s(QuietCopy.to),
                hour = quietHours.endHour,
                onPick = { onChange(quietHours.copy(endHour = it)) },
            )
        }
    }
}

@Composable
private fun HourMenu(label: String, hour: Int, onPick: (Int) -> Unit) {
    val colors = BadanTheme.colors
    var expanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(label, style = BadanType.caption, color = colors.textSecondary)
        Box {
            Text(
                text = hourLabel(hour),
                style = BadanType.body,
                color = colors.primary,
                modifier = Modifier
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .clickable { expanded = true }
                    .defaultMinSize(minHeight = BadanSpace.touchMin)
                    .padding(horizontal = BadanSpace.s3, vertical = BadanSpace.s2),
            )
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                for (h in 0..23) {
                    DropdownMenuItem(
                        text = { Text(hourLabel(h)) },
                        onClick = { expanded = false; onPick(h) },
                    )
                }
            }
        }
    }
}

/**
 * Hours are rendered as a fixed 24-hour `HH:00` label in Latin digits in both languages: this is a
 * schedule boundary the user is picking, and the app's Arabic-numeral preference applies to
 * measured values, not to a menu of clock hours.
 */
private fun hourLabel(hour: Int): String = "%02d:00".format(hour)

// MARK: - Local components
//
// `SettingsScreen`'s own toggle/divider/note composables are private to that file. Re-declared here
// (rather than widening their visibility) so this section can live in its own file without editing
// a file three other epics are also touching; they render identically.

@Composable
private fun NotificationToggleRow(
    title: String,
    subtitle: String?,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(text = title, style = BadanType.body, color = colors.textPrimary)
            if (!subtitle.isNullOrEmpty()) {
                Text(text = subtitle, style = BadanType.caption, color = colors.textSecondary)
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
        )
    }
}

@Composable
private fun NotificationDivider() {
    val colors = BadanTheme.colors
    Box(
        modifier = Modifier
            .padding(vertical = BadanSpace.s1)
            .fillMaxWidth()
            .height(1.dp)
            .background(colors.separator),
    )
}

@Composable
private fun NotificationNote(text: String, warning: Boolean = false) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth().padding(top = BadanSpace.s1),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        if (warning) {
            Icon(
                imageVector = Icons.Filled.NotificationsOff,
                contentDescription = null,
                tint = colors.outOfBand,
                modifier = Modifier.size(16.dp),
            )
        }
        Text(text = text, style = BadanType.caption, color = colors.textSecondary)
    }
}

// MARK: - Copy

/**
 * Quiet-hours copy, byte-identical to iOS `SettingsStrings.notifQuietHours` / `notifQuietHoursHint`
 * / `notifQuietFrom` / `notifQuietTo`. Kept beside this section rather than in the shared
 * `SettingsStrings` object because nothing else on Android uses it.
 */
private object QuietCopy {
    val title = LocalizedString(en = "Quiet hours", ar = "ساعات الهدوء")
    val hint = LocalizedString(
        en = "These notifications are held during this window.",
        ar = "تُحجب هذه الإشعارات خلال هذه الفترة.",
    )
    val from = LocalizedString(en = "From", ar = "من")
    val to = LocalizedString(en = "To", ar = "إلى")
}
