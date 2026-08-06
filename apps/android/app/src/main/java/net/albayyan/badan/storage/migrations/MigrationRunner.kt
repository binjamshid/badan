package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * The pending-migration decision, factored out of `Database.migrate` so it is unit-testable on a
 * module that has no JVM SQLite (no Robolectric, no `androidTest` source set — see
 * `MigrationOrderingTest`'s scope note).
 *
 * Two rules, both load-bearing, both changed by ADR-0012:
 *
 * 1. **Predicate.** A migration is pending iff its version is not already recorded — the Kotlin
 *    evaluation of ADR-0012's `version NOT IN (SELECT version FROM schema_migrations)`. The old
 *    `version > MAX(version)` high-water mark could never run a number below one already applied,
 *    which is exactly what filling a reserved hole (main 3, sensitive 2) requires; and once
 *    providers are aggregated from areas built in parallel, a provider owning v9 registered after
 *    one owning v10 would have had its migration silently skipped forever on any device that saw
 *    v10 first. The set is read once instead of re-running the subquery per migration; the
 *    predicate is identical.
 * 2. **Order.** Application order is **ascending by version**, never registration order. A v12
 *    provider registered before a v11 provider would otherwise run `ALTER TABLE` against a table
 *    v11 has not created yet. [Migrations] sorts its aggregated output for the same reason, and
 *    this sort is the second belt: an unsorted list reaching `Database.migrate` from anywhere —
 *    a test fixture, a future caller, a hand-built list — still applies in the right order.
 *
 * Safe on this codebase specifically: Android has never shipped (`versionCode = 1`), every applied
 * version is written in the same transaction as its statements, `resetAll()` drops
 * `schema_migrations` outright, and `schema_migrations.version` is `INTEGER PRIMARY KEY` — a rowid
 * alias, so it can never be NULL and the classic `NOT IN`-with-NULL footgun cannot fire.
 */
object MigrationRunner {

    /**
     * The migrations still to apply, ascending by version.
     *
     * @param migrations every migration for one namespace, in any order.
     * @param applied the versions already recorded in `schema_migrations`.
     */
    fun pending(migrations: List<Migration>, applied: Set<Int>): List<Migration> =
        migrations.filter { it.version !in applied }.sortedBy { it.version }
}
