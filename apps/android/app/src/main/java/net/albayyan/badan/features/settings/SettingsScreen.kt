package net.albayyan.badan.features.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.RestartAlt
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.DepthBadge
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.AppTheme
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.UnitProfileMode

// MARK: - Screen

/**
 * The configuration tree. Every control edits the single [net.albayyan.badan.domain.CustomizationProfile]
 * through `env.update { ... }`, which persists and — because `env.profile` is Compose-observable —
 * re-skins the whole app instantly (language flips RTL, theme flips the colour scheme, depth
 * reveals/hides power affordances). Same one model, presented at two altitudes. Faithful port of
 * the iOS `SettingsScreen`: appearance, language + Arabic numerals, detail level, units (power
 * only), home modules, the sensitive-records gate (turning it off routes through an honest
 * confirm + a real file purge), the data & privacy note with links to Sources and Export, and
 * "Delete all data". A tab screen that owns its own header (there is no shared top bar for tabs).
 *
 * Notifications are absent by design until delivery exists — see [NotificationsSection].
 */
@Composable
fun SettingsScreen() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    var showPurgeConfirm by remember { mutableStateOf(false) }
    var showResetConfirm by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background)
            .verticalScroll(rememberScrollState())
            .padding(BadanSpace.s4),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s6),
    ) {
        Text(
            text = env.s(Loc.settingsTitle),
            style = BadanType.sectionTitle.copy(fontSize = 28.sp),
            color = colors.textPrimary,
        )

        AppearanceSection()
        LanguageSection()
        DetailSection()
        // Units are a power-only affordance — canonical vs. display is meaningless in casual.
        if (env.depth.showsPowerDetail) {
            UnitsSection()
        }
        ModulesSection()
        // Notifications are deliberately not shown on Android — see [NotificationsSection].
        SensitiveSection(onRequestPurge = { showPurgeConfirm = true })
        PrivacySection()
        // EPIC-18: preview & verify a backup file (writing back is not wired yet — see the section).
        BackupRestoreSection()
        DataManagementSection(onRequestReset = { showResetConfirm = true })
    }

    // Purge is a real file deletion (the sensitive store is a separate DB) — confirm honestly.
    if (showPurgeConfirm) {
        ConfirmDialog(
            title = env.s(SettingsStrings.purgeConfirmTitle),
            message = env.s(SettingsStrings.purgeConfirmMessage),
            confirmLabel = env.s(SettingsStrings.purgeConfirmAction),
            onConfirm = {
                showPurgeConfirm = false
                env.update { it.copy(sensitiveModulesEnabled = false) }
                runCatching { env.database.purgeSensitiveNamespace() }
            },
            onDismiss = { showPurgeConfirm = false },
        )
    }
    if (showResetConfirm) {
        ConfirmDialog(
            title = env.s(SettingsStrings.resetConfirmTitle),
            message = env.s(SettingsStrings.resetConfirmMessage(env.isHealthConnected)),
            confirmLabel = env.s(Loc.deleteAllData),
            onConfirm = {
                showResetConfirm = false
                scope.launch { env.resetDemoData() }
            },
            onDismiss = { showResetConfirm = false },
        )
    }
}

// MARK: - Appearance

@Composable
private fun AppearanceSection() {
    val env = LocalAppEnvironment.current
    SettingsSection(title = env.s(Loc.appearance)) {
        SettingsRadioGroup(
            options = AppTheme.entries.toList(),
            title = { it.displayName.resolved(env.language) },
            isSelected = { it == env.profile.theme },
            onSelect = { theme -> env.update { it.copy(theme = theme) } },
        )
    }
}

// MARK: - Language

@Composable
private fun LanguageSection() {
    val env = LocalAppEnvironment.current
    SettingsSection(title = env.s(Loc.language)) {
        SettingsRadioGroup(
            options = AppLanguage.entries.toList(),
            title = { it.displayName },
            isSelected = { it == env.language },
            onSelect = { lang -> env.update { it.copy(language = lang) } },
        )
        BadanCard {
            SettingsToggleRow(
                title = env.s(Loc.arabicDigits),
                subtitle = env.s(SettingsStrings.arabicDigitsHint),
                checked = env.profile.arabicDigits,
                onCheckedChange = { value -> env.update { it.copy(arabicDigits = value) } },
            )
        }
    }
}

// MARK: - Detail level (depth)

