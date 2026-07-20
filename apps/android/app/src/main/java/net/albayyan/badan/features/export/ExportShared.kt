package net.albayyan.badan.features.export

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.StatBox
import net.albayyan.badan.domain.ExportDestination
import net.albayyan.badan.domain.ExportErrorCode
import net.albayyan.badan.domain.ExportErrorDetail
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportJob
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportRun
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportStage
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.export.ExportRunException
import net.albayyan.badan.export.ExportRunner
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

// MARK: - Copy
//
// Screen-local bilingual strings shared by every export surface. Every string carries both
// languages (a `LocalizedString` cannot be built without both), so no export screen can ship
// English-only. Mirror of the iOS `ExportCopy`, extended for the EPIC-10/11/09/16 surfaces.

internal object ExportCopy {
    val onDeviceOnly = LocalizedString(en = "On this device — no network", ar = "على هذا الجهاز — دون شبكة")
    val formatCSVSubtitle = LocalizedString(
        en = "Spreadsheet-friendly. Raw and computed rows in separate files.",
        ar = "مناسب لجداول البيانات. صفوف خام ومحسوبة في ملفات منفصلة.",
    )
    val formatJSONSubtitle = LocalizedString(
        en = "One structured file with everything and its manifest.",
        ar = "ملف واحد منظّم يضم كل شيء مع بيانه.",
    )

    val includeRawSubtitle = LocalizedString(
        en = "Measured records straight from your sources.",
        ar = "سجلات مُقاسة مباشرة من مصادرك.",
    )
    val includeDerivedSubtitle = LocalizedString(
        en = "Baselines and scores BADAN computed for you.",
        ar = "المستويات المعتادة والدرجات التي حسبها بدن.",
    )
    val includeSuppressedSubtitle = LocalizedString(
        en = "Duplicate readings that were quietly set aside.",
        ar = "قراءات مكرّرة تم وضعها جانباً بهدوء.",
    )
    val includeSensitiveSubtitle = LocalizedString(
        en = "Your private medication and symptom logs.",
        ar = "سجلات أدويتك وأعراضك الخاصة.",
    )
    val sensitiveNote = LocalizedString(
        en = "This export will contain your medications and symptoms. Keep the file somewhere private.",
        ar = "سيتضمّن هذا التصدير أدويتك وأعراضك. احتفظ بالملف في مكان خاص.",
    )
    val sensitiveModuleDisabledNote = LocalizedString(
        en = "Turn on Sensitive records in Settings to include this.",
        ar = "فعّل السجلات الحساسة في الإعدادات لتضمين هذا.",
    )

    val dateRange = LocalizedString(en = "Date range", ar = "النطاق الزمني")
    val unitSource = LocalizedString(en = "Source units", ar = "وحدات المصدر")
    val unitDisplay = LocalizedString(en = "My units", ar = "وحداتي")
    val unitNote = LocalizedString(
        en = "Source units keep the original SI values; my units convert to your chosen display units. Canonical columns are always preserved either way.",
        ar = "وحدات المصدر تُبقي قيم SI الأصلية؛ ووحداتي تُحوّل إلى وحدات العرض التي اخترتها. تُحفظ الأعمدة القياسية في الحالتين.",
    )

    val preparing = LocalizedString(en = "Preparing your export…", ar = "جارٍ تجهيز تصديرك…")
    val exportReady = LocalizedString(en = "Export ready", ar = "التصدير جاهز")
    val records = LocalizedString(en = "Records", ar = "السجلات")
    val recordsInline = LocalizedString(en = "records", ar = "سجل")
    val files = LocalizedString(en = "Files", ar = "الملفات")
    val checksums = LocalizedString(en = "Checksums (SHA-256)", ar = "بصمات التحقق (SHA-256)")

    val manifest = LocalizedString(en = "Manifest", ar = "البيان")
    val schema = LocalizedString(en = "Schema", ar = "المخطط")
    val generated = LocalizedString(en = "Generated", ar = "أُنشئ")
    val rangeField = LocalizedString(en = "Range", ar = "النطاق")
    val exportId = LocalizedString(en = "Export ID", ar = "معرّف التصدير")
    val rowsPerMetric = LocalizedString(en = "Rows per metric", ar = "الصفوف لكل مؤشر")

