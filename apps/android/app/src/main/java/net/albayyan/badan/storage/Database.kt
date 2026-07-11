package net.albayyan.badan.storage

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

    fun resetAll() {
        purgeSensitiveNamespace()
        val tables = main.query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';")
            .mapNotNull { it.getString("name") }
        main.transaction {
            main.execute("PRAGMA foreign_keys = OFF;")
            for (name in tables) main.execute("DROP TABLE IF EXISTS \"$name\";")
            main.execute("PRAGMA foreign_keys = ON;")
        }
        migrate(main, Schema.mainMigrations)
    }

    companion object {
        const val MAIN_FILE = "badan.db"
        const val SENSITIVE_FILE = "badan_sensitive.db"

        fun forApp(filesDir: File): Database = Database(File(filesDir, "BADAN"))

        private fun migrate(conn: SqliteConnection, migrations: List<Migration>) {
            conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);")
            val current = conn.query("SELECT MAX(version) AS v FROM schema_migrations;").firstOrNull()?.getLong("v") ?: 0L
            for (m in migrations.filter { it.version.toLong() > current }) {
                conn.transaction {
                    for (stmt in m.statements) conn.execute(stmt)
                    conn.run("INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?);",
                        listOf(m.version.toLong(), System.currentTimeMillis()))
                }
            }
        }
    }
}
