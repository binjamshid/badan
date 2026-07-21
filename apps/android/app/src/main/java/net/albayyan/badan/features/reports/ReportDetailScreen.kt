package net.albayyan.badan.features.reports

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.filled.Refresh
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.reports.EvidenceRef
import net.albayyan.badan.domain.reports.MetricSummary
import net.albayyan.badan.domain.reports.ReportBuilder
import net.albayyan.badan.domain.reports.ReportModel
import net.albayyan.badan.domain.reports.ReportPresentation
import net.albayyan.badan.domain.reports.ReportSection
import net.albayyan.badan.domain.reports.ReportSectionKind
import net.albayyan.badan.export.ReportRenderer
import net.albayyan.badan.features.export.shareFiles
import net.albayyan.badan.storage.repositories.ReportRecord
import java.io.File
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

private object ReportDetailStrings {
    val share = LocalizedString(en = "Share PDF", ar = "مشاركة PDF")
    val staleNote = LocalizedString(
        en = "New data has landed since this report. Regenerate to refresh it.",
        ar = "وصلت بيانات جديدة منذ هذا التقرير. أعد الإنشاء للتحديث.",
    )
    val generatedAt = LocalizedString(en = "Generated {when}", ar = "أُنشئ في {when}")
    val missing = LocalizedString(
        en = "This report is no longer available.",
        ar = "هذا التقرير لم يعد متاحاً.",
    )
}

private data class ReportDetailModel(
    val model: ReportModel,
    val record: ReportRecord,
    /**
     * The persisted row's content hash still matches a fresh re-derivation — nothing new has landed
     * since it was generated.
     */
    val isUpToDate: Boolean,
)

/**
 * One report, in full (EPIC-31). Casual reads the narrative; power adds the per-metric stat tables and
 * the evidence refs behind each claim (the transparency contract). A "regenerate" affordance is always
 * present, and a stale report — one whose stored hash no longer matches a fresh re-derivation — says
 * so plainly rather than being silently shown as current. Mirror of the iOS `ReportDetailView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportDetailScreen(reportId: String) {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val context = LocalContext.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    val tz = remember { TimeZone.getDefault().id }

    var state by remember { mutableStateOf<LoadState<ReportDetailModel>>(LoadState.Loading) }
    var isWorking by remember { mutableStateOf(false) }

    LaunchedEffect(reportId, env.language, env.depth) {
        state = loadReportDetail(env, reportId)
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(ReportsStrings.title),
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
            StatefulContainer(state) { detail ->
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        Text(
                            text = ReportPresentation.periodLabel(
                                detail.model, env.language, env.profile.arabicDigits,
                            ),
                            style = BadanType.sectionTitle,
                            color = colors.textPrimary,
                        )
                        Text(
                            text = env.s(
                                ReportDetailStrings.generatedAt.filling(
                                    mapOf("when" to formatInstant(detail.model.generatedAt, env)),
                                ),
                            ),
                            style = BadanType.caption,
                            color = colors.textSecondary,
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                            TextButton(
                                enabled = !isWorking,
                                onClick = {
                                    isWorking = true
                                    scope.launch {
                                        val outcome = withContext(Dispatchers.IO) {
                                            runCatching {
                                                env.reportGeneration.generateAndSave(
                                                    detail.record.periodKey, env.now(),
                                                )
                                            }
                                        }
                                        // A regenerate that quietly left the stale banner up would
                                        // leave the user tapping a button that appears to do nothing.
                                        if (outcome.isFailure) {
                                            Toast.makeText(
                                                context,
                                                env.s(ReportPresentation.generateError),
                                                Toast.LENGTH_SHORT,
                                            ).show()
                                        }
                                        state = loadReportDetail(env, reportId)
                                        isWorking = false
                                    }
                                },
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.Refresh,
                                    contentDescription = null,
                                    tint = colors.primary,
                                    modifier = Modifier.size(18.dp),
                                )
                                Text(
                                    text = env.s(ReportPresentation.regenerateLabel),
                                    style = BadanType.body,
                                    color = colors.primary,
                                    modifier = Modifier.padding(start = BadanSpace.s1),
                                )
                            }
                            TextButton(
                                enabled = !isWorking && detail.model.hasSufficientData,
                                onClick = {
                                    scope.launch {
                                        val file = withContext(Dispatchers.IO) {
                                            writeReportPdf(context.cacheDir, detail.model, env)
                                        }
                                        if (file != null) shareFiles(context, listOf(file))
                                    }
                                },
                            ) {
                                Icon(
                                    imageVector = Icons.Filled.IosShare,
                                    contentDescription = null,
                                    tint = colors.primary,
                                    modifier = Modifier.size(18.dp),
                                )
                                Text(
                                    text = env.s(ReportDetailStrings.share),
                                    style = BadanType.body,
                                    color = colors.primary,
                                    modifier = Modifier.padding(start = BadanSpace.s1),
                                )
                            }
                        }
                    }

                    if (!detail.isUpToDate) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(BadanRadius.card))
                                .background(colors.outOfBand.copy(alpha = 0.12f))
                                .padding(BadanSpace.s3),
                            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                            verticalAlignment = Alignment.Top,
                        ) {
                            Icon(
                                imageVector = Icons.Filled.Refresh,
                                contentDescription = null,
                                tint = colors.outOfBand,
                                modifier = Modifier.size(18.dp),
                            )
                            Text(
                                text = env.s(ReportDetailStrings.staleNote),
                                style = BadanType.caption,
                                color = colors.textPrimary,
                            )
                        }
                    }

                    if (!detail.model.hasSufficientData) {
                        BadanCard {
                            Text(
                                text = env.s(ReportPresentation.emptyMessage(detail.model.periodKind)),
                                style = BadanType.body,
                                color = colors.textSecondary,
                            )
                        }
                    }

                    detail.model.sections.forEach { section ->
                        SectionCard(section, detail.model, env.depth == DepthPolicy.POWER)
                    }

                    MedicalDisclaimerFooter()
                }
            }
        }
    }
}

// MARK: - Loader

/**
 * Re-derives the report's model from the store rather than reading a cached artifact — the model IS
 * the report, and re-deriving is what makes staleness detectable: if the fresh hash differs from the
 * row's, new data has landed and the screen says so.
 */