@Composable
private fun DetailSection() {
    val env = LocalAppEnvironment.current
    SettingsSection(
        title = env.s(Loc.depthLevel),
        trailing = { DepthBadge(depth = env.depth, language = env.language) },
    ) {
        SettingsRadioGroup(
            options = DepthPolicy.entries.toList(),
            title = { it.displayName.resolved(env.language) },
            subtitle = { SettingsStrings.depthSubtitle(it).resolved(env.language) },
            isSelected = { it == env.depth },
            onSelect = { depth -> env.update { it.copy(depthPolicy = depth) } },
        )
    }
}

// MARK: - Units (power only)

@Composable
private fun UnitsSection() {
    val env = LocalAppEnvironment.current
    SettingsSection(title = env.s(Loc.units)) {
        SettingsRadioGroup(
            options = listOf(UnitProfileMode.DISPLAY, UnitProfileMode.CANONICAL),
            title = { SettingsStrings.unitModeTitle(it).resolved(env.language) },
            subtitle = { SettingsStrings.unitModeSubtitle(it).resolved(env.language) },
            isSelected = { it == env.profile.unitProfile },
            onSelect = { mode -> env.update { it.copy(unitProfile = mode) } },
        )
    }
}

// MARK: - Home modules

@Composable
private fun ModulesSection() {
    val env = LocalAppEnvironment.current
    SettingsSection(title = env.s(Loc.modules)) {
        val modules = env.profile.homeModules.sortedBy { it.order }
        BadanCard {
            modules.forEachIndexed { index, module ->
                SettingsToggleRow(
                    title = env.s(homeModuleLabel(module.id)),
                    subtitle = null,
                    checked = env.profile.module(module.id)?.visible ?: module.visible,
                    onCheckedChange = { value -> setModuleVisible(env, module.id, value) },
                )
                if (index < modules.size - 1) SettingsDivider()
            }
        }
    }
}

// MARK: - Notifications

/**
 * Not called today — see the call site in [SettingsScreen].
 *
 * All four of these toggles were wired to nothing. Android has no notification delivery
 * whatsoever: no scheduler, no channel, no `POST_NOTIFICATIONS` permission, no receiver — a
 * repo-wide search for any of them returns nothing. Each switch persisted a boolean no code
 * reads, under a hint promising "nudges at the times you've scheduled". A user could enable
 * medication reminders, believe their medication would be remembered for them, and never be
 * told otherwise. That is the most harmful shape a dead control can take in a health app.
 *
 * Hidden rather than deleted, following the pattern iOS's `notificationsSection` already
 * demonstrates for its own three unbuilt toggles: the profile fields stay, the UI makes no
 * promise the app cannot keep, and this composable is ready for the day a real scheduler exists.
 * Unhide it only alongside actual delivery — starting with medication reminders, which is the
 * one iOS ships.
 */
@Suppress("UnusedPrivateMember")
@Composable
private fun NotificationsSection() {
    val env = LocalAppEnvironment.current
    SettingsSection(title = env.s(Loc.notifications)) {
        BadanCard {
            SettingsToggleRow(
                title = env.s(SettingsStrings.notifMorning),
                subtitle = env.s(SettingsStrings.notifMorningHint),
                checked = env.profile.notifications.morningNarrative,
                onCheckedChange = { value ->
                    env.update { it.copy(notifications = it.notifications.copy(morningNarrative = value)) }
                },
            )
            SettingsDivider()
            SettingsToggleRow(
                title = env.s(SettingsStrings.notifWeekly),
                subtitle = env.s(SettingsStrings.notifWeeklyHint),
                checked = env.profile.notifications.weeklyDigest,
                onCheckedChange = { value ->
                    env.update { it.copy(notifications = it.notifications.copy(weeklyDigest = value)) }
                },
            )
            SettingsDivider()
            SettingsToggleRow(
                title = env.s(SettingsStrings.notifMeds),
                subtitle = env.s(SettingsStrings.notifMedsHint),
                checked = env.profile.notifications.medicationReminders,
                onCheckedChange = { value ->
                    env.update { it.copy(notifications = it.notifications.copy(medicationReminders = value)) }
                },
            )
            SettingsDivider()
            SettingsToggleRow(
                title = env.s(SettingsStrings.notifPaused),
                subtitle = env.s(SettingsStrings.notifPausedHint),
                checked = env.profile.notifications.dataPausedAlerts,
                onCheckedChange = { value ->
                    env.update { it.copy(notifications = it.notifications.copy(dataPausedAlerts = value)) }
                },
            )
        }
    }
}

