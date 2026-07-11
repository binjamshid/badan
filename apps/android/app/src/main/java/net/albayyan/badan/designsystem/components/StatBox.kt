package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType

/**
 * A hero value block (mirror of iOS `StatBox`): a big tabular numeral with a caption label, an
 * optional unit and an optional status chip. The workhorse for stat cards and metric heroes.
 * The hero value uses tabular figures so it never jitters as it ticks.
 */
@Composable
fun StatBox(
    value: String,
    label: String,
    modifier: Modifier = Modifier,
    unit: String? = null,
    chip: (@Composable () -> Unit)? = null,
) {
    val colors = BadanTheme.colors
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        Row(
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s1),
        ) {
            Text(
                text = value,
                style = BadanType.heroNumeral,
                color = colors.textPrimary,
                modifier = Modifier.alignByBaseline(),
            )
            if (unit != null) {
                Text(
                    text = unit,
                    style = BadanType.body,
                    color = colors.textSecondary,
                    modifier = Modifier.alignByBaseline(),
                )
            }
        }
        Text(
            text = label,
            style = BadanType.caption,
            color = colors.textSecondary,
        )
        if (chip != null) {
            chip()
        }
    }
}