    val history = LocalizedString(en = "Previous exports", ar = "التصديرات السابقة")
    val noHistory = LocalizedString(
        en = "No exports yet — create your first above.",
        ar = "لا توجد تصديرات بعد — أنشئ أول تصدير أعلاه.",
    )
    val loadMoreHistory = LocalizedString(en = "Load more", ar = "تحميل المزيد")
    val filesUnavailable = LocalizedString(
        en = "Files no longer available",
        ar = "الملفات لم تعد متوفرة",
    )

    val scopeIncludes = LocalizedString(en = "Includes:", ar = "يتضمّن:")
    val scopeExcludes = LocalizedString(en = "Excludes:", ar = "يستبعد:")

    val copied = LocalizedString(en = "Copied", ar = "تم النسخ")

    val couldntPrepare = LocalizedString(
        en = "That export couldn't be prepared. Nothing left your device.",
        ar = "تعذّر تجهيز هذا التصدير. لم يغادر شيء جهازك.",
    )
}

/**
 * The offered windows for the advanced builder. Maps to [ExportScope.startDate]/[endDate];
 * "all time" leaves both open and "custom" reads two user-picked dates instead of a fixed offset.
 * Quick Export does not use this — it works directly off [net.albayyan.badan.domain.QuickExportPreset]'s
 * fixed Last 7 / Last 30 / All time set (EPIC-10). Mirror of the iOS `ExportRange`. Epoch is millis
 * on Android, so fixed windows count in milliseconds.
 */
internal enum class ExportRange {
    LAST30, LAST90, ALL, CUSTOM;

    fun startDate(now: Long): Long? = when (this) {
        LAST30 -> now - 30L * MILLIS_PER_DAY
        LAST90 -> now - 90L * MILLIS_PER_DAY
        ALL, CUSTOM -> null
    }

    fun label(format: ValueFormatter): LocalizedString = when (this) {
        LAST30 -> {
            val n = format.integer(30)
            LocalizedString(en = "Last $n days", ar = "آخر $n يوماً")
        }
        LAST90 -> {
            val n = format.integer(90)
            LocalizedString(en = "Last $n days", ar = "آخر $n يوماً")
        }
        ALL -> LocalizedString(en = "All time", ar = "كل الوقت")
        CUSTOM -> LocalizedString(en = "Custom", ar = "مخصص")
    }

    companion object {
        private const val MILLIS_PER_DAY = 86_400_000L
    }
}

/** History page size and matching on-run retention window for the on-disk export folders. */
internal const val HISTORY_PAGE_SIZE = 20
private const val EXPORT_RETENTION_DAYS = 30L
private const val EXPORT_RETENTION_MILLIS = EXPORT_RETENTION_DAYS * 24 * 60 * 60 * 1000

// MARK: - Run orchestration (the ledger seam)

/**
 * Run an export through [ExportRunner] — the one and only run entry point — and append the matching
 * [ExportRun] ledger row.
 *
 * This is the seam EPIC-16 is built on and the entire anti-HAE thesis in one function: a run that
 * fails leaves a row saying it failed, so the Export Health dashboard can always answer "did my
 * export actually happen?". Phase 0 shipped the `export_runs` table and its repository but no
 * caller ever wrote to it; every Compose export surface now goes through here so the ledger is
 * populated the day the surfaces land, not the day a scheduler does (EPIC-15, later).
 *
 * Deliberately conservative about what it records: [ExportRunner.ExportResult] gives a *total*
 * record count, not the per-class breakdown [ExportRowCounts] wants, and inventing one here would
 * be a value the runner never actually reported — so `rowCounts` is left null rather than faked.
 * `bytesWritten` is summed from the files that exist, which is real. `manifestSha256` is likewise
 * left null: there is no manifest-of-manifest digest without reaching into the runner, and a made-up
 * one would defeat the chain-verification the field exists for.
 *
 * Runs on the caller's dispatcher — call it inside `withContext(Dispatchers.IO)`, as the runner's
 * gather/write path is synchronous and must never touch the main thread on a large "all time" run.
 */
