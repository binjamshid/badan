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
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.app.ValueFormatter
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.export.ExportRunner

// MARK: - Copy

private object TemplatesCopy {
    val title = LocalizedString(en = "Saved templates", ar = "القوالب المحفوظة")
    val trust = LocalizedString(
        en = "A template never automatically includes a newly-added sensitive data type. Meds & symptoms are re-confirmed every run, with a fresh passphrase — saving a template is not standing permission.",
        ar = "لا يتضمّن القالب تلقائياً أي نوع بيانات حساس أُضيف حديثاً. تؤكَّد الأدوية والأعراض في كل تشغيل بعبارة مرور جديدة — حفظ القالب ليس إذناً دائماً.",
    )
    val presetsHeader = LocalizedString(en = "Quick Export presets", ar = "قوالب التصدير السريع")
    val yoursHeader = LocalizedString(en = "Your templates", ar = "قوالبك")
    val readOnly = LocalizedString(en = "Read-only", ar = "للقراءة فقط")
    val sensitive = LocalizedString(en = "Meds & symptoms", ar = "أدوية وأعراض")
    val noneYet = LocalizedString(
        en = "No templates yet. Build one in Advanced export and tap \"Save as template\".",
        ar = "لا توجد قوالب بعد. أنشئ واحداً في التصدير المتقدم واضغط \"الحفظ كقالب\".",
    )
    val run = LocalizedString(en = "Run", ar = "تشغيل")
    val confirmSensitive = LocalizedString(
        en = "This template includes meds & symptoms, so it opens the advanced builder for a fresh passphrase before it runs.",
        ar = "يتضمّن هذا القالب أدوية وأعراضاً، لذا يفتح المُنشئ المتقدم لعبارة مرور جديدة قبل التشغيل.",
    )
    val deleteTitle = LocalizedString(en = "Delete this template?", ar = "حذف هذا القالب؟")
    val deleteBody = LocalizedString(
        en = "The configuration is removed. Exports you already created and their run history stay untouched.",
        ar = "يُحذف الإعداد. تبقى التصديرات التي أنشأتها بالفعل وسِجل تشغيلها دون تغيير.",
    )

    fun rangeLabel(rule: ExportRangeRule, format: ValueFormatter): LocalizedString = when (rule) {
        is ExportRangeRule.LastNDays -> {
            val n = format.integer(rule.safeDays)
            LocalizedString(en = "Last $n days", ar = "آخر $n يوماً")
        }
        is ExportRangeRule.AllTime -> LocalizedString(en = "All time", ar = "كل الوقت")
        is ExportRangeRule.Fixed -> LocalizedString(en = "Custom range", ar = "نطاق مخصص")
        is ExportRangeRule.SinceLastRun -> LocalizedString(en = "Since last run", ar = "منذ آخر تشغيل")
    }
}

/**
 * Resolve a template's stored scope into a concrete run scope, applying its [ExportRangeRule]
 * against the clock so a "last 30 days" saved in March means the last 30 days when it runs in April
 * (the whole reason a rule is stored instead of two dates). Pure and testable.
 *
 * `SinceLastRun` (delta) has no cursor in this interactive path, so — per §12 EPIC-09's input
 * rule — it falls back to a rolling 30-day window rather than silently exporting all of history.
 */
internal fun resolveTemplateRunScope(
    template: ExportTemplate,
    languageScope: ExportScope,
    now: Long,
): ExportScope = when (val rule = template.rangeRule) {
    is ExportRangeRule.LastNDays -> languageScope.copy(startDate = now - rule.safeDays * 86_400_000L, endDate = null)
    is ExportRangeRule.AllTime -> languageScope.copy(startDate = null, endDate = null)
    is ExportRangeRule.Fixed -> languageScope
    is ExportRangeRule.SinceLastRun -> languageScope.copy(startDate = now - 30L * 86_400_000L, endDate = null)
}

// MARK: - Screen

