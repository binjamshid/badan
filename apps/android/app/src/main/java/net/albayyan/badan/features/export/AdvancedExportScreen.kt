package net.albayyan.badan.features.export

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.AltRoute
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DataObject
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.LayersClear
import androidx.compose.material.icons.filled.MedicalServices
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Save
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.TableChart
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDefaults
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberDatePickerState
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.text.KeyboardOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.ExportFormat
import net.albayyan.badan.domain.ExportRangeRule
import net.albayyan.badan.domain.ExportScope
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.QuickExportPreset
import net.albayyan.badan.domain.Source
import net.albayyan.badan.domain.UnitProfileMode
import net.albayyan.badan.export.ExportPassphrasePolicy
import net.albayyan.badan.export.ExportRunner
import net.albayyan.badan.ontology.MetricRegistry
import net.albayyan.badan.storage.repositories.ExportTemplateError
import net.albayyan.badan.core.Ulid
import java.util.Calendar

// MARK: - Copy

private object BuilderCopy {
    val titleNew = LocalizedString(en = "Advanced export", ar = "تصدير متقدم")
    val titleEdit = LocalizedString(en = "Edit template", ar = "تعديل القالب")

    val metricsTitle = LocalizedString(en = "Metrics", ar = "المؤشرات")
    val metricsAll = LocalizedString(en = "All metrics", ar = "كل المؤشرات")
    val metricsSelected = LocalizedString(en = "{n} selected", ar = "المحدد: {n}")
    val metricsSearch = LocalizedString(en = "Search metrics", ar = "ابحث في المؤشرات")
    val metricsClear = LocalizedString(en = "Select all", ar = "تحديد الكل")

    val sourcesTitle = LocalizedString(en = "Sources", ar = "المصادر")
    val sourcesAll = LocalizedString(en = "All sources", ar = "كل المصادر")

    val routesTitle = LocalizedString(en = "Workout routes (GPX)", ar = "مسارات التمارين (GPX)")
    val routesUnavailable = LocalizedString(
        en = "Route export isn't available in this build yet — your GPS routes never leave the device. It stays a separate opt-in, never bundled with anything else.",
        ar = "تصدير المسارات غير متاح في هذا الإصدار بعد — لا تغادر مساراتك الموقعية الجهاز. يبقى خياراً منفصلاً، لا يُدمج مع غيره أبداً.",
    )

    val customStart = LocalizedString(en = "Start date", ar = "تاريخ البدء")
    val customEnd = LocalizedString(en = "End date", ar = "تاريخ الانتهاء")
    val customInvalid = LocalizedString(
        en = "Start date must be on or before the end date.",
        ar = "يجب أن يكون تاريخ البدء في أو قبل تاريخ الانتهاء.",
    )

    val passphraseIntro = LocalizedString(
        en = "This export will be encrypted. Choose a passphrase (at least {n} characters) — BADAN never stores it. If you forget it, this export cannot be recovered.",
        ar = "سيُشفَّر هذا التصدير. اختر عبارة مرور ({n} أحرف على الأقل) — لا يحتفظ بدن بها أبداً. إن نسيتها، لا يمكن استرداد هذا التصدير.",
    )
    val passphrase = LocalizedString(en = "Passphrase", ar = "عبارة المرور")
    val passphraseConfirm = LocalizedString(en = "Confirm passphrase", ar = "تأكيد عبارة المرور")
    val passphraseTooShort = LocalizedString(en = "Passphrase is too short.", ar = "عبارة المرور قصيرة جداً.")
    val passphraseMismatch = LocalizedString(en = "Passphrases don't match.", ar = "عبارتا المرور غير متطابقتين.")

    val saveTitle = LocalizedString(en = "Save as template", ar = "الحفظ كقالب")
    val saveBlurb = LocalizedString(
        en = "Save this configuration to rerun it in one tap. A template never automatically includes newly-added sensitive data types — you re-confirm meds & symptoms every run.",
        ar = "احفظ هذا الإعداد لإعادة تشغيله بنقرة واحدة. لا يتضمّن القالب تلقائياً أنواع بيانات حساسة أُضيفت حديثاً — تؤكّد الأدوية والأعراض في كل تشغيل.",
    )
    val nameField = LocalizedString(en = "Template name", ar = "اسم القالب")
    val nameTaken = LocalizedString(en = "That name is already in use.", ar = "هذا الاسم مستخدم بالفعل.")
    val save = LocalizedString(en = "Save template", ar = "حفظ القالب")
    val saved = LocalizedString(en = "Saved", ar = "تم الحفظ")
    val presetReadOnly = LocalizedString(
        en = "Quick Export presets are read-only.",
        ar = "قوالب التصدير السريع للقراءة فقط.",
    )
}

