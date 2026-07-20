package net.albayyan.badan.features.onboarding

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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MedicalInformation
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import net.albayyan.badan.app.LocalAppEnvironment
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.designsystem.components.BadanCard
import net.albayyan.badan.domain.DepthPolicy
import net.albayyan.badan.domain.PermissionStatus
import net.albayyan.badan.features.health.FamilyBundlePicker
import net.albayyan.badan.features.health.InlineNotice
import net.albayyan.badan.features.health.rememberStagedPermissionRequest
import net.albayyan.badan.features.health.stageProgressLabel
import net.albayyan.badan.features.health.stagedPermissionFamilies
import net.albayyan.badan.platform.health.HealthAvailability

/**
 * The pre-shell welcome flow (mirror of the iOS `OnboardingView`). The root gates the tab UI on
 * `env.onboardingComplete`; this screen owns its own full-screen layout and, on the final step,
 * calls `env.completeOnboarding()` to hand off to the shell.
 *
 * Five calm steps over the BADAN background:
 *   1. Welcome — with a live EN/AR language toggle so RTL flips immediately.
 *   2. A short "why BADAN" value set (private repository / your data is yours / works offline).
 *   3. "What BADAN never does" — the negative half of the promise (plan §16). Placed *before* the
 *      connect step on purpose: the commitments a user most wants before handing over health data
 *      are the ones about what will not happen to it, and a screen making them after the request
 *      is reassurance nobody asked for.
 *   4. A depth preset choice — "Keep it simple" (casual) vs "Show me detail" (power).
 *   5. A connect step — the staged, per-family permission flow, plus "explore with sample data"
 *      and "start empty", all of which complete onboarding.
 *
 * Swiping (via [HorizontalPager]) and the Back/Skip/Next controls all move between steps; only the
 * Next button is gated on the depth page until a preset is chosen. RTL is honoured automatically
 * because `LayoutDirection` is provided app-wide from `env.language`.
 */
@Composable
fun OnboardingScreen() {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()

    val pageCount = 5
    val lastStep = pageCount - 1
    /** The depth picker's index — the one page whose Next button is gated on a choice. */
    val depthStep = 3
    val pagerState = rememberPagerState(pageCount = { pageCount })
    val step = pagerState.currentPage

    var selectedDepth by remember { mutableStateOf<DepthPolicy?>(null) }

    // Reflect any already-chosen depth so returning to the picker shows it selected.
    LaunchedEffect(Unit) {
        selectedDepth = if (env.depth == DepthPolicy.BALANCED) null else env.depth
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(colors.background),
    ) {
        Column(modifier = Modifier.fillMaxSize()) {
            OnboardingHeader(
                step = step,
                lastStep = lastStep,
                pageCount = pageCount,
                onBack = { scope.launch { pagerState.animateScrollToPage(step - 1) } },
                // Skip jumps to the connect step rather than straight into the app. It used to
                // call `completeOnboarding()`, which dropped the user into 90 days of fabricated
                // data having never been shown the sentence explaining that's what it is —
                // skipping the intro is a reasonable thing to want; being quietly handed invented
                // health data as a result is not. They still skip everything they meant to skip.
                onSkip = { scope.launch { pagerState.animateScrollToPage(lastStep) } },
                s = env::s,
            )

            HorizontalPager(
                state = pagerState,
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth(),
            ) { page ->
                when (page) {
                    0 -> WelcomePage(
                        language = env.language,
                        onSelectLanguage = { lang -> env.update { it.copy(language = lang) } },
                        s = env::s,
                    )

                    1 -> ValuePage(s = env::s)

                    2 -> NeverDoesPage(s = env::s)

                    3 -> DepthPage(
                        selected = selectedDepth,
                        onSelect = { policy ->
                            selectedDepth = policy
                            env.update { it.copy(depthPolicy = policy) }
                        },
                        s = env::s,
                    )

                    else -> ConnectPage(s = env::s)
                }
            }

            // Footer: a Next button for every step but the last (which carries its own actions).
            if (step < lastStep) {
                val disabled = step == depthStep && selectedDepth == null
                PrimaryButton(
                    label = env.s(Loc.next),
                    enabled = !disabled,
                    onClick = { scope.launch { pagerState.animateScrollToPage(step + 1) } },
                    modifier = Modifier
                        .padding(horizontal = BadanSpace.s5)
                        .padding(top = BadanSpace.s3, bottom = BadanSpace.s5),
                )
            }
        }
    }
}

