package net.albayyan.badan.features.settings

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.export.BackupBundle

/**
 * EPIC-18 — the Android backup & restore settings surface (mirror of iOS
 * `BackupRestoreSettingsScreen`'s restore section + `BackupRestorePreviewScreen`).
 *
 * Previewing a backup — reading it, verifying its per-file SHA-256 and schema version, and showing
 * exactly what it holds — is built and lives behind this section. Writing the records back into the
 * store is a separate, destructive step that goes through the `import_batches` staged-import
 * machinery (preview + batch undo), which is not wired on-device yet. Rather than a control that
 * would silently do nothing, the preview dialog states the true thing.
 *
 * A backup made by a newer version of BADAN is refused outright rather than imported in part, an
 * encrypted backup asks for its passphrase, and a backup carrying meds/symptoms surfaces that fact —
 * the sensitive class stays independently gated (I7). Everything here is offline and self-contained.
 */
@Composable
fun BackupRestoreSection() {
    val env = LocalAppEnvironment.current
    val context = LocalContext.current
    val colors = BadanTheme.colors

    var dialog by remember { mutableStateOf<RestoreDialog?>(null) }
    var pickedBytes by remember { mutableStateOf<ByteArray?>(null) }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val bytes = runCatching {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        }.getOrNull()
        if (bytes == null) {
            dialog = RestoreDialog.Failed(Loc.unreadable)
            return@rememberLauncherForActivityResult
        }
        pickedBytes = bytes
        dialog = if (BackupBundle.isEncryptedContainer(bytes)) RestoreDialog.Locked(wrongAttempt = false)
                 else parse(bytes, null)
    }

    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(Loc.header))
        Text(env.s(Loc.blurb), style = BadanType.caption, color = colors.textSecondary)
        BadanCard(padding = 0.dp) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { launcher.launch(arrayOf("application/json", "application/octet-stream", "*/*")) }
                    .defaultMinSize(minHeight = BadanSpace.touchMin)
                    .padding(horizontal = BadanSpace.s4, vertical = BadanSpace.s3),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(env.s(Loc.choose), style = BadanType.body, color = colors.textPrimary,
                    modifier = Modifier.weight(1f))
            }
        }
    }

    when (val d = dialog) {
        null -> Unit
        is RestoreDialog.Locked -> PassphraseDialog(
            wrongAttempt = d.wrongAttempt,
            onUnlock = { pass -> dialog = parse(pickedBytes ?: ByteArray(0), pass) },
            onDismiss = { dialog = null },
        )
        is RestoreDialog.Loaded -> PreviewDialog(d.preview) { dialog = null }
        is RestoreDialog.Failed -> FailedDialog(env.s(d.message)) { dialog = null }
    }
}

private sealed interface RestoreDialog {
    data class Locked(val wrongAttempt: Boolean) : RestoreDialog
    data class Loaded(val preview: BackupBundle.RestorePreview) : RestoreDialog
    data class Failed(val message: LocalizedString) : RestoreDialog
}

/** Parse + map failures to a dialog state. Mirror of iOS `BackupRestorePreviewScreen.load`. */
private fun parse(bytes: ByteArray, passphrase: String?): RestoreDialog =
    try {
        RestoreDialog.Loaded(BackupBundle.preview(BackupBundle.parse(bytes, passphrase)))
    } catch (e: BackupBundle.RestoreException.Encrypted) {
        RestoreDialog.Locked(wrongAttempt = true)
    } catch (e: BackupBundle.RestoreException.SchemaTooNew) {
        RestoreDialog.Failed(Loc.schemaTooNew)
    } catch (e: BackupBundle.RestoreException.ChecksumMismatch) {
        RestoreDialog.Failed(Loc.checksumMismatch)
    } catch (e: BackupBundle.RestoreException.KdfCostTooHigh) {
        RestoreDialog.Failed(Loc.kdfCostTooHigh)
    } catch (e: BackupBundle.RestoreException.NotABackup) {
        RestoreDialog.Failed(Loc.notABackup)
    } catch (e: BackupBundle.RestoreException) {
        RestoreDialog.Failed(Loc.malformed)
    }

