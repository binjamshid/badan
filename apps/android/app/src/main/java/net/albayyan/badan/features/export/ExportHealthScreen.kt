package net.albayyan.badan.features.export

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BatteryAlert
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.graphics.Color
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
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.ExportOutcome
import net.albayyan.badan.domain.ExportRun
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.ExportTrigger
import net.albayyan.badan.export.ExportRunner
import net.albayyan.badan.storage.repositories.CadenceSummary

// MARK: - Plain-language mapping (pure; testable)

/** How an outcome should read as status — never colour alone, always icon + word. */
internal enum class HealthChipStyle { SUCCESS, PROBLEM, NEUTRAL }

/**
 * The §16 "plain-language mapping" for the outcome taxonomy: every closed [ExportOutcome] token
 * becomes a calm sentence and a status style, so the dashboard never shows jargon like
 * "skippedLocked". Pure so a test can assert every enum case is mapped (a missing case would leave a
 * run styled as an unexplained blank).
 */
internal object ExportOutcomeCopy {
    fun style(outcome: ExportOutcome): HealthChipStyle = when {
        outcome == ExportOutcome.SUCCESS -> HealthChipStyle.SUCCESS
        // Only real failures read as problems — locked / no-data / throttled / cancelled are the
        // scheduler and the user behaving normally, and styling them as errors would be false.
        outcome.isFailure -> HealthChipStyle.PROBLEM
        else -> HealthChipStyle.NEUTRAL
    }

    fun label(outcome: ExportOutcome): LocalizedString = when (outcome) {
        ExportOutcome.SUCCESS -> LocalizedString(en = "Exported successfully", ar = "تم التصدير بنجاح")
        ExportOutcome.PARTIAL -> LocalizedString(en = "Some files weren't written", ar = "لم تُكتب بعض الملفات")
        ExportOutcome.FAILED_GENERATION -> LocalizedString(en = "Couldn't be created", ar = "تعذّر إنشاؤه")
        ExportOutcome.FAILED_DELIVERY -> LocalizedString(en = "Created, but didn't arrive", ar = "أُنشئ، لكنه لم يصل")
        ExportOutcome.SKIPPED_LOCKED -> LocalizedString(en = "Skipped — sensitive records were locked", ar = "تُخطّي — السجلات الحساسة كانت مقفلة")
        ExportOutcome.SKIPPED_NO_DATA -> LocalizedString(en = "Nothing new to export", ar = "لا جديد للتصدير")
        ExportOutcome.THROTTLED -> LocalizedString(en = "Delayed by the system", ar = "أخّره النظام")
        ExportOutcome.CANCELLED -> LocalizedString(en = "Cancelled", ar = "أُلغي")
    }
}

/** Plain-language for what started a run. Pure; testable. */
internal fun triggerLabel(trigger: ExportTrigger): LocalizedString = when (trigger) {
    ExportTrigger.MANUAL -> LocalizedString(en = "You ran this", ar = "شغّلته أنت")
    ExportTrigger.SHORTCUT -> LocalizedString(en = "Shortcut", ar = "اختصار")
    ExportTrigger.SCHEDULED_OPPORTUNISTIC -> LocalizedString(en = "Background", ar = "في الخلفية")
    ExportTrigger.SCHEDULED_WORK -> LocalizedString(en = "Scheduled", ar = "مجدول")
    ExportTrigger.RETRY -> LocalizedString(en = "Automatic retry", ar = "إعادة محاولة تلقائية")
}

// MARK: - Loaded state

private data class HealthData(
    val outcomeCounts: List<Pair<ExportOutcome, Int>>,
    val recentRuns: List<ExportRun>,
    val jobsWithoutRun: List<String>,
    val templateStatus: List<Pair<ExportTemplate, ExportRun?>>,
    val cadence: CadenceSummary,
)

// MARK: - Copy