// MARK: - Header (progress + back / skip)

@Composable
private fun OnboardingHeader(
    step: Int,
    lastStep: Int,
    pageCount: Int,
    onBack: () -> Unit,
    onSkip: () -> Unit,
    s: (LocalizedString) -> String,
) {
    val colors = BadanTheme.colors
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = BadanSpace.s5)
            .padding(top = BadanSpace.s2),
        contentAlignment = Alignment.Center,
    ) {
        // Centred progress dots.
        Row(
            modifier = Modifier.semantics {
                contentDescription = s(stepAnnouncement(step, pageCount))
            },
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            repeat(pageCount) { index ->
                val isCurrent = index == step
                Box(
                    modifier = Modifier
                        .size(width = if (isCurrent) 22.dp else 7.dp, height = 7.dp)
                        .background(
                            if (isCurrent) colors.primary else colors.separator,
                            CircleShape,
                        ),
                )
            }
        }

        // Back (leading) and Skip (trailing) framed to the touch minimum.
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (step > 0) {
                Row(
                    modifier = Modifier
                        .heightIn(min = BadanSpace.touchMin)
                        .padding(horizontal = BadanSpace.s2)
                        .clickable(onClick = onBack),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = null,
                        tint = colors.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                    Text(
                        text = locBack(),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                }
            } else {
                Box(modifier = Modifier.size(BadanSpace.touchMin))
            }

            Spacer(modifier = Modifier.weight(1f))

            if (step < lastStep) {
                Box(
                    modifier = Modifier
                        .heightIn(min = BadanSpace.touchMin)
                        .padding(horizontal = BadanSpace.s2)
                        .clickable(onClick = onSkip),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    Text(
                        text = locSkip(),
                        style = BadanType.bodyCompact,
                        color = colors.textSecondary,
                    )
                }
            } else {
                Box(modifier = Modifier.size(BadanSpace.touchMin))
            }
        }
    }
}

// MARK: - Page 1: Welcome + language

@Composable
private fun WelcomePage(
    language: AppLanguage,
    onSelectLanguage: (AppLanguage) -> Unit,
    s: (LocalizedString) -> String,
) {
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = BadanSpace.s5),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        IconMark(icon = Icons.Filled.Favorite, tint = colors.primary, diameter = 84.dp)

        Spacer(modifier = Modifier.size(BadanSpace.s6))

        Text(
            text = s(Loc.welcomeTitle),
            style = titleFont,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(modifier = Modifier.size(BadanSpace.s3))
        Text(
            text = s(Loc.welcomeSubtitle),
            style = BadanType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )

        Spacer(modifier = Modifier.size(BadanSpace.s6))

        Text(
            text = s(Loc.language),
            style = BadanType.chip,
            color = colors.textSecondary,
        )
        Spacer(modifier = Modifier.size(BadanSpace.s2))
        LanguageToggle(language = language, onSelect = onSelectLanguage)
        Spacer(modifier = Modifier.size(BadanSpace.s2))
        Text(
            text = s(languageHint),
            style = BadanType.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun LanguageToggle(
    language: AppLanguage,
    onSelect: (AppLanguage) -> Unit,
) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.control)
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        AppLanguage.entries.forEach { lang ->
            val isSelected = language == lang
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = BadanSpace.touchMin)
                    .clickable { onSelect(lang) }
                    .background(
                        if (isSelected) colors.primary.copy(alpha = 0.14f) else colors.surface,
                        shape,
                    )
                    .border(
                        width = if (isSelected) 1.5.dp else 1.dp,
                        color = if (isSelected) colors.primary else colors.separator,
                        shape = shape,
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = lang.displayName,
                    style = BadanType.body.copy(fontWeight = FontWeight.Medium),
                    color = if (isSelected) colors.primary else colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Page 2: Value set

@Composable
private fun ValuePage(s: (LocalizedString) -> String) {
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BadanSpace.s5)
            .padding(top = BadanSpace.s4, bottom = BadanSpace.s4),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
    ) {
        Text(
            text = s(whyTitle),
            style = titleFont,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        ValueCard(
            icon = Icons.Filled.Shield,
            tint = colors.primary,
            title = s(valuePrivateTitle),
            body = s(valuePrivateBody),
        )
        ValueCard(
            icon = Icons.Filled.Share,
            tint = colors.info,
            title = s(valueOwnTitle),
            body = s(valueOwnBody),
        )
        ValueCard(
            icon = Icons.Filled.WifiOff,
            tint = colors.inBand,
            title = s(valueOfflineTitle),
            body = s(valueOfflineBody),
        )
    }
}

@Composable
private fun ValueCard(icon: ImageVector, tint: Color, title: String, body: String) {
    val colors = BadanTheme.colors
    BadanCard {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            IconMark(icon = icon, tint = tint, diameter = 44.dp)
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = title,
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = body,
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
            }
        }
    }
}

