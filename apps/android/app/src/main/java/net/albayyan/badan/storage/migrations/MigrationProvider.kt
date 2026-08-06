package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration

/**
 * One area's contribution to the two migration lists (ADR-0012, `docs/android-port-conventions.md`
 * §3/§4). An area fills **its own** provider file; nobody edits [Migrations], `Schema.kt`, or
 * another area's provider.
 *
 * Both [main] and [sensitive] default to `emptyList()` on purpose. The parity port registers every
 * provider up front and fills them across several batches, so a provider whose content has not
 * landed yet must be a *no-op*, not a compile error and not a half-applied schema: an unfilled
 * provider records nothing, and a dev device running a half-built tree simply has fewer tables
 * rather than a database that fails to open. A provider that touches only one namespace overrides
 * only that one and inherits the empty default for the other.
 *
 * [taskId] is not decoration. `MigrationAllocationTest` uses it to assert that a provider emits
 * only the versions [MigrationAllocation] allocated to *that* task — which is what stops two
 * concurrently-authored areas from both claiming, say, version 10 and only finding out on a
 * device that already applied one of them.
 */
interface MigrationProvider {
    /** The plan task id that owns this provider (e.g. `"B2-4"`), matching [MigrationAllocation]. */
    val taskId: String

    /** Human name for assertion messages; the object's own simple name unless overridden. */
    val name: String get() = this::class.simpleName ?: "<anonymous MigrationProvider>"

    /** Migrations for `badan.db`. Versions MUST be allocated in [MigrationAllocation]. */
    val main: List<Migration> get() = emptyList()

    /** Migrations for `badan_sensitive.db`. Versions MUST be allocated in [MigrationAllocation]. */
    val sensitive: List<Migration> get() = emptyList()
}
