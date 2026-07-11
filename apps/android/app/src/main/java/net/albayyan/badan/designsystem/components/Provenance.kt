package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FileDownload
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType
import net.albayyan.badan.domain.IngestionPath
import java.text.DateFormat
import java.util.Date
import java.util.Locale

/**
 * The power-mode lineage line for a datum (mirror of iOS `ProvenanceRow`): an ingestion-path
 * icon, the source name, the human ingestion-path label and when it arrived. Makes "where did
 * this number come from" a visible row rather than a promise.
 */
@Composable
fun ProvenanceRow(
    sourceName: String,
    ingestionPath: IngestionPath,
    timestampMillis: Long,
    language: AppLanguage,
    modifier: Modifier = Modifier,
) {
    val colors = BadanTheme.colors
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Icon(
            imageVector = ingestionPath.provenanceIcon(),
            contentDescription = null,
            tint = colors.textSecondary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = sourceName,
            style = BadanType.caption,
            color = colors.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            text = ingestionPath.displayLabel.resolved(language),
            style = BadanType.caption,
            color = colors.textSecondary,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            // Memoized so the DateFormat isn't rebuilt on every unrelated recomposition of this
            // row's parent (PERF-221).
            text = remember(timestampMillis, language) { formatTimestamp(timestampMillis, language) },
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

private fun IngestionPath.provenanceIcon(): ImageVector = when (this) {
    IngestionPath.PLATFORM_STORE -> Icons.Filled.MonitorHeart
    IngestionPath.MANUAL -> Icons.Filled.Edit
    IngestionPath.FILE_IMPORT -> Icons.Filled.FileDownload
    IngestionPath.DERIVED -> Icons.Filled.Functions
    IngestionPath.VENDOR -> Icons.Filled.Link
}

private fun formatTimestamp(millis: Long, language: AppLanguage): String {
    val locale = Locale.forLanguageTag(language.localeTag)
    val formatter = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT, locale)
    return formatter.format(Date(millis))
}
