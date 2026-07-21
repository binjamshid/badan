package net.albayyan.badan.features.export

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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Autorenew
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.PauseCircle
import androidx.compose.material.icons.filled.RadioButtonChecked
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TimePicker
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTimePickerState
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
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.PillLabel
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.ExportTemplate
import net.albayyan.badan.domain.automation.AutomationCadence
import net.albayyan.badan.domain.automation.AutomationSchedule
import net.albayyan.badan.domain.automation.AutomationTier
import net.albayyan.badan.domain.automation.QuietHours
import net.albayyan.badan.storage.repositories.AutomationScheduleRepository

// MARK: - Shared icon mapping (UI-only, so it stays out of the pure AutomationPresentation)

/** The tier's glyph — paired with [AutomationPresentation.tierChip]/tierLabel text so status is
 *  never colour-only. Shared by the wizard and the health dashboard. */
internal fun automationTierIcon(tier: AutomationTier): ImageVector = when (tier) {
    AutomationTier.OPPORTUNISTIC_BACKGROUND -> Icons.Filled.Autorenew
    AutomationTier.SHORTCUT_DRIVEN -> Icons.Filled.Schedule
    AutomationTier.MANUAL_ONLY -> Icons.Filled.TouchApp
}

/** The status glyph — paired with [AutomationPresentation.statusLabel] text. */
internal fun automationStatusIcon(status: AutomationPresentation.StatusKind): ImageVector = when (status) {
    AutomationPresentation.StatusKind.ACTIVE -> Icons.Filled.CheckCircle
    AutomationPresentation.StatusKind.PAUSED -> Icons.Filled.PauseCircle
    AutomationPresentation.StatusKind.OFF -> Icons.Filled.Bedtime
}

// MARK: - Copy

private object WizardCopy {
    val title = LocalizedString(en = "Set up automation", ar = "إعداد الأتمتة")
    fun stepOf(current: String, total: String) =
        LocalizedString(en = "Step $current of $total", ar = "الخطوة $current من $total")

    val pickTemplateHeader = LocalizedString(en = "What should run?", ar = "ما الذي سيُشغَّل؟")
    val pickTemplateIntro = LocalizedString(
        en = "Choose one of your saved export templates. Automation reruns that exact setup — it never widens what a template already exports.",
        ar = "اختر أحد قوالب التصدير المحفوظة لديك. تعيد الأتمتة تشغيل الإعداد نفسه بالضبط — ولا توسّع أبداً ما يصدّره القالب.",
    )
    val noTemplates = LocalizedString(
        en = "You don't have any saved templates yet. Build an export and save it as a template first, then come back to schedule it.",
        ar = "لا توجد لديك قوالب محفوظة بعد. أنشئ تصديراً واحفظه كقالب أولاً، ثم عُد لجدولته.",
    )
    val buildTemplate = LocalizedString(en = "Build a template", ar = "أنشئ قالباً")
    val alreadyScheduled = LocalizedString(en = "Already scheduled", ar = "مجدول بالفعل")

    val howHeader = LocalizedString(en = "How should it run?", ar = "كيف سيعمل؟")
    val howIntro = LocalizedString(
        en = "This is the honest part. Each option tells you exactly how reliable it is — read it before you choose.",
        ar = "هذا هو الجزء الصريح. يخبرك كل خيار بمدى موثوقيته بالضبط — اقرأه قبل أن تختار.",
    )
    val cadenceHeader = LocalizedString(en = "How often", ar = "كم مرة")
    val quietHeader = LocalizedString(en = "Quiet hours", ar = "ساعات الهدوء")
    val quietToggle = LocalizedString(en = "Don't run during a window", ar = "لا تُشغّل خلال فترة")
    val quietHint = LocalizedString(
        en = "The schedule stays quiet between these times — useful overnight. It resumes on its own afterwards.",
        ar = "يبقى الجدول هادئاً بين هذين الوقتين — مفيد أثناء الليل. ويستأنف تلقائياً بعدها.",
    )
    val quietFrom = LocalizedString(en = "From", ar = "من")
    val quietTo = LocalizedString(en = "To", ar = "إلى")