private object HealthCopy {
    val title = LocalizedString(en = "Export health", ar = "حالة التصدير")
    val trust = LocalizedString(
        en = "If something didn't run, you'll see it here — nothing fails silently.",
        ar = "إن لم يُنفَّذ شيء، فسيظهر هنا — لا شيء يفشل بصمت.",
    )
    val last30 = LocalizedString(en = "Last 30 days", ar = "آخر ٣٠ يوماً")
    val noRuns = LocalizedString(
        en = "No exports yet. When you create one, its result is recorded here.",
        ar = "لا توجد تصديرات بعد. عند إنشاء تصدير، تُسجَّل نتيجته هنا.",
    )
    val everyRunRecorded = LocalizedString(
        en = "Every export has a recorded result.",
        ar = "لكل تصدير نتيجة مسجّلة.",
    )
    fun jobsWithoutRun(count: String) = LocalizedString(
        en = "$count export(s) started without a recorded result. On some phones a background task can be stopped mid-run before it can log an outcome.",
        ar = "بدأ $count تصدير دون نتيجة مسجّلة. في بعض الهواتف قد يُوقَف عمل الخلفية أثناء التشغيل قبل أن يسجّل نتيجته.",
    )
    val templatesHeader = LocalizedString(en = "Your templates", ar = "قوالبك")
    val runNow = LocalizedString(en = "Run now", ar = "شغّل الآن")
    val neverRun = LocalizedString(en = "Not run yet", ar = "لم يُشغّل بعد")
    val runsWhenYouAsk = LocalizedString(
        en = "Runs when you ask — no schedule.",
        ar = "يُشغّل عند طلبك — دون جدولة.",
    )
    val historyHeader = LocalizedString(en = "Recent runs", ar = "التشغيلات الأخيرة")
    val oemGuidance = LocalizedString(
        en = "Some phones delay background work to save battery. This isn't an error — open BADAN to refresh now, or allow it to run in the background in your phone's battery settings.",
        ar = "تؤخّر بعض الهواتف عمل الخلفية لتوفير البطارية. هذا ليس خطأً — افتح بدن للتحديث الآن، أو اسمح له بالعمل في الخلفية من إعدادات البطارية بهاتفك.",
    )
    val backgroundHeader = LocalizedString(en = "Background work", ar = "عمل الخلفية")
    val bgRuns = LocalizedString(en = "Runs (24h)", ar = "تشغيلات (٢٤س)")
    val bgThrottled = LocalizedString(en = "Throttled", ar = "مُقيَّدة")
    val bgErrors = LocalizedString(en = "Errors", ar = "أخطاء")
}

// MARK: - Screen