// MARK: - Pure range helpers (mirror the iOS builder; testable without Compose)

/** Start of [millis]'s calendar day in the device timezone. */
internal fun startOfDayMillis(millis: Long): Long {
    val cal = Calendar.getInstance().apply {
        timeInMillis = millis
        set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
        set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0)
    }
    return cal.timeInMillis
}

/**
 * The half-open next-midnight bound after [millis]'s calendar day — the correct inclusive upper
 * bound for a same-day-inclusive range filter, so the entire final day is included instead of
 * silently dropping everything after whatever time-of-day the screen happened to be open (mirror of
 * iOS `endOfDayBound`, DATA-04).
 */
internal fun endOfDayBound(millis: Long): Long {
    val cal = Calendar.getInstance().apply { timeInMillis = startOfDayMillis(millis) }
    cal.add(Calendar.DAY_OF_MONTH, 1)
    return cal.timeInMillis
}

/** True only for an unusable custom range (start's day after end's day) — mirror of iOS. */
internal fun isCustomRangeInvalid(startMillis: Long, endMillis: Long): Boolean =
    startOfDayMillis(startMillis) > startOfDayMillis(endMillis)

/** The range rule a builder selection saves into a template. */
internal fun builderRangeRule(range: ExportRange): ExportRangeRule = when (range) {
    ExportRange.LAST30 -> ExportRangeRule.LastNDays(30)
    ExportRange.LAST90 -> ExportRangeRule.LastNDays(90)
    ExportRange.ALL -> ExportRangeRule.AllTime
    ExportRange.CUSTOM -> ExportRangeRule.Fixed
}

/** Best-effort inverse for the edit prefill: pick the builder option nearest a stored rule. */
internal fun builderRangeFor(rule: ExportRangeRule, scope: ExportScope): ExportRange = when {
    rule is ExportRangeRule.LastNDays && rule.safeDays == 30 -> ExportRange.LAST30
    rule is ExportRangeRule.LastNDays && rule.safeDays == 90 -> ExportRange.LAST90
    rule is ExportRangeRule.AllTime -> ExportRange.ALL
    rule is ExportRangeRule.Fixed && (scope.startDate != null || scope.endDate != null) -> ExportRange.CUSTOM
    // SinceLastRun (delta) and odd LastNDays counts can't be represented by the builder's four
    // options; fall back to "all time" so editing never silently narrows the window.
    else -> ExportRange.ALL
}

// MARK: - Screen

