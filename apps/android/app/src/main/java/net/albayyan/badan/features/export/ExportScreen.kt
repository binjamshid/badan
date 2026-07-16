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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.LayersClear
import androidx.compose.material.icons.filled.MedicalServices
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatBox
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportJob
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.export.ExportRunner
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale

// MARK: - Copy

/**
 * Screen-local bilingual strings that don't belong in the shared catalog. Every string in the app
 * carries both languages; these are the ones specific to the export cockpit. Mirror of the iOS
 * `ExportCopy`.
 */
private object ExportCopy {
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
 * The three offered windows. Maps to [ExportScope.startDate]; "all time" leaves it open. Epoch is
 * millis on Android, so windows are counted in milliseconds. Mirror of the iOS `ExportRange`.
 */
private enum class ExportRange {
    LAST30, LAST90, ALL;

    fun startDate(now: Long): Long? = when (this) {
        LAST30 -> now - 30L * 86_400_000L
        LAST90 -> now - 90L * 86_400_000L
        ALL -> null
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
    }
}

/** History page size and matching on-run retention window for the on-disk export folders. */
private const val HISTORY_PAGE_SIZE = 20
private const val EXPORT_RETENTION_DAYS = 30L
private const val EXPORT_RETENTION_MILLIS = EXPORT_RETENTION_DAYS * 24 * 60 * 60 * 1000

// MARK: - Screen

/**
 * The trust cockpit. Pick a format, choose exactly what to include, set a window, and create a
 * fully offline export — then share the file or re-share any earlier one. Casual keeps it calm
 * (format, the sensitive toggle, a window); power exposes the raw/computed/suppressed toggles, the
 * unit profile, per-file checksums and the manifest. Same run, two altitudes. Faithful port of the
 * iOS `ExportCenterScreen`.
 *
 * The run itself is fully offline and synchronous; it is dispatched on [Dispatchers.IO] so a large
 * "all time · raw+derived" export never blocks the UI. On success the share sheet opens
 * automatically, and both the success card and every history row can re-share.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var exportScope by remember { mutableStateOf(ExportScope()) }
    var format by remember { mutableStateOf(ExportFormat.CSV) }
    var range by remember { mutableStateOf(ExportRange.LAST30) }

    var history by remember { mutableStateOf<List<ExportJob>>(emptyList()) }
    var historyHasMore by remember { mutableStateOf(false) }
    var isLoadingMoreHistory by remember { mutableStateOf(false) }
    var lastResult by remember { mutableStateOf<ExportRunner.ExportResult?>(null) }
    var isRunning by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // History is a secondary surface: load it off the main thread on first show, one page at a time.
    LaunchedEffect(Unit) {
        val page = withContext(Dispatchers.IO) {
            runCatching { env.exportJobs.recent(HISTORY_PAGE_SIZE) }.getOrDefault(emptyList())
        }
        history = page
        historyHasMore = page.size == HISTORY_PAGE_SIZE
    }

    fun loadMoreHistory() {
        if (isLoadingMoreHistory || !historyHasMore) return
        isLoadingMoreHistory = true
        coroutineScope.launch {
            val more = withContext(Dispatchers.IO) {
                runCatching {
                    env.exportJobs.recent(HISTORY_PAGE_SIZE, offset = history.size)
                }.getOrDefault(emptyList())
            }
            history = history + more
            historyHasMore = more.size == HISTORY_PAGE_SIZE
            isLoadingMoreHistory = false
        }
    }

    fun runExport() {
        if (isRunning) return
        isRunning = true
        errorText = null
        lastResult = null
        // Freeze the picked window against the current clock and carry the display language into the
        // scope so filenames / manifest reflect what the user sees.
        val scoped = exportScope.copy(
            language = env.language,
            startDate = range.startDate(env.now()),
            endDate = null,
        )
        val chosenFormat = format
        coroutineScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    // (M3) Internal cache, not external: exports contain the user's health
                    // records, and on Android 8-10 external cache is readable by any app holding
                    // READ_EXTERNAL_STORAGE. It is also what `file_paths.xml` scopes the
                    // FileProvider to, so sharing works precisely because the files are private.
                    val base = context.cacheDir
                    // Best-effort housekeeping: repeated exports would otherwise accumulate on-disk
                    // folders forever. Never let a pruning failure block the export itself.
                    runCatching {
                        val keepJobs = env.exportJobs.recent(HISTORY_PAGE_SIZE)
                        pruneOldExports(base, keepJobs)
                    }
                    val dir = File(base, "badan-exports/${System.currentTimeMillis()}")
                    env.exporter.run(scope = scoped, format = chosenFormat, outputDir = dir)
                }
            }
            outcome
                .onSuccess { result ->
                    lastResult = result
                    val page = withContext(Dispatchers.IO) {
                        runCatching { env.exportJobs.recent(HISTORY_PAGE_SIZE) }.getOrDefault(emptyList())
                    }
                    history = page
                    historyHasMore = page.size == HISTORY_PAGE_SIZE
                    // Mirror iOS: a fresh result presents the share sheet immediately.
                    shareFiles(context, result.files)
                }
                .onFailure { errorText = it.toString() }
            isRunning = false
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(Loc.exportTitle),
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
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(BadanSpace.s4),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
        ) {
            IntroCard()

            // Format
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(Loc.exportFormat))
                Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    ExportFormatCard(
                        modifier = Modifier.weight(1f),
                        title = "CSV",
                        subtitle = env.s(ExportCopy.formatCSVSubtitle),
                        fileNames = listOf("raw.csv", "derived.csv", "manifest.json"),
                        icon = Icons.Filled.TableChart,
                        selected = format == ExportFormat.CSV,
                        onClick = { format = ExportFormat.CSV },
                    )
                    ExportFormatCard(
                        modifier = Modifier.weight(1f),
                        title = "JSON",
                        subtitle = env.s(ExportCopy.formatJSONSubtitle),
                        fileNames = listOf("bundle.json"),
                        icon = Icons.Filled.DataObject,
                        selected = format == ExportFormat.JSON,
                        onClick = { format = ExportFormat.JSON },
                    )
                }
            }

            // Scope
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(Loc.exportScope))
                BadanCard {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        if (env.depth.showsPowerDetail) {
                            ScopeToggleRow(
                                title = env.s(Loc.includeRaw),
                                subtitle = env.s(ExportCopy.includeRawSubtitle),
                                icon = Icons.Filled.MonitorHeart,
                                checked = exportScope.includeRaw,
                                onCheckedChange = { exportScope = exportScope.copy(includeRaw = it) },
                            )
                            RowDivider()
                            ScopeToggleRow(
                                title = env.s(Loc.includeDerived),
                                subtitle = env.s(ExportCopy.includeDerivedSubtitle),
                                icon = Icons.Filled.Functions,
                                checked = exportScope.includeDerived,
                                onCheckedChange = { exportScope = exportScope.copy(includeDerived = it) },
                            )
                            RowDivider()
                            ScopeToggleRow(
                                title = env.s(Loc.includeSuppressed),
                                subtitle = env.s(ExportCopy.includeSuppressedSubtitle),
                                icon = Icons.Filled.LayersClear,
                                checked = exportScope.includeSuppressed,
                                onCheckedChange = { exportScope = exportScope.copy(includeSuppressed = it) },
                            )
                            RowDivider()
                        }
                        ScopeToggleRow(
                            title = env.s(Loc.includeSensitive),
                            subtitle = env.s(ExportCopy.includeSensitiveSubtitle),
                            icon = Icons.Filled.MedicalServices,
                            checked = exportScope.includeSensitive,
                            onCheckedChange = { exportScope = exportScope.copy(includeSensitive = it) },
                        )
                        if (exportScope.includeSensitive) {
                            SensitiveNote(text = env.s(ExportCopy.sensitiveNote))
                        }
                    }
                }
            }

            // Date range
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(ExportCopy.dateRange))
                ExportSegmented(
                    options = ExportRange.entries.map { it to env.s(it.label(env.format)) },
                    selected = range,
                    onSelect = { range = it },
                )
            }

            // Unit profile (power altitude only)
            if (env.depth.showsPowerDetail) {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(Loc.units))
                    ExportSegmented(
                        options = listOf(
                            UnitProfileMode.CANONICAL to env.s(ExportCopy.unitSource),
                            UnitProfileMode.DISPLAY to env.s(ExportCopy.unitDisplay),
                        ),
                        selected = exportScope.unitProfile,
                        onSelect = { exportScope = exportScope.copy(unitProfile = it) },
                    )
                    Text(
                        text = env.s(ExportCopy.unitNote),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }

            ScopeSummary(scope = exportScope)
            RunButton(isRunning = isRunning, onClick = ::runExport)

            errorText?.let { ErrorCard(message = it, showDetail = env.depth.showsPowerDetail) }

            lastResult?.let { result ->
                ExportSuccessCard(
                    result = result,
                    onShare = { shareFiles(context, result.files) },
                )
            }

            // History
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(ExportCopy.history))
                if (history.isEmpty()) {
                    BadanCard {
                        Text(
                            text = env.s(ExportCopy.noHistory),
                            style = BadanType.body,
                            color = colors.textSecondary,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                } else {
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            history.forEachIndexed { index, job ->
                                ExportHistoryRow(
                                    job = job,
                                    onShare = { shareFiles(context, availableFiles(job)) },
                                )
                                if (index < history.size - 1) {
                                    RowDivider()
                                }
                            }
                        }
                    }
                    if (historyHasMore) {
                        LoadMoreRow(isLoading = isLoadingMoreHistory, onClick = ::loadMoreHistory)
                    }
                }
            }

            // Footer disclaimer
            Text(
                text = env.s(Loc.exportDisclaimer),
                style = BadanType.caption,
                color = colors.textSecondary,
                modifier = Modifier.padding(top = BadanSpace.s2),
            )
        }
    }
}

// MARK: - Intro

@Composable
private fun IntroCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.Shield,
                    contentDescription = null,
                    tint = colors.primary,
                    modifier = Modifier.size(24.dp),
                )
                PillLabel(
                    text = env.s(ExportCopy.onDeviceOnly),
                    icon = Icons.Filled.WifiOff,
                    tint = colors.primary,
                )
            }
            Text(
                text = env.s(Loc.exportEverything),
                style = BadanType.body,
                color = colors.textPrimary,
            )
        }
    }
}

// MARK: - Format card

@Composable
private fun ExportFormatCard(
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
private fun <T> ExportSegmented(
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
                    .background(if (isSelected) colors.primary.copy(alpha = 0.14f) else Color.Transparent)
                    .heightIn(min = BadanSpace.touchMin)
                    .padding(horizontal = BadanSpace.s2),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label,
                    style = BadanType.chip,
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
private fun ScopeToggleRow(
    title: String,
    subtitle: String,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable { onCheckedChange(!checked) }
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Box(modifier = Modifier.width(26.dp), contentAlignment = Alignment.Center) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = colors.primary,
                modifier = Modifier.size(22.dp),
            )
        }
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(text = title, style = BadanType.body, color = colors.textPrimary)
            Text(text = subtitle, style = BadanType.caption, color = colors.textSecondary)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
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
private fun SensitiveNote(text: String) {
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

// MARK: - Scope summary

/**
 * A single legible line echoing exactly what the run will include/exclude, right above the button
 * that commits to it — so a scope that's silently missing a category (e.g. an unchecked "Computed
 * values") is never discovered only after the export is out the door.
 */
@Composable
private fun ScopeSummary(scope: ExportScope) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val categories = listOf(
        Loc.includeRaw to scope.includeRaw,
        Loc.includeDerived to scope.includeDerived,
        Loc.includeSuppressed to scope.includeSuppressed,
        Loc.includeSensitive to scope.includeSensitive,
    )
    val included = categories.filter { it.second }.map { env.s(it.first) }
    val excluded = categories.filter { !it.second }.map { env.s(it.first) }
    if (included.isEmpty() && excluded.isEmpty()) return

