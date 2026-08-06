package net.albayyan.badan.storage

import net.albayyan.badan.storage.migrations.MigrationProvider
import net.albayyan.badan.storage.migrations.MigrationRunner
import net.albayyan.badan.storage.migrations.Migrations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * **The test that protects against the fourteen-parallel-agent failure mode.**
 *
 * `Schema.kt` never needed a sort: it is one hand-written list that happens to be in ascending
 * order. A provider aggregator has no such property — [Migrations.providers] is a hand-maintained
 * literal, and the moment its order stops matching version order, *provider registration order
 * becomes schema application order*. A v10 provider registered ahead of a v1 provider runs
 * `ALTER TABLE sources ADD COLUMN connection_type` against a `sources` table that does not exist,
 * and `Database.init` throws on every launch.
 *
 * So the sort is asserted in both places it lives: [Migrations.aggregate] (registration order) and
 * [MigrationRunner.pending] (whatever list reaches `Database.migrate`, from anywhere).
 */
class MigrationOrderingTest {

    private fun provider(task: String, mainVersions: List<Int> = emptyList(), sensitiveVersions: List<Int> = emptyList()) =
        object : MigrationProvider {
            override val taskId = task
            override val name = "fake-$task"
            override val main = mainVersions.map { Migration(it, listOf("-- main v$it")) }
            override val sensitive = sensitiveVersions.map { Migration(it, listOf("-- sensitive v$it")) }
        }

    // ------------------------------------------------------------------------------------
    // The aggregator sorts, regardless of registration order.
    // ------------------------------------------------------------------------------------

    @Test fun aggregatorSortsProvidersRegisteredOutOfOrder() {
        // Deliberately adversarial: highest first, the hole-filling 3 dead last, and one provider
        // owning two non-adjacent versions (the real shape of B2-3, which owns main 3 and main 12).
        val outOfOrder = listOf(
            provider("B2-3", mainVersions = listOf(12)),
            provider("B2-5", mainVersions = listOf(10)),
            provider("pre-port", mainVersions = listOf(8, 1, 5)),
            provider("B2-6", mainVersions = listOf(11)),
            provider("B2-4", mainVersions = listOf(9)),
            provider("B2-3b", mainVersions = listOf(3)),
        )
        assertEquals(
            listOf(1, 3, 5, 8, 9, 10, 11, 12),
            Migrations.aggregate(outOfOrder) { it.main }.map { it.version },
        )
    }

    @Test fun aggregatorSortsTheSensitiveNamespaceToo() {
        val outOfOrder = listOf(
            provider("B2-7", sensitiveVersions = listOf(9, 5)),
            provider("pre-port", sensitiveVersions = listOf(4, 1, 3)),
            provider("B2-7b", sensitiveVersions = listOf(2)),
        )
        assertEquals(
            listOf(1, 2, 3, 4, 5, 9),
            Migrations.aggregate(outOfOrder) { it.sensitive }.map { it.version },
        )
    }

    // ------------------------------------------------------------------------------------
    // The runner sorts too — the second belt, for any list that reaches Database.migrate.
    // ------------------------------------------------------------------------------------

    @Test fun runnerAppliesAscendingRegardlessOfInputOrder() {
        val shuffled = listOf(12, 3, 9, 1, 11, 2, 10).map { Migration(it, listOf("-- v$it")) }
        assertEquals(
            listOf(1, 2, 3, 9, 10, 11, 12),
            MigrationRunner.pending(shuffled, applied = emptySet()).map { it.version },
        )
    }

    @Test fun runnerKeepsAscendingOrderWhenSomeVersionsAreAlreadyApplied() {
        val shuffled = listOf(12, 3, 9, 1, 11, 2, 10).map { Migration(it, listOf("-- v$it")) }
        assertEquals(
            listOf(3, 10, 12),
            MigrationRunner.pending(shuffled, applied = setOf(1, 2, 9, 11)).map { it.version },
        )
    }

    // ------------------------------------------------------------------------------------
    // The shipped registration is itself in order, and the shipped output is sorted.
    // ------------------------------------------------------------------------------------

    @Test fun theRealAggregatedListsAreAscending() {
        val mainVersions = Migrations.main.map { it.version }
        val sensitiveVersions = Migrations.sensitive.map { it.version }
        assertEquals("main is not ascending: $mainVersions", mainVersions.sorted(), mainVersions)
        assertEquals("sensitive is not ascending: $sensitiveVersions", sensitiveVersions.sorted(), sensitiveVersions)
    }

    /**
     * Today `Migrations` must reproduce `Schema.kt` exactly, since every port provider is still an
     * empty stub. That equality is what makes swapping `Database`'s migration source from
     * `Schema.*Migrations` to `Migrations.*` a provably behaviour-preserving change at this commit.
     */
    @Test fun scaffoldChangesNothingYet() {
        assertEquals(Schema.mainMigrations.map { it.version }, Migrations.main.map { it.version })
        assertEquals(Schema.sensitiveMigrations.map { it.version }, Migrations.sensitive.map { it.version })
        assertEquals(
            Schema.mainMigrations.flatMap { it.statements },
            Migrations.main.flatMap { it.statements },
        )
        assertEquals(
            Schema.sensitiveMigrations.flatMap { it.statements },
            Migrations.sensitive.flatMap { it.statements },
        )
    }

    /** Every registered provider names an owning task; the allocation test relies on it. */
    @Test fun everyProviderDeclaresATaskId() {
        val anonymous = Migrations.providers.filter { it.taskId.isBlank() }.map { it.name }
        assertTrue("providers with no taskId: $anonymous", anonymous.isEmpty())
    }
}