/**
 * The advanced export builder (EPIC-11). Everything the Quick Export card hides: exact metrics,
 * per-source filtering, an arbitrary (or custom) date window, the raw/derived/suppressed toggles,
 * the sensitive namespace behind a passphrase, unit profile, and "save as template".
 *
 * [templateId] non-null opens the screen in edit mode, pre-filled from that saved user template.
 * Presets are never editable — the repository refuses `update`/`softDelete` on a preset id — so if
 * one somehow arrives here the Save section shows a read-only notice instead of a Save button.
 *
 * Honesty notes, stated plainly rather than papered over:
 *  - Layout (tidy/wide) and aggregation (hour/day/week + method) are NOT offered here. The one run
 *    entry point, `ExportRunner.run`, takes neither, so a selector for them would be a control that
 *    silently does nothing. `WideCsvProjector`/`MetricAggregator` exist but are not wired into the
 *    run path; wiring them is EPIC-11/13 runner work, out of this UI lane's scope.
 *  - The route (GPX) switch is present and deliberately separate from the sensitive switch (plan
 *    §4 rule 11: routes are their own opt-in, never bundled) but disabled — no route export
 *    representation exists yet (EPIC-12 owns the GPX writer). The copy says so rather than pretending.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdvancedExportScreen(templateId: String?) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    var scope by remember { mutableStateOf(ExportScope(unitProfile = env.profile.unitProfile)) }
    var format by remember { mutableStateOf(ExportFormat.CSV) }
    var range by remember { mutableStateOf(ExportRange.LAST30) }
    var customStart by remember { mutableStateOf(env.now() - 30L * 86_400_000L) }
    var customEnd by remember { mutableStateOf(env.now()) }

    var passphrase by remember { mutableStateOf("") }
    var passphraseConfirm by remember { mutableStateOf("") }

    var selectedMetricIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var metricsExpanded by remember { mutableStateOf(false) }
    var metricQuery by remember { mutableStateOf("") }

    var availableSources by remember { mutableStateOf<List<Source>>(emptyList()) }
    var selectedSourceIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var sourcesExpanded by remember { mutableStateOf(false) }

    var isRunning by remember { mutableStateOf(false) }
    var lastResult by remember { mutableStateOf<ExportRunner.ExportResult?>(null) }
    var errorText by remember { mutableStateOf<String?>(null) }

    // Save-as-template state.
    var saveName by remember { mutableStateOf("") }
    var otherTemplateNames by remember { mutableStateOf<Set<String>>(emptySet()) }
    var editingTemplate by remember { mutableStateOf<ExportTemplate?>(null) }
    var saveError by remember { mutableStateOf<String?>(null) }
    var saved by remember { mutableStateOf(false) }

    val isPreset = templateId != null && QuickExportPreset.presetIds.contains(templateId)

    LaunchedEffect(templateId) {
        val loaded = withContext(Dispatchers.IO) {
            val sources = runCatching { env.catalog.sources() }.getOrDefault(emptyList())
                .filter { it.deletedAt == null }
            val templates = runCatching { env.exportTemplates.all() }.getOrDefault(emptyList())
            val editing = templateId?.let { id -> templates.firstOrNull { it.id == id } }
            Triple(sources, templates, editing)
        }
        availableSources = loaded.first
        // Names of every OTHER live template — the in-memory set the name field validates against so
        // a keystroke never round-trips to SQLite. The repository still enforces uniqueness
        // atomically on insert; this is only for inline feedback.
        otherTemplateNames = loaded.second.filter { it.id != templateId }.map { it.name }.toSet()

        loaded.third?.let { t ->
            editingTemplate = t
            scope = t.scope
            format = t.format
            range = builderRangeFor(t.rangeRule, t.scope)
            t.scope.startDate?.let { customStart = it }
            t.scope.endDate?.let { customEnd = it }
            selectedMetricIds = t.scope.metricIds?.toSet() ?: emptySet()
            selectedSourceIds = t.scope.sourceIds?.toSet() ?: emptySet()
            saveName = t.name
        }
    }

    val passphraseValid = ExportPassphrasePolicy.isValid(passphrase) &&
        ExportPassphrasePolicy.matches(passphrase, passphraseConfirm)
    val customInvalid = range == ExportRange.CUSTOM && isCustomRangeInvalid(customStart, customEnd)
    val sensitiveBlocked = scope.includeSensitive && !passphraseValid
    val runEnabled = !customInvalid && !sensitiveBlocked

    fun buildRunScope(): ExportScope {
        val metricIds = selectedMetricIds.takeIf { it.isNotEmpty() }?.toList()
        val sourceIds = selectedSourceIds
            .takeIf { it.isNotEmpty() && it.size < availableSources.size }?.toList()
        val (start, end) = when (range) {
            ExportRange.CUSTOM -> startOfDayMillis(customStart) to endOfDayBound(customEnd)
            ExportRange.ALL -> null to null
            else -> range.startDate(env.now()) to null
        }
        return scope.copy(
            metricIds = metricIds,
            sourceIds = sourceIds,
            startDate = start,
            endDate = end,
            language = env.language,
        )
    }

    fun runExport() {
        if (isRunning || !runEnabled) return
        isRunning = true
        errorText = null
        lastResult = null
        val runScope = buildRunScope()
        val chosenFormat = format
        val pass = if (runScope.includeSensitive) passphrase else null
        coroutineScope.launch {
            val outcome = withContext(Dispatchers.IO) {
                runCatching {
                    runCatching { pruneOldExports(context.cacheDir, env.exportJobs.recent(HISTORY_PAGE_SIZE)) }
                    runAndRecordExport(
                        env = env,
                        scope = runScope,
                        format = chosenFormat,
                        templateId = editingTemplate?.id,
                        outputDir = newExportDir(context),
                        passphrase = pass,
                    )
                }
            }
            outcome
                .onSuccess { lastResult = it }
                .onFailure { errorText = it.toString() }
            isRunning = false
        }
    }

    fun saveTemplate() {
        val name = saveName.trim()
        if (name.isEmpty() || isPreset) return
        saveError = null
        val now = env.now()
        val runScope = buildRunScope().copy(language = env.language)
        val existing = editingTemplate
        val template = ExportTemplate(
            id = existing?.id ?: Ulid.newId(),
            name = name,
            scope = runScope,
            rangeRule = builderRangeRule(range),
            format = format,
            aggregation = existing?.aggregation ?: net.albayyan.badan.domain.ExportAggregation.Raw,
            layout = existing?.layout ?: net.albayyan.badan.domain.ExportLayout.TIDY,
            includeSchemaDocs = existing?.includeSchemaDocs ?: false,
            destinationId = existing?.destinationId ?: net.albayyan.badan.domain.ExportDestination.SHARE_SHEET_ID,
            createdAt = existing?.createdAt ?: now,
            updatedAt = now,
            originDeviceId = existing?.originDeviceId ?: env.deviceId,
        )
        coroutineScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    if (existing != null) env.exportTemplates.update(template)
                    else env.exportTemplates.insert(template)
                }
            }
            result
                .onSuccess { saved = true; nav.pop() }
                .onFailure { e ->
                    saveError = when (e) {
                        is ExportTemplateError.NameTaken -> env.s(BuilderCopy.nameTaken)
                        is ExportTemplateError.PresetIsReadOnly -> env.s(BuilderCopy.presetReadOnly)
                        else -> env.s(ExportCopy.couldntPrepare)
                    }
                }
        }
    }

    val nameCollides = saveName.trim().isNotEmpty() && otherTemplateNames.contains(saveName.trim())

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(if (templateId != null) BuilderCopy.titleEdit else BuilderCopy.titleNew),
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
                        ScopeToggleRow(
                            title = env.s(Loc.includeRaw),
                            subtitle = env.s(ExportCopy.includeRawSubtitle),
                            icon = Icons.Filled.MonitorHeart,
                            checked = scope.includeRaw,
                            onCheckedChange = { scope = scope.copy(includeRaw = it) },
                        )
                        RowDivider()
                        ScopeToggleRow(
                            title = env.s(Loc.includeDerived),
                            subtitle = env.s(ExportCopy.includeDerivedSubtitle),
                            icon = Icons.Filled.Functions,
                            checked = scope.includeDerived,
                            onCheckedChange = { scope = scope.copy(includeDerived = it) },
                        )
                        RowDivider()
                        ScopeToggleRow(
                            title = env.s(Loc.includeSuppressed),
                            subtitle = env.s(ExportCopy.includeSuppressedSubtitle),
                            icon = Icons.Filled.LayersClear,
                            checked = scope.includeSuppressed,
                            onCheckedChange = { scope = scope.copy(includeSuppressed = it) },
                        )
                        RowDivider()
                        // Sensitive — its own switch, gated on the Settings module toggle (I7).
                        ScopeToggleRow(
                            title = env.s(Loc.includeSensitive),
                            subtitle = env.s(ExportCopy.includeSensitiveSubtitle),
                            icon = Icons.Filled.MedicalServices,
                            checked = scope.includeSensitive,
                            enabled = env.profile.sensitiveModulesEnabled,
                            onCheckedChange = { on ->
                                scope = scope.copy(includeSensitive = on)
                                if (!on) { passphrase = ""; passphraseConfirm = "" }
                            },
                        )
                        if (!env.profile.sensitiveModulesEnabled) {
                            Text(
                                text = env.s(ExportCopy.sensitiveModuleDisabledNote),
                                style = BadanType.caption,
                                color = colors.textSecondary,
                            )
                        } else if (scope.includeSensitive) {
                            SensitiveNote(text = env.s(ExportCopy.sensitiveNote))
                            PassphraseFields(
                                passphrase = passphrase,
                                confirm = passphraseConfirm,
                                onPassphrase = { passphrase = it },
                                onConfirm = { passphraseConfirm = it },
                            )
                        }
                        RowDivider()
                        // Routes — a distinct opt-in, never folded into "sensitive" (plan §4 rule
                        // 11). Disabled with honest copy: no GPX export representation exists yet.
                        ScopeToggleRow(
                            title = env.s(BuilderCopy.routesTitle),
                            subtitle = env.s(BuilderCopy.routesUnavailable),
                            icon = Icons.Filled.AltRoute,
                            checked = false,
                            enabled = false,
                            onCheckedChange = {},
                        )
                    }
                }
            }

            // Metrics
            MetricPickerSection(
                registry = env.registry,
                depth = env.depth,
                language = env.language,
                expanded = metricsExpanded,
                onToggleExpanded = { metricsExpanded = !metricsExpanded },
                query = metricQuery,
                onQuery = { metricQuery = it },
                selected = selectedMetricIds,
                onToggleMetric = { id ->
                    selectedMetricIds = selectedMetricIds.toMutableSet().apply {
                        if (contains(id)) remove(id) else add(id)
                    }
                },
                onSelectAll = { selectedMetricIds = emptySet() },
            )

            // Sources
            if (availableSources.isNotEmpty()) {
                SourcePickerSection(
                    sources = availableSources,
                    expanded = sourcesExpanded,
                    onToggleExpanded = { sourcesExpanded = !sourcesExpanded },
                    selected = selectedSourceIds,
                    onToggleSource = { id ->
                        selectedSourceIds = selectedSourceIds.toMutableSet().apply {
                            if (contains(id)) remove(id) else add(id)
                        }
                    },
                    onSelectAll = { selectedSourceIds = emptySet() },
                )
            }

            // Date range
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(ExportCopy.dateRange))
                ExportSegmented(
                    options = ExportRange.entries.map { it to env.s(it.label(env.format)) },
                    selected = range,
                    onSelect = { range = it },
                )
                if (range == ExportRange.CUSTOM) {
                    DateFieldRow(
                        label = env.s(BuilderCopy.customStart),
                        millis = customStart,
                        onPick = { customStart = it },
                    )
                    DateFieldRow(
                        label = env.s(BuilderCopy.customEnd),
                        millis = customEnd,
                        onPick = { customEnd = it },
                    )
                    if (customInvalid) {
                        Text(
                            text = env.s(BuilderCopy.customInvalid),
                            style = BadanType.caption,
                            color = colors.outOfBand,
                        )
                    }
                }
            }

            // Units
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(Loc.units))
                ExportSegmented(
                    options = listOf(
                        UnitProfileMode.CANONICAL to env.s(ExportCopy.unitSource),
                        UnitProfileMode.DISPLAY to env.s(ExportCopy.unitDisplay),
                    ),
                    selected = scope.unitProfile,
                    onSelect = { scope = scope.copy(unitProfile = it) },
                )
                Text(
                    text = env.s(ExportCopy.unitNote),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }

            ScopeSummary(scope = buildRunScope())
            RunButton(isRunning = isRunning, enabled = runEnabled, onClick = ::runExport)

            errorText?.let { ErrorCard(message = it, showDetail = env.depth.showsPowerDetail) }
            lastResult?.let { result ->
                ExportSuccessCard(result = result, onShare = { shareFiles(context, result.files) })
            }

            // Save as template
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(BuilderCopy.saveTitle))
                BadanCard {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        Text(
                            text = env.s(BuilderCopy.saveBlurb),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                        if (isPreset) {
                            Text(
                                text = env.s(BuilderCopy.presetReadOnly),
                                style = BadanType.body,
                                color = colors.textSecondary,
                            )
                        } else {
                            OutlinedTextField(
                                value = saveName,
                                onValueChange = { saveName = it; saved = false; saveError = null },
                                label = { Text(env.s(BuilderCopy.nameField)) },
                                singleLine = true,
                                isError = nameCollides || saveError != null,
                                modifier = Modifier.fillMaxWidth(),
                                colors = TextFieldDefaults.colors(
                                    focusedContainerColor = colors.surface,
                                    unfocusedContainerColor = colors.surface,
                                    focusedTextColor = colors.textPrimary,
                                    unfocusedTextColor = colors.textPrimary,
                                    cursorColor = colors.primary,
                                    focusedIndicatorColor = colors.primary,
                                    unfocusedIndicatorColor = colors.separator,
                                    focusedLabelColor = colors.primary,
                                    unfocusedLabelColor = colors.textSecondary,
                                ),
                            )
                            // Inline collision validation (§16 friction risk: name collisions).
                            if (nameCollides || saveError != null) {
                                Text(
                                    text = saveError ?: env.s(BuilderCopy.nameTaken),
                                    style = BadanType.caption,
                                    color = colors.outOfBand,
                                )
                            }
                            SaveTemplateButton(
                                label = env.s(BuilderCopy.save),
                                enabled = saveName.trim().isNotEmpty() && !nameCollides,
                                onClick = ::saveTemplate,
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Scope summary

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
            append(env.s(ExportCopy.scopeIncludes)); append(' '); append(included.joinToString(", "))
        }
        if (excluded.isNotEmpty()) {
            if (isNotEmpty()) append("  ")
            append(env.s(ExportCopy.scopeExcludes)); append(' '); append(excluded.joinToString(", "))
        }
    }
    Text(text = text, style = BadanType.caption, color = colors.textSecondary)
}

// MARK: - Metric picker

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun MetricPickerSection(
    registry: MetricRegistry,
    depth: net.albayyan.badan.domain.DepthPolicy,
    language: net.albayyan.badan.core.AppLanguage,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    query: String,
    onQuery: (String) -> Unit,
    selected: Set<String>,
    onToggleMetric: (String) -> Unit,
    onSelectAll: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val summary = if (selected.isEmpty()) {
        env.s(BuilderCopy.metricsAll)
    } else {
        env.s(BuilderCopy.metricsSelected.filling(mapOf("n" to env.format.integer(selected.size))))
    }
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(BuilderCopy.metricsTitle))
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(BadanRadius.control))
                        .clickable(onClick = onToggleExpanded)
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(text = summary, style = BadanType.body, color = colors.textPrimary, modifier = Modifier.weight(1f))
                    Icon(
                        imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(22.dp),
                    )
                }
                if (expanded) {
                    OutlinedTextField(
                        value = query,
                        onValueChange = onQuery,
                        label = { Text(env.s(BuilderCopy.metricsSearch)) },
                        singleLine = true,
                        leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null, tint = colors.textSecondary) },
                        modifier = Modifier.fillMaxWidth(),
                        colors = TextFieldDefaults.colors(
                            focusedContainerColor = colors.surface,
                            unfocusedContainerColor = colors.surface,
                            focusedTextColor = colors.textPrimary,
                            unfocusedTextColor = colors.textPrimary,
                            cursorColor = colors.primary,
                            focusedIndicatorColor = colors.primary,
                            unfocusedIndicatorColor = colors.separator,
                            focusedLabelColor = colors.primary,
                            unfocusedLabelColor = colors.textSecondary,
                        ),
                    )
                    if (selected.isNotEmpty()) {
                        Text(
                            text = env.s(BuilderCopy.metricsClear),
                            style = BadanType.caption.copy(fontWeight = FontWeight.Medium),
                            color = colors.primary,
                            modifier = Modifier
                                .clip(RoundedCornerShape(BadanRadius.control))
                                .clickable(onClick = onSelectAll)
                                .padding(vertical = BadanSpace.s1),
                        )
                    }
                    val results = if (query.isBlank()) registry.all else registry.search(query)
                    for (def in results) {
                        SelectableRow(
                            label = def.label(depth, language),
                            selected = selected.contains(def.metricId),
                            onClick = { onToggleMetric(def.metricId) },
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Source picker

@Composable
private fun SourcePickerSection(
    sources: List<Source>,
    expanded: Boolean,
    onToggleExpanded: () -> Unit,
    selected: Set<String>,
    onToggleSource: (String) -> Unit,
    onSelectAll: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val summary = if (selected.isEmpty()) {
        env.s(BuilderCopy.sourcesAll)
    } else {
        env.s(BuilderCopy.metricsSelected.filling(mapOf("n" to env.format.integer(selected.size))))
    }
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(BuilderCopy.sourcesTitle))
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(BadanRadius.control))
                        .clickable(onClick = onToggleExpanded)
                        .heightIn(min = BadanSpace.touchMin),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                ) {
                    Text(text = summary, style = BadanType.body, color = colors.textPrimary, modifier = Modifier.weight(1f))
                    Icon(
                        imageVector = if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(22.dp),
                    )
                }
                if (expanded) {
                    if (selected.isNotEmpty()) {
                        Text(
                            text = env.s(BuilderCopy.metricsClear),
                            style = BadanType.caption.copy(fontWeight = FontWeight.Medium),
                            color = colors.primary,
                            modifier = Modifier
                                .clip(RoundedCornerShape(BadanRadius.control))
                                .clickable(onClick = onSelectAll)
                                .padding(vertical = BadanSpace.s1),
                        )
                    }
                    for (source in sources) {
                        SelectableRow(
                            label = source.displayName,
                            selected = selected.contains(source.id),
                            onClick = { onToggleSource(source.id) },
                        )
                    }
                }
            }
        }
    }
}

/**
 * A tappable inclusion row. State is carried by the filled/empty circle glyph AND the label weight,
 * never by hue alone (a11y — status never colour-only). Selecting nothing means "all", which the
 * section summary states explicitly, so an empty selection is never ambiguous.
 */
