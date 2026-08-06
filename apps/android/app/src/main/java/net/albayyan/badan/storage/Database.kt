package net.albayyan.badan.storage

import android.os.Trace
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.storage.migrations.MigrationRunner
import net.albayyan.badan.storage.migrations.Migrations
import net.albayyan.badan.storage.sqlite.SqliteConnection
import java.io.File

/** A forward-only, numbered migration (mirror of iOS). */
data class Migration(val version: Int, val statements: List<String>)

/**
 * Opens and migrates BADAN's two physical databases (mirror of iOS `Database`). The sensitive
 * namespace is a separate file so "disable this module" is a literal file deletion (D-9). The
 * connection **object identity is preserved** across purge/reset (close handle → delete files →
 * reopen) so repositories holding a reference keep working.
 */
class Database(val directory: File) {
    val main: SqliteConnection
    val sensitive: SqliteConnection

    /**
     * Extra tables `purgeIngestedData()` deletes wholesale, contributed by the feature that owns
     * them rather than named in this file's own list (below).
     *
     * This exists because the built-in `ingestedOnly` list is a hardcoded literal inside a file the
     * parity port freezes. Batch 2 alone lands eight new main-DB tables (`workout_checkpoints`,
     * `strength_sets`, `workout_intervals`, `workout_quality`, `data_conflicts`,
     * `source_priority_rules`, `derived_feedback`, `metric_calibrations`), and only the area that
     * builds each one knows whether its rows are BADAN-derived bookkeeping (purge) or something the
     * user typed (preserve — `strength_sets` is a manual log, not an ingest artifact). Without a
     * registry, every one of those features would either ship a purge that silently misses its own
     * tables or need an edit to this frozen file; with it, the knowledge stays at the feature.
     *
     * Same shape and same reasoning as the sensitive-namespace wipe-hook registry on iOS
     * (`apps/ios/Sources/Storage/Database.swift`): `Database` deliberately knows nothing about what
     * a registrant owns, so a new storage surface is a self-contained addition at its own call
     * site instead of a `Database.kt` edit. Registrations run for the lifetime of this `Database`
     * instance; there is no unregister, matching how `main`/`sensitive` are themselves never torn
     * down independently of the whole object.
     */
    private val ingestedOnlyTableHooks = mutableListOf<String>()

    /**
     * Arbitrary cleanup `purgeIngestedData()` runs **inside its single transaction**, for ingested
     * data a wholesale `DELETE FROM <table>` would get wrong — a child table with no
     * `ingestion_path` of its own that must be scoped to the parent rows actually being deleted
     * (the shape `session_stages` already needs below), or a table mixing ingested and manual rows.
     */
    private val ingestedWipeHooks = mutableListOf<() -> Unit>()

    /**
     * Declare tables that hold ONLY ingested/derived rows — nothing a user can enter by hand — so
     * `purgeIngestedData()` clears them. Do not register a table a user writes to directly; a
     * manual log surviving a Health Connect connect is the whole point of that method existing.
     */
    fun registerIngestedOnlyTables(vararg names: String) {
        ingestedOnlyTableHooks.addAll(names)
    }

    /** Register scoped cleanup for `purgeIngestedData()`. Runs inside the purge's transaction. */
    fun registerIngestedWipeHook(hook: () -> Unit) {
        ingestedWipeHooks.add(hook)
    }

    // Declared after the two registries above so their initializers have run before `migrate`
    // touches anything (Kotlin runs property initializers and `init` blocks in declaration order).
    init {
        directory.mkdirs()
        main = SqliteConnection(File(directory, MAIN_FILE).path)
        sensitive = SqliteConnection(File(directory, SENSITIVE_FILE).path)
        migrate(main, Migrations.main)
        migrate(sensitive, Migrations.sensitive)
    }

