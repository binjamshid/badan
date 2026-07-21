package net.albayyan.badan.designsystem.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.HourglassEmpty
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.BadanRadius
import net.albayyan.badan.designsystem.BadanSpace
import net.albayyan.badan.designsystem.BadanTheme
import net.albayyan.badan.designsystem.BadanType

// The pure model (`CalibrationProgress`, `calibrationDayLabel`, `calibrationDefaultMessage`) lives in
// `CalibrationModel.kt` so a JVM unit test can assert it without loading this Compose file.

// MARK: - Component

/**
 * The cold-start calibration state (mirror of the iOS `CalibrationState`). Shown in place of a score
 * the baseline is not yet honest enough to render: a calm "still learning" badge, the day count, a
 * quiet progress bar, and a reassuring, judgment-free line. Impatience is met by showing what already
 * works, never by guessing a number early (plan §16: "We don't guess before we know you").
 *
 * The progress bar is a plain filled [Box], not a Material determinate indicator, so it inherits the
 * calm token palette (primary at low alpha) rather than the Material accent, and never animates
 * urgently.
 */
@Composable
fun CalibrationState(
    progress: CalibrationProgress,
    language: AppLanguage,
    arabicDigits: Boolean,
    modifier: Modifier = Modifier,
    title: String? = null,
    message: LocalizedString = calibrationDefaultMessage,
) {
    val colors = BadanTheme.colors
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(BadanSpace.s2),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(BadanSpace.s2),
        ) {
            Icon(
                imageVector = Icons.Filled.HourglassEmpty,
                contentDescription = null,
                tint = colors.info,
                modifier = Modifier.size(18.dp),
            )
            Text(
                text = title ?: calibrationStillLearning.resolved(language),
                style = BadanType.body,
                color = colors.textPrimary,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = calibrationDayLabel(progress, language, arabicDigits),
                style = BadanType.monospaceDigits(BadanType.caption),
                color = colors.textSecondary,
            )
        }
        // The bar — a soft track with a primary-tinted fill proportional to calibration.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(RoundedCornerShape(BadanRadius.chip))
                .background(colors.surfaceElevated),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(progress.fraction)
                    .height(6.dp)
                    .clip(RoundedCornerShape(BadanRadius.chip))
                    .background(colors.primary.copy(alpha = 0.55f)),
            )
        }
        Text(
            text = message.resolved(language),
            style = BadanType.caption,
            color = colors.textSecondary,
        )
    }
}

// MARK: - Copy (bilingual, wellness-safe)

private val calibrationStillLearning = LocalizedString(
    en = "Still learning your baseline",
    ar = "ما زلنا نتعرّف على مستواك المعتاد",
)
// `calibrationDefaultMessage` (the default `message`) lives in `CalibrationModel.kt` beside the model.
