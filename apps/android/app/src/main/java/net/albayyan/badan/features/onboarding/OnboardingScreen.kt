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
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.Favorite
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

/**
 * The pre-shell welcome flow (mirror of the iOS `OnboardingView`). The root gates the tab UI on
 * `env.onboardingComplete`; this screen owns its own full-screen layout and, on the final step,
 * calls `env.completeOnboarding()` to hand off to the shell.
 *
 * Four calm steps over the BADAN background:
 *   1. Welcome — with a live EN/AR language toggle so RTL flips immediately.
 *   2. A short "why BADAN" value set (private repository / your data is yours / works offline).
 *   3. A depth preset choice — "Keep it simple" (casual) vs "Show me detail" (power).
 *   4. A connect step — a primary connect action and a secondary "continue without connecting",
 *      both of which complete onboarding.
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

    val pageCount = 4
    val lastStep = pageCount - 1
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
                onSkip = { env.completeOnboarding() },
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

                    2 -> DepthPage(
                        selected = selectedDepth,
                        onSelect = { policy ->
                            selectedDepth = policy
                            env.update { it.copy(depthPolicy = policy) }
                        },
                        s = env::s,
                    )

                    else -> ConnectPage(
                        onComplete = { env.completeOnboarding() },
                        s = env::s,
                    )
                }
            }

            // Footer: a Next button for steps 0–2 (the final step carries its own actions).
            if (step < lastStep) {
                val disabled = step == 2 && selectedDepth == null
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

// MARK: - Page 3: Depth preset

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

// MARK: - Page 4: Connect

@Composable
private fun ConnectPage(
    onComplete: () -> Unit,
    s: (LocalizedString) -> String,
) {
    val colors = BadanTheme.colors
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = BadanSpace.s5)
            .padding(bottom = BadanSpace.s5),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(modifier = Modifier.weight(1f))

        IconMark(icon = Icons.Filled.MonitorHeart, tint = colors.primary, diameter = 84.dp)
        Spacer(modifier = Modifier.size(BadanSpace.s6))
        Text(
            text = s(connectTitle),
            style = titleFont,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Spacer(modifier = Modifier.size(BadanSpace.s3))
        Text(
            text = s(connectSubtitle),
            style = BadanType.body,
            color = colors.textSecondary,
            textAlign = TextAlign.Center,
        )

        Spacer(modifier = Modifier.weight(1f))

        PrimaryButton(
            label = s(connectPrimary),
            enabled = true,
            onClick = onComplete,
            modifier = Modifier.fillMaxWidth(),
        )
        Spacer(modifier = Modifier.size(BadanSpace.s3))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = BadanSpace.touchMin)
                .clickable(onClick = onComplete),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                text = s(Loc.continueWithoutConnecting),
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
    // No dedicated on-primary token: white on the light-theme teal, near-black on the light
    // dark-theme teal — legible in both.
    val onPrimary = if (colors.isDark) Color(0xFF08201D) else Color.White
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