internal suspend fun runAndRecordExport(
    env: AppEnvironment,
    scope: ExportScope,
    format: ExportFormat,
    templateId: String?,
    outputDir: File,
    passphrase: String? = null,
    trigger: ExportTrigger = ExportTrigger.MANUAL,
): ExportRunner.ExportResult {
    val startedAt = env.now()
    try {
        val result = env.exporter.run(scope = scope, format = format, outputDir = outputDir, passphrase = passphrase)
        val bytes = result.files.filter { it.exists() }.sumOf { it.length() }
        // A ledger-write failure must never make a successful export look failed to the user — the
        // file is already on disk. Swallow it (the run just won't appear in Export Health) rather
        // than surface a scary error after the export plainly worked.
        runCatching {
            env.exportRuns.insert(
                ExportRun(
                    id = Ulid.newId(),
                    templateId = templateId,
                    jobId = result.job.id,
                    trigger = trigger,
                    startedAt = startedAt,
                    finishedAt = env.now(),
                    outcome = ExportOutcome.SUCCESS,
                    bytesWritten = bytes,
                    destinationId = ExportDestination.SHARE_SHEET_ID,
                ),
            )
        }
        return result
    } catch (t: Throwable) {
        runCatching {
            env.exportRuns.insert(
                ExportRun(
                    id = Ulid.newId(),
                    templateId = templateId,
                    // No job: generation threw before a job was persisted, or the runner recorded a
                    // failed job of its own (the sensitive half-encrypt guard) — either way this
                    // ledger row is the durable evidence, keyed to the attempt, not the artifact.
                    jobId = null,
                    trigger = trigger,
                    startedAt = startedAt,
                    finishedAt = env.now(),
                    outcome = ExportOutcome.FAILED_GENERATION,
                    errorCode = errorCodeFor(t),
                    errorDetail = ExportErrorDetail(stage = ExportStage.WRITING),
                    destinationId = ExportDestination.SHARE_SHEET_ID,
                ),
            )
        }
        throw t
    }
}

/**
 * Map a thrown export failure to the closed [ExportErrorCode] vocabulary so Export Health can style
 * it without parsing text. Only the reasons this UI can actually produce are enumerated; everything
 * else is honestly [ExportErrorCode.UNKNOWN] rather than a guess.
 */
internal fun errorCodeFor(t: Throwable): ExportErrorCode = when (t) {
    is ExportRunException.SensitiveExportRequiresPassphrase -> ExportErrorCode.PASSPHRASE_MISSING
    else -> ExportErrorCode.UNKNOWN
}

// MARK: - Format card

/**
 * A tappable format tile (CSV / JSON) with an icon, a subtitle, and the filenames it produces.
 * Selection is carried by the border weight, the tinted icon AND the checkmark glyph — never hue
 * alone (a11y) — and the whole tile is marked selected for TalkBack via [android.R] semantics on
 * the caller side. Mirror of the iOS `ExportFormatCard`.
 */
@Composable
internal fun ExportFormatCard(
    title: String,
    subtitle: String,
    icon: ImageVector,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fileNames: List<String> = emptyList(),
) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onClick)
            .background(if (selected) colors.primary.copy(alpha = 0.08f) else colors.surface, shape)
            .border(
                width = if (selected) 2.dp else 1.dp,
                color = if (selected) colors.primary else colors.separator,
                shape = shape,
            )
            .heightIn(min = 116.dp)
            .padding(BadanSpace.s3),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (selected) colors.primary else colors.textSecondary,
                modifier = Modifier.size(24.dp),
            )
            Spacer(modifier = Modifier.weight(1f))
            Icon(
                imageVector = if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                contentDescription = null,
                tint = if (selected) colors.primary else colors.separator,
                modifier = Modifier.size(22.dp),
            )
        }
        Text(
            text = title,
            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
        )
        Text(
            text = subtitle,
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        if (fileNames.isNotEmpty()) {
            // Filenames are technical identifiers — always left-to-right, in any language.
            CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                Text(
                    text = fileNames.joinToString(" · "),
                    style = BadanType.monospaceDigits(BadanType.caption),
                    color = if (selected) colors.primary else colors.textSecondary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// MARK: - Segmented control

/** A calm segmented selector over a small option set. Mirror of the iOS `ExportSegmented`. */
@Composable
internal fun <T> ExportSegmented(
    options: List<Pair<T, String>>,
    selected: T,
    onSelect: (T) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.surfaceElevated)
            .padding(BadanSpace.s1),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        for ((value, label) in options) {
            val isSelected = value == selected
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(BadanRadius.chip))
                    .clickable { onSelect(value) }
                    // Weight carries selection independently of hue (a11y): a user who can't
                    // separate the tint from the surface still reads the bold label + the fill.
                    .background(if (isSelected) colors.primary.copy(alpha = 0.14f) else Color.Transparent)
                    .heightIn(min = BadanSpace.touchMin)
                    .padding(horizontal = BadanSpace.s2),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label,
                    style = BadanType.chip.copy(fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium),
                    color = if (isSelected) colors.primary else colors.textSecondary,
                    maxLines = 1,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

// MARK: - Scope toggle

@Composable
internal fun ScopeToggleRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    enabled: Boolean = true,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(enabled = enabled) { onCheckedChange(!checked) }
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Box(modifier = Modifier.width(26.dp), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = if (enabled) colors.primary else colors.textSecondary,
                modifier = Modifier.size(22.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                text = title,
                style = BadanType.body,
                color = if (enabled) colors.textPrimary else colors.textSecondary,
            )
            Text(text = subtitle, style = BadanType.caption, color = colors.textSecondary)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.surface,
                checkedTrackColor = colors.primary,
                checkedBorderColor = colors.primary,
                uncheckedThumbColor = colors.textSecondary,
                uncheckedTrackColor = colors.surfaceElevated,
                uncheckedBorderColor = colors.separator,
            ),
        )
    }
}