    val reviewHeader = LocalizedString(en = "Review", ar = "المراجعة")
    val reviewTemplate = LocalizedString(en = "Template", ar = "القالب")
    val reviewReliability = LocalizedString(en = "Reliability", ar = "الموثوقية")
    val reviewWhen = LocalizedString(en = "When", ar = "متى")
    val reviewQuiet = LocalizedString(en = "Quiet hours", ar = "ساعات الهدوء")
    val ledgerNote = LocalizedString(
        en = "Every run lands in Export & Automation Health — including the ones that find nothing and the ones that fail. If it isn't there, it didn't run.",
        ar = "يظهر كل تشغيل في حالة التصدير والأتمتة — بما فيها ما لم يجد شيئاً وما أخفق. وإن لم يكن هناك فهو لم يعمل.",
    )
    val oemNote = LocalizedString(
        en = "Some phones (e.g. Samsung, Xiaomi) delay background work to save battery. If it runs late, allow BADAN to run in the background in your phone's battery settings.",
        ar = "تؤخّر بعض الهواتف (مثل سامسونج وشاومي) عمل الخلفية لتوفير البطارية. إن تأخّر التشغيل، فاسمح لبدن بالعمل في الخلفية من إعدادات البطارية بهاتفك.",
    )

    val back = LocalizedString(en = "Back", ar = "رجوع")
    val continueLabel = LocalizedString(en = "Continue", ar = "متابعة")
    val enable = LocalizedString(en = "Enable automation", ar = "تفعيل الأتمتة")
}

// MARK: - Screen

