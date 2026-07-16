package net.albayyan.badan.storage

import android.os.Trace
import net.albayyan.badan.domain.IngestionPath
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

    init {
        directory.mkdirs()
        main = SqliteConnection(File(directory, MAIN_FILE).path)
        sensitive = SqliteConnection(File(directory, SENSITIVE_FILE).path)
        migrate(main, Schema.mainMigrations)
        migrate(sensitive, Schema.sensitiveMigrations)
    }

    fun purgeSensitiveNamespace() {
        sensitive.closeHandle()
        for (suffix in listOf("", "-wal", "-shm", "-journal")) {
            File(directory, SENSITIVE_FILE + suffix).delete()
        }
        sensitive.reopen()
        migrate(sensitive, Schema.sensitiveMigrations)
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
        )
        val manual = IngestionPath.MANUAL.code
        main.transaction {
            for (name in ingestedOnly) main.execute("DELETE FROM ${quoteIdent(name)};")
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
        migrate(main, Schema.mainMigrations)
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

        private fun migrate(conn: SqliteConnection, migrations: List<Migration>) {
            // Named marker (platform android.os.Trace — no new dependency) so a Perfetto/Studio
            // Profiler capture of app startup shows this hot path labeled instead of raw samples.
            Trace.beginSection("Database.migrate")
            try {
                conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
                val current = conn.query("SELECT MAX(version) AS v FROM schema_migrations;").firstOrNull()?.getLong("v") ?: 0L
                val pending = migrations.filter { it.version.toLong() > current }
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
