package net.albayyan.badan.storage

import net.albayyan.badan.storage.migrations.MigrationRunner
import net.albayyan.badan.storage.migrations.Migrations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **Fresh install and staged upgrade must reach the same schema.**
 *
 * This is the assertion that actually catches a duplicate version number, and it catches the half
 * that nothing else does. A duplicate is LOUD on a fresh install — the second
 * `INSERT INTO schema_migrations (version, …)` violates that table's `INTEGER PRIMARY KEY`, and
 * `Database.migrate` has no catch inside its transaction block, so the app fails to open at all.
 * On an UPGRADED device it is silent: the version is already recorded, so the second claimant is
 * simply not pending and its tables are never created. The user gets a database missing whatever
 * the loser owned, with no error anywhere. Comparing the two paths' schemas is what surfaces it.
 *
 * It also catches an ordering regression for free: `apply` throws when an index or `ALTER TABLE`
 * names a table that does not exist yet, which is exactly what an unsorted provider list produces.
 *
 * Scope, stated plainly: [SchemaSimulator], not SQLite, models the DDL — this module has no
 * Robolectric and no JVM SQLite driver, so no unit test here can open a real database. See that
 * class's header for what that does and does not prove.
 */
class MigrationEquivalenceTest {

    /** Mirrors `Database.migrate`: pending in ascending order, each version recorded as it runs. */
    private fun migrate(sim: SchemaSimulator, all: List<Migration>, applied: MutableSet<Int>) {
        for (m in MigrationRunner.pending(all, applied)) {
            sim.apply(m)
            // `schema_migrations.version` is INTEGER PRIMARY KEY — a second insert of the same
            // version throws in SQLite, uncaught, inside the transaction. Model that exactly.
            check(applied.add(m.version)) {
                "duplicate migration version ${m.version} — schema_migrations PRIMARY KEY violation"
            }
        }
    }

    private fun freshInstall(all: List<Migration>): List<String> {
        val sim = SchemaSimulator()
        migrate(sim, all, mutableSetOf())
        return sim.dump()
    }

    private fun stagedUpgrade(all: List<Migration>, stopAt: Int): List<String> {
        val sim = SchemaSimulator()
        val applied = mutableSetOf<Int>()
        migrate(sim, all.filter { it.version <= stopAt }, applied)
        migrate(sim, all, applied)
        return sim.dump()
    }

    // ------------------------------------------------------------------------------------
    // The real schema.
    // ------------------------------------------------------------------------------------

    /**
     * `stopAt = 8` is `Schema.kt`'s current main head: the newest schema any Android device could
     * be sitting on today. Everything the port adds (3, 9, 10, 11, 12) must take such a device to
     * the same place a brand-new install lands.
     */
    @Test fun mainFreshInstallMatchesUpgradeFromTheCurrentHead() {
        val all = Migrations.main
        assertTrue("the main schema must actually contain objects", freshInstall(all).isNotEmpty())
        assertEquals(freshInstall(all), stagedUpgrade(all, stopAt = 8))
    }

    /** `stopAt = 4` is `Schema.kt`'s current sensitive head, for the same reason. */
    @Test fun sensitiveFreshInstallMatchesUpgradeFromTheCurrentHead() {
        val all = Migrations.sensitive
        assertTrue("the sensitive schema must actually contain objects", freshInstall(all).isNotEmpty())
        assertEquals(freshInstall(all), stagedUpgrade(all, stopAt = 4))
    }

    /** Also equivalent from a v1-era install, which is the longest upgrade path that exists. */
    @Test fun mainFreshInstallMatchesUpgradeFromVersionOne() {
        val all = Migrations.main
        assertEquals(freshInstall(all), stagedUpgrade(all, stopAt = 1))
    }

    @Test fun sensitiveFreshInstallMatchesUpgradeFromVersionOne() {
        val all = Migrations.sensitive
        assertEquals(freshInstall(all), stagedUpgrade(all, stopAt = 1))
    }

    // ------------------------------------------------------------------------------------
    // Negative controls — proof the assertions above have teeth.
    // ------------------------------------------------------------------------------------

    /**
     * The exact failure this test exists for: two providers both numbered 9. On a fresh install it
     * blows up; on a device that already applied the first claimant's 9, the second is not pending
     * and its table is silently absent. Both halves asserted, because only asserting the loud half
     * would leave the dangerous half untested.
     */
    @Test fun aDuplicateVersionIsLoudOnFreshInstallAndSilentOnUpgrade() {
        val base = listOf(
            Migration(1, listOf("CREATE TABLE a (id TEXT PRIMARY KEY);")),
            Migration(9, listOf("CREATE TABLE b (id TEXT PRIMARY KEY);")),
        )
        val withDuplicate = base + Migration(9, listOf("CREATE TABLE c (id TEXT PRIMARY KEY);"))

        // Fresh: loud.
        val loud = runCatching { freshInstall(withDuplicate) }.exceptionOrNull()
        assertTrue(
            "a fresh install must fail on a duplicate version, not absorb it (got $loud)",
            loud is IllegalStateException && loud.message!!.contains("duplicate migration version 9"),
        )

        // Upgrade from a device that already recorded 9: silent, and short a table.
        val sim = SchemaSimulator()
        val applied = mutableSetOf<Int>()
        migrate(sim, base, applied)                 // device is at 1, 9
        migrate(sim, withDuplicate, applied)        // second v9 is not pending — nothing happens
        val upgraded = sim.dump()

        assertNotEquals(
            "the upgrade path silently diverges from a fresh install — this is the whole point",
            freshInstall(base + Migration(10, listOf("CREATE TABLE c (id TEXT PRIMARY KEY);"))),
            upgraded,
        )
        assertTrue(
            "table c never got created on the upgraded device, with no error anywhere",
            upgraded.none { it.contains("|c|") },
        )
    }

    /**
     * An ordering regression — an `ALTER TABLE`/`CREATE INDEX` reaching the connection before the
     * `CREATE TABLE` it depends on — must fail, not pass quietly. This is what `Migrations`' and
     * `MigrationRunner`'s sorts prevent, and this asserts the harness would notice if they stopped.
     */
    @Test fun applyingAnAlterBeforeItsTableFails() {
        val sim = SchemaSimulator()
        val failure = runCatching {
            sim.apply("ALTER TABLE sources ADD COLUMN connection_type TEXT;")
        }.exceptionOrNull()
        assertTrue("expected a no-such-table failure, got $failure", failure is IllegalStateException)

        val indexFailure = runCatching {
            sim.apply("CREATE INDEX idx_x ON sources(id);")
        }.exceptionOrNull()
        assertTrue("expected a no-such-table failure, got $indexFailure", indexFailure is IllegalStateException)
    }

    /** The simulator must refuse statements it does not model rather than skipping them. */
    @Test fun anUnmodelledStatementIsRejected() {
        val failure = runCatching { SchemaSimulator().apply("CREATE TRIGGER t AFTER INSERT ON x BEGIN END;") }
            .exceptionOrNull()
        assertTrue("expected a rejection, got $failure", failure is IllegalStateException)
    }
}
