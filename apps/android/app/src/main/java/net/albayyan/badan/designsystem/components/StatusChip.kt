package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Info
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.domain.Baseline

/**
 * The judgment-free positions a [StatusChip] can render. Out-of-band above and below share ONE
 * amber tint; only the arrow + text disambiguate direction.
 */
enum class ChipStatus { InBand, Above, Below, Info }

/**
 * A calm status pill (mirror of iOS `StatusChip`). It never uses red/green to moralize: in-band
 * is a subtle green with a check, both out-of-band directions share one amber and disambiguate
 * with an up/down arrow, and info is blue. Colour is never the only signal — every state pairs
 * hue with an icon and text.
 */
@Composable
fun StatusChip(status: ChipStatus, label: String, modifier: Modifier = Modifier) {
    val colors = BadanTheme.colors
    val tint: Color = when (status) {
        ChipStatus.InBand -> colors.inBand
        ChipStatus.Above, ChipStatus.Below -> colors.outOfBand
        ChipStatus.Info -> colors.info
    }
    val icon: ImageVector = when (status) {
        ChipStatus.InBand -> Icons.Filled.Check
        ChipStatus.Above -> Icons.Filled.ArrowUpward
        ChipStatus.Below -> Icons.Filled.ArrowDownward
        ChipStatus.Info -> Icons.Filled.Info
    }

    // Arrows are semantic (up = higher value), not directional, so the chip layout stays LTR
    // even inside an RTL screen — the up-arrow must never flip to a down-arrow.
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Row(
            modifier = modifier
                .background(tint.copy(alpha = 0.14f), RoundedCornerShape(BadanRadius.chip))
                .padding(horizontal = BadanSpace.s2, vertical = BadanSpace.s1),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(14.dp),
            )
            Text(text = label, style = BadanType.chip, color = tint)
        }
    }
}

/**
 * Convenience overload: build a [StatusChip] directly from a personal-band [Baseline.Position].
 */
@Composable
fun StatusChip(position: Baseline.Position, label: String, modifier: Modifier = Modifier) {
    StatusChip(status = position.toChipStatus(), label = label, modifier = modifier)
}

private fun Baseline.Position.toChipStatus(): ChipStatus = when (this) {
    Baseline.Position.WITHIN -> ChipStatus.InBand
    Baseline.Position.ABOVE -> ChipStatus.Above
    Baseline.Position.BELOW -> ChipStatus.Below
}