private suspend fun loadReportDetail(env: AppEnvironment, reportId: String): LoadState<ReportDetailModel> =
    withContext(Dispatchers.IO) {
        try {
            val record = env.reports.report(reportId)
                ?: return@withContext LoadState.Empty(env.s(ReportDetailStrings.missing))
            val model = ReportBuilder(env.derivation, env.logging)
                .generate(record.periodKey, TimeZone.getDefault().id, env.now())
            LoadState.Loaded(
                ReportDetailModel(model = model, record = record, isUpToDate = !record.isStale(model.sha256)),
            )
        } catch (t: Throwable) {
            LoadState.Error(env.s(ReportsStrings.loadError))
        }
    }

/**
 * Render the report's PDF into the shareable export cache directory. The artifact is regenerable, so
 * it is (re)written on each share rather than kept as a source of truth; `badan-exports/` is the only
 * path BADAN's FileProvider is allowed to hand out.
 */
private fun writeReportPdf(cacheDir: File, model: ReportModel, env: AppEnvironment): File? = runCatching {
    val dir = File(cacheDir, "badan-exports/reports").apply { mkdirs() }
    val file = File(dir, "BADAN-${model.periodKey.replace(":", "_")}.pdf")
    file.writeBytes(ReportRenderer.renderPdf(model, env.language, env.profile.arabicDigits))
    file
}.getOrNull()

// MARK: - Sections

@Composable
private fun SectionCard(section: ReportSection, model: ReportModel, isPower: Boolean) {
    val env = LocalAppEnvironment.current
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        SectionHeader(title = env.s(ReportPresentation.sectionTitle(section.kind)))
        BadanCard {
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                when (section.kind) {
                    ReportSectionKind.SLEEP, ReportSectionKind.EFFORT, ReportSectionKind.READINESS ->
                        section.metrics.forEach { MetricBlock(it, model, isPower) }
                    ReportSectionKind.CHANGES ->
                        section.changes.forEach { change ->
                            ClaimBlock(
                                text = ReportPresentation.changeNarrative(
                                    change, model.periodKind, env.language, env.profile.arabicDigits,
                                ),
                                evidence = change.evidence,
                                evidenceCount = change.evidence.size,
                                isPower = isPower,
                            )
                        }
                    ReportSectionKind.ADHERENCE ->
                        section.adherence?.let { a ->
                            ClaimBlock(
                                text = ReportPresentation.adherenceNarrative(
                                    a, model.periodKind, env.language, env.profile.arabicDigits,
                                ),
                                evidence = a.evidence,
                                evidenceCount = a.logged,
                                isPower = isPower,
                            )
                        }
                }
            }
        }
    }
}

@Composable
private fun MetricBlock(m: MetricSummary, model: ReportModel, isPower: Boolean) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = ReportPresentation.metricNarrative(
                m, model.periodKind, env.language, env.profile.arabicDigits,
            ),
            style = BadanType.body,
            color = colors.textPrimary,
        )
        if (isPower) {
            fun num(v: Double) = ReportPresentation.number(v, env.language, env.profile.arabicDigits)
            Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s1)) {
                StatRow(env.s(ReportPresentation.averageLabel), num(m.mean ?: 0.0))
                StatRow(env.s(ReportPresentation.rangeLabel), "${num(m.min ?: 0.0)}–${num(m.max ?: 0.0)}")
                StatRow(env.s(ReportPresentation.latestLabel), num(m.latest ?: 0.0))
            }
            EvidenceBlock(m.evidence, m.count)
        }
    }
}

@Composable
private fun ClaimBlock(text: String, evidence: List<EvidenceRef>, evidenceCount: Int, isPower: Boolean) {
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(text = text, style = BadanType.body, color = colors.textPrimary)
        if (isPower) EvidenceBlock(evidence, evidenceCount)
    }
}

@Composable
private fun StatRow(label: String, value: String) {
    val colors = BadanTheme.colors
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(text = label, style = BadanType.caption, color = colors.textSecondary, modifier = Modifier.weight(1f))
        Text(text = value, style = BadanType.caption, color = colors.textPrimary)
    }
}

/** The transparency contract, on screen: how many rows a claim rests on, and which ones. */
@Composable
private fun EvidenceBlock(refs: List<EvidenceRef>, count: Int) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier.padding(top = BadanSpace.s1),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            text = ReportPresentation.evidenceCountPhrase(count, env.language, env.profile.arabicDigits),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        if (refs.isNotEmpty()) {
            Text(
                text = refs.joinToString(", ") { it.periodKey ?: it.id },
                style = BadanType.monospaceDigits(BadanType.caption),
                color = colors.textSecondary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

private fun formatInstant(millis: Long, env: AppEnvironment): String {
    // `Locale.forLanguageTag(localeTag)` is the app-wide way to build a locale from the profile's
    // language (the `Locale(String, String)` constructors are deprecated), so a report's timestamps
    // are formatted exactly the way every other screen formats theirs.
    val locale = Locale.forLanguageTag(env.language.localeTag)
    val df = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale)
    return df.format(Date(millis))
}