@Composable
private fun PassphraseDialog(wrongAttempt: Boolean, onUnlock: (String) -> Unit, onDismiss: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    var passphrase by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(env.s(Loc.encryptedHeader), style = BadanType.sectionTitle) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                Text(env.s(Loc.encryptedBlurb), style = BadanType.caption, color = colors.textSecondary)
                OutlinedTextField(
                    value = passphrase,
                    onValueChange = { passphrase = it },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions.Default,
                    label = { Text(env.s(Loc.passphrase)) },
                )
                if (wrongAttempt) {
                    Text(env.s(Loc.wrongPassphrase), style = BadanType.caption, color = colors.critical)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onUnlock(passphrase) }, enabled = passphrase.isNotEmpty()) {
                Text(env.s(Loc.unlock))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(env.s(Loc.cancel)) } },
    )
}

@Composable
private fun PreviewDialog(preview: BackupBundle.RestorePreview, onDismiss: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(env.s(Loc.previewTitle), style = BadanType.sectionTitle) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                InfoRow(env.s(Loc.origin), "${preview.originPlatform} · ${preview.originAppVersion}")
                InfoRow(env.s(Loc.protection),
                    env.s(if (preview.encrypted) Loc.encrypted else Loc.plaintext))
                InfoRow(env.s(Loc.formatVersion), preview.schemaVersion)
                Spacer(Modifier.defaultMinSize(minHeight = BadanSpace.s2))
                val rows = namespaceLabels.mapNotNull { (key, label) ->
                    val count = preview.namespaceCounts[key] ?: 0
                    if (count > 0) env.s(label) to env.format.integer(count) else null
                }
                if (rows.isEmpty()) {
                    Text(env.s(Loc.noRecords), style = BadanType.caption, color = colors.textSecondary)
                } else {
                    rows.forEach { (label, value) -> InfoRow(label, value) }
                }
                val templates = preview.configCounts["export_templates"] ?: 0
                if (templates > 0) InfoRow(env.s(Loc.templates), env.format.integer(templates))
                if (preview.sensitivePresent) {
                    Spacer(Modifier.defaultMinSize(minHeight = BadanSpace.s2))
                    Text(env.s(Loc.sensitiveBlurb), style = BadanType.caption, color = colors.textSecondary)
                }
                Spacer(Modifier.defaultMinSize(minHeight = BadanSpace.s2))
                // The honest statement: previewing is built; writing back is not.
                Text(env.s(Loc.applyNotice), style = BadanType.caption, color = colors.textSecondary)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text(env.s(Loc.done)) } },
    )
}

@Composable
private fun FailedDialog(message: String, onDismiss: () -> Unit) {
    val env = LocalAppEnvironment.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(env.s(Loc.cantRead), style = BadanType.sectionTitle) },
        text = { Text(message, style = BadanType.body, color = BadanTheme.colors.textPrimary) },
        confirmButton = { TextButton(onClick = onDismiss) { Text(env.s(Loc.done)) } },
    )
}

@Composable
private fun InfoRow(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = BadanType.caption, color = colors.textSecondary, modifier = Modifier.weight(1f))
        Text(value, style = BadanType.body, color = colors.textPrimary)
    }
}

private val namespaceLabels: List<Pair<String, LocalizedString>> = listOf(
    "raw_samples" to LocalizedString(en = "Measurements", ar = "القياسات"),
    "interval_records" to LocalizedString(en = "Daily aggregates", ar = "التجميعات اليومية"),
    "sessions" to LocalizedString(en = "Sleep sessions", ar = "جلسات النوم"),
    "workouts" to LocalizedString(en = "Workouts", ar = "التمارين"),
    "derived_values" to LocalizedString(en = "Computed values", ar = "القيم المحسوبة"),
    "baselines" to LocalizedString(en = "Baselines", ar = "خطوط الأساس"),
    "logs.symptoms" to LocalizedString(en = "Symptom logs", ar = "سجلات الأعراض"),
    "logs.adherence" to LocalizedString(en = "Medication logs", ar = "سجلات الأدوية"),
    "logs.nutrition" to LocalizedString(en = "Nutrition logs", ar = "سجلات التغذية"),
    "logs.hydration" to LocalizedString(en = "Hydration logs", ar = "سجلات الترطيب"),
)

