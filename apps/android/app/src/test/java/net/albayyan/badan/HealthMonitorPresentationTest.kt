package net.albayyan.badan

import net.albayyan.badan.core.Loc
import net.albayyan.badan.designsystem.components.ChipStatus
import net.albayyan.badan.domain.derivation.SparklinePoint
import net.albayyan.badan.domain.derivation.TempDirection
import net.albayyan.badan.domain.derivation.VitalState
import net.albayyan.badan.features.healthmonitor.HealthMonitorStrings
import net.albayyan.badan.features.healthmonitor.sparklineRange
import net.albayyan.badan.features.healthmonitor.vitalChip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * EPIC-27 — the Health Monitor's pure presentation mapping: a vital's honest state to a calm chip, and
 * a gap-aware sparkline's range. Both must be view-independent. Mirror of the iOS
 * `HealthMonitorPresentationTests`.
 */
class HealthMonitorPresentationTest {

    @Test
    fun banded_states_map_to_calm_direction_chips() {
        assertEquals(ChipStatus.InBand to Loc.inYourRange, vitalChip(VitalState.WithinBand))
        assertEquals(ChipStatus.Above to Loc.aboveYourRange, vitalChip(VitalState.AboveBand))
        assertEquals(ChipStatus.Below to Loc.belowYourRange, vitalChip(VitalState.BelowBand))
    }

    @Test
    fun calibrating_and_no_data_are_neutral_info_never_a_verdict() {
        assertEquals(ChipStatus.Info to Loc.stillLearning, vitalChip(VitalState.Calibrating))
        assertEquals(ChipStatus.Info to HealthMonitorStrings.noReadingYet, vitalChip(VitalState.NoData))
    }

    @Test
    fun temperature_deviation_borrows_the_usual_level_grammar() {
        assertEquals(
            ChipStatus.InBand to HealthMonitorStrings.atUsual,
            vitalChip(VitalState.Deviation(TempDirection.AT_USUAL)),
        )
        assertEquals(
            ChipStatus.Above to HealthMonitorStrings.aboveUsual,
            vitalChip(VitalState.Deviation(TempDirection.ABOVE_USUAL)),
        )
        assertEquals(
            ChipStatus.Below to HealthMonitorStrings.belowUsual,
            vitalChip(VitalState.Deviation(TempDirection.BELOW_USUAL)),
        )
    }

    @Test
    fun sparkline_range_ignores_gaps() {
        val points = listOf(
            SparklinePoint("2026-07-01", 50.0),
            SparklinePoint("2026-07-02", null),   // gap — must not become a zero
            SparklinePoint("2026-07-03", 60.0),
        )
        val range = sparklineRange(points)!!
        assertEquals(50.0, range.first, 1e-9)   // min ignores the gap, never reads it as 0
        assertEquals(10.0, range.second, 1e-9)  // span 60 - 50
    }

    @Test
    fun sparkline_range_is_null_with_fewer_than_two_readings() {
        assertNull(sparklineRange(listOf(SparklinePoint("2026-07-01", 50.0), SparklinePoint("2026-07-02", null))))
        assertNull(sparklineRange(emptyList()))
    }

    @Test
    fun sparkline_range_span_never_collapses_to_zero() {
        val flat = listOf(
            SparklinePoint("2026-07-01", 50.0),
            SparklinePoint("2026-07-02", 50.0),
        )
        assertEquals(1.0, sparklineRange(flat)!!.second, 1e-9)
    }
}