@Composable
private fun SelectableRow(label: String, selected: Boolean, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClick = onClick)
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) colors.primary else colors.separator,
            modifier = Modifier.size(22.dp),
        )
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal),
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

// MARK: - Passphrase

@Composable
private fun PassphraseFields(
    passphrase: String,
    confirm: String,
    onPassphrase: (String) -> Unit,
    onConfirm: (String) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val minLen = env.format.integer(ExportPassphrasePolicy.MINIMUM_LENGTH)
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = env.s(BuilderCopy.passphraseIntro.filling(mapOf("n" to minLen))),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        PassphraseField(label = env.s(BuilderCopy.passphrase), value = passphrase, onChange = onPassphrase)
        PassphraseField(label = env.s(BuilderCopy.passphraseConfirm), value = confirm, onChange = onConfirm)
        if (passphrase.isNotEmpty() && !ExportPassphrasePolicy.isValid(passphrase)) {
            Text(env.s(BuilderCopy.passphraseTooShort), style = BadanType.caption, color = colors.outOfBand)
        } else if (confirm.isNotEmpty() && !ExportPassphrasePolicy.matches(passphrase, confirm)) {
            Text(env.s(BuilderCopy.passphraseMismatch), style = BadanType.caption, color = colors.outOfBand)
        }
    }
}