// MARK: - Page 3: What BADAN never does

/**
 * The negative promises (plan §16: "no selling, no diagnosis, no cloud without your action").
 *
 * Deliberately three flat statements with no hedging verbs — "never", not "does not currently".
 * Each one corresponds to something structural rather than to a policy that could quietly change:
 * there is no account and no server to sell to, the wellness-language rule is enforced on every
 * user-facing string, and nothing leaves the device without an explicit share action.
 */
@Composable
private fun NeverDoesPage(s: (LocalizedString) -> String) {
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BadanSpace.s5)
            .padding(top = BadanSpace.s4, bottom = BadanSpace.s4),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
    ) {
        Text(
            text = s(neverTitle),
            style = titleFont,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        ValueCard(
            icon = Icons.Filled.Block,
            tint = colors.primary,
            title = s(neverSellTitle),
            body = s(neverSellBody),
        )
        ValueCard(
            icon = Icons.Filled.MedicalInformation,
            tint = colors.info,
            title = s(neverDiagnoseTitle),
            body = s(neverDiagnoseBody),
        )
        ValueCard(
            icon = Icons.Filled.CloudOff,
            tint = colors.inBand,
            title = s(neverCloudTitle),
            body = s(neverCloudBody),
        )
    }
}

// MARK: - Page 4: Depth preset

