@file:OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)

package net.albayyan.badan.features.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.app.LocalNavigator
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.designsystem.components.SectionHeader
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.ContextStatusKind
import java.text.DateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * EPIC-29 — the context-status manager: where a user declares that a stretch of days was not an
 * ordinary one (travelling, unwell, fasting, at altitude, injured). Mirror of the iOS
 * `ContextStatusManagerView`.
 *
 * **What this screen is careful never to imply.** A status does not change a number. `ContextStatus`
 * makes that structural — it exposes no metric id, no value, no offset and no multiplier, and its
 * only output is a confidence ceiling plus caveat sentences — and this screen says the same thing in
 * the user's own words ([JournalStrings.contextExplainer]) so the guarantee is legible rather than
 * only enforced. Each card also shows the exact caveat that status will attach, so "what does
 * marking this do?" is answered before the tap and not discovered later on a score card.
 *
 * **And the promise is kept, not merely stated.** The confidence half is applied by the score
 * engines through `ContextAnnotationResolver` (readiness, sleep need/performance/consistency and the
 * stress trend all cap their stored `confidence` at
 * `ContextAnnotator.ACTIVE_CONTEXT_CONFIDENCE_CEILING` for a day inside a declared interval;
 * `effort.day` stores no confidence, so a context reaches it as copy only — see `EffortEngine`). The
 * copy half is rendered by `ContextCaveatNote` on the readiness hero, the metric detail + anatomy
 * sheet and the stress card, from the SAME caveat sentence each card below previews.
 *
 * **I7.** Statuses are sensitive-plus (illness, travel and injury disclose circumstance) and are
 * written through the sensitive-only `JournalRepository`, same as the journal itself.
 */