/**
 * Export & Automation Health (EPIC-16) — the trust ledger. Reads `export_runs` (the append-only
 * record every export surface now writes via [runAndRecordExport]) and answers the one question
 * §16 makes primary: "did my export actually run?".
 *
 * Never-silent-failure is structural here: the completeness check ([jobIdsWithoutRun]) surfaces
 * exports that started and left no ledger row — the killed-mid-run case that is otherwise invisible.
 * The OEM-throttling guidance is exactly that — guidance, styled `info`, never an error — matching
 * Android's honest "some phones delay background work" story from Phase 0.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExportHealthScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var data by remember { mutableStateOf<HealthData?>(null) }
    var isRunning by remember { mutableStateOf(false) }
    var lastResult by remember { mutableStateOf<ExportRunner.ExportResult?>(null) }
    var errorText by remember { mutableStateOf<String?>(null) }

    fun reload() {
        coroutineScope.launch {
            val loaded = withContext(Dispatchers.IO) {
                val now = env.now()
                runCatching { env.exportTemplates.seedPresets(now, env.deviceId) }
                val since = now - 30L * 86_400_000L
                val templates = runCatching { env.exportTemplates.all() }.getOrDefault(emptyList())
                HealthData(
                    outcomeCounts = runCatching { env.exportRuns.outcomeCounts(since) }.getOrDefault(emptyList()),
                    recentRuns = runCatching { env.exportRuns.recent(50) }.getOrDefault(emptyList()),
                    jobsWithoutRun = runCatching { env.exportRuns.jobIdsWithoutRun(50) }.getOrDefault(emptyList()),
                    templateStatus = templates.map { t ->
                        t to runCatching { env.exportRuns.lastRun(t.id) }.getOrNull()
                    },
                    cadence = runCatching { env.backgroundRuns.cadence(now = now) }
                        .getOrDefault(CadenceSummary(86_400_000L, 0, 0, 0, 0L, null)),
                )
            }
            data = loaded
        }
    }

    LaunchedEffect(Unit) { reload() }

    fun runTemplate(template: ExportTemplate) {
        if (template.requiresSensitiveConfirmation) {
            nav.push(Route.ExportBuilder(template.id))
            return
        }
        if (isRunning) return
        isRunning = true
        errorText = null
        lastResult = null
        val runScope = resolveTemplateRunScope(
            template,
            languageScope = template.scope.copy(language = env.language),
            now = env.now(),
        )
        coroutineScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    runCatching { pruneOldExports(context.cacheDir, env.exportJobs.recent(HISTORY_PAGE_SIZE)) }
                    runAndRecordExport(
                        env = env,
                        scope = runScope,
                        format = template.format,
                        templateId = template.id,
                        outputDir = newExportDir(context),
                    )
                }
            }
            outcome
                .onSuccess { lastResult = it }
                .onFailure { errorText = it.toString() }
            isRunning = false
            reload()
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(HealthCopy.title),
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
        val loaded = data
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .verticalScroll(rememberScrollState())
                .padding(BadanSpace.s4),
            verticalArrangement = Arrangement.spacedBy(BadanSpace.s5),
        ) {
            // Trust copy
            BadanCard {
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Icon(Icons.Filled.Info, contentDescription = null, tint = colors.primary, modifier = Modifier.size(20.dp))
                    Text(text = env.s(HealthCopy.trust), style = BadanType.body, color = colors.textPrimary)
                }
            }

            errorText?.let { ErrorCard(message = it, showDetail = env.depth.showsPowerDetail) }
            lastResult?.let { result ->
                ExportSuccessCard(result = result, onShare = { shareFiles(context, result.files) })
            }

            if (loaded == null) {
                Box(modifier = Modifier.fillMaxWidth().padding(BadanSpace.s6), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = colors.primary, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
                }
            } else {
                // Summary
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(HealthCopy.last30))
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            if (loaded.recentRuns.isEmpty()) {
                                Text(env.s(HealthCopy.noRuns), style = BadanType.body, color = colors.textSecondary)
                            } else {
                                for ((outcome, count) in loaded.outcomeCounts) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                                    ) {
                                        OutcomeChip(outcome = outcome)
                                        androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
                                        Text(
                                            text = env.format.integer(count),
                                            style = BadanType.monospaceDigits(BadanType.body),
                                            color = colors.textPrimary,
                                        )
                                    }
                                }
                            }
                            // Completeness check — the anti-HAE spine.
                            if (loaded.jobsWithoutRun.isNotEmpty()) {
                                InfoNote(
                                    icon = Icons.Filled.WarningAmber,
                                    tint = colors.outOfBand,
                                    text = env.s(HealthCopy.jobsWithoutRun(env.format.integer(loaded.jobsWithoutRun.size))),
                                )
                            } else if (loaded.recentRuns.isNotEmpty()) {
                                InfoNote(
                                    icon = Icons.Filled.Check,
                                    tint = colors.inBand,
                                    text = env.s(HealthCopy.everyRunRecorded),
                                )
                            }
                        }
                    }
                }

                // Per-template status
                val userTemplates = loaded.templateStatus.filter { !it.first.isPreset }
                if (userTemplates.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(HealthCopy.templatesHeader))
                        BadanCard {
                            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                                userTemplates.forEachIndexed { index, (template, lastRun) ->
                                    TemplateStatusRow(
                                        template = template,
                                        lastRun = lastRun,
                                        running = isRunning,
                                        onRun = { runTemplate(template) },
                                    )
                                    if (index < userTemplates.size - 1) RowDivider()
                                }
                            }
                        }
                    }
                }

                // Run history
                if (loaded.recentRuns.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(HealthCopy.historyHeader))
                        BadanCard {
                            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                                loaded.recentRuns.forEachIndexed { index, run ->
                                    RunHistoryRow(run = run, showDetail = env.depth.showsPowerDetail)
                                    if (index < loaded.recentRuns.size - 1) RowDivider()
                                }
                            }
                        }
                    }
                }

                // OEM throttling guidance — guidance, never an error (Android honesty).
                if (loaded.cadence.suggestsThrottling(expectedPeriodMs = 3_600_000L)) {
                    InfoNote(
                        icon = Icons.Filled.BatteryAlert,
                        tint = colors.info,
                        text = env.s(HealthCopy.oemGuidance),
                        card = true,
                    )
                }

                // Power-mode background diagnostics
                if (env.depth.showsPowerDetail) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(HealthCopy.backgroundHeader))
                        BadanCard {
                            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                                DetailLine(label = env.s(HealthCopy.bgRuns), value = env.format.integer(loaded.cadence.runs))
                                DetailLine(label = env.s(HealthCopy.bgThrottled), value = env.format.integer(loaded.cadence.throttled))
                                DetailLine(label = env.s(HealthCopy.bgErrors), value = env.format.integer(loaded.cadence.errors))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Outcome chip (icon + word + hue — never colour alone)

@Composable
private fun OutcomeChip(outcome: ExportOutcome) {
    val colors = BadanTheme.colors
    val style = ExportOutcomeCopy.style(outcome)
    val tint: Color = when (style) {
        HealthChipStyle.SUCCESS -> colors.inBand
        HealthChipStyle.PROBLEM -> colors.outOfBand
        HealthChipStyle.NEUTRAL -> colors.info
    }
    val icon: ImageVector = when (style) {
        HealthChipStyle.SUCCESS -> Icons.Filled.Check
        HealthChipStyle.PROBLEM -> Icons.Filled.WarningAmber
        HealthChipStyle.NEUTRAL -> Icons.Filled.Info
    }
    val env = LocalAppEnvironment.current
    Row(
        modifier = Modifier
            .background(tint.copy(alpha = 0.14f), RoundedCornerShape(BadanRadius.chip))
            .padding(horizontal = BadanSpace.s2, vertical = BadanSpace.s1),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(text = env.s(ExportOutcomeCopy.label(outcome)), style = BadanType.chip, color = tint)
    }
}

@Composable
private fun TemplateStatusRow(
    template: ExportTemplate,
    lastRun: ExportRun?,
    running: Boolean,
    onRun: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = template.name,
            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textPrimary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            if (lastRun != null) {
                OutcomeChip(outcome = lastRun.outcome)
                Text(
                    text = formatTimestamp(lastRun.startedAt, env.language),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            } else {
                Text(text = env.s(HealthCopy.neverRun), style = BadanType.caption, color = colors.textSecondary)
            }
        }
        Text(text = env.s(HealthCopy.runsWhenYouAsk), style = BadanType.caption, color = colors.textSecondary)
        RunNowChip(running = running, label = env.s(HealthCopy.runNow), onClick = onRun)
    }
}

@Composable
private fun RunNowChip(running: Boolean, label: String, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.primary.copy(alpha = if (running) 0.5f else 1f))
            .clickable(enabled = !running, onClick = onClick)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        if (running) {
            CircularProgressIndicator(color = colors.onPrimary, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
        } else {
            Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = colors.onPrimary, modifier = Modifier.size(18.dp))
        }
        Text(text = label, style = BadanType.body.copy(fontWeight = FontWeight.SemiBold), color = colors.onPrimary)
    }
}

@Composable
private fun RunHistoryRow(run: ExportRun, showDetail: Boolean) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            OutcomeChip(outcome = run.outcome)
            androidx.compose.foundation.layout.Spacer(Modifier.weight(1f))
            Text(
                text = env.s(triggerLabel(run.trigger)),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        Text(
            text = formatTimestamp(run.startedAt, env.language),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        // Sanitized, value-free detail only (ExportErrorDetail is Ints + a closed enum by
        // construction — it can never hold a health value), and only at power depth.
        if (showDetail) {
            run.errorDetail?.let { detail ->
                Text(
                    text = "${detail.stage.name.lowercase()} · ${env.format.integer(detail.filesWritten)}/${env.format.integer(detail.filesExpected)}",
                    style = BadanType.monospaceDigits(BadanType.caption),
                    color = colors.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun InfoNote(icon: ImageVector, tint: Color, text: String, card: Boolean = false) {
    val colors = BadanTheme.colors
    val content: @Composable () -> Unit = {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
            Text(text = text, style = BadanType.caption, color = colors.textSecondary)
        }
    }
    if (card) {
        BadanCard { content() }
    } else {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(BadanRadius.control))
                .background(tint.copy(alpha = 0.10f))
                .padding(BadanSpace.s3),
        ) { content() }
    }
}