/**
 * The template manager (EPIC-09). Presets are listed read-only; the user's own templates get Run /
 * Edit / Delete. A non-sensitive template runs in place (recorded to the ledger); a sensitive one
 * routes to the advanced builder so a fresh passphrase is typed before anything is written — a saved
 * template is never standing permission to export meds & symptoms (§9.3).
 *
 * Scheduling is intentionally absent: no automation engine is wired on this platform yet (EPIC-15),
 * and a "Schedule" button that did nothing would be exactly the silent-nothing this product is
 * built against. It arrives with the automation wizard, not here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplateManagerScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val context = androidx.compose.ui.platform.LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var templates by remember { mutableStateOf<List<ExportTemplate>>(emptyList()) }
    var isRunning by remember { mutableStateOf(false) }
    var lastResult by remember { mutableStateOf<ExportRunner.ExportResult?>(null) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var pendingDelete by remember { mutableStateOf<ExportTemplate?>(null) }

    fun reload() {
        coroutineScope.launch {
            val loaded = withContext(Dispatchers.IO) {
                runCatching { env.exportTemplates.seedPresets(env.now(), env.deviceId) }
                runCatching { env.exportTemplates.all() }.getOrDefault(emptyList())
            }
            templates = loaded
        }
    }

    LaunchedEffect(Unit) { reload() }

    fun runTemplate(template: ExportTemplate) {
        // A sensitive template never runs from here: it opens the builder, where a fresh passphrase
        // (which is also the run-time re-confirmation) is required before anything is written.
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
        }
    }

    val presets = templates.filter { it.isPreset }
    val userTemplates = templates.filter { !it.isPreset }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(TemplatesCopy.title),
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
            // Trust copy
            BadanCard {
                Row(
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Icon(
                        imageVector = Icons.Filled.Lock,
                        contentDescription = null,
                        tint = colors.primary,
                        modifier = Modifier.size(20.dp),
                    )
                    Text(
                        text = env.s(TemplatesCopy.trust),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }

            errorText?.let { ErrorCard(message = it, showDetail = env.depth.showsPowerDetail) }
            lastResult?.let { result ->
                ExportSuccessCard(result = result, onShare = { shareFiles(context, result.files) })
            }

            // Presets
            if (presets.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(TemplatesCopy.presetsHeader))
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            presets.forEachIndexed { index, t ->
                                TemplateRow(
                                    template = t,
                                    running = isRunning,
                                    onRun = { runTemplate(t) },
                                    onEdit = null,
                                    onDelete = null,
                                )
                                if (index < presets.size - 1) RowDivider()
                            }
                        }
                    }
                }
            }

            // User templates
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(TemplatesCopy.yoursHeader))
                if (userTemplates.isEmpty()) {
                    BadanCard {
                        Text(
                            text = env.s(TemplatesCopy.noneYet),
                            style = BadanType.body,
                            color = colors.textSecondary,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                } else {
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            userTemplates.forEachIndexed { index, t ->
                                TemplateRow(
                                    template = t,
                                    running = isRunning,
                                    onRun = { runTemplate(t) },
                                    onEdit = { nav.push(Route.ExportBuilder(t.id)) },
                                    onDelete = { pendingDelete = t },
                                )
                                if (index < userTemplates.size - 1) RowDivider()
                            }
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(env.s(TemplatesCopy.deleteTitle), style = BadanType.sectionTitle) },
            text = { Text(env.s(TemplatesCopy.deleteBody), style = BadanType.body) },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    coroutineScope.launch {
                        withContext(Dispatchers.IO) {
                            runCatching { env.exportTemplates.softDelete(target.id, env.now()) }
                        }
                        reload()
                    }
                }) { Text(env.s(Loc.delete), color = colors.critical) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text(env.s(Loc.cancel)) }
            },
            shape = RoundedCornerShape(BadanRadius.sheet),
            containerColor = colors.surface,
        )
    }
}

// MARK: - Template row

@Composable
private fun TemplateRow(
    template: ExportTemplate,
    running: Boolean,
    onRun: () -> Unit,
    onEdit: (() -> Unit)?,
    onDelete: (() -> Unit)?,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(
                    text = template.name,
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2), verticalAlignment = Alignment.CenterVertically) {
                    PillLabel(text = template.format.code.uppercase(), tint = colors.primary)
                    Text(
                        text = env.s(TemplatesCopy.rangeLabel(template.rangeRule, env.format)),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
            }
        }
        // Badges — a11y: sensitive/read-only carry an icon + text, never colour alone.
        Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            if (template.isPreset) {
                PillLabel(text = env.s(TemplatesCopy.readOnly), icon = Icons.Filled.Lock, tint = colors.textSecondary)
            }
            if (template.scope.includeSensitive) {
                PillLabel(text = env.s(TemplatesCopy.sensitive), icon = Icons.Filled.Lock, tint = colors.info)
            }
        }
        // Actions
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RunChip(running = running, label = env.s(TemplatesCopy.run), onClick = onRun)
            if (onEdit != null) {
                ActionIcon(icon = Icons.Filled.Edit, contentDescription = env.s(Loc.edit), onClick = onEdit)
            }
            if (onDelete != null) {
                ActionIcon(icon = Icons.Filled.Delete, contentDescription = env.s(Loc.delete), tint = colors.critical, onClick = onDelete)
            }
        }
    }
}

@Composable
private fun RunChip(running: Boolean, label: String, onClick: () -> Unit) {
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
            Icon(imageVector = Icons.Filled.PlayArrow, contentDescription = null, tint = colors.onPrimary, modifier = Modifier.size(18.dp))
        }
        Text(text = label, style = BadanType.body.copy(fontWeight = FontWeight.SemiBold), color = colors.onPrimary)
    }
}

@Composable
private fun ActionIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    tint: androidx.compose.ui.graphics.Color = BadanTheme.colors.textSecondary,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(BadanSpace.touchMin)
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(imageVector = icon, contentDescription = contentDescription, tint = tint, modifier = Modifier.size(22.dp))
    }
}