    val text = buildString {
        if (included.isNotEmpty()) {
            append(env.s(ExportCopy.scopeIncludes))
            append(' ')
            append(included.joinToString(", "))
        }
        if (excluded.isNotEmpty()) {
            if (isNotEmpty()) append("  ")
            append(env.s(ExportCopy.scopeExcludes))
            append(' ')
            append(excluded.joinToString(", "))
        }
    }
    Text(text = text, style = BadanType.caption, color = colors.textSecondary)
}

// MARK: - Run button

@Composable
private fun RunButton(isRunning: Boolean, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.primary.copy(alpha = if (isRunning) 0.75f else 1f))
            .clickable(enabled = !isRunning, onClick = onClick)
            .heightIn(min = BadanSpace.touchMin + 6.dp)
            .padding(horizontal = BadanSpace.s4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2, Alignment.CenterHorizontally),
    ) {
        if (isRunning) {
            CircularProgressIndicator(
                color = colors.background,
                strokeWidth = 2.dp,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = env.s(ExportCopy.preparing),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.background,
            )
        } else {
            Icon(
                imageVector = Icons.Filled.FileUpload,
                contentDescription = null,
                tint = colors.background,
                modifier = Modifier.size(20.dp),
            )
            Text(
                text = env.s(Loc.runExport),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.background,
            )
        }
    }
}