@Composable
internal fun SensitiveNote(text: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.info.copy(alpha = 0.10f))
            .padding(BadanSpace.s3),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = Icons.Filled.Info,
            contentDescription = null,
            tint = colors.info,
            modifier = Modifier.size(18.dp),
        )
        Text(text = text, style = BadanType.caption, color = colors.textSecondary)
    }
}

// MARK: - Run / share buttons

@Composable
internal fun RunButton(isRunning: Boolean, enabled: Boolean = true, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val active = enabled && !isRunning
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.primary.copy(alpha = if (active) 1f else 0.5f))
            .clickable(enabled = active, onClick = onClick)
            .heightIn(min = BadanSpace.touchMin + 6.dp)
            .padding(horizontal = BadanSpace.s4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2, Alignment.CenterHorizontally),
    ) {
        if (isRunning) {
            CircularProgressIndicator(
                color = colors.onPrimary,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = env.s(ExportCopy.preparing),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.onPrimary,
            )
        } else {
            Icon(
                imageVector = Icons.Filled.FileUpload,
                contentDescription = null,
                tint = colors.onPrimary,
                modifier = Modifier.size(20.dp),
            )
            Text(
                text = env.s(Loc.runExport),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.onPrimary,
            )
        }
    }
}

@Composable
internal fun ShareButton(onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .border(
                width = 1.dp,
                color = colors.primary,
                shape = RoundedCornerShape(BadanRadius.control),
            )
            .clickable(onClick = onClick)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2, Alignment.CenterHorizontally),
    ) {
        Icon(
            imageVector = Icons.Filled.Share,
            contentDescription = null,
            tint = colors.primary,
            modifier = Modifier.size(20.dp),
        )
        Text(
            text = env.s(Loc.share),
            style = BadanType.body.copy(fontWeight = FontWeight.Medium),
            color = colors.primary,
        )
    }
}

// MARK: - Error card

@Composable
internal fun ErrorCard(message: String, showDetail: Boolean) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.WarningAmber,
                    contentDescription = null,
                    tint = colors.outOfBand,
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    text = env.s(ExportCopy.couldntPrepare),
                    style = BadanType.body,
                    color = colors.textPrimary,
                )
            }
            if (showDetail) {
                Text(
                    text = message,
                    style = BadanType.monospaceDigits(BadanType.caption),
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Success card

@Composable
internal fun ExportSuccessCard(result: ExportRunner.ExportResult, onShare: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val clipboard = LocalClipboardManager.current
    val copiedLabel = env.s(ExportCopy.copied)
    val checksums = result.job.manifest?.checksums ?: emptyMap()

    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.Verified,
                    contentDescription = null,
                    tint = colors.inBand,
                    modifier = Modifier.size(24.dp),
                )
                Text(
                    text = env.s(ExportCopy.exportReady),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                PillLabel(text = result.job.format.code.uppercase(), tint = colors.primary)
            }

            // Row counts sit above the Share button on purpose (§16 Quick Export: "show row counts
            // before share"): the user sees exactly how many records they are about to hand over
            // before the share sheet ever opens.
            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s6)) {
                StatBox(value = env.format.integer(result.rowCount), label = env.s(ExportCopy.records))
                StatBox(value = env.format.integer(result.files.size), label = env.s(ExportCopy.files))
            }

            if (checksums.isNotEmpty()) {
                RowDivider()
                Text(
                    text = env.s(ExportCopy.checksums),
                    style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textSecondary,
                )
                for (name in checksums.keys.sorted()) {
                    val fullHash = checksums[name] ?: ""
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(BadanRadius.control))
                            // Tap to copy the full hash — the truncated display alone can't verify
                            // export integrity against an external tool.
                            .clickable(enabled = fullHash.isNotEmpty()) {
                                clipboard.setText(AnnotatedString(fullHash))
                                Toast.makeText(context, copiedLabel, Toast.LENGTH_SHORT).show()
                            }
                            .heightIn(min = BadanSpace.touchMin),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Text(
                            text = name,
                            style = BadanType.monospaceDigits(BadanType.caption),
                            color = colors.textPrimary,
                        )
                        Spacer(modifier = Modifier.weight(1f))
                        // Hashes read left-to-right in any language.
                        CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                            Text(
                                text = shortHash(fullHash),
                                style = BadanType.monospaceDigits(BadanType.caption),
                                color = colors.textSecondary,
                            )
                        }
                    }
                }
            }

            if (env.depth.showsPowerDetail) {
                result.job.manifest?.let { manifest ->
                    RowDivider()
                    ManifestDetail(manifest)
                }
            }

            ShareButton(onClick = onShare)
        }
    }
}

