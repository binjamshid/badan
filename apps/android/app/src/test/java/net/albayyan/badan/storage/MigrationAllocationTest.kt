package net.albayyan.badan.storage

import net.albayyan.badan.storage.migrations.MigrationAllocation
import net.albayyan.badan.storage.migrations.MigrationProvider
import net.albayyan.badan.storage.migrations.Migrations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The allocation table is the only thing standing between fourteen concurrently-authored areas and
 * two of them both shipping a migration numbered 10. There is no compiler check for that: two
 * `Migration(version = 10, …)` literals in two different files compile perfectly, and the failure
 * shows up as a primary-key violation on a fresh install or — worse — as silently missing tables on
 * an upgraded one (see `MigrationEquivalenceTest`).
 *
 * These assertions are that check. They run against the REAL [Migrations.providers], so they keep
 * holding as Batch 2 fills the stubs in.
 */
class MigrationAllocationTest {

    private fun emitted(select: (MigrationProvider) -> List<Migration>): List<Pair<Int, MigrationProvider>> =
        Migrations.providers.flatMap { p -> select(p).map { it.version to p } }

    // ------------------------------------------------------------------------------------
    // 1. No duplicate versions across providers.
    // ------------------------------------------------------------------------------------

    @Test fun noMainVersionIsEmittedTwice() = assertNoDuplicates("main") { it.main }

    @Test fun noSensitiveVersionIsEmittedTwice() = assertNoDuplicates("sensitive") { it.sensitive }

    private fun assertNoDuplicates(namespace: String, select: (MigrationProvider) -> List<Migration>) {
        val byVersion = emitted(select).groupBy({ it.first }, { it.second.name })
        val duplicates = byVersion.filterValues { it.size > 1 }
        assertTrue(
            "two providers claim the same $namespace migration version — one of them will never " +
                "apply on an upgraded device, and a fresh install will violate schema_migrations' " +
                "PRIMARY KEY: $duplicates",
            duplicates.isEmpty(),
        )
    }

    // ------------------------------------------------------------------------------------
    // 2. Every emitted version is declared in MigrationAllocation.
    // ------------------------------------------------------------------------------------

    @Test fun everyEmittedMainVersionIsAllocated() =
        assertAllocated("main", MigrationAllocation.main) { it.main }

    @Test fun everyEmittedSensitiveVersionIsAllocated() =
        assertAllocated("sensitive", MigrationAllocation.sensitive) { it.sensitive }

    private fun assertAllocated(
        namespace: String,
        allocation: Map<Int, String>,
        select: (MigrationProvider) -> List<Migration>,
    ) {
        val undeclared = emitted(select)
            .filter { it.first !in allocation }
            .map { "v${it.first} from ${it.second.name}" }
        assertTrue(
            "$namespace migration version(s) exist that MigrationAllocation never allocated. A " +
                "version is not a number you pick — it is handed to your task. $undeclared",
            undeclared.isEmpty(),
        )
    }

    // ------------------------------------------------------------------------------------
    // 3. No provider emits a version allocated to another task.
    // ------------------------------------------------------------------------------------

    @Test fun noProviderEmitsAnotherTasksMainVersion() =
        assertOwnership("main", MigrationAllocation.main) { it.main }

    @Test fun noProviderEmitsAnotherTasksSensitiveVersion() =
        assertOwnership("sensitive", MigrationAllocation.sensitive) { it.sensitive }

    private fun assertOwnership(
        namespace: String,
        allocation: Map<Int, String>,
        select: (MigrationProvider) -> List<Migration>,
    ) {
        val trespass = emitted(select)
            .filter { (version, provider) ->
                val owner = allocation[version]
                owner != null && owner != provider.taskId
            }
            .map { (version, provider) ->
                "$namespace v$version is allocated to ${allocation[version]} but was emitted by " +
                    "${provider.name} (task ${provider.taskId})"
            }
        assertTrue(trespass.joinToString("; "), trespass.isEmpty())
    }

    // ------------------------------------------------------------------------------------
    // 4. The table itself matches what Schema.kt actually holds, and the holes are reserved.
    // ------------------------------------------------------------------------------------

    /**
     * The pre-port allocation must describe `Schema.kt` exactly. If someone adds a migration to
     * `Schema.kt` — which this port explicitly does not do; new work goes in a provider — this
     * fails rather than letting an unallocated version enter through the back door.
     */
    @Test fun prePortAllocationMatchesSchemaKt() {
        assertEquals(
            "main versions in Schema.kt",
            listOf(1, 2, 4, 5, 6, 7, 8),
            Schema.mainMigrations.map { it.version }.sorted(),
        )
        assertEquals(
            "sensitive versions in Schema.kt",
            listOf(1, 3, 4),
            Schema.sensitiveMigrations.map { it.version }.sorted(),
        )
        assertEquals(
            "MigrationAllocation's pre-port main versions",
            listOf(1, 2, 4, 5, 6, 7, 8),
            MigrationAllocation.main.filterValues { it == MigrationAllocation.OWNER_PRE_PORT }.keys.sorted(),
        )
        assertEquals(
            "MigrationAllocation's pre-port sensitive versions",
            listOf(1, 3, 4),
            MigrationAllocation.sensitive.filterValues { it == MigrationAllocation.OWNER_PRE_PORT }.keys.sorted(),
        )
    }

    /**
     * The reserved holes are the entire reason the pending predicate changed. Pin them: main 3 and
     * sensitive 2 are allocated, are NOT pre-port, and sit BELOW their namespace's current head —
     * so a regression to `version > MAX(version)` cannot be made to look harmless.
     */
    @Test fun reservedHolesAreAllocatedBelowTheCurrentHead() {
        assertEquals("B2-3", MigrationAllocation.main[MigrationAllocation.MAIN_SESSION_IDENTITY_REPAIR])
        assertEquals("B2-7", MigrationAllocation.sensitive[MigrationAllocation.SENSITIVE_REGIMEN_ENDED_INDEX])
        assertTrue(
            "main 3 must be below Schema.kt's current main head, or it is not a hole-fill",
            MigrationAllocation.MAIN_SESSION_IDENTITY_REPAIR < Schema.mainMigrations.maxOf { it.version },
        )
        assertTrue(
            "sensitive 2 must be below Schema.kt's current sensitive head",
            MigrationAllocation.SENSITIVE_REGIMEN_ENDED_INDEX < Schema.sensitiveMigrations.maxOf { it.version },
        )
    }

    /** The allocation is contiguous — a gap would mean a slot nobody owns and nobody can fill. */
    @Test fun allocationIsContiguousFromOne() {
        assertEquals((1..12).toList(), MigrationAllocation.main.keys.sorted())
        assertEquals((1..9).toList(), MigrationAllocation.sensitive.keys.sorted())
    }
}
