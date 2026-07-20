package net.albayyan.badan.features.export

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
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
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportJob
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.QuickExportPreset
import net.albayyan.badan.export.ExportRunner

// MARK: - Hub copy

/** Copy specific to the Export Center hub. Screen-specific bilingual strings live here; the atoms
 *  shared across every export surface live in [ExportCopy]. */
private object ExportHubCopy {
    val quickTitle = LocalizedString(en = "Quick export", ar = "تصدير سريع")
    val quickBlurb = LocalizedString(
        en = "Your raw and computed records, in two taps. Meds, symptoms, and routes are never in a quick export — those need the advanced builder.",
        ar = "سجلاتك الخام والمحسوبة بنقرتين. لا تتضمّن التصديرات السريعة الأدوية أو الأعراض أو المسارات أبداً — تلك تحتاج المُنشئ المتقدم.",
    )
    val range7 = LocalizedString(en = "Last 7 days", ar = "آخر ٧ أيام")
    val range30 = LocalizedString(en = "Last 30 days", ar = "آخر ٣٠ يوماً")
    val rangeAll = LocalizedString(en = "All time", ar = "كل الوقت")

    val moreTitle = LocalizedString(en = "More ways to export", ar = "طرق أخرى للتصدير")
    val advancedTitle = LocalizedString(en = "Advanced export", ar = "تصدير متقدم")
    val advancedSubtitle = LocalizedString(
        en = "Pick exact metrics, sources, dates, and units — and save it as a template.",
        ar = "اختر مؤشرات ومصادر وتواريخ ووحدات محددة — واحفظها كقالب.",
    )
    val templatesTitle = LocalizedString(en = "Saved templates", ar = "القوالب المحفوظة")
    val templatesSubtitle = LocalizedString(
        en = "Run a saved configuration again in one tap.",
        ar = "شغّل إعداداً محفوظاً مرة أخرى بنقرة واحدة.",
    )
    val healthTitle = LocalizedString(en = "Export health", ar = "حالة التصدير")
    val healthSubtitle = LocalizedString(
        en = "Did my exports actually run? Every attempt is recorded here.",
        ar = "هل نُفّذت تصديراتي فعلاً؟ تُسجَّل كل محاولة هنا.",
    )
}

/** The three quick windows. Fixed and narrow — they resolve to the seeded read-only presets
 *  (EPIC-10), so a quick export cannot be widened to include sensitive data or routes. */
internal enum class QuickRange { LAST_7, LAST_30, ALL }

/**
 * The one place a quick window + format resolves to a seeded [QuickExportPreset]. Pure so the
 * structural-exclusion guarantee (a quick export is always one of the six read-only presets, never
 * an arbitrary scope) is directly testable without a database.
 */
internal fun quickExportPreset(range: QuickRange, format: ExportFormat): QuickExportPreset = when (range) {
    QuickRange.LAST_7 -> if (format == ExportFormat.CSV) QuickExportPreset.LAST_7_CSV else QuickExportPreset.LAST_7_JSON
    QuickRange.LAST_30 -> if (format == ExportFormat.CSV) QuickExportPreset.LAST_30_CSV else QuickExportPreset.LAST_30_JSON
    QuickRange.ALL -> if (format == ExportFormat.CSV) QuickExportPreset.ALL_TIME_CSV else QuickExportPreset.ALL_TIME_JSON
}

/**
 * Resolve a preset's stored scope into a concrete run scope: freeze its rolling window against the
 * clock and carry the display language so filenames / manifest reflect what the user sees. Pure and
 * testable; note it can only ever return the preset's narrow scope (raw + derived, no
 * sensitive/suppressed/routes) — there is no parameter through which a caller could widen it.
 */
internal fun quickExportScope(
    preset: QuickExportPreset,
    language: AppLanguage,
    now: Long,
    deviceId: String,
): ExportScope {
    val base = preset.template(now, deviceId).scope
    val start = when (val rule = preset.rangeRule) {
        is ExportRangeRule.LastNDays -> now - rule.safeDays * 86_400_000L
        else -> null
    }
    return base.copy(language = language, startDate = start, endDate = null)
}

// MARK: - Screen

