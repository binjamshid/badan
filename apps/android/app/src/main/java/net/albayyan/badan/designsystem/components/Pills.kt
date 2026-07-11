package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.Eco
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.domain.DepthPolicy

/**
 * A small, generic labelled pill with an optional leading icon and tint (mirror of iOS
 * `PillLabel`). The base shape reused by the depth and provisional badges. Tint defaults to the
 * secondary text colour when not specified — that untinted default renders with a
 * `surfaceElevated` fill and a hairline border rather than a barely-there tinted wash, so it
 * still reads clearly as a pill rather than as plain caption text (UIUX-282).
 */
@Composable
fun PillLabel(
    text: String,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    tint: Color? = null,
) {
    val colors = BadanTheme.colors
    val resolvedTint = tint ?: colors.textSecondary
    val shape = RoundedCornerShape(BadanRadius.chip)
    val backgroundModifier = if (tint != null) {
        Modifier.background(resolvedTint.copy(alpha = 0.12f), shape)
    } else {
        Modifier
            .background(colors.surfaceElevated, shape)
            .border(width = 1.dp, color = colors.separator, shape = shape)
    }
    Row(
        modifier = modifier
            .then(backgroundModifier)
            .padding(horizontal = BadanSpace.s2, vertical = BadanSpace.s1),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        if (icon != null) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = resolvedTint,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(text = text, style = BadanType.chip, color = resolvedTint)
    }
}

/**
 * Indicates the current depth altitude ("Simple"/"Balanced"/"Detailed"). Mirror of iOS
 * `DepthBadge`. One model, two altitudes — this badge just names which altitude is showing.
 */
@Composable
fun DepthBadge(depth: DepthPolicy, language: AppLanguage, modifier: Modifier = Modifier) {
    val icon = when (depth) {
        DepthPolicy.CASUAL -> Icons.Filled.Eco
        DepthPolicy.BALANCED -> Icons.Filled.Contrast
        DepthPolicy.POWER -> Icons.Filled.Tune
    }
    PillLabel(
        text = depth.displayName.resolved(language),
        modifier = modifier,
        icon = icon,
        tint = BadanTheme.colors.primary,
    )
}

/**
 * A "still learning" badge for provisional derivations/baselines (mirror of iOS
 * `ProvisionalBadge`) — honest that a number is not yet settled, without alarming.
 */
@Composable
fun ProvisionalBadge(language: AppLanguage, modifier: Modifier = Modifier) {
    PillLabel(
        text = provisionalLabel.resolved(language),
        modifier = modifier,
        icon = Icons.Filled.HourglassEmpty,
        tint = BadanTheme.colors.info,
    )
}

private val provisionalLabel = LocalizedString(en = "Still learning", ar = "قيد التعلّم")