@Composable
fun ContextStatusScreen() {
    val env = LocalAppEnvironment.current
    val nav = LocalNavigator.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    val tz = remember { TimeZone.getDefault().id }

    var list by remember { mutableStateOf<ContextStatusList?>(null) }
    var loadFailed by remember { mutableStateOf(false) }
    var saveFailed by remember { mutableStateOf(false) }
    var reloadKey by remember { mutableStateOf(0) }
    var customLabel by remember { mutableStateOf("") }

    LaunchedEffect(reloadKey) {
        val loaded = withContext(Dispatchers.IO) {
            runCatching { ContextStatusList.from(env.journal.allStatuses(), env.now()) }
        }
        loadFailed = loaded.isFailure
        loaded.getOrNull()?.let { list = it }
    }

    val commit: (suspend () -> Unit) -> Unit = { work ->
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { work() } }
            saveFailed = result.isFailure
            reloadKey++
        }
    }

    Scaffold(
        containerColor = colors.background,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = env.s(JournalStrings.contextTitle),
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
            ExplainerRow()
            if (loadFailed || saveFailed) {
                Text(
                    text = env.s(if (loadFailed) JournalStrings.loadFailed else JournalStrings.saveFailed),
                    style = BadanType.bodyCompact,
                    color = colors.textPrimary,
                )
            }

            list?.let { model ->
                Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                    SectionHeader(title = env.s(JournalStrings.contextStart))
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
                    ) {
                        ContextStatusKind.entries.forEach { kind ->
                            // A kind already running cannot be started twice — two open "travelling"
                            // intervals would annotate the same days twice for no added meaning.
                            val alreadyOpen = model.active.any { it.kind == kind }
                            KindChip(kind = kind, enabled = !alreadyOpen) {
                                commit { openStatus(env, kind = kind, customLabel = null, tz = tz) }
                            }
                        }
                    }
                    CustomStatusField(
                        value = customLabel,
                        onValueChange = { customLabel = it },
                        onSubmit = {
                            val label = customLabel.trim()
                            if (label.isNotEmpty()) {
                                customLabel = ""
                                commit { openStatus(env, kind = null, customLabel = label, tz = tz) }
                            }
                        },
                    )
                }

                if (model.active.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(JournalStrings.contextOngoing))
                        model.active.forEach { status ->
                            StatusCard(
                                status = status,
                                onEnd = { commit { env.journal.closeStatus(status.id, env.now(), env.now()) } },
                                onDelete = { commit { env.journal.deleteStatus(status.id, env.now()) } },
                            )
                        }
                    }
                }

                if (model.past.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s3)) {
                        SectionHeader(title = env.s(JournalStrings.contextEarlier))
                        model.past.forEach { status ->
                            StatusCard(
                                status = status,
                                onEnd = null,
                                onDelete = { commit { env.journal.deleteStatus(status.id, env.now()) } },
                            )
                        }
                    }
                }

                if (model.isEmpty) {
                    BadanCard {
                        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
                            Text(
                                text = env.s(JournalStrings.contextNoneTitle),
                                style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                                color = colors.textPrimary,
                            )
                            Text(
                                text = env.s(JournalStrings.contextNoneMessage),
                                style = BadanType.caption,
                                color = colors.textSecondary,
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

@Composable
private fun ExplainerRow() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Info,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = env.s(JournalStrings.contextExplainer),
            style = BadanType.caption,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun KindChip(kind: ContextStatusKind, enabled: Boolean, onClick: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.chip)
    Box(
        modifier = Modifier
            .clip(shape)
            .clickable(enabled = enabled, onClick = onClick)
            .background(colors.surface, shape)
            .border(1.dp, colors.separator, shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = env.s(kind.displayLabel),
            style = BadanType.chip,
            color = if (enabled) colors.textPrimary else colors.textSecondary,
            maxLines = 1,
        )
    }
}

@Composable
private fun CustomStatusField(value: String, onValueChange: (String) -> Unit, onSubmit: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceElevated, shape)
            .heightIn(min = BadanSpace.touchMin)
            .padding(horizontal = BadanSpace.s3),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Box(modifier = Modifier.weight(1f)) {
            if (value.isEmpty()) {
                Text(
                    text = env.s(JournalStrings.contextCustomPlaceholder),
                    style = BadanType.body,
                    color = colors.textSecondary,
                )
            }
            BasicTextField(
                value = value,
                onValueChange = onValueChange,
                textStyle = BadanType.body.copy(color = colors.textPrimary),
                singleLine = true,
                cursorBrush = SolidColor(colors.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { onSubmit() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        val canAdd = value.trim().isNotEmpty()
        TextButton(onClick = onSubmit, enabled = canAdd) {
            Text(
                text = env.s(Loc.add),
                style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                color = if (canAdd) colors.primary else colors.textSecondary,
            )
        }
    }
}

@Composable
private fun StatusCard(status: ContextStatus, onEnd: (() -> Unit)?, onDelete: () -> Unit) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    BadanCard {
        Column(verticalArrangement = Arrangement.spacedBy(BadanSpace.s2)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Text(
                    text = env.s(status.displayLabel),
                    style = BadanType.bodyCompact.copy(fontWeight = FontWeight.Medium),
                    color = colors.textPrimary,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onDelete) {
                    Icon(
                        imageVector = Icons.Filled.Close,
                        contentDescription = "${env.s(JournalStrings.contextDelete)} ${env.s(status.displayLabel)}",
                        tint = colors.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            Text(
                text = intervalText(env, status),
                style = BadanType.caption,
                color = colors.textSecondary,
            )
            // The exact sentence this status attaches to values computed inside it — shown here so
            // the effect of marking a period is legible from the manager, not only from a score.
            Text(text = env.s(status.caveat), style = BadanType.caption, color = colors.textSecondary)
            if (onEnd != null) {
                TextButton(onClick = onEnd) {
                    Text(
                        text = env.s(JournalStrings.contextEndNow),
                        style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                        color = colors.primary,
                    )
                }
            }
        }
    }
}

// MARK: - I/O (non-composable)

/**
 * Declare a status starting now, left open-ended.
 *
 * Open-ended is the correct default and not an omission: a user marks travel when it starts and
 * closes it when they are back, so asking for an end date up front would be asking for a fact they
 * do not have. `ContextStatus` treats a null `endAt` as "still active" everywhere.
 */
private fun openStatus(env: AppEnvironment, kind: ContextStatusKind?, customLabel: String?, tz: String) {
    val now = env.now()
    env.journal.upsertStatus(
        ContextStatus(
            id = Ulid.newId(),
            statusId = kind?.code,
            customLabel = customLabel,
            startAt = now,
            endAt = null,
            tzId = tz,
            provenance = Provenance(
                sourceId = env.deviceId,
                deviceId = env.deviceId,
                ingestionPath = IngestionPath.MANUAL,
                measuredAt = now,
                measuredTimezone = tz,
                recordedAt = now,
                ingestedAt = now,
            ),
            updatedAt = now,
            originDeviceId = env.deviceId,
        ),
    )
}

/** "Started 12 Jul" while open; "12 Jul to 18 Jul" once closed. Dates only — a status describes days. */
private fun intervalText(env: AppEnvironment, status: ContextStatus): String {
    val start = formatDay(status.startAt, env.language)
    val end = status.endAt ?: return env.s(JournalStrings.contextStarted.filling(mapOf("date" to start)))
    return env.s(
        JournalStrings.contextRange.filling(
            mapOf("start" to start, "end" to formatDay(end, env.language)),
        ),
    )
}

private fun formatDay(millis: Long, language: AppLanguage): String =
    DateFormat.getDateInstance(DateFormat.MEDIUM, Locale.forLanguageTag(language.localeTag))
        .apply { timeZone = TimeZone.getDefault() }
        .format(Date(millis))
