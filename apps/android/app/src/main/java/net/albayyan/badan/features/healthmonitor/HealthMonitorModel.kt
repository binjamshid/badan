package net.albayyan.badan.features.healthmonitor

import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.domain.derivation.SparklinePoint
import net.albayyan.badan.domain.derivation.TempDirection
import net.albayyan.badan.domain.derivation.VitalState

/**
 * The Health Monitor's Compose-free presentation core (mirror of the iOS `HealthMonitorStrings` +
 * chip mapping). Kept out of the screen file so `HealthMonitorPresentationTest` asserts the tile→chip
 * mapping and the sparkline range without loading the Compose runtime — the same pure/UI split the
 * engines use.
 *
 * The tile-state labels and the honesty framing live here; the mandatory "not a medical evaluation"
 * footer copy itself lives on `DeviationEngine.disclaimer` (asserted by a test and the copy lint), so
 * this surface cannot drift it.
 */
internal object HealthMonitorStrings {
    val title = LocalizedString(en = "Health Monitor", ar = "مراقب الصحة")
    val subtitle = LocalizedString(
        en = "Your vitals against your own usual range.",
        ar = "علاماتك الحيوية مقارنةً بنطاقك المعتاد.",
    )
    val noReadingYet = LocalizedString(en = "No reading yet", ar = "لا قراءة بعد")
    val atUsual = LocalizedString(en = "At your usual level", ar = "عند مستواك المعتاد")
    val aboveUsual = LocalizedString(en = "Above your usual level", ar = "أعلى من مستواك المعتاد")
    val belowUsual = LocalizedString(en = "Below your usual level", ar = "أدنى من مستواك المعتاد")
    val asOf = LocalizedString(en = "as of {date}", ar = "حتى {date}")
    val fromSource = LocalizedString(en = "from {source}", ar = "من {source}")
    val usualRange = LocalizedString(en = "Your usual range", ar = "نطاقك المعتاد")
    val daysUsed = LocalizedString(en = "days", ar = "يوماً")
    val emptyMessage = LocalizedString(
        en = "No vitals yet — connect a wearable or log readings to see them here.",
        ar = "لا علامات حيوية بعد — اربط جهازاً أو سجّل قراءات لتظهر هنا.",
    )
}

/**
 * Map a vital's honest [VitalState] to a calm chip: in-band is a green check, both out-of-band
 * directions share ONE amber and disambiguate by arrow, calibrating/no-data are neutral info, and a
 * temperature deviation borrows the same band grammar (above/below/at the usual level). `null` means
 * "draw no chip" — nothing is claimed. Pure so `HealthMonitorPresentationTest` pins the mapping.
 */
internal fun vitalChip(state: VitalState): Pair<ChipStatus, LocalizedString>? = when (state) {
    VitalState.WithinBand -> ChipStatus.InBand to Loc.inYourRange
    VitalState.AboveBand -> ChipStatus.Above to Loc.aboveYourRange
    VitalState.BelowBand -> ChipStatus.Below to Loc.belowYourRange
    VitalState.Calibrating -> ChipStatus.Info to Loc.stillLearning
    VitalState.NoData -> ChipStatus.Info to HealthMonitorStrings.noReadingYet
    is VitalState.Deviation -> when (state.direction) {
        TempDirection.AT_USUAL -> ChipStatus.InBand to HealthMonitorStrings.atUsual
        TempDirection.ABOVE_USUAL -> ChipStatus.Above to HealthMonitorStrings.aboveUsual
        TempDirection.BELOW_USUAL -> ChipStatus.Below to HealthMonitorStrings.belowUsual
    }
}

/** Min value and span across the present points, ignoring gaps; null when fewer than two readings. */
internal fun sparklineRange(points: List<SparklinePoint>): Pair<Double, Double>? {
    val values = points.mapNotNull { it.value }
    if (values.size < 2) return null
    val minV = values.min()
    val maxV = values.max()
    return minV to (maxV - minV).let { if (it == 0.0) 1.0 else it }
}
