@file:OptIn(ExperimentalMaterial3Api::class)

package net.albayyan.badan.features.insights

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Insights
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.app.Route
import net.albayyan.badan.core.Loc
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.designsystem.components.LoadState
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.designsystem.components.StatefulContainer
import net.albayyan.badan.designsystem.components.StatusChip
import net.albayyan.badan.domain.derivation.CorrelationEngine
import net.albayyan.badan.features.journal.JournalStrings
import net.albayyan.badan.storage.repositories.CorrelationRepository

/**
 * EPIC-29 — the correlations list. **The refusal is the product.** Mirror of the iOS
 * `CorrelationsScreen`.
 *
 * Three things are on this screen that a "what affects my sleep" feature usually leaves off:
 *
 * * **Below-gate pairs are shown as shortfalls, not teasers.** A behaviour with nine logged days
 *   gets "about five more days would let this be looked at" and no number, no bar, no direction —
 *   `CorrelationRenderer.Card.powerText` is null for a suppression by construction, so there is no
 *   altitude at which one grows statistics.
 * * **"No clear association" is a result.** It is rendered in the findings section with the same
 *   weight as a positive one, because a list that only ever contains hits is a slot machine.
 * * **"Association, not cause" is on every card**, in both languages, including the shortfall
 *   cards — the shared renderer attaches it to every outcome it can produce, so no caller can forget
 *   it, and it sits inside the card's spoken label so it cannot be swiped past either.
 *
 * Casual is one sentence plus a confidence word. Power adds n, the effect size and the interval as
 * numbers. Both read the same `CorrelationFinding` (D-5) — there is no second computation for the
 * detailed view, which is what stops the two altitudes from ever disagreeing.
 */
@Composable
fun CorrelationsScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    var state by remember { mutableStateOf<LoadState<CorrelationsReadModel>>(LoadState.Loading) }
    val sensitiveOn = env.profile.sensitiveModulesEnabled

    // Loaded ONCE per visit — keyed on neither depth nor language, and that is the D-5 guarantee made
    // structural. `CorrelationRenderer` fills every template in both languages at once, so a card is
    // already bilingual; depth only selects which of its lines are drawn. Nothing a user can toggle
    // re-runs the statistics, so one computation stands behind every altitude and both languages.
    // (It is also a 2000-resample bootstrap per behaviour x score pair — not work to repeat on a
    // language switch.)
    LaunchedEffect(sensitiveOn) {
        if (!sensitiveOn) return@LaunchedEffect
        state = LoadState.Loading
        state = withContext(Dispatchers.IO) { loadCorrelations(env) }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(CorrelationsStrings.title),
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
            if (!sensitiveOn) {
                SensitiveOffCard()
                return@Column
            }

            StatefulContainer(state) { model ->
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s5)) {
                    Text(
                        text = env.s(CorrelationsStrings.subtitle),
                        style = BadanType.body,
                        color = colors.textSecondary,
                    )

                    if (model.findings.isNotEmpty()) {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            SectionHeader(title = env.s(CorrelationsStrings.findingsHeader))
                            model.findings.forEach { CorrelationCard(it) }
                        }
                    }

                    if (model.notYet.isNotEmpty()) {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                            SectionHeader(title = env.s(CorrelationsStrings.notYetHeader))
                            Text(
                                text = gateText(env, model),
                                style = BadanType.caption,
                                color = colors.textSecondary,
                            )
                            model.notYet.forEach { CorrelationCard(it) }
                        }
                    }
                }
            }

            if (state is LoadState.Empty) EmptyGuidance()
            FooterNote()
        }
    }
}

/** The published gates, stated as numbers the reader can check the app against. */
private fun gateText(env: AppEnvironment, model: CorrelationsReadModel): String = env.s(
    CorrelationsStrings.gateNote.filling(
        mapOf(
            "n" to env.format.integer(model.minObservedDays),
            "arm" to env.format.integer(model.minDaysPerArm),
        ),
    ),
)

// MARK: - One card