@Composable
private fun ManifestDetail(manifest: ExportManifest) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = env.s(ExportCopy.manifest),
            style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
        DetailLine(label = env.s(ExportCopy.schema), value = manifest.schemaVersion)
        DetailLine(
            label = env.s(ExportCopy.generated),
            value = formatTimestamp(manifest.generatedAt, env.language),
        )
        DetailLine(label = env.s(ExportCopy.rangeField), value = manifest.dateRange)
        val context = LocalContext.current
        val clipboard = LocalClipboardManager.current
        val copiedLabel = env.s(ExportCopy.copied)
        DetailLine(
            label = env.s(ExportCopy.exportId),
            value = manifest.exportId.take(10) + if (manifest.exportId.length > 10) "…" else "",
            // Tap to copy the full id — useful when referencing this export in a support request.
            onClick = {
                clipboard.setText(AnnotatedString(manifest.exportId))
                Toast.makeText(context, copiedLabel, Toast.LENGTH_SHORT).show()
            },
        )

        if (manifest.perMetricRowCounts.isNotEmpty()) {
            Text(
                text = env.s(ExportCopy.rowsPerMetric),
                style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textSecondary,
                modifier = Modifier.padding(top = BadanSpace.s1),
            )
            for (id in manifest.perMetricRowCounts.keys.sorted()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    // Metric ids are canonical identifiers — always left-to-right.
                    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                        Text(
                            text = id,
                            style = BadanType.monospaceDigits(BadanType.caption),
                            color = colors.textPrimary,
                        )
                    }
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = env.format.integer(manifest.perMetricRowCounts[id] ?: 0),
                        style = BadanType.monospaceDigits(BadanType.caption),
                        color = colors.textSecondary,
                    )
                }
            }
        }
    }
}

@Composable
internal fun DetailLine(label: String, value: String, onClick: (() -> Unit)? = null) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .let { if (onClick != null) it.clip(RoundedCornerShape(BadanRadius.control)).clickable(onClick = onClick) else it }
            .heightIn(min = if (onClick != null) BadanSpace.touchMin else 0.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(text = label, style = BadanType.caption, color = colors.textSecondary)
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = value,
            style = BadanType.caption,
            color = colors.textPrimary,
            textAlign = TextAlign.End,
        )
    }
}

// MARK: - History row

@Composable
internal fun ExportHistoryRow(job: ExportJob, onShare: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val files = availableFiles(job)
    val canShare = files.isNotEmpty()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            // The whole row shares the same files as the trailing icon — matches the fully-tappable
            // row pattern used elsewhere instead of only the icon.
            .clickable(enabled = canShare, onClick = onShare)
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Box(modifier = Modifier.width(26.dp), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = if (job.format == ExportFormat.CSV) Icons.Filled.TableChart else Icons.Filled.DataObject,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(22.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Text(
                    text = job.format.code.uppercase(),
                    style = BadanType.bodyCompact.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                PillLabel(text = "${env.format.integer(job.rowCount ?: 0)} ${env.s(ExportCopy.recordsInline)}")
            }
            Text(
                text = formatTimestamp(job.createdAt, env.language),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        if (canShare) {
            Icon(
                imageVector = Icons.Filled.Share,
                contentDescription = env.s(Loc.share),
                tint = colors.primary,
                modifier = Modifier.size(20.dp),
            )
        } else {
            // Explain the gap instead of silently omitting the share affordance — the files that
            // backed this job are no longer on disk (e.g. cleared cache).
            Text(
                text = env.s(ExportCopy.filesUnavailable),
                style = BadanType.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.End,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.width(88.dp),
            )
        }
    }
}

/** Simple text affordance to page in the next [HISTORY_PAGE_SIZE] history rows. */
@Composable
internal fun LoadMoreRow(isLoading: Boolean, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(enabled = !isLoading, onClick = onClick)
            .heightIn(min = BadanSpace.touchMin),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (isLoading) {
            CircularProgressIndicator(
                color = colors.primary,
                strokeWidth = 2.dp,
                modifier = Modifier.size(16.dp),
            )
        }
        Text(
            text = env.s(ExportCopy.loadMoreHistory),
            style = BadanType.body.copy(fontWeight = FontWeight.Medium),
            color = colors.primary,
        )
    }
}

@Composable
internal fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(BadanTheme.colors.separator),
    )
}