@Composable
private fun DepthPage(
    selected: DepthPolicy?,
    onSelect: (DepthPolicy) -> Unit,
    s: (LocalizedString) -> String,
) {
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BadanSpace.s5)
            .padding(top = BadanSpace.s4, bottom = BadanSpace.s4),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s4),
    ) {
        Text(
            text = s(depthTitle),
            style = titleFont,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = s(depthSubtitle),
            style = BadanType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
        DepthOption(
            icon = Icons.Filled.Eco,
            title = s(depthSimpleTitle),
            body = s(depthSimpleBody),
            isSelected = selected == DepthPolicy.CASUAL,
            onClick = { onSelect(DepthPolicy.CASUAL) },
        )
        DepthOption(
            icon = Icons.Filled.Tune,
            title = s(depthDetailTitle),
            body = s(depthDetailBody),
            isSelected = selected == DepthPolicy.POWER,
            onClick = { onSelect(DepthPolicy.POWER) },
        )
        if (selected == null) {
            Text(
                text = s(depthChooseHint),
                style = BadanType.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun DepthOption(
    icon: ImageVector,
    title: String,
    body: String,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    val selectionModifier = if (isSelected) {
        Modifier.border(width = 2.dp, color = colors.primary, shape = shape)
    } else {
        Modifier
    }
    BadanCard(
        modifier = Modifier
            .clickable(onClick = onClick)
            .then(selectionModifier),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s3),
        ) {
            IconMark(icon = icon, tint = colors.primary, diameter = 44.dp)
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
            ) {
                Text(
                    text = title,
                    style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
                    color = colors.textPrimary,
                )
                Text(
                    text = body,
                    style = BadanType.bodyCompact,
                    color = colors.textSecondary,
                )
            }
            Icon(
                imageVector = if (isSelected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
                contentDescription = null,
                tint = if (isSelected) colors.primary else colors.separator,
                modifier = Modifier.size(24.dp),
            )
        }
    }
}

// MARK: - Page 5: Connect (staged, per family)

/**
 * The connect step, asking one consent family at a time (EPIC-02, plan §13.1/§14).
 *
 * What changed and why it matters: this page used to launch a single request for all fifteen Health
 * Connect permissions. The system sheet that produces is an undifferentiated wall of toggles with
 * no statement of purpose attached to any of them, at the moment in the app where the user has the
 * least context — so the realistic answers are "allow everything unread" or "deny everything", and
 * neither is consent. Now the user sees what each bundle is for, can drop any of them before
 * anything is requested, and answers one focused sheet per bundle.
 *
 * The 30-day disclosure appears here rather than after the first sync, because "BADAN can read the
 * last 30 days" is information needed to *decide*, not an explanation owed afterwards.
 */
@Composable
private fun ConnectPage(s: (LocalizedString) -> String) {
    val env = LocalAppEnvironment.current
    val colors = BadanTheme.colors
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var syncing by remember { mutableStateOf(false) }
    var connectError by remember { mutableStateOf<LocalizedString?>(null) }

    // Everything selected by default — the user tapped "connect", so the default is yes to each,
    // and each is individually removable rather than individually opt-in.
    var selected by remember { mutableStateOf(stagedPermissionFamilies.toSet()) }

    val staged = rememberStagedPermissionRequest(
        onComplete = { outcomes ->
            val anyGranted = outcomes.values.any {
                it == PermissionStatus.GRANTED || it == PermissionStatus.PARTIAL
            }
            if (anyGranted) {
                scope.launch {
                    // Purges the sample seed before ingesting, so a connected user never ends up
                    // with their data blended into fabricated readings.
                    syncing = true
                    env.syncHealthConnect()
                    syncing = false
                    env.completeOnboarding()
                }
            } else {
                // Denial is not a dead end and not a scolding: stay on the page, say so calmly,
                // and leave the other two ways forward available.
                connectError = connectDeniedNotice
            }
        },
    )

    val onConnect: () -> Unit = {
        connectError = null
        if (selected.isEmpty()) {
            connectError = connectNothingSelectedNotice
        } else if (env.healthConnect.availability() == HealthAvailability.available) {
            staged.start(stagedPermissionFamilies.filter { it in selected })
        } else {
            connectError = connectUnavailableNotice
        }
    }
    val onExploreSample: () -> Unit = {
        // Nothing to do but proceed: bootstrap already seeded, and the flag it set keeps the
        // sample banner up for as long as that data is what's on screen.
        env.completeOnboarding()
    }
    val onStartEmpty: () -> Unit = {
        busy = true
        scope.launch {
            env.startEmpty()
            busy = false
            env.completeOnboarding()
        }
    }
    val working = staged.isRunning || syncing || busy

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BadanSpace.s5)
            .padding(bottom = BadanSpace.s5),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        IconMark(icon = Icons.Filled.MonitorHeart, tint = colors.primary, diameter = 64.dp)
        Spacer(modifier = Modifier.size(BadanSpace.s4))
        Text(
            text = s(connectTitle),
            style = titleFont,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(modifier = Modifier.size(BadanSpace.s2))
        Text(
            text = s(connectSubtitle),
            style = BadanType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )

        Spacer(modifier = Modifier.size(BadanSpace.s4))

        FamilyBundlePicker(
            selected = selected,
            onToggle = { family ->
                selected = if (family in selected) selected - family else selected + family
            },
        )

        Spacer(modifier = Modifier.size(BadanSpace.s3))

        // The Android-specific honesty obligation, stated before the request rather than after it.
        InlineNotice(text = s(historyWindowNotice), icon = Icons.Filled.History)

        Spacer(modifier = Modifier.size(BadanSpace.s4))

        if (connectError != null) {
            Text(
                text = s(connectError!!),
                style = BadanType.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(bottom = BadanSpace.s3),
            )
        }
        // Progress through the sequence, so five consecutive system sheets read as a designed flow
        // rather than as the app asking again because it did not hear the answer.
        staged.current?.let { family ->
            Text(
                text = s(stageProgressLabel(family, staged.completedStages, staged.totalStages)),
                style = BadanType.caption,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(bottom = BadanSpace.s2),
            )
        }
        PrimaryButton(
            label = when {
                syncing -> s(readingLabel)
                staged.isRunning -> s(connectingLabel)
                else -> s(connectPrimary)
            },
            enabled = !working,
            onClick = onConnect,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(modifier = Modifier.size(BadanSpace.s3))

        // Sample data is offered plainly, and says what it is right here — the caption is the
        // difference between "explore the app" and "here is some health data".
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BadanSpace.touchMin)
                .clickable(enabled = !working, onClick = onExploreSample),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = s(exploreSampleLabel),
                style = BadanType.body,
                color = colors.primary,
            )
        }
        Text(
            text = s(exploreSampleCaption),
            style = BadanType.caption,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )
        Spacer(modifier = Modifier.size(BadanSpace.s3))

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BadanSpace.touchMin)
                .clickable(enabled = !working, onClick = onStartEmpty),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = s(startEmptyLabel),
                style = BadanType.body,
                color = colors.textSecondary,
            )
        }
    }
}