@Composable
private fun CorrelationCard(row: CorrelationRow) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val spoken = CorrelationsPresentation.spokenCard(row, env.depth, env.language)
    BadanCard(
        // One accessibility stop per card, read as a phrase, with the locked line inside it.
        modifier = Modifier.clearAndSetSemantics { contentDescription = spoken },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
            ) {
                Icon(
                    imageVector = if (row.isSuppressed) Icons.Filled.HourglassEmpty else Icons.Filled.Insights,
                    contentDescription = null,
                    tint = if (row.isSuppressed) colors.textSecondary else colors.primary,
                    modifier = Modifier.size(20.dp),
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = env.s(row.behaviorName),
                        style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                        color = colors.textPrimary,
                    )
                    Text(
                        text = env.s(row.scoreName),
                        style = BadanType.caption,
                        color = colors.textSecondary,
                    )
                }
                // The casual altitude's whole quantitative vocabulary: one word, read off the same
                // confidence value power mode prints. Absent on a suppressed card — there is no
                // confidence in a comparison that was never made.
                row.finding?.let { finding ->
                    StatusChip(
                        status = ChipStatus.Info,
                        label = env.s(CorrelationsPresentation.confidenceWord(finding.confidence).label),
                    )
                }
            }

            Text(
                text = env.s(row.card.casualText),
                style = BadanType.body,
                color = colors.textPrimary,
            )

            // Declared-context disclosure: those days were counted exactly as logged and the
            // confidence was capped instead. Shown at every altitude — it is a fact about what the
            // finding is made of, not a power-user detail.
            row.card.contextNote?.let { note ->
                Text(text = env.s(note), style = BadanType.caption, color = colors.textSecondary)
            }

            if (env.depth.showsPowerDetail) {
                row.card.powerText?.let { power ->
                    // The numbers stay visually left-to-right in both languages: an interval like
                    // "[−0.42, 0.10]" is a technical fragment, not prose, and mirroring it moves the
                    // brackets off the bounds they belong to (the rule `InsightsScreen`'s detail rows
                    // already follow).
                    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
                        Text(
                            text = env.s(power),
                            style = BadanType.monospaceDigits(BadanType.caption),
                            color = colors.textSecondary,
                        )
                    }
                }
            }

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(1.dp)
                    .background(colors.separator),
            )

            // The locked line. Not conditional, not a caller's choice: a card without it reads as
            // causal, which is the single failure this epic exists to prevent.
            Text(
                text = env.s(row.card.associationNotCause),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Supporting surfaces

/**
 * What to do about an empty list. Rendered BELOW [StatefulContainer]'s own empty state, which
 * already carries the title — repeating it here would say the same thing twice.
 */
@Composable
private fun EmptyGuidance() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
        Text(
            text = env.s(CorrelationsStrings.emptyMessage),
            style = BadanType.body,
            color = colors.textSecondary,
        )
        TextButton(onClick = { nav.push(Route.Journal) }) {
            Text(
                text = env.s(CorrelationsStrings.openJournal),
                style = BadanType.body,
                color = colors.primary,
            )
        }
    }
}

@Composable
private fun FooterNote() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = BadanSpace.s1),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Lock,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = env.s(CorrelationsStrings.methodNote),
            style = BadanType.bodyCompact,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
    }
}

/**
 * Sensitive records are off. Named rather than left as a missing screen, and it names WHY placement
 * decides this: a finding's own metric id (`journal.correlation.alcohol.readiness.score`) discloses
 * the behaviour before any value is read, so the findings live in the purgeable store with the
 * journal.
 */
@Composable
private fun SensitiveOffCard() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Text(
                text = env.s(JournalStrings.sensitiveOffTitle),
                style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                color = colors.textPrimary,
            )
            Text(
                text = env.s(CorrelationsStrings.sensitiveOffMessage),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Loader (non-composable)

/**
 * Recompute and render, off the main thread.
 *
 * Why the read path RUNS the engine rather than only reading stored rows: a suppression is never
 * persisted — that is the storage-level half of the small-n invariant, so a below-gate pair does not
 * exist as a row some future reader could render without re-checking the gate — and the "not yet"
 * rows can therefore only come from an evaluation. Findings written along the way are the engine's
 * own append-only, skip-if-identical persistence (I2); this loader adds no storage rule of its own.
 *
 * The repository is constructed here rather than held on `AppEnvironment`, matching
 * `HealthMonitorScreen`'s DeviationEngine: a surface-only reader should not grow a field in the
 * composition root. [CorrelationRepository] takes the SENSITIVE connection and nothing else.
 */
private fun loadCorrelations(env: AppEnvironment): LoadState<CorrelationsReadModel> = runCatching {
    val spec = correlationSpec
    // A spec that failed to load — or one whose gate params are missing, which `CorrelationSpec`
    // resolves to Int.MAX_VALUE so that everything is suppressed — computes nothing. Say so, rather
    // than render a gate note promising 2,147,483,647 days.
    //
    // Reported as an error rather than as empty, and the distinction is not cosmetic: "you haven't
    // journaled enough yet" invites the user to keep tagging, and telling them that when the app
    // itself shipped without its constants would send them off to collect data that still would not
    // be compared.
    if (!spec.isLoaded ||
        spec.params.minObservedDays == Int.MAX_VALUE ||
        spec.params.minDaysPerArm == Int.MAX_VALUE
    ) {
        return@runCatching LoadState.Error(env.s(CorrelationsStrings.unavailable))
    }

    val engine = CorrelationEngine(
        journal = env.journal,
        derivation = env.derivation,
        findings = CorrelationRepository(env.database.sensitive),
        clock = env.clock,
        deviceId = env.deviceId,
        spec = spec,
    )
    val model = CorrelationsReadModel.build(
        outcomes = engine.recompute(),
        behaviors = env.behaviors,
        registry = env.registry,
        templates = env.templates,
        params = spec.params,
    )
    if (model.isEmpty) {
        LoadState.Empty(env.s(CorrelationsStrings.emptyTitle))
    } else {
        LoadState.Loaded(model)
    }
}.getOrElse { LoadState.Error(env.s(CorrelationsStrings.loadFailed)) }
