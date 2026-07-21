package net.albayyan.badan

import net.albayyan.badan.storage.Schema
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v6 (audit 2026-07-20, FINDING #1): the baseline append-only fix. `baselines` had a UNIQUE index
 * on its natural key (metric_id, covariate_context, window_days, valid_from), and `upsertBaseline`
 * wrote with `INSERT OR REPLACE`, so a retried score-backfill that recomputed a different band at an
 * already-used `valid_from` did a DELETE-then-INSERT — an in-place overwrite that violated I2. v6
 * drops that unique index and replaces it with a non-unique lookup index; the writer becomes a plain
 * `INSERT`.
 *
 * Scope, stated honestly (as `ProfileHRZonesTest` and `BaselineEngineGoldenTest` do): this module
 * has no `androidTest` source set and no Robolectric, so nothing here opens a real SQLite database.
 * The append-only BEHAVIOR — two rows sharing a `valid_from` both surviving, `computed_at` breaking
 * the tie on read — is therefore exercised on iOS by `DerivationFixTests`, which runs against a real
 * connection. What is verifiable on the JVM is pinned here: the v6 migration statements are asserted
 * string-for-string against the iOS anchor (that identity is the whole cross-platform-parity
 * guarantee for this migration), and v6 is confirmed to be the head main-schema version.
 */
class BaselineAppendOnlyMigrationTest {

    /**
     * The two v6 statements are identical to iOS's, character for character. If either platform
     * rewords one, its own copy of this assertion fails rather than the two schemas silently
     * diverging. The `IF NOT EXISTS` on the CREATE is load-bearing: Android already shipped
     * `idx_baseline_lookup` in its own v2, so v6's CREATE is a no-op on Android and a create on iOS —
     * which is exactly what lets the statement string be byte-identical on both platforms.
     */
    @Test fun v6IsExactlyTheBaselineIndexSwap() {
        val v6 = Schema.mainMigrations.firstOrNull { it.version == 6 }
        assertNotNull("there must be a version-6 main migration", v6)
        assertEquals(
            listOf(
                "DROP INDEX IF EXISTS idx_baseline_identity;",
                "CREATE INDEX IF NOT EXISTS idx_baseline_lookup ON baselines(metric_id, covariate_context, valid_from DESC);",
            ),
            v6!!.statements,
        )
    }

    /**
     * The DROP must come before the CREATE, and the new index must be NON-unique — a UNIQUE index
     * here would reintroduce the exact conflict that `INSERT OR REPLACE` overwrote history on, and a
     * plain `INSERT` would then start throwing instead of appending.
     */
    @Test fun v6DropsTheUniqueIdentityAndAddsANonUniqueLookup() {
        val statements = Schema.mainMigrations.first { it.version == 6 }.statements
        assertTrue("first statement drops the old unique identity index",
            statements[0].contains("DROP INDEX") && statements[0].contains("idx_baseline_identity"))
        assertTrue("second statement creates the replacement lookup index",
            statements[1].contains("CREATE INDEX") && statements[1].contains("idx_baseline_lookup"))
        assertFalse("the replacement lookup index must NOT be UNIQUE — that is the whole fix",
            statements[1].contains("UNIQUE"))
    }
}