/**
 * The Export Center — the hub for every export surface. Quick Export lives here as a card (§16: "at
 * top of Export Center"); the advanced builder, template manager, and Export Health each open as
 * their own screen from the "More ways to export" rows. "Previous exports" lists the files still on
 * disk to re-share.
 *
 * Quick Export is deliberately calm and offline: pick a window, pick a format, tap Create. The run
 * happens on [Dispatchers.IO], and — unlike a share-immediately flow — the result card shows the
 * record count first and only shares when the user taps Share (§16 trust rule: "show row counts
 * before share").
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var quickRange by remember { mutableStateOf(QuickRange.LAST_30) }
    var quickFormat by remember { mutableStateOf(ExportFormat.CSV) }
    var quickRunning by remember { mutableStateOf(false) }
    var quickResult by remember { mutableStateOf<ExportRunner.ExportResult?>(null) }
    var quickError by remember { mutableStateOf<String?>(null) }

    var history by remember { mutableStateOf<List<ExportJob>>(emptyList()) }
    var historyHasMore by remember { mutableStateOf(false) }
    var isLoadingMoreHistory by remember { mutableStateOf(false) }

    // Load history and seed the read-only presets off the main thread on first show. Seeding is
    // idempotent (INSERT OR IGNORE on fixed preset ids) so this is safe on every visit, and it has
    // to happen somewhere the user actually reaches — it makes each preset a real template row so
    // Export Health can attribute a quick export's run to it (EPIC-09/16).
    LaunchedEffect(Unit) {
        val page = withContext(Dispatchers.IO) {
            runCatching { env.exportTemplates.seedPresets(env.now(), env.deviceId) }
            runCatching { env.exportJobs.recent(HISTORY_PAGE_SIZE) }.getOrDefault(emptyList())
        }
        history = page
        historyHasMore = page.size == HISTORY_PAGE_SIZE
    }

    fun reloadHistory() {
        coroutineScope.launch {
            val page = withContext(Dispatchers.IO) {
                runCatching { env.exportJobs.recent(HISTORY_PAGE_SIZE) }.getOrDefault(emptyList())
            }
            history = page
            historyHasMore = page.size == HISTORY_PAGE_SIZE
        }
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

    fun runQuickExport() {
        if (quickRunning) return
        quickRunning = true
        quickError = null
        quickResult = null
        val preset = quickExportPreset(quickRange, quickFormat)
        val scope = quickExportScope(preset, env.language, env.now(), env.deviceId)
        coroutineScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    runCatching { pruneOldExports(context.cacheDir, env.exportJobs.recent(HISTORY_PAGE_SIZE)) }
                    runAndRecordExport(
                        env = env,
                        scope = scope,
                        format = quickFormat,
                        templateId = preset.id,
                        outputDir = newExportDir(context),
                    )
                }
            }
            outcome
                .onSuccess { quickResult = it; reloadHistory() }
                .onFailure { quickError = it.toString() }
            quickRunning = false
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

            // Quick export (EPIC-10)
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(ExportHubCopy.quickTitle))
                BadanCard {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        Text(
                            text = env.s(ExportHubCopy.quickBlurb),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                        Text(
                            text = env.s(ExportCopy.dateRange),
                            style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.textSecondary,
                        )
                        ExportSegmented(
                            options = listOf(
                                QuickRange.LAST_7 to env.s(ExportHubCopy.range7),
                                QuickRange.LAST_30 to env.s(ExportHubCopy.range30),
                                QuickRange.ALL to env.s(ExportHubCopy.rangeAll),
                            ),
                            selected = quickRange,
                            onSelect = { quickRange = it },
                        )
                        Text(
                            text = env.s(Loc.exportFormat),
                            style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.textSecondary,
                        )
                        ExportSegmented(
                            options = listOf(
                                ExportFormat.CSV to "CSV",
                                ExportFormat.JSON to "JSON",
                            ),
                            selected = quickFormat,
                            onSelect = { quickFormat = it },
                        )
                        RunButton(isRunning = quickRunning, onClick = ::runQuickExport)
                    }
                }
                quickError?.let { ErrorCard(message = it, showDetail = env.depth.showsPowerDetail) }
                quickResult?.let { result ->
                    ExportSuccessCard(result = result, onShare = { shareFiles(context, result.files) })
                }
            }

            // More ways to export — the three pushed surfaces
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(ExportHubCopy.moreTitle))
                BadanCard {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        HubRow(
                            icon = Icons.Filled.Tune,
                            title = env.s(ExportHubCopy.advancedTitle),
                            subtitle = env.s(ExportHubCopy.advancedSubtitle),
                            onClick = { nav.push(Route.ExportBuilder()) },
                        )
                        RowDivider()
                        HubRow(
                            icon = Icons.Outlined.Bookmarks,
                            title = env.s(ExportHubCopy.templatesTitle),
                            subtitle = env.s(ExportHubCopy.templatesSubtitle),
                            onClick = { nav.push(Route.ExportTemplates) },
                        )
                        RowDivider()
                        HubRow(
                            icon = Icons.Filled.HealthAndSafety,
                            title = env.s(ExportHubCopy.healthTitle),
                            subtitle = env.s(ExportHubCopy.healthSubtitle),
                            onClick = { nav.push(Route.ExportHealth) },
                        )
                    }
                }
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

// MARK: - Hub row

@Composable
private fun HubRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClick = onClick)
            .padding(vertical = BadanSpace.s1),
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
        // Auto-mirrored: the chevron points toward the content in both LTR and RTL.
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(22.dp),
        )
    }
}
