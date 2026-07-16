package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType

/**
 * A single, global, honest label for "what you're looking at right now is the bundled sample
 * dataset, not your own." Port of iOS's `SampleDataBanner` (STUB-01/COMP-06).
 *
 * Android shipped without any equivalent. It seeds 90 days of fabricated health data before
 * onboarding ever runs, and every screen — Home, Body, Insights, Sources, Timeline — then
 * presented those invented readings exactly as it would present the user's own measurements,
 * with nothing anywhere saying otherwise. This is the label that was missing.
 *
 * Deliberately has **no dismiss control**: it goes away on its own when the flag clears (a real
 * connect, or "Start empty"), not because the user waved away a warning about their own data.
 * Calm and small by design — a standing fact about the current view, not an alert.
 *
 * Presentational only — takes [language] explicitly (matching `StatusChip`/`DepthBadge`) rather
 * than reading `AppEnvironment` itself, so it stays a plain, reusable design-system component.
 */
@Composable
fun SampleDataBanner(language: AppLanguage, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    val text = message.resolved(language)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = BadanSpace.s4, vertical = BadanSpace.s2)
            .clip(RoundedCornerShape(percent = 50))
            .background(colors.surfaceElevated)
            .border(1.dp, colors.separator, RoundedCornerShape(percent = 50))
            .padding(horizontal = BadanSpace.s4, vertical = BadanSpace.s2)
            // Read as one phrase; the icon is decorative and must not be announced separately.
            .clearAndSetSemantics { contentDescription = text },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = Icons.Filled.Info,
            contentDescription = null,
            tint = colors.info,
            modifier = Modifier.size(16.dp),
        )
        Text(text = text, style = BadanType.chip, color = colors.textPrimary, maxLines = 2)
    }
}

/** Kept identical in meaning to iOS's banner copy — the two apps must make the same promise. */
private val message = LocalizedString(
    en = "Sample data — connect Health Connect to see yours",
    ar = "بيانات تجريبية — اربط Health Connect لرؤية بياناتك",
)
