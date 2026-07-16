package net.albayyan.badan

import net.albayyan.badan.core.Units
import net.albayyan.badan.core.Ulid
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.derivation.BaselineEngine
import net.albayyan.badan.domain.ingestion.DedupLite
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * Pure-JVM parity tests for the ported logic that the Android port must match iOS on: unit
 * conversion, dedup overlap/reconcile, ULID, and baseline median/MAD.
 *
 * This doc used to end "(DB-backed pipeline tests run as instrumented tests on a device.)" —
 * which was not true. There is no `androidTest` source set in this module and never has been, so
 * the repositories, migrations, ingestion pipeline and export writers have no automated coverage
 * on Android at all. The sentence made a reviewer reading this file believe the opposite of the
 * truth, which is worse than the gap itself. Stated plainly here until those tests exist.
 */
class FoundationTest {

    // --- Units (must match iOS UnitTests numerically) ---

    @Test fun energyConversion() {
        assertEquals(4.184, Units.convert(1.0, "kcal", "kJ"), 0.001)
        assertEquals(1.0, Units.convert(Units.convert(1.0, "kcal", "kJ"), "kJ", "kcal"), 0.0001)
    }

    @Test fun durationConversion() {
        assertEquals(1.0, Units.convert(3600.0, "s", "h"), 0.0001)
        assertEquals(5400.0, Units.convert(90.0, "min", "s"), 0.0001)
    }

    @Test fun massAndDistanceConversion() {
        assertEquals(2.2046, Units.convert(1.0, "kg", "lb"), 0.001)
        assertEquals(1.0, Units.convert(1000.0, "m", "km"), 0.0001)
        assertEquals(1609.344, Units.convert(1.0, "mi", "m"), 0.01)
    }

    @Test fun temperatureOffsetConversion() {
        assertEquals(0.0, Units.convert(32.0, "degF", "degC"), 0.001)
        assertEquals(212.0, Units.convert(100.0, "degC", "degF"), 0.001)
    }

    @Test fun unknownUnitPassesThrough() {
        assertEquals(97.0, Units.toCanonical(97.0, "percent", "percent"), 0.0)
        assertEquals(55.0, Units.toCanonical(55.0, "bpm", "bpm"), 0.0)
    }

    @Test(expected = Units.ConversionError.Incompatible::class)
    fun incompatibleDimensionsThrow() {
        Units.convert(1.0, "kg", "m")
    }

    // --- Dedup ---

    @Test fun overlapFullContainmentAndDisjoint() {
        val base = 1_000_000L
        assertEquals(1.0, DedupLite.overlap(base to base + 3600, base + 300 to base + 3300), 0.001)
        assertEquals(0.0, DedupLite.overlap(base to base + 3600, base + 7200 to base + 10800), 0.001)
    }

    @Test fun reconcilePicksHigherPriority() {
        fun session(id: String, source: String) = Session(
            id = id, kind = SessionKind.SLEEP_PRIMARY, startAt = 1_000_000L, endAt = 1_000_000L + 28_800,
            tzId = "UTC", localNight = "2001-01-01",
            provenance = Provenance(sourceId = source, ingestionPath = IngestionPath.PLATFORM_STORE,
                measuredAt = 1_000_000L, measuredTimezone = "UTC", recordedAt = 1_000_000L, ingestedAt = 1_000_000L),
            updatedAt = 1_000_000L, originDeviceId = "d")
        val outcome = DedupLite.reconcile(listOf(session("phone", "src_iphone"), session("watch", "src_watch"))) {
            if (it == "src_watch") 100 else 50
        }
        assertEquals("watch", outcome.winnerId)
        assertEquals(listOf("phone"), outcome.suppressed.map { it.loserId })
    }

    // --- ULID ---

    @Test fun ulidSortableAndDecodable() {
        val early = Ulid.generate(1_000_000L, Random(1))
        val late = Ulid.generate(2_000_000L, Random(1))
        assertEquals(26, early.length)
        assertTrue("ULIDs sort by embedded time", early < late)
        assertEquals(1_000_000L, Ulid.timestampOf(early))
    }

    // --- Baseline math ---

    @Test fun medianAndMad() {
        assertEquals(2.0, BaselineEngine.median(listOf(3.0, 1.0, 2.0)), 0.0001)
        val data = listOf(1.0, 2.0, 3.0, 4.0, 5.0)
        val center = BaselineEngine.median(data)
        assertEquals(3.0, center, 0.0001)
        assertEquals(1.0, BaselineEngine.mad(data, center), 0.0001)
    }
}