// MARK: - Sensitive records (meds & symptoms)

@Composable
private fun SensitiveSection(onRequestPurge: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    SettingsSection(title = env.s(SettingsStrings.sensitiveHeader)) {
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SettingsToggleRow(
                    title = env.s(Loc.includeSensitive),
                    subtitle = env.s(SettingsStrings.sensitiveSubtitle),
                    checked = env.profile.sensitiveModulesEnabled,
                    // Turning ON is immediate; turning OFF routes through a confirm + purge.
                    onCheckedChange = { value ->
                        if (value) env.update { it.copy(sensitiveModulesEnabled = true) }
                        else onRequestPurge()
                    },
                )
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Icon(
                        imageVector = Icons.Filled.WarningAmber,
                        contentDescription = null,
                        tint = colors.outOfBand,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        text = env.s(SettingsStrings.sensitivePurgeNote),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

// MARK: - Data & privacy

@Composable
private fun PrivacySection() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    SettingsSection(title = env.s(Loc.privacy)) {
        BadanCard {
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = Icons.Filled.Security,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(28.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                    Text(
                        text = env.s(Loc.deviceOnly),
                        style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = env.s(Loc.localFirstNote),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                }
            }
        }

        BadanCard {
            SettingsNavRow(icon = Icons.Filled.Sensors, title = env.s(Loc.dataSources)) {
                nav.push(Route.Sources)
            }
            SettingsDivider()
            SettingsNavRow(icon = Icons.Filled.IosShare, title = env.s(Loc.exportTitle)) {
                nav.push(Route.Export)
            }
        }
    }
}

// MARK: - Data management (reset)

@Composable
private fun DataManagementSection(onRequestReset: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard(
        modifier = Modifier
            .clip(RoundedCornerShape(BadanRadius.card))
            .clickable(onClick = onRequestReset),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .defaultMinSize(minHeight = BadanSpace.touchMin),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = Icons.Filled.RestartAlt,
                    contentDescription = null,
                    tint = colors.info,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = env.s(Loc.deleteAllData),
                    style = BadanType.body,
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                // chevron.forward — auto-mirrors under RTL; matches SettingsNavRow's tap affordance.
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(20.dp),
                )
            }
            // Proportionate cue before the tap, matching SensitiveSection's purge-note pattern.
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.WarningAmber,
                    contentDescription = null,
                    tint = colors.outOfBand,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = env.s(SettingsStrings.resetHint),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Section scaffold

/** A titled group: a [SectionHeader] with an optional trailing badge, then its content, spaced. */
@Composable
private fun SettingsSection(
    title: String,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = title, trailing = trailing)
        content()
    }
}

// MARK: - Reusable single-select group (radio rows)

/**
 * A calm list of mutually-exclusive choices inside a single card. Uses a filled check for the
 * selected row and an open circle otherwise — never colour alone — and reads correctly in both
 * LTR and RTL because it relies on start/end layout.
 */
@Composable
private fun <T> SettingsRadioGroup(
    options: List<T>,
    title: (T) -> String,
    isSelected: (T) -> Boolean,
    onSelect: (T) -> Unit,
    subtitle: ((T) -> String)? = null,
) {
    val colors = BadanTheme.colors
    BadanCard {
        options.forEachIndexed { index, option ->
            val selected = isSelected(option)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .clickable { onSelect(option) }
                    .defaultMinSize(minHeight = BadanSpace.touchMin),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Text(
                        text = title(option),
                        style = BadanType.body,
                        color = colors.textPrimary,
                    )
                    val sub = subtitle?.invoke(option)
                    if (!sub.isNullOrEmpty()) {
                        Text(
                            text = sub,
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                    }
                }
                Icon(
                    imageVector = if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                    contentDescription = null,
                    tint = if (selected) colors.primary else colors.textSecondary,
                    modifier = Modifier.size(22.dp),
                )
            }
            if (index < options.size - 1) SettingsDivider()
        }
    }
}

// MARK: - Reusable toggle row

@Composable
private fun SettingsToggleRow(
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
            Text(
                text = title,
                style = BadanType.body,
                color = colors.textPrimary,
            )
            if (!subtitle.isNullOrEmpty()) {
                Text(
                    text = subtitle,
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(checkedTrackColor = colors.primary),
        )
    }
}

