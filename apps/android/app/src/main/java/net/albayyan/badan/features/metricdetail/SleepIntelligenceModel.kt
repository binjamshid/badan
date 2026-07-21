package net.albayyan.badan.features.metricdetail

import net.albayyan.badan.domain.derivation.SleepSpec
import kotlin.math.max

/**
 * The honest need band the surface renders (mirror of the engine's `SleepNeedRange`). Compose-free so
 * `SleepSectionPresentationTest` pins the band and the show-range threshold without loading the
 * Compose runtime.
 *
 * Only the need CENTRE and its confidence are stored on the derived row; the band is reconstructed
 * from the SAME published half-width the engine used (`rangeHalfWidthSeconds · (2 − confidence)`), and
 * [showRange] fires below the same published confidence threshold — so the surface reproduces the
 * published range rather than inventing a display-only one (plan §4 principle 9: no fake-exact minutes).
 */
internal data class NeedRangeDisplay(
    val centerSeconds: Double,
    val lowSeconds: Double,
    val highSeconds: Double,
    val showRange: Boolean,
)

internal fun needRangeDisplay(centerSeconds: Double, confidence: Double, spec: SleepSpec): NeedRangeDisplay {
    if (!spec.isLoaded) {
        return NeedRangeDisplay(centerSeconds, centerSeconds, centerSeconds, showRange = false)
    }
    val c = confidence.coerceIn(0.0, 1.0)
    val halfWidth = spec.rangeHalfWidthSeconds * (2 - c)
    return NeedRangeDisplay(
        centerSeconds = centerSeconds,
        lowSeconds = max(0.0, centerSeconds - halfWidth),
        highSeconds = centerSeconds + halfWidth,
        showRange = c < spec.lowConfidenceThreshold,
    )
}
