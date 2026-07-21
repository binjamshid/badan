package net.albayyan.badan.features.reports

import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Info
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.domain.reports.ReportBuilder
import net.albayyan.badan.domain.reports.ReportModel
import net.albayyan.badan.domain.reports.ReportPeriod
import net.albayyan.badan.domain.reports.ReportPeriodKind
import net.albayyan.badan.domain.reports.ReportPresentation
import net.albayyan.badan.domain.reports.ReportTrigger
import net.albayyan.badan.storage.repositories.ReportRecord
import java.util.TimeZone

// MARK: - Local strings

/**
 * Copy only the Reports surface needs; shared report wording (titles, section labels, narratives, the
 * disclaimer) comes from [ReportPresentation], so the PDF and this screen never diverge.
 */
internal object ReportsStrings {
    val title = LocalizedString(en = "Reports", ar = "التقارير")
    val subtitle = LocalizedString(
        en = "Weekly and monthly summaries — every number links to its evidence.",
        ar = "ملخّصات أسبوعية وشهرية — كل رقم مرتبط بدليله.",
    )
    val generateHeader = LocalizedString(en = "Generate", ar = "إنشاء")
    val yourReportsHeader = LocalizedString(en = "Your reports", ar = "تقاريرك")
    val noReports = LocalizedString(
        en = "No reports yet. Generate one above, or one appears automatically after a week of data.",
        ar = "لا توجد تقارير بعد. أنشئ واحداً بالأعلى، أو سيظهر تلقائياً بعد أسبوع من البيانات.",
    )
    val generateAction = LocalizedString(en = "Generate", ar = "إنشاء")
    val loadError = LocalizedString(
        en = "Something didn't load. Try again.",
        ar = "لم يتم تحميل شيء ما. حاول مرة أخرى.",
    )
}

// MARK: - List read model

internal data class ReportSuggestion(
    val periodKey: String,
    val kind: ReportPeriodKind,
    val exists: Boolean,
)

internal data class ReportsListModel(
    val records: List<ReportRecord>,
    val suggestions: List<ReportSuggestion>,
)

/**
 * The periods worth offering to generate, in a stable order: the last completed week (what the
 * substrate would have produced), the week in progress (manual-only — the trigger never generates a
 * partial week), and last month. Pure so a JVM test can pin the offer set without a database.
 */
internal fun reportSuggestions(now: Long, tz: String, existing: Set<String>): List<ReportSuggestion> {
    val thisMonth = ReportPeriod.month(now, tz)
    val keys = listOf(
        ReportTrigger.lastCompletedWeek(now, tz).periodKey to ReportPeriodKind.WEEK,
        ReportPeriod.week(now, tz).periodKey to ReportPeriodKind.WEEK,
        ReportPeriod.prior(thisMonth, tz).periodKey to ReportPeriodKind.MONTH,
    )
    val seen = mutableSetOf<String>()
    return keys.mapNotNull { (key, kind) ->
        if (!seen.add(key)) null else ReportSuggestion(key, kind, existing.contains(key))
    }
}

// MARK: - Screen