// MARK: - Navigation row

@Composable
private fun SettingsNavRow(icon: ImageVector, title: String, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClick = onClick)
            .defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(22.dp),
        )
        Text(
            text = title,
            style = BadanType.body,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        // chevron.forward — auto-mirrors under RTL.
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

// MARK: - Divider

@Composable
private fun SettingsDivider() {
    val colors = BadanTheme.colors
    Box(
        modifier = Modifier
            .padding(vertical = BadanSpace.s1)
            .fillMaxWidth()
            .height(1.dp)
            .background(colors.separator),
    )
}

// MARK: - Confirm dialog

/**
 * A calm two-action confirmation. The confirm action is tinted with the critical colour because
 * both call sites (removing the sensitive store, resetting demo data) are destructive; the app's
 * status colours are never used to moralize, but a genuinely irreversible action earns the honest
 * cue. Cancel is the quiet default.
 */
@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.WarningAmber,
                    contentDescription = null,
                    tint = colors.critical,
                    modifier = Modifier.size(20.dp),
                )
                Text(text = title, style = BadanType.sectionTitle, color = colors.textPrimary)
            }
        },
        text = { Text(text = message, style = BadanType.body, color = colors.textSecondary) },
        confirmButton = {
            Button(
                onClick = onConfirm,
                colors = ButtonDefaults.buttonColors(
                    containerColor = colors.critical,
                    contentColor = colors.onPrimary,
                ),
            ) {
                Text(
                    text = confirmLabel,
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.onPrimary,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(text = env.s(Loc.cancel), style = BadanType.body, color = colors.textSecondary)
            }
        },
        containerColor = colors.surface,
    )
}

// MARK: - Local helpers (non-composable)

private fun setModuleVisible(env: AppEnvironment, id: String, visible: Boolean) {
    env.update { profile ->
        profile.copy(
            homeModules = profile.homeModules.map {
                if (it.id == id) it.copy(visible = visible) else it
            },
        )
    }
}

private fun homeModuleLabel(id: String): LocalizedString = when (id) {
    "readiness" -> Loc.readiness
    "sleep" -> LocalizedString(en = "Sleep", ar = "النوم")
    "activity" -> LocalizedString(en = "Activity", ar = "النشاط")
    "heart" -> LocalizedString(en = "Heart", ar = "القلب")
    "meds" -> Loc.logMedication
    "nutrition" -> LocalizedString(en = "Nutrition", ar = "التغذية")
    "timeline" -> Loc.timeline
    else -> LocalizedString(en = id.replaceFirstChar { it.uppercase() }, ar = id)
}

// MARK: - Strings (screen-local, always bilingual)

private object SettingsStrings {
    val arabicDigitsHint = LocalizedString(
        en = "Show numbers using Arabic-Indic digits.",
        ar = "عرض الأرقام بالصيغة العربية الهندية.",
    )

    val sensitiveHeader = LocalizedString(en = "Sensitive records", ar = "السجلات الحساسة")
    val sensitiveSubtitle = LocalizedString(
        en = "Kept in a separate store on this device.",
        ar = "تُحفظ في مخزن منفصل على هذا الجهاز.",
    )
    val sensitivePurgeNote = LocalizedString(
        en = "Turning this off removes all medication and symptom records from this device.",
        ar = "إيقاف هذا يزيل جميع سجلات الأدوية والأعراض من هذا الجهاز.",
    )

    val purgeConfirmTitle = LocalizedString(
        en = "Turn off and remove meds & symptoms?",
        ar = "إيقاف وإزالة الأدوية والأعراض؟",
    )
    val purgeConfirmMessage = LocalizedString(
        en = "This permanently removes every medication and symptom record from this device.",
        ar = "يزيل هذا نهائياً كل سجلات الأدوية والأعراض من هذا الجهاز.",
    )
    val purgeConfirmAction = LocalizedString(en = "Turn off & remove", ar = "إيقاف وإزالة")