// MARK: - Non-composable helpers

internal fun shortHash(hash: String): String =
    if (hash.isEmpty()) "—" else hash.take(12) + "…"

internal fun formatTimestamp(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date(millis))
}

/**
 * Rebuild the shareable files from a persisted job. The manifest's checksum keys are the written
 * filenames; CSV runs additionally carry a manifest.json. Only files still on disk are offered.
 * Mirror of the iOS `availableFileURLs`.
 */
internal fun availableFiles(job: ExportJob): List<File> {
    val path = job.outputPath ?: return emptyList()
    val folder = File(path)
    val names = job.manifest?.checksums?.keys?.toMutableList()
        ?: mutableListOf()
    if (names.isEmpty()) {
        names += if (job.format == ExportFormat.CSV) listOf("raw.csv", "derived.csv") else listOf("bundle.json")
    }
    if (job.format == ExportFormat.CSV) {
        names += "manifest.json"
    }
    return names.map { File(folder, it) }.filter { it.exists() }
}

/**
 * Share the export files through the system chooser, as `content://` uris from BADAN's
 * [androidx.core.content.FileProvider]. `FLAG_GRANT_READ_URI_PERMISSION` is what actually gives the
 * target app read access, scoped to these uris and this share. Mirror of the iOS `ShareSheet`.
 */
internal fun shareFiles(context: Context, files: List<File>) {
    val existing = files.filter { it.exists() }
    if (existing.isEmpty()) return

    val authority = "${context.packageName}.fileprovider"
    val uris = ArrayList(
        existing.mapNotNull { file ->
            // A file outside the provider's declared paths throws rather than returning null;
            // failing one attachment must not take down the whole share.
            runCatching { FileProvider.getUriForFile(context, authority, file) }.getOrNull()
        },
    )
    if (uris.isEmpty()) return
    val send = if (uris.size == 1) {
        Intent(Intent.ACTION_SEND).apply {
            type = mimeTypeFor(existing.first())
            putExtra(Intent.EXTRA_STREAM, uris.first())
        }
    } else {
        Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "application/octet-stream"
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        }
    }
    send.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)

    val chooser = Intent.createChooser(send, null).apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { context.startActivity(chooser) }
}

/**
 * Delete on-disk export folders under `<base>/badan-exports/` older than [EXPORT_RETENTION_DAYS]
 * that aren't referenced by any of [recentJobs]. Runs on `Dispatchers.IO` right before a new export
 * is written; failures are swallowed by the caller so housekeeping never blocks the export itself.
 */
internal fun pruneOldExports(base: File, recentJobs: List<ExportJob>) {
    val exportsDir = File(base, "badan-exports")
    val dirs = exportsDir.listFiles { file -> file.isDirectory } ?: return
    val keepPaths = recentJobs.mapNotNull { it.outputPath }.toSet()
    val cutoff = System.currentTimeMillis() - EXPORT_RETENTION_MILLIS
    for (dir in dirs) {
        if (dir.absolutePath in keepPaths) continue
        if (dir.lastModified() >= cutoff) continue
        dir.deleteRecursively()
    }
}

/** The output folder for one run under the app's private cache (M3: never external cache). */
internal fun newExportDir(context: Context): File =
    File(context.cacheDir, "badan-exports/${System.currentTimeMillis()}")

private fun mimeTypeFor(file: File): String = when (file.extension.lowercase()) {
    "csv" -> "text/csv"
    "json" -> "application/json"
    else -> "application/octet-stream"
}