/**
 * EPIC-15 — the automation setup wizard (Android). A guided three-step flow that turns an existing
 * export template into an [AutomationSchedule], and — the whole point — makes the reliability tier a
 * *mandatory* step the user reads BEFORE anything is enabled (§16: "the wizard IS the
 * expectation-setting"). WorkManager is genuinely more reliable than iOS best-effort, so the
 * background label is honest in that direction too ("usually within an hour"), while still disclosing
 * OEM battery throttling.
 *
 * Android offers two tiers here — background and manual — because there is no timed-shortcut path on
 * Android yet (§14); offering a "Shortcuts" tier whose tap did nothing would be exactly the silent
 * nothing this product is built against.
 *
 * The screen creates the schedule row and pops; it never runs anything itself. A background schedule
 * fires from the WorkManager wake; a manual one from a Run-now tap — so nothing here can make the
 * tier label a lie.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutomationSetupScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val coroutineScope = rememberCoroutineScope()

    var step by remember { mutableStateOf(0) }
    var templates by remember { mutableStateOf<List<ExportTemplate>>(emptyList()) }
    var scheduledIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    var selectedTemplateId by remember { mutableStateOf<String?>(null) }
    var tier by remember { mutableStateOf(AutomationTier.OPPORTUNISTIC_BACKGROUND) }
    var cadence by remember { mutableStateOf(AutomationCadence.DAILY_BEST_EFFORT) }
    var quietEnabled by remember { mutableStateOf(false) }
    var quietStartMin by remember { mutableStateOf(22 * 60) }
    var quietEndMin by remember { mutableStateOf(7 * 60) }
    var editing by remember { mutableStateOf<QuietField?>(null) }

    val offeredTiers = listOf(AutomationTier.OPPORTUNISTIC_BACKGROUND, AutomationTier.MANUAL_ONLY)
    val totalSteps = 3
    val selectedTemplate = templates.firstOrNull { it.id == selectedTemplateId }

    fun reload() {
        coroutineScope.launch {
            val loaded = withContext(Dispatchers.IO) {
                runCatching { env.exportTemplates.seedPresets(env.now(), env.deviceId) }
                val all = runCatching { env.exportTemplates.all() }.getOrDefault(emptyList())
                val schedules = runCatching { AutomationScheduleRepository(env.database.main).all() }
                    .getOrDefault(emptyList())
                all.filter { !it.isPreset } to schedules.map { it.templateId }.toSet()
            }
            templates = loaded.first
            scheduledIds = loaded.second
            if (selectedTemplateId != null && templates.none { it.id == selectedTemplateId }) {
                selectedTemplateId = null
            }
        }
    }

    LaunchedEffect(Unit) { reload() }

    fun enable() {
        val template = selectedTemplate ?: return
        // Cadence and quiet hours only mean anything for the background tier — the engine never
        // consults them for the manual tier, which fires from a tap. Store an inert ON_NEW_DATA for
        // manual so the row is well-formed without implying a cadence the tier can't honor.
        val effectiveCadence = if (tier == AutomationTier.OPPORTUNISTIC_BACKGROUND) cadence else AutomationCadence.ON_NEW_DATA
        val quiet = if (tier == AutomationTier.OPPORTUNISTIC_BACKGROUND && quietEnabled) {
            QuietHours(quietStartMin, quietEndMin)
        } else {
            null
        }
        coroutineScope.launch {
            withContext(Dispatchers.IO) {
                val now = env.now()
                runCatching {
                    AutomationScheduleRepository(env.database.main).upsert(
                        AutomationSchedule(
                            id = Ulid.newId(),
                            templateId = template.id,
                            tier = tier,
                            desiredCadence = effectiveCadence,
                            quietHours = quiet,
                            enabled = true,
                            createdAt = now,
                            updatedAt = now,
                            originDeviceId = env.deviceId,
                        ),
                    )
                }
            }
            nav.pop()
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(WizardCopy.title),
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
        bottomBar = {
            BottomBar(
                showBack = step > 0,
                isFinal = step == totalSteps - 1,
                primaryEnabled = !(step == 0 && selectedTemplate == null),
                onBack = { step -= 1 },
                onPrimary = { if (step == totalSteps - 1) enable() else step += 1 },
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
            StepIndicator(current = step, total = totalSteps)
            when (step) {
                0 -> TemplateStep(
                    templates = templates,
                    scheduledIds = scheduledIds,
                    selectedId = selectedTemplateId,
                    onSelect = { selectedTemplateId = it },
                    onBuild = { nav.push(Route.ExportBuilder()) },
                )
                1 -> HowStep(
                    tiers = offeredTiers,
                    tier = tier,
                    onTier = { tier = it },
                    cadence = cadence,
                    onCadence = { cadence = it },
                    quietEnabled = quietEnabled,
                    onQuietEnabled = { quietEnabled = it },
                    quietStartMin = quietStartMin,
                    quietEndMin = quietEndMin,
                    onEditQuiet = { editing = it },
                )
                else -> ReviewStep(
                    template = selectedTemplate,
                    tier = tier,
                    cadence = cadence,
                    quietEnabled = quietEnabled,
                    quietStartMin = quietStartMin,
                    quietEndMin = quietEndMin,
                )
            }
        }
    }

    // Quiet-hours time picker (Material3), reused for both the From and To fields.
    editing?.let { field ->
        val initial = if (field == QuietField.START) quietStartMin else quietEndMin
        val tpState = rememberTimePickerState(
            initialHour = initial / 60,
            initialMinute = initial % 60,
            is24Hour = false,
        )
        AlertDialog(
            onDismissRequest = { editing = null },
            confirmButton = {
                TextButton(onClick = {
                    val minutes = tpState.hour * 60 + tpState.minute
                    if (field == QuietField.START) quietStartMin = minutes else quietEndMin = minutes
                    editing = null
                }) { Text(env.s(Loc.save)) }
            },
            dismissButton = {
                TextButton(onClick = { editing = null }) { Text(env.s(Loc.cancel)) }
            },
            text = { TimePicker(state = tpState) },
            shape = RoundedCornerShape(BadanRadius.sheet),
            containerColor = colors.surface,
        )
    }
}

private enum class QuietField { START, END }

// MARK: - Step indicator

@Composable
private fun StepIndicator(current: Int, total: Int) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = env.s(WizardCopy.stepOf(env.format.integer(current + 1), env.format.integer(total))),
            style = BadanType.caption.copy(fontWeight = FontWeight.SemiBold),
            color = colors.textSecondary,
        )
        Spacer(Modifier.weight(1f))
        Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
            for (i in 0 until total) {
                Box(
                    modifier = Modifier
                        .width(if (i == current) 20.dp else 8.dp)
                        .height(6.dp)
                        .clip(RoundedCornerShape(3.dp))
                        .background(if (i <= current) colors.primary else colors.separator),
                )
            }
        }
    }
}

// MARK: - Step 1: template

@Composable
private fun TemplateStep(
    templates: List<ExportTemplate>,
    scheduledIds: Set<String>,
    selectedId: String?,
    onSelect: (String) -> Unit,
    onBuild: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        SectionHeader(title = env.s(WizardCopy.pickTemplateHeader))
        Text(env.s(WizardCopy.pickTemplateIntro), style = BadanType.body, color = colors.textSecondary)
        if (templates.isEmpty()) {
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    Text(env.s(WizardCopy.noTemplates), style = BadanType.body, color = colors.textSecondary)
                    Row(
                        modifier = Modifier
                            .clip(RoundedCornerShape(BadanRadius.control))
                            .clickable(onClick = onBuild)
                            .heightIn(min = BadanSpace.touchMin)
                            .padding(horizontal = BadanSpace.s2),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        Icon(Icons.Filled.Add, contentDescription = null, tint = colors.primary, modifier = Modifier.size(20.dp))
                        Text(
                            text = env.s(WizardCopy.buildTemplate),
                            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                            color = colors.primary,
                        )
                    }
                }
            }
        } else {
            BadanCard {
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    templates.forEachIndexed { index, template ->
                        TemplateChoiceRow(
                            template = template,
                            selected = selectedId == template.id,
                            scheduled = scheduledIds.contains(template.id),
                            onSelect = { onSelect(template.id) },
                        )
                        if (index < templates.size - 1) RowDivider()
                    }
                }
            }
        }
    }
}

@Composable
private fun TemplateChoiceRow(
    template: ExportTemplate,
    selected: Boolean,
    scheduled: Boolean,
    onSelect: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClick = onSelect)
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = template.name,
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2), verticalAlignment = Alignment.CenterVertically) {
                PillLabel(text = template.format.code.uppercase(), tint = colors.primary)
                if (scheduled) {
                    PillLabel(text = env.s(WizardCopy.alreadyScheduled), icon = Icons.Filled.Schedule, tint = colors.info)
                }
            }
        }
        Icon(
            imageVector = if (selected) Icons.Filled.RadioButtonChecked else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) colors.primary else colors.separator,
            modifier = Modifier.size(22.dp),
        )
    }
}

// MARK: - Step 2: how it runs

@Composable
private fun HowStep(
    tiers: List<AutomationTier>,
    tier: AutomationTier,
    onTier: (AutomationTier) -> Unit,
    cadence: AutomationCadence,
    onCadence: (AutomationCadence) -> Unit,
    quietEnabled: Boolean,
    onQuietEnabled: (Boolean) -> Unit,
    quietStartMin: Int,
    quietEndMin: Int,
    onEditQuiet: (QuietField) -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            SectionHeader(title = env.s(WizardCopy.howHeader))
            Text(env.s(WizardCopy.howIntro), style = BadanType.body, color = colors.textSecondary)
            for (t in tiers) {
                TierOption(tier = t, selected = tier == t, onSelect = { onTier(t) })
            }
        }
        if (tier == AutomationTier.OPPORTUNISTIC_BACKGROUND) {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(WizardCopy.cadenceHeader))
                BadanCard {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        val cadences = AutomationCadence.entries
                        cadences.forEachIndexed { index, c ->
                            CadenceRow(cadence = c, selected = cadence == c, onSelect = { onCadence(c) })
                            if (index < cadences.size - 1) RowDivider()
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                SectionHeader(title = env.s(WizardCopy.quietHeader))
                BadanCard {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                            Text(
                                text = env.s(WizardCopy.quietToggle),
                                style = BadanType.body,
                                color = colors.textPrimary,
                                modifier = Modifier.weight(1f),
                            )
                            Switch(
                                checked = quietEnabled,
                                onCheckedChange = onQuietEnabled,
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
                        if (quietEnabled) {
                            Text(env.s(WizardCopy.quietHint), style = BadanType.caption, color = colors.textSecondary)
                            Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                                QuietTimeField(label = env.s(WizardCopy.quietFrom), minutes = quietStartMin, onClick = { onEditQuiet(QuietField.START) }, modifier = Modifier.weight(1f))
                                QuietTimeField(label = env.s(WizardCopy.quietTo), minutes = quietEndMin, onClick = { onEditQuiet(QuietField.END) }, modifier = Modifier.weight(1f))
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TierOption(tier: AutomationTier, selected: Boolean, onSelect: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onSelect)
            .background(if (selected) colors.primary.copy(alpha = 0.08f) else colors.surface, shape)
            .border(width = if (selected) 2.dp else 1.dp, color = if (selected) colors.primary else colors.separator, shape = shape)
            .padding(BadanSpace.s3),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Icon(
                imageVector = automationTierIcon(tier),
                contentDescription = null,
                tint = if (selected) colors.primary else colors.textSecondary,
                modifier = Modifier.size(20.dp),
            )
            Text(
                text = env.s(AutomationPresentation.tierTitle(tier)),
                style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = if (selected) Icons.Filled.RadioButtonChecked else Icons.Filled.RadioButtonUnchecked,
                contentDescription = null,
                tint = if (selected) colors.primary else colors.separator,
                modifier = Modifier.size(22.dp),
            )
        }
        Text(
            text = env.s(AutomationPresentation.tierLabel(tier)),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

@Composable
private fun CadenceRow(cadence: AutomationCadence, selected: Boolean, onSelect: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .clickable(onClick = onSelect)
            .heightIn(min = BadanSpace.touchMin),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = if (selected) Icons.Filled.RadioButtonChecked else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) colors.primary else colors.separator,
            modifier = Modifier.size(20.dp).padding(top = 2.dp),
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                text = env.s(AutomationPresentation.cadenceLabel(cadence)),
                style = BadanType.body.copy(fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal),
                color = colors.textPrimary,
            )
            Text(env.s(AutomationPresentation.cadenceHint(cadence)), style = BadanType.caption, color = colors.textSecondary)
        }
    }
}

@Composable
private fun QuietTimeField(label: String, minutes: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
        Text(text = label, style = BadanType.caption, color = colors.textSecondary)
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(BadanRadius.control))
                .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.control))
                .clickable(onClick = onClick)
                .heightIn(min = BadanSpace.touchMin)
                .padding(horizontal = BadanSpace.s3),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(text = formatMinuteOfDay(minutes), style = BadanType.body, color = colors.textPrimary)
        }
    }
}

// MARK: - Step 3: review

@Composable
private fun ReviewStep(
    template: ExportTemplate?,
    tier: AutomationTier,
    cadence: AutomationCadence,
    quietEnabled: Boolean,
    quietStartMin: Int,
    quietEndMin: Int,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s4)) {
        SectionHeader(title = env.s(WizardCopy.reviewHeader))
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                ReviewLine(label = env.s(WizardCopy.reviewTemplate), value = template?.name ?: "—")
                RowDivider()
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        Text(env.s(WizardCopy.reviewReliability), style = BadanType.caption, color = colors.textSecondary, modifier = Modifier.weight(1f))
                        PillLabel(text = env.s(AutomationPresentation.tierChip(tier)), icon = automationTierIcon(tier), tint = colors.primary)
                    }
                    Text(env.s(AutomationPresentation.tierLabel(tier)), style = BadanType.caption, color = colors.textSecondary)
                }
                RowDivider()
                ReviewLine(
                    label = env.s(WizardCopy.reviewWhen),
                    value = if (tier == AutomationTier.OPPORTUNISTIC_BACKGROUND) {
                        env.s(AutomationPresentation.cadenceLabel(cadence))
                    } else {
                        env.s(AutomationPresentation.nextWindowLabel(AutomationPresentation.NextWindow.ON_TAP, null))
                    },
                )
                if (tier == AutomationTier.OPPORTUNISTIC_BACKGROUND && quietEnabled) {
                    RowDivider()
                    ReviewLine(
                        label = env.s(WizardCopy.reviewQuiet),
                        value = "${formatMinuteOfDay(quietStartMin)} – ${formatMinuteOfDay(quietEndMin)}",
                    )
                }
            }
        }
        if (tier == AutomationTier.OPPORTUNISTIC_BACKGROUND) {
            NoteRow(icon = Icons.Filled.Lock, tint = colors.info, text = env.s(WizardCopy.oemNote))
        }
        NoteRow(icon = Icons.Filled.Shield, tint = colors.primary, text = env.s(WizardCopy.ledgerNote))
    }
}

@Composable
private fun ReviewLine(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
        Text(text = label, style = BadanType.caption, color = colors.textSecondary)
        Spacer(Modifier.weight(1f))
        Text(text = value, style = BadanType.body, color = colors.textPrimary)
    }
}

@Composable
private fun NoteRow(icon: ImageVector, tint: androidx.compose.ui.graphics.Color, text: String) {
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(BadanRadius.control))
            .background(tint.copy(alpha = 0.08f))
            .padding(BadanSpace.s3),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(imageVector = icon, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        Text(text = text, style = BadanType.caption, color = colors.textSecondary)
    }
}

// MARK: - Bottom bar

@Composable
private fun BottomBar(
    showBack: Boolean,
    isFinal: Boolean,
    primaryEnabled: Boolean,
    onBack: () -> Unit,
    onPrimary: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column {
        Box(modifier = Modifier.fillMaxWidth().heightIn(min = 1.dp, max = 1.dp).background(colors.separator))
        Row(
            modifier = Modifier
                .background(colors.surface)
                .fillMaxWidth()
                .padding(BadanSpace.s4),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (showBack) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(BadanRadius.control))
                        .border(1.dp, colors.separator, RoundedCornerShape(BadanRadius.control))
                        .clickable(onClick = onBack)
                        .heightIn(min = BadanSpace.touchMin),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(env.s(WizardCopy.back), style = BadanType.body.copy(fontWeight = FontWeight.Medium), color = colors.textPrimary)
                }
            }
            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(BadanRadius.control))
                    .background(colors.primary.copy(alpha = if (primaryEnabled) 1f else 0.4f))
                    .clickable(enabled = primaryEnabled, onClick = onPrimary)
                    .heightIn(min = BadanSpace.touchMin),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = env.s(if (isFinal) WizardCopy.enable else WizardCopy.continueLabel),
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.onPrimary,
                )
            }
        }
    }
}

// MARK: - Helpers

/** A 24-hour "H:mm" rendering of a minute-of-day, digits localized (minutes zero-padded). */
@Composable
private fun formatMinuteOfDay(minutes: Int): String {
    val env = LocalAppEnvironment.current
    val h = env.format.integer(minutes / 60)
    val minPart = minutes % 60
    val m = if (minPart < 10) "${env.format.integer(0)}${env.format.integer(minPart)}" else env.format.integer(minPart)
    return "$h:$m"
}
