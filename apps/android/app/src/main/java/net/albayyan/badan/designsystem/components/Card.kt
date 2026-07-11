package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType

/**
 * The standard surface for grouped content (mirror of iOS `BadanCard`). One card style
 * everywhere means casual and power are two altitudes over a single container, never two
 * designs: surface background, soft 20dp corners and a subtle separator border. Content is
 * laid out in a [ColumnScope] filling the card width.
 *
 * Elevation cue is theme-aware: light mode uses a quiet drop shadow against the near-white
 * surface; dark mode swaps the shadow for Material's tonal-elevation approach (a lighter
 * `surfaceElevated` fill) since a soft dark blur reads as a muddy halo rather than a true
 * shadow once the background is already near-black (UIUX-221).
 */
@Composable
fun BadanCard(
    modifier: Modifier = Modifier,
    padding: Dp = BadanSpace.cardPadding,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = BadanTheme.colors
    val shape = RoundedCornerShape(BadanRadius.card)
    val surfaceModifier = if (colors.isDark) {
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceElevated)
            .border(width = 1.dp, color = colors.separator, shape = shape)
    } else {
        Modifier
            .fillMaxWidth()
            .shadow(elevation = 6.dp, shape = shape, clip = false)
            .clip(shape)
            .background(colors.surface)
            .border(width = 1.dp, color = colors.separator, shape = shape)
    }
    Column(
        modifier = modifier.then(surfaceModifier).padding(padding),
        content = content,
    )
}

/**
 * A titled section header with an optional trailing action (e.g. "See all", a menu). Mirror of
 * iOS `SectionHeader`. The title takes the available width and any trailing content sits at the
 * end, mirroring correctly under RTL. The `trailing` slot always gets a structural minimum touch
 * target (48dp) rather than relying on each call site to add it (UIUX-235).
 */
@Composable
fun SectionHeader(
    title: String,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Text(
            text = title,
            style = BadanType.sectionTitle,
            color = colors.textPrimary,
            modifier = Modifier.weight(1f),
        )
        if (trailing != null) {
            Box(
                modifier = Modifier.heightIn(min = BadanSpace.touchMin),
                contentAlignment = Alignment.CenterEnd,
            ) {
                trailing()
            }
        }
    }
}
