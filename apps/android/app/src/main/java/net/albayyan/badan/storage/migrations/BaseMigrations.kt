package net.albayyan.badan.storage.migrations

import net.albayyan.badan.storage.Migration
import net.albayyan.badan.storage.Schema

/**
 * Everything `storage/Schema.kt` already held before the parity port resumed — main 1, 2, 4, 5, 6,
 * 7, 8 and sensitive 1, 3, 4 — surfaced through the provider interface **by delegation, verbatim**.
 *
 * The delegation is the point. `Schema.kt` is 841 lines and 47 `CREATE TABLE`s of shipped,
 * byte-identical-to-iOS DDL, every migration of which carries a comment explaining exactly why its
 * statement strings read the way they do (including v6's `IF NOT EXISTS`, which exists purely to
 * keep the two platforms' version-6 strings identical). Copying that into provider files would put
 * all of it on the collision surface of a fourteen-agent parallel port for zero benefit. Reading it
 * through a `get()` puts none of it there: **`Schema.kt` is never edited by this port.**
 *
 * New migrations do NOT go here. They go in the owning area's own provider, at the version
 * [MigrationAllocation] reserved for it.
 */
object BaseMigrations : MigrationProvider {
    override val taskId: String = MigrationAllocation.OWNER_PRE_PORT
    override val main: List<Migration> get() = Schema.mainMigrations
    override val sensitive: List<Migration> get() = Schema.sensitiveMigrations
}
