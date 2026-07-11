package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType

/**
 * The four states any data-backed surface can be in (mirror of iOS `LoadState`). Modelled
 * explicitly so screens can't forget the empty/error paths.
 */
sealed interface LoadState<out T> {
    object Loading : LoadState<Nothing>
    data class Empty(val message: String) : LoadState<Nothing>
    data class Error(val message: String) : LoadState<Nothing>
    data class Loaded<T>(val value: T) : LoadState<T>
}

/**
 * Switches over a [LoadState], rendering calm loading/empty/error surfaces or handing the
 * loaded value to its content (mirror of iOS `StatefulContainer`). Quiet by default — no idle
 * drama.
 */
@Composable
fun <T> StatefulContainer(
    state: LoadState<T>,
    modifier: Modifier = Modifier,
    content: @Composable (T) -> Unit,
) {
    val colors = BadanTheme.colors
    when (state) {
        is LoadState.Loading -> Box(
            modifier = modifier
                .fillMaxWidth()
                .padding(vertical = BadanSpace.s7),
            contentAlignment = Alignment.Center,
        ) {
            CircularProgressIndicator(color = colors.primary)
        }

        is LoadState.Empty -> EmptyState(
            icon = Icons.Filled.Inbox,
            title = state.message,
            message = "",
            modifier = modifier,
        )

        is LoadState.Error -> EmptyState(
            icon = Icons.Filled.WarningAmber,
            title = state.message,
            message = "",
            modifier = modifier,
        )

        is LoadState.Loaded -> content(state.value)
    }
}

/**
 * A gentle empty/error surface (mirror of iOS `EmptyStateView`): icon, title, supporting
 * message and an optional action. Centred and calm; the optional action honours the 48dp
 * minimum touch target through its own composable.
 */
@Composable
fun EmptyState(
    icon: ImageVector,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    action: (@Composable () -> Unit)? = null,
) {
    val colors = BadanTheme.colors
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(vertical = BadanSpace.s7, horizontal = BadanSpace.s5),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s3),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(28.dp),
        )
        Text(
            text = title,
            style = BadanType.sectionTitle,
            color = colors.textPrimary,
            textAlign = TextAlign.Center,
        )
        if (message.isNotEmpty()) {
            Text(
                text = message,
                style = BadanType.body,
                color = colors.textSecondary,
                textAlign = TextAlign.Center,
            )
        }
        if (action != null) {
            action()
        }
    }
}