// MARK: - Shared building blocks

@Composable
private fun PrimaryButton(
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = BadanTheme.colors
    val onPrimary = colors.onPrimary
    Box(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = BadanSpace.touchMin)
            .clickable(enabled = enabled, onClick = onClick)
            .background(
                colors.primary.copy(alpha = if (enabled) 1f else 0.45f),
                RoundedCornerShape(BadanRadius.control),
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = label,
            style = BadanType.body.copy(fontWeight = FontWeight.SemiBold),
            color = onPrimary.copy(alpha = if (enabled) 1f else 0.6f),
        )
    }
}

@Composable
private fun IconMark(icon: ImageVector, tint: Color, diameter: Dp) {
    Box(
        modifier = Modifier
            .size(diameter)
            .background(tint.copy(alpha = 0.12f), CircleShape),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(diameter * 0.42f),
        )
    }
}

// MARK: - Local tokens

/**
 * A slightly larger display title for onboarding heroes — the shared ramp tops out at
 * `sectionTitle` (20sp), so the welcome uses one warmer bold weight.
 */
private val titleFont = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold)

@Composable
private fun locBack(): String = LocalAppEnvironment.current.s(Loc.back)

@Composable
private fun locSkip(): String = LocalAppEnvironment.current.s(Loc.skip)

/** Spoken step progress for TalkBack, e.g. "Step 2 of 4". */
private fun stepAnnouncement(step: Int, pageCount: Int): LocalizedString = LocalizedString(
    en = "Step ${step + 1} of $pageCount",
    ar = "الخطوة ${step + 1} من $pageCount",
)

// MARK: - Strings (bilingual; wellness-safe)

private val languageHint = LocalizedString(
    en = "Choose your language. You can change it anytime.",
    ar = "اختر لغتك. يمكنك تغييرها في أي وقت.",
)

private val whyTitle = LocalizedString(en = "Why BADAN", ar = "لماذا بدن")

private val valuePrivateTitle = LocalizedString(en = "A private repository", ar = "مستودع خاص")
private val valuePrivateBody = LocalizedString(
    en = "Your health lives in one place that belongs to you.",
    ar = "صحتك في مكان واحد يخصّك وحدك.",
)

private val valueOwnTitle = LocalizedString(en = "Your data is yours", ar = "بياناتك ملكك")
private val valueOwnBody = LocalizedString(
    en = "Export everything, anytime. Raw data is never locked away.",
    ar = "صدّر كل شيء في أي وقت. البيانات الخام لا تُحجب أبداً.",
)

private val valueOfflineTitle = LocalizedString(en = "Works offline", ar = "يعمل دون اتصال")
private val valueOfflineBody = LocalizedString(
    en = "Everything stays on your device. No account needed.",
    ar = "كل شيء يبقى على جهازك. لا حاجة إلى حساب.",
)

private val depthTitle = LocalizedString(en = "How much detail?", ar = "كم من التفاصيل؟")
private val depthSubtitle = LocalizedString(
    en = "Two views over the same data. Switch anytime in Settings.",
    ar = "عرضان لنفس البيانات. بدّل في أي وقت من الإعدادات.",
)

private val depthSimpleTitle = LocalizedString(en = "Keep it simple", ar = "أبقِه بسيطاً")
private val depthSimpleBody = LocalizedString(
    en = "Calm summaries and the numbers that matter most.",
    ar = "ملخّصات هادئة والأرقام الأهم.",
)

private val depthDetailTitle = LocalizedString(en = "Show me detail", ar = "أرِني التفاصيل")
private val depthDetailBody = LocalizedString(
    en = "Raw values, your ranges, and where each number came from.",
    ar = "القيم الخام ونطاقاتك ومصدر كل رقم.",
)

private val depthChooseHint = LocalizedString(
    en = "Choose one to continue",
    ar = "اختر أحد الخيارين للمتابعة",
)