/**
 * EPIC-31 — the Reports surface, under Body. Lists generated weekly/monthly reports and offers to
 * generate the most useful periods. Casual reads the narrative; power adds the stat tables and the
 * evidence refs (see [ReportDetailScreen]). A persistent "wellness summary, not a medical assessment"
 * footer sits below the list at all times. Mirror of the iOS `ReportsScreen`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportsScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val context = LocalContext.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    val tz = remember { TimeZone.getDefault().id }

    var state by remember { mutableStateOf<LoadState<ReportsListModel>>(LoadState.Loading) }
    var isWorking by remember { mutableStateOf(false) }

    LaunchedEffect(env.language, env.depth) {
        state = loadReports(env, tz)
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
            StatefulContainer(state) { model ->
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
                    Text(
                        text = env.s(ReportsStrings.subtitle),
                        style = BadanType.body,
                        color = colors.textSecondary,
                    )

                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        SectionHeader(title = env.s(ReportsStrings.generateHeader))
                        BadanCard(padding = 0.dp) {
                            model.suggestions.forEachIndexed { index, suggestion ->
                                if (index > 0) RowDivider()
                                SuggestionRow(
                                    suggestion = suggestion,
                                    tz = tz,
                                    enabled = !isWorking,
                                    onGenerate = {
                                        isWorking = true
                                        scope.launch {
                                            val outcome = withContext(Dispatchers.IO) {
                                                runCatching {
                                                    env.reportGeneration.generateAndSave(suggestion.periodKey, env.now())
                                                }
                                            }
                                            // Report the failure rather than swallow it: an empty
                                            // period still produces a (honest) report, so a silently
                                            // unchanged list would be the only sign nothing was written.
                                            if (outcome.isFailure) {
                                                Toast.makeText(
                                                    context,
                                                    env.s(ReportPresentation.generateError),
                                                    Toast.LENGTH_SHORT,
                                                ).show()
                                            }
                                            state = loadReports(env, tz)
                                            isWorking = false
                                        }
                                    },
                                )
                            }
                        }
                    }

                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                        SectionHeader(title = env.s(ReportsStrings.yourReportsHeader))
                        if (model.records.isEmpty()) {
                            BadanCard {
                                Text(
                                    text = env.s(ReportsStrings.noReports),
                                    style = BadanType.body,
                                    color = colors.textSecondary,
                                )
                            }
                        } else {
                            BadanCard(padding = 0.dp) {
                                model.records.forEachIndexed { index, record ->
                                    if (index > 0) RowDivider()
                                    ReportRow(record = record, tz = tz) {
                                        nav.push(Route.ReportDetail(record.id))
                                    }
                                }
                            }
                        }
                    }

                    MedicalDisclaimerFooter()
                }
            }
        }
    }
}

// MARK: - Loader

private suspend fun loadReports(env: AppEnvironment, tz: String): LoadState<ReportsListModel> =
    withContext(Dispatchers.IO) {
        try {
            val records = env.reports.all()
            val existing = records.map { it.periodKey }.toSet()
            LoadState.Loaded(
                ReportsListModel(
                    records = records,
                    suggestions = reportSuggestions(env.now(), tz, existing),
                ),
            )
        } catch (t: Throwable) {
            LoadState.Error(env.s(ReportsStrings.loadError))
        }
    }

// MARK: - Rows

@Composable
private fun SuggestionRow(
    suggestion: ReportSuggestion,
    tz: String,
    enabled: Boolean,
    onGenerate: () -> Unit,
) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = BadanSpace.cardPadding)
            .defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = env.s(ReportPresentation.title(suggestion.kind)),
                style = BadanType.body,
                color = colors.textPrimary,
            )
            Text(
                text = periodDisplay(suggestion.periodKey, tz, env),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        TextButton(onClick = onGenerate, enabled = enabled) {
            Text(
                // The action is always a build — for a period that already has a report it rebuilds
                // it in place. Labelling that "View" would promise navigation this button does not
                // perform; the report itself is reachable from the list below.
                text = env.s(
                    if (suggestion.exists) {
                        ReportPresentation.regenerateLabel
                    } else {
                        ReportsStrings.generateAction
                    },
                ),
                style = BadanType.body,
                color = colors.primary,
            )
        }
    }
}

@Composable
private fun ReportRow(record: ReportRecord, tz: String, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = BadanSpace.cardPadding)
            .defaultMinSize(minHeight = BadanSpace.touchMin),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = periodDisplay(record.periodKey, tz, env),
                style = BadanType.body,
                color = colors.textPrimary,
            )
            Text(
                text = ReportPresentation.sectionCount(
                    record.sectionsIncluded.size, env.language, env.profile.arabicDigits,
                ),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
        Icon(
            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun RowDivider() {
    val colors = BadanTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = BadanSpace.cardPadding)
            .height(1.dp)
            .background(colors.separator),
    )
}

/**
 * The persistent "wellness summary, not a medical assessment" strip. Shared by the list and the
 * detail so both always carry it, and worded by [ReportPresentation] so it cannot drift from the PDF.
 */
@Composable
internal fun MedicalDisclaimerFooter() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = BadanSpace.s2),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            imageVector = Icons.Filled.Info,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = env.s(ReportPresentation.disclaimer),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

/**
 * "Week 29, 2026" / "July 2026" for a period key, or the raw key if it does not resolve (which only a
 * corrupt row could produce — better a visible key than a fabricated period).
 */
internal fun periodDisplay(periodKey: String, tz: String, env: AppEnvironment): String {
    val resolved = ReportPeriod.resolve(periodKey, tz) ?: return periodKey
    val stub = ReportModel(
        periodKey = resolved.periodKey, periodKind = resolved.kind, periodStart = resolved.start,
        periodEnd = resolved.end, timezone = resolved.timezone, generatedAt = env.now(),
        algorithmVersionId = ReportBuilder.algorithm.id, hasSufficientData = false,
        sections = emptyList(), sha256 = "",
    )
    return ReportPresentation.periodLabel(stub, env.language, env.profile.arabicDigits)
}