    // (C1) This read "Reset demo data?" / "This restores the sample data set on this device." —
    // which told the user nothing of theirs was at stake. `AppEnvironment.resetDemoData` calls
    // `Database.resetAll()`, which drops every table in BOTH databases first: any medications,
    // symptoms, workouts, nutrition entries or notes they logged are permanently gone, and only
    // afterwards is the sample set re-seeded. A user reading the old copy had every reason to tap
    // it, believing it only touched demo content. iOS renamed this in COMP-09; Android kept the
    // pre-fix wording. This is that port, plus iOS's connected-user branch (C3).
    val resetConfirmTitle = LocalizedString(en = "Delete all data?", ar = "حذف جميع البيانات؟")

    fun resetConfirmMessage(connected: Boolean): LocalizedString {
        val deletes = LocalizedString(
            en = "This permanently deletes everything on this device — including anything you've " +
                "logged yourself.",
            ar = "يؤدي هذا إلى حذف كل شيء على هذا الجهاز نهائياً — بما في ذلك كل ما سجّلته بنفسك.",
        )
        val after = if (connected) {
            LocalizedString(
                en = " Your measurements are then read again from Health Connect. Anything Health " +
                    "Connect doesn't have — your own logs — won't come back.",
                ar = " ثم تُقرأ قياساتك مجدداً من Health Connect. أما ما ليس لديه — أي سجلاتك " +
                    "الخاصة — فلن يعود.",
            )
        } else {
            LocalizedString(
                en = " It's then replaced with the bundled sample data set.",
                ar = " ثم يُستبدل بمجموعة البيانات التجريبية المرفقة.",
            )
        }
        val undo = LocalizedString(en = " This can't be undone.", ar = " لا يمكن التراجع عن هذا.")
        return LocalizedString(en = deletes.en + after.en + undo.en, ar = deletes.ar + after.ar + undo.ar)
    }
    val resetHint = LocalizedString(
        en = "Replaces current data on this device with the sample set.",
        ar = "يستبدل البيانات الحالية على هذا الجهاز بمجموعة البيانات التجريبية.",
    )

    val notifMorning = LocalizedString(en = "Morning summary", ar = "ملخّص الصباح")
    val notifMorningHint = LocalizedString(
        en = "A calm recap of the night and the day ahead.",
        ar = "ملخّص هادئ لليلة واليوم القادم.",
    )
    val notifWeekly = LocalizedString(en = "Weekly digest", ar = "الملخّص الأسبوعي")
    val notifWeeklyHint = LocalizedString(
        en = "A summary of trends across the past week.",
        ar = "ملخّص للاتجاهات خلال الأسبوع الماضي.",
    )
    val notifMeds = LocalizedString(en = "Medication reminders", ar = "تذكيرات الأدوية")
    val notifMedsHint = LocalizedString(
        en = "Nudges at the times you've scheduled for each medication.",
        ar = "تنبيهات في الأوقات التي حدّدتها لكل دواء.",
    )
    val notifPaused = LocalizedString(en = "Data-paused reminders", ar = "تذكيرات توقّف البيانات")
    val notifPausedHint = LocalizedString(
        en = "Nudge me if no data has synced in a while.",
        ar = "نبّهني إذا لم تتم مزامنة أي بيانات لفترة.",
    )

    fun depthSubtitle(depth: DepthPolicy): LocalizedString = when (depth) {
        DepthPolicy.CASUAL -> LocalizedString(en = "Calm and minimal.", ar = "هادئ ومبسّط.")
        DepthPolicy.BALANCED -> LocalizedString(en = "A little more context.", ar = "سياق أكثر قليلاً.")
        DepthPolicy.POWER -> LocalizedString(
            en = "Raw values, lineage and tables.",
            ar = "القيم الخام والمصدر والجداول.",
        )
    }

    fun unitModeTitle(mode: UnitProfileMode): LocalizedString = when (mode) {
        UnitProfileMode.DISPLAY -> LocalizedString(en = "My display units", ar = "وحداتي المعروضة")
        UnitProfileMode.CANONICAL -> LocalizedString(en = "Original units", ar = "الوحدات الأصلية")
    }

    fun unitModeSubtitle(mode: UnitProfileMode): LocalizedString = when (mode) {
        UnitProfileMode.DISPLAY -> LocalizedString(
            en = "Convert to the units you prefer.",
            ar = "تحويل إلى الوحدات التي تفضّلها.",
        )
        UnitProfileMode.CANONICAL -> LocalizedString(
            en = "Show source units, unchanged.",
            ar = "عرض وحدات المصدر كما هي دون تغيير.",
        )
    }
}