private val connectTitle = LocalizedString(en = "Bring in your health data", ar = "أحضِر بياناتك الصحية")
private val connectSubtitle = LocalizedString(
    en = "Connect a source now, or add it later — BADAN works either way.",
    ar = "اربط مصدراً الآن أو أضِفه لاحقاً — يعمل بدن في الحالتين.",
)

private val connectPrimary = LocalizedString(en = "Connect health data", ar = "ربط البيانات الصحية")
private val connectingLabel = LocalizedString(en = "Connecting…", ar = "جارٍ الربط…")
private val readingLabel = LocalizedString(en = "Reading your data…", ar = "جارٍ قراءة بياناتك…")

/** Deselecting everything is a coherent choice, so it gets a nudge rather than a disabled button
 *  the user has to reverse-engineer. */
private val connectNothingSelectedNotice = LocalizedString(
    en = "Nothing is selected. Pick at least one kind of data, or continue with one of the options below.",
    ar = "لم يُحدَّد شيء. اختر نوعاً واحداً على الأقل من البيانات، أو تابع بأحد الخيارين أدناه.",
)

/**
 * The 30-day statement in its shortest honest form (plan §14 Phase-0 exit criterion). The full
 * version, with the per-type breakdown, lives on the Sources screen — this one has to fit on a
 * decision screen without becoming the thing the user skims past.
 */
private val historyWindowNotice = LocalizedString(
    en = "Health Connect shares the last 30 days with other apps, so that's what BADAN can read to " +
        "start with. Everything after today is kept as it arrives.",
    ar = "يشارك هيلث كونكت آخر ٣٠ يوماً مع التطبيقات الأخرى، وهذا ما يستطيع بدن قراءته في البداية. " +
        "أما ما يأتي بعد اليوم فيُحفَظ فور وصوله.",
)

private val neverTitle = LocalizedString(en = "What BADAN never does", ar = "ما لا يفعله بدن أبداً")

private val neverSellTitle = LocalizedString(en = "Never sells your data", ar = "لا يبيع بياناتك أبداً")
private val neverSellBody = LocalizedString(
    en = "There is no account, no advertising and nobody to sell to. BADAN has no server that holds your health data.",
    ar = "لا يوجد حساب ولا إعلانات ولا جهة تُباع لها البيانات. ليس لبدن خادم يحتفظ ببياناتك الصحية.",
)

private val neverDiagnoseTitle = LocalizedString(en = "Never diagnoses", ar = "لا يشخّص أبداً")
private val neverDiagnoseBody = LocalizedString(
    en = "BADAN describes what your data shows and how it worked that out. It doesn't tell you what's wrong with you, and it isn't a substitute for a clinician.",
    ar = "يصف بدن ما تُظهره بياناتك وكيف توصّل إليه. لا يخبرك بما تعاني منه، وليس بديلاً عن الطبيب.",
)

private val neverCloudTitle = LocalizedString(en = "Never uploads on its own", ar = "لا يرفع شيئاً من تلقاء نفسه")
private val neverCloudBody = LocalizedString(
    en = "Nothing leaves this device unless you export or share it yourself.",
    ar = "لا يغادر أي شيء هذا الجهاز إلا إذا صدّرته أو شاركته بنفسك.",
)

/** Denial is a legitimate answer, not a failure — no scolding, no dead end. */
private val connectDeniedNotice = LocalizedString(
    en = "No problem — Health Connect wasn't granted. You can pick one of the options below, or " +
        "connect later from Settings.",
    ar = "لا بأس — لم يُمنح إذن Health Connect. يمكنك اختيار أحد الخيارين أدناه، أو الربط لاحقاً من الإعدادات.",
)
private val connectUnavailableNotice = LocalizedString(
    en = "Health Connect isn't available on this device yet. You can still explore or start empty.",
    ar = "Health Connect غير متاح على هذا الجهاز بعد. لا يزال بإمكانك الاستكشاف أو البدء فارغاً.",
)
private val exploreSampleLabel = LocalizedString(en = "Explore with sample data", ar = "استكشف ببيانات تجريبية")

/** The admission that makes the sample option honest rather than a trap. */
private val exploreSampleCaption = LocalizedString(
    en = "Made-up readings, so you can look around. Nothing here is yours until you connect.",
    ar = "قراءات مُختلَقة كي تتصفّح التطبيق. لا شيء هنا يخصّك حتى تربط بياناتك.",
)
private val startEmptyLabel = LocalizedString(en = "Start empty", ar = "ابدأ فارغاً")