@Composable
private fun PassphraseField(label: String, value: String, onChange: (String) -> Unit) {
    val colors = BadanTheme.colors
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        singleLine = true,
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
        modifier = Modifier.fillMaxWidth(),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = colors.surface,
            unfocusedContainerColor = colors.surface,
            focusedTextColor = colors.textPrimary,
            unfocusedTextColor = colors.textPrimary,
            cursorColor = colors.primary,
            focusedIndicatorColor = colors.primary,
            unfocusedIndicatorColor = colors.separator,
            focusedLabelColor = colors.primary,
            unfocusedLabelColor = colors.textSecondary,
        ),
    )
}

// MARK: - Date field

@Composable
@OptIn(ExperimentalMaterial3Api::class)
private fun DateFieldRow(label: String, millis: Long, onPick: (Long) -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    var show by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.surfaceElevated)
            .clickable { show = true }
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(text = label, style = BadanType.body, color = colors.textSecondary, modifier = Modifier.weight(1f))
        Text(text = formatTimestamp(millis, env.language).substringBefore(","), style = BadanType.body, color = colors.textPrimary)
    }
    if (show) {
        val state = rememberDatePickerState(initialSelectedDateMillis = millis)
        DatePickerDialog(
            onDismissRequest = { show = false },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let(onPick)
                    show = false
                }) { Text(env.s(Loc.save)) }
            },
            dismissButton = {
                TextButton(onClick = { show = false }) { Text(env.s(Loc.cancel)) }
            },
            shape = RoundedCornerShape(BadanRadius.sheet),
            colors = DatePickerDefaults.colors().copy(containerColor = colors.surface),
        ) {
            DatePicker(state = state)
        }
    }
}

// MARK: - Save button

@Composable
private fun SaveTemplateButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(colors.primary.copy(alpha = if (enabled) 1f else 0.5f))
            .clickable(enabled = enabled, onClick = onClick)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s4),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2, Alignment.CenterHorizontally),
    ) {
        Icon(
            imageVector = Icons.Filled.Save,
            contentDescription = null,
            tint = colors.onPrimary,
            modifier = Modifier.size(20.dp),
        )
        Text(text = label, style = BadanType.body.copy(fontWeight = FontWeight.SemiBold), color = colors.onPrimary)
    }
}