// MARK: - Error card

@Composable
private fun ErrorCard(message: String, showDetail: Boolean) {
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
private fun ExportSuccessCard(result: ExportRunner.ExportResult, onShare: () -> Unit) {
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
                            // Tap to copy the full hash — the truncated display alone can't be used
                            // to actually verify export integrity against an external tool.
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
private fun DetailLine(label: String, value: String, onClick: (() -> Unit)? = null) {
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

@Composable
private fun ShareButton(onClick: () -> Unit) {
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

// MARK: - History row

@Composable
private fun ExportHistoryRow(job: ExportJob, onShare: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val files = remember(job.id) { availableFiles(job) }
    val canShare = files.isNotEmpty()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            // The whole row shares the same files as the trailing icon — matches the fully-tappable
            // row pattern used elsewhere (e.g. SettingsNavRow, BodyToolRow) instead of only the icon.
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
private fun LoadMoreRow(isLoading: Boolean, onClick: () -> Unit) {
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
private fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(1.dp)
            .background(BadanTheme.colors.separator),
    )
}

// MARK: - Non-composable helpers

private fun shortHash(hash: String): String =
    if (hash.isEmpty()) "—" else hash.take(12) + "…"

private fun formatTimestamp(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    return DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale).format(Date(millis))
}

/**
 * Rebuild the shareable files from a persisted job. The manifest's checksum keys are the written
 * filenames; CSV runs additionally carry a manifest.json. Only files still on disk are offered.
 * Mirror of the iOS `availableFileURLs`.
 */
private fun availableFiles(job: ExportJob): List<File> {
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
 * [androidx.core.content.FileProvider].
 *
 * This used to attach `file://` uris and reset the app's global StrictMode VM policy to stop the
 * resulting `FileUriExposedException`. That silenced the crash without fixing anything: passing a
 * `file://` uri to another app has not worked since Android 7, so on a real device the chooser
 * opened, the user picked Gmail or Drive, and nothing arrived — the flagship "your data is yours,
 * take it with you" feature failed silently, which is the worst way for a trust feature to fail.
 * The policy reset was also global: one share disabled StrictMode's disk/leak detection for the
 * whole process, well beyond this screen.
 *
 * `FLAG_GRANT_READ_URI_PERMISSION` is what actually gives the target app read access, scoped to
 * these uris and this share.
 */
private fun shareFiles(context: Context, files: List<File>) {
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
 * that aren't referenced by any of [recentJobs] (so a still-shareable history row's files are never
 * removed). Runs on [Dispatchers.IO] right before a new export is written; failures are swallowed by
 * the caller so housekeeping never blocks the export itself.
 */
private fun pruneOldExports(base: File, recentJobs: List<ExportJob>) {
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

private fun mimeTypeFor(file: File): String = when (file.extension.lowercase()) {
    "csv" -> "text/csv"
    "json" -> "application/json"
    else -> "application/octet-stream"
}