    fun purgeSensitiveNamespace() {
        sensitive.closeHandle()
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            File(directory, SENSITIVE_FILE + suffix).delete()
        }
        sensitive.reopen()
        migrate(sensitive, Migrations.sensitive)
    }

    /**
     * Delete only *ingested* measurement data — sources/devices, samples, intervals, sessions,
     * derived values, baselines, insights and dedup bookkeeping — leaving every manual log
     * (workouts/nutrition/notes), the customization profile, goals, pins, export jobs and the
     * whole sensitive database untouched. Mirror of iOS's `Database.purgeIngestedData`.
     *
     * Android had no such primitive, which is why connecting Health Connect ingested real
     * readings ON TOP of the fabricated seed and left the two mixed together permanently: the
     * only tool available was [resetAll], which also destroys the user's own logs, so the connect
     * path understandably called neither. This is the missing middle.
     *
     * Purges the three measurement tables by `ingestion_path` rather than wholesale (iOS F2):
     * they hold user-entered rows as well as ingested ones, and `manual` is the only path a human
     * types in. No seeded row is manual (the seed goes through `FakeHealthStore` /
     * `IngestionPipeline` as `platformStore`), so nothing fabricated survives the predicate.
     */
    fun purgeIngestedData() {
        // Tables with no `ingestion_path` column: bookkeeping, catalogs and BADAN-derived rows,
        // none of which a user can enter by hand. All are rebuilt by the ingest/derive chain.
        val ingestedOnly = listOf(
            "dedup_decisions", "insights", "baselines", "input_manifests", "derived_values",
            "read_anchors", "source_devices", "sources",
            // Anything a feature registered for itself — see `registerIngestedOnlyTables`. Appended
            // rather than merged into the literal above so the pre-port set stays readable as the
            // set iOS also names, and `distinct()` makes a duplicate registration harmless.
        ) + ingestedOnlyTableHooks
        val manual = IngestionPath.MANUAL.code
        main.transaction {
            for (name in ingestedOnly.distinct()) main.execute("DELETE FROM ${quoteIdent(name)};")
            // Scoped to the sessions actually being deleted: session_stages has no
            // ingestion_path of its own, so a wholesale wipe would strip the stages off any
            // session the predicate preserves.
            main.execute(
                "DELETE FROM session_stages WHERE session_id IN " +
                    "(SELECT id FROM sessions WHERE ingestion_path != '$manual');",
            )
            for (name in listOf("sessions", "interval_records", "raw_samples")) {
                main.execute("DELETE FROM ${quoteIdent(name)} WHERE ingestion_path != '$manual';")
            }
            // Registered last, inside the same transaction, so a hook's scoped delete sees the
            // same all-or-nothing outcome as the built-in ones.
            for (hook in ingestedWipeHooks) hook()
        }
    }

    /**
     * Delete the main-DB manual-log tables. Used only for clearing a demo seed's manual logs on
     * the first real connect — see `AppEnvironment.connectHealthConnect`. Mirror of iOS's
     * `Database.purgeDemoManualLogs`.
     */
    fun purgeDemoManualLogs() {
        main.transaction {
            for (name in listOf("workout_entries", "nutrition_entries", "note_entries")) {
                main.execute("DELETE FROM ${quoteIdent(name)};")
            }
        }
    }

    fun resetAll() {
        purgeSensitiveNamespace()
        val tables = main.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
            .mapNotNull { it.getString("name") }
        main.transaction {
            main.execute("PRAGMA foreign_keys = OFF;")
            for (name in tables) main.execute("DROP TABLE IF EXISTS ${quoteIdent(name)};")
            main.execute("PRAGMA foreign_keys = ON;")
        }
        migrate(main, Migrations.main)
    }

    /**
     * Truncates the WAL file back into the main db file on both namespaces. Nothing calls this
     * automatically today — wire it to an app-background lifecycle transition (e.g.
     * `Activity.onStop`/`ProcessLifecycleOwner`) so it never competes with foreground work.
     */
    fun checkpointWal() {
        main.execute("PRAGMA wal_checkpoint(TRUNCATE);")
        sensitive.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    companion object {
        const val MAIN_FILE = "badan.db"
        const val SENSITIVE_FILE = "badan_sensitive.db"

        fun forApp(filesDir: File): Database = Database(File(filesDir, "BADAN"))

        /** Quotes a SQL identifier (doubling embedded quotes) for the rare case a table/column
         *  name must be interpolated into DDL — never build SQL from unquoted dynamic identifiers. */
        private fun quoteIdent(name: String): String = "\"" + name.replace("\"", "\"\"") + "\""

        /**
         * Internal rather than private, for the same reason iOS's `Database.migrate` is internal
         * rather than private (`apps/ios/Sources/Storage/Database.swift:195-198`): migration tests
         * need to drive a connection to an OLD schema version — pass a truncated `migrations` list,
         * then run the full list to exercise the real upgrade — and there is no other way to build
         * a dirty-old-database fixture, since `init` always migrates straight to the head version.
         * The visibility widening is deliberate and mirrored, not drift.
         *
         * `migrations` may arrive in ANY order; [MigrationRunner] sorts. See its doc for why the
         * pending predicate is `version NOT IN (SELECT version FROM schema_migrations)` rather than
         * the `version > MAX(version)` high-water mark this used to use (ADR-0012).
         */
        internal fun migrate(conn: SqliteConnection, migrations: List<Migration>) {
            // Named marker (platform android.os.Trace — no new dependency) so a Perfetto/Studio
            // Profiler capture of app startup shows this hot path labeled instead of raw samples.
            Trace.beginSection("Database.migrate")
            try {
                conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
                // The whole applied set, read once — the Kotlin evaluation of ADR-0012's
                // `version NOT IN (SELECT version FROM schema_migrations)`. Reading the set here
                // rather than embedding the subquery per migration is what makes the predicate
                // and the ordering unit-testable on a module with no JVM SQLite.
                val applied = conn.query("SELECT version FROM schema_migrations;")
                    .mapNotNull { it.getInt("version") }
                    .toSet()
                val pending = MigrationRunner.pending(migrations, applied)
                for (m in pending) {
                    conn.transaction {
                        for (stmt in m.statements) conn.execute(stmt)
                        conn.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
                            listOf(m.version.toLong(), System.currentTimeMillis()))
                    }
                }
                // Refresh planner statistics once, only when the schema actually changed — avoids
                // paying ANALYZE's cost on every unchanged cold start.
                if (pending.isNotEmpty()) conn.execute("ANALYZE;")
            } finally {
                Trace.endSection()
            }
        }
    }
}