private object Loc {
    val header = LocalizedString(en = "Backup & restore", ar = "النسخ والاستعادة")
    val blurb = LocalizedString(
        en = "Pick a BADAN backup to check it and see exactly what it holds — records, saved "
            + "templates, and whether it's encrypted. BADAN verifies the file first, and refuses one "
            + "made by a newer version rather than importing it in part.",
        ar = "اختر نسخة احتياطية من بدن لفحصها ورؤية ما تحتويه تماماً — السجلات والقوالب المحفوظة "
            + "وما إذا كانت مشفّرة. يتحقق بدن من الملف أولاً، ويرفض نسخة أنشأها إصدار أحدث بدل استيرادها جزئياً.")
    val choose = LocalizedString(en = "Preview a backup file", ar = "معاينة ملف نسخة احتياطية")
    val previewTitle = LocalizedString(en = "Backup preview", ar = "معاينة النسخة الاحتياطية")
    val origin = LocalizedString(en = "From", ar = "من")
    val protection = LocalizedString(en = "Protection", ar = "الحماية")
    val encrypted = LocalizedString(en = "Encrypted", ar = "مشفّرة")
    val plaintext = LocalizedString(en = "Plain (unencrypted)", ar = "غير مشفّرة")
    val formatVersion = LocalizedString(en = "Format version", ar = "إصدار التنسيق")
    val templates = LocalizedString(en = "Saved export templates", ar = "قوالب التصدير المحفوظة")
    val noRecords = LocalizedString(en = "This backup carries configuration only — no health records.",
        ar = "تحمل هذه النسخة الإعدادات فقط — دون سجلات صحية.")
    val sensitiveBlurb = LocalizedString(
        en = "This backup contains medication and symptom records. Restoring them would be a separate "
            + "choice, each time — a backup is never permission to write them back.",
        ar = "تحتوي هذه النسخة على سجلات أدوية وأعراض. استعادتها قرار منفصل في كل مرة — والنسخة "
            + "الاحتياطية ليست إذناً بإعادة كتابتها.")
    val applyNotice = LocalizedString(
        en = "Writing this backup back into BADAN isn't available in this version. Previewing and "
            + "verifying a backup are.",
        ar = "إعادة كتابة هذه النسخة إلى بدن غير متاحة في هذا الإصدار. أما معاينة النسخة والتحقق منها فمتاحتان.")
    val encryptedHeader = LocalizedString(en = "Encrypted backup", ar = "نسخة مشفّرة")
    val encryptedBlurb = LocalizedString(
        en = "This backup is locked. Enter the passphrase it was created with to read what's inside.",
        ar = "هذه النسخة مقفلة. أدخل عبارة المرور التي أُنشئت بها لقراءة محتواها.")
    val passphrase = LocalizedString(en = "Passphrase", ar = "عبارة المرور")
    val unlock = LocalizedString(en = "Unlock", ar = "فتح")
    val cancel = LocalizedString(en = "Cancel", ar = "إلغاء")
    val done = LocalizedString(en = "Done", ar = "تم")
    val cantRead = LocalizedString(en = "Couldn't read this backup", ar = "تعذّرت قراءة هذه النسخة")
    val wrongPassphrase = LocalizedString(
        en = "That passphrase didn't open it — or the file was altered.",
        ar = "لم تفتحها عبارة المرور هذه — أو أن الملف قد عُدِّل.")
    val unreadable = LocalizedString(
        en = "This file couldn't be read. It may have moved, or access was not granted.",
        ar = "تعذّرت قراءة هذا الملف. ربما نُقل، أو لم يُمنح الوصول إليه.")
    val schemaTooNew = LocalizedString(
        en = "This backup was made by a newer version of BADAN than the one on this device. To keep "
            + "your data safe, it is not imported at all rather than partly. Update BADAN, then try again.",
        ar = "أُنشئت هذه النسخة بإصدار من بدن أحدث من الموجود على هذا الجهاز. حفاظاً على بياناتك، لا "
            + "تُستورد إطلاقاً بدل أن تُستورد جزئياً. حدِّث بدن ثم أعد المحاولة.")
    val checksumMismatch = LocalizedString(
        en = "This backup appears altered or incomplete — its contents don't match its own checksums. "
            + "It was not imported.",
        ar = "يبدو أن هذه النسخة عُدِّلت أو أنها ناقصة — محتواها لا يطابق بصماتها. لم تُستورد.")
    val kdfCostTooHigh = LocalizedString(
        en = "This backup asks for an unusually expensive unlock and was refused as a precaution.",
        ar = "تطلب هذه النسخة فتحاً مكلفاً بشكل غير معتاد وقد رُفضت احترازاً.")
    val notABackup = LocalizedString(en = "This isn't a BADAN backup file.",
        ar = "هذا ليس ملف نسخة احتياطية من بدن.")
    val malformed = LocalizedString(en = "This backup file is damaged and couldn't be read.",
        ar = "ملف النسخة الاحتياطية هذا تالف وتعذّرت قراءته.")
}
