package net.albayyan.badan

import net.albayyan.badan.domain.HRZone
import net.albayyan.badan.domain.HRZones
import net.albayyan.badan.domain.UserProfile
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.Schema
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v5 (plan §11 EPIC-26 stage 1): the profile columns the Effort engine reads — an `hr_max` override
 * and an editable `hr_zones` blob.
 *
 * Scope, stated honestly (as `BackgroundSubstrateTest` does): this module has no `androidTest`
 * source set and no Robolectric, so nothing here opens a real SQLite database. The migration is
 * therefore verified where it CAN be on the JVM — the v5 statements are asserted string-for-string
 * against the iOS anchor, which is what makes the two schemas byte-equivalent — and the `HRZones`
 * JSON that lands in the `hr_zones` column is round-tripped through the real `JsonCoding`. The
 * live-database half (a v4→v5 upgrade preserving rows, the resulting column order) is covered on
 * iOS by `ProfileHRZonesFixTests`, which runs against a real connection.
 */
class ProfileHRZonesTest {

    // MARK: - The migration (byte-parity anchor)

    /**
     * The two v5 statements are identical to iOS's, character for character — that identity is the
     * whole cross-platform-parity guarantee for this migration. If either platform rewords one,
     * its own copy of this assertion fails rather than the two schemas silently diverging.
     */
    @Test fun v5IsExactlyTheTwoHRAlterStatements() {
        val v5 = Schema.mainMigrations.firstOrNull { it.version == 5 }
        assertNotNull("there must be a version-5 main migration", v5)
        assertEquals(
            listOf(
                "ALTER TABLE user_profile ADD COLUMN hr_max REAL;",
                "ALTER TABLE user_profile ADD COLUMN hr_zones TEXT;",
            ),
            v5!!.statements,
        )
    }

    /**
     * Statement ORDER is load-bearing: `ALTER TABLE ADD COLUMN` appends in execution order, so
     * hr_max-before-hr_zones is what makes the final `user_profile` column layout match iOS's. This
     * pins that order without a database to inspect.
     */
    @Test fun hrMaxColumnIsAddedBeforeHrZones() {
        val statements = Schema.mainMigrations.first { it.version == 5 }.statements
        assertTrue(statements[0].contains("hr_max"))
        assertTrue(statements[1].contains("hr_zones"))
    }

    // v5 was the head until the audit-2026-07-20 baseline append-only fix added v6 (the
    // `idx_baseline_identity` → `idx_baseline_lookup` swap). Bumped here as the routine maintenance
    // that adding a migration entails; the v6 statements themselves are pinned in
    // `BaselineAppendOnlyMigrationTest`.
    @Test fun v6IsTheHeadMainSchemaVersion() {
        assertEquals(6, Schema.mainMigrations.maxOf { it.version })
    }

    // MARK: - HRZones JSON round-trip (what lands in the hr_zones column)

    private fun fiveZones() = HRZones(
        zones = listOf(
            HRZone(lowerBpm = 93, upperBpm = 111), HRZone(lowerBpm = 112, upperBpm = 130),
            HRZone(lowerBpm = 131, upperBpm = 148), HRZone(lowerBpm = 149, upperBpm = 167),
            HRZone(lowerBpm = 168, upperBpm = 186),
        ),
    )

    @Test fun hrZonesRoundTripThroughTheJsonColumn() {
        val zones = fiveZones()
        val readBack = JsonCoding.decodeOrNull<HRZones>(JsonCoding.encode(zones))
        assertEquals(zones, readBack)
        assertEquals(HRZones.ZONE_COUNT, readBack?.zones?.size)
    }

    /**
     * The exact serialized shape, pinned. It matches what iOS's `JSONCoding` (sorted keys) emits —
     * `lowerBpm` sorts before `upperBpm`, which is also kotlinx's declaration order — so a row
     * written on one platform reads on the other. A field rename or reorder that would break that
     * fails here.
     */
    @Test fun hrZonesSerializesToTheSharedShape() {
        assertEquals(
            """{"zones":[{"lowerBpm":93,"upperBpm":111},{"lowerBpm":112,"upperBpm":130},""" +
                """{"lowerBpm":131,"upperBpm":148},{"lowerBpm":149,"upperBpm":167},""" +
                """{"lowerBpm":168,"upperBpm":186}]}""",
            JsonCoding.encode(fiveZones()),
        )
    }

    @Test fun nullHrZonesIsNotSerializedAsAnEmptyOverride() {
        // A null override must decode back to null (EPIC-26 then derives), never to an empty zone
        // list that would read as "the user pinned zero zones".
        assertNull(JsonCoding.decodeOrNull<HRZones>(null))
    }

    // MARK: - HRZones.isWellFormed shape check

    @Test fun aFiveZoneAscendingOverrideIsWellFormed() {
        assertTrue(fiveZones().isWellFormed)
    }

    @Test fun theWrongZoneCountIsNotWellFormed() {
        assertFalse(HRZones(zones = fiveZones().zones.drop(1)).isWellFormed)
    }

    @Test fun anInvertedZoneIsNotWellFormed() {
        val zones = fiveZones().zones.toMutableList()
        zones[2] = HRZone(lowerBpm = 148, upperBpm = 131) // upper < lower
        assertFalse(HRZones(zones = zones).isWellFormed)
    }

    @Test fun outOfOrderZonesAreNotWellFormed() {
        val zones = fiveZones().zones.toMutableList()
        zones[0] = HRZone(lowerBpm = 200, upperBpm = 210) // first zone's floor above the rest
        assertFalse(HRZones(zones = zones).isWellFormed)
    }

    // MARK: - UserProfile carries the fields

    @Test fun userProfileCarriesTheEffortEngineInputs() {
        val profile = UserProfile(
            id = "u-1", heightMeters = 1.7, birthYear = 1990,
            hrMax = 186.6, hrZones = fiveZones(), createdAt = 100L, updatedAt = 100L,
        )
        assertEquals(186.6, profile.hrMax)
        assertEquals(fiveZones(), profile.hrZones)
        // Defaults keep every existing construction (e.g. SeedController) valid: omit both and they
        // are null, the "derive it" default.
        val bare = UserProfile(id = "u-2", createdAt = 0L, updatedAt = 0L)
        assertNull(bare.hrMax)
        assertNull(bare.hrZones)
    }
}
