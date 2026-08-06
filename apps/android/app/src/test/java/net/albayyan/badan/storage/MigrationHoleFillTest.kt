package net.albayyan.badan.storage

import net.albayyan.badan.storage.migrations.MigrationAllocation
import net.albayyan.badan.storage.migrations.MigrationRunner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The predicate change, stated as a test.
 *
 * Android's main migration list has a hole at 3 and its sensitive list has one at 2 — reserved for
 * iOS's main v3 and sensitive v2 content, which was never ported before the 2026-07-22 pause.
 * ADR-0012 directs that content to land AT those numbers rather than being appended past the head.
 *
 * Under the old `version > MAX(version)` predicate that is impossible: a device that already
 * recorded 4 or 5 would never run 3, ever, silently. Under `version NOT IN (SELECT version FROM
 * schema_migrations)` each version is judged on its own. Both halves are asserted below — the new
 * behaviour, and the old behaviour it replaces — so a future "simplification" back to a high-water
 * mark fails here with the reason attached rather than shipping.
 */
class MigrationHoleFillTest {

    private fun m(version: Int) = Migration(version, listOf("-- v$version"))

    /** The old predicate, kept only so the contrast below is concrete rather than asserted. */
    private fun highWaterMarkPending(migrations: List<Migration>, applied: Set<Int>): List<Migration> {
        val current = applied.maxOrNull() ?: 0
        return migrations.filter { it.version > current }
    }

    @Test fun aHoleFillingVersionAppliesOnADeviceThatAlreadyPassedIt() {
        val applied = setOf(1, 2, 4, 5)
        val all = listOf(1, 2, 3, 4, 5).map(::m)

        val pending = MigrationRunner.pending(all, applied)

        assertEquals("only the hole is left to apply", listOf(3), pending.map { it.version })
    }

    @Test fun theOldHighWaterMarkPredicateWouldHaveSkippedItSilently() {
        val applied = setOf(1, 2, 4, 5)
        val all = listOf(1, 2, 3, 4, 5).map(::m)

        val old = highWaterMarkPending(all, applied).map { it.version }

        assertFalse(
            "`version > MAX(version)` cannot ever run a hole-fill — that is why the predicate " +
                "changed (ADR-0012). If this ever passes, the predicate regressed.",
            old.contains(3),
        )
        assertTrue("and it would have run nothing at all here", old.isEmpty())
    }

    /**
     * The concurrency half of the same problem: a provider owning a LOWER version registered after
     * one owning a higher version. On a device that already applied the higher one, `> MAX` skips
     * the lower forever. This is not hypothetical for this port — B2-3's main 3 lands after
     * `Schema.kt`'s 4-8 already exist.
     */
    @Test fun aLowerVersionRegisteredAfterAHigherOneStillApplies() {
        val applied = setOf(1, 2, 4, 5, 6, 7, 8)
        // Registration order deliberately wrong: 12 before 3.
        val all = listOf(12, 1, 2, 4, 5, 6, 7, 8, 3, 9, 10, 11).map(::m)

        val pending = MigrationRunner.pending(all, applied)

        assertEquals(
            "the hole applies first, then the appended ones, ascending",
            listOf(3, 9, 10, 11, 12),
            pending.map { it.version },
        )
    }

    @Test fun anAlreadyFullyMigratedDatabaseHasNothingPending() {
        val all = (1..12).map(::m)
        assertTrue(MigrationRunner.pending(all, applied = (1..12).toSet()).isEmpty())
    }

    @Test fun aFreshDatabaseAppliesEverythingAscending() {
        val all = listOf(12, 3, 1, 2).map(::m)
        assertEquals(listOf(1, 2, 3, 12), MigrationRunner.pending(all, applied = emptySet()).map { it.version })
    }

    /**
     * Same assertion, but expressed against the real reserved slots rather than toy numbers, so it
     * keeps meaning something once B2-3 and B2-7 fill them in.
     */
    @Test fun bothRealReservedHolesApplyOnAnAlreadyMigratedDevice() {
        val mainAll = (MigrationAllocation.main.keys).map(::m)
        val mainApplied = Schema.mainMigrations.map { it.version }.toSet()
        assertTrue(
            "main 3 must be pending on a device sitting at Schema.kt's current head",
            MigrationRunner.pending(mainAll, mainApplied).map { it.version }
                .contains(MigrationAllocation.MAIN_SESSION_IDENTITY_REPAIR),
        )

        val sensitiveAll = (MigrationAllocation.sensitive.keys).map(::m)
        val sensitiveApplied = Schema.sensitiveMigrations.map { it.version }.toSet()
        assertTrue(
            "sensitive 2 must be pending on a device sitting at Schema.kt's current head",
            MigrationRunner.pending(sensitiveAll, sensitiveApplied).map { it.version }
                .contains(MigrationAllocation.SENSITIVE_REGIMEN_ENDED_INDEX),
        )
    }
}
