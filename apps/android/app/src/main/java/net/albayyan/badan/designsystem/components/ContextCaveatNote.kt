package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notes
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType

/**
 * The note a score card shows when the day it describes sat inside a period the user marked
 * (EPIC-29, plan §18: "`ContextStatus` … annotate confidence and copy — they modify *interpretation
 * framing*, never the stored value"). Mirror of the iOS `ContextCaveatNote`.
 *
 * This is the visible half of that promise, and the reason the context manager's explainer can say
 * "adds a note beside them" without overstating: the sentences come from `ContextStatus.caveat` —
 * the same text the manager screen previews on each card before the tap — so what the user was told
 * a period would do is exactly what they later meet on the score.
 *
 * **Deliberately not a warning.** No triangle, no amber, no retry: nothing is wrong with the number,
 * and the sentence says only that the personal pattern it is read against was built from days that
 * didn't look like this one. It renders at `textSecondary`, the same weight as the window and
 * provisional notes it sits with.
 *
 * **Why the text is resolved at display time.** Caveats name a circumstance ("travelling", "feeling
 * unwell") and are therefore sensitive-plus, so they are never written onto the derived row in the
 * main database — the surface reads them from the sensitive store when it renders (see
 * `ContextCaveats`). Only the confidence CEILING crosses into `badan.db`, as a bare number.
 * Renders nothing at all when [caveats] is empty, which is the ordinary day.
 */
@Composable
fun ContextCaveatNote(
    caveats: List<LocalizedString>,
    language: AppLanguage,
    modifier: Modifier = Modifier,
) {
    if (caveats.isEmpty()) return
    val colors = BadanTheme.colors
    val spoken = caveats.joinToString(". ") { it.resolved(language) }
    Column(
        modifier = modifier
            .fillMaxWidth()
            // One stop per note block; the icon is decorative and the sentences already read as prose.
            .clearAndSetSemantics { contentDescription = spoken },
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s1),
    ) {
        for (caveat in caveats) {
            Row(
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
            ) {
                Icon(
                    imageVector = Icons.Filled.Notes,
                    contentDescription = null,
                    tint = colors.textSecondary,
                    modifier = Modifier.size(16.dp),
                )
                Text(
                    text = caveat.resolved(language),
                    style = BadanType.caption,
                    color = colors.textSecondary,
                )
            }
        }
    }
}
