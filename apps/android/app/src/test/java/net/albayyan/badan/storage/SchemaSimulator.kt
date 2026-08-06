package net.albayyan.badan.storage

/**
 * A deliberately small, deliberately strict in-memory DDL applier that produces a `sqlite_master`-
 * shaped dump.
 *
 * **Why this exists, stated honestly.** `app/build.gradle.kts` sets
 * `testOptions.unitTests.isReturnDefaultValues = true` and the module has no Robolectric, no
 * JVM SQLite driver and no `androidTest` source set — `SQLiteDatabase.openOrCreateDatabase` returns
 * a default (null) in a unit test, so **no test on this module can open a real database.**
 * `BaselineAppendOnlyMigrationTest` says the same thing about its own scope. Adding Robolectric or
 * `sqlite-jdbc` would mean editing `app/build.gradle.kts` and `gradle/libs.versions.toml`, neither
 * of which the migration-scaffold task owns.
 *
 * So this class stands in for SQLite's schema engine — nothing else. It models exactly the
 * statement shapes BADAN's migrations use, and it **throws on anything it does not recognise**
 * rather than skipping it, so it cannot silently pass a migration it did not actually understand.
 *
 * What it genuinely proves, which is the point of the equivalence test:
 *  * a `CREATE INDEX`/`ALTER TABLE` that runs before the `CREATE TABLE` it depends on **fails**,
 *    which is the ordering bug an unsorted provider list produces;
 *  * a fresh install and a staged upgrade reach the same set of objects — i.e. no version was
 *    skipped, duplicated or reordered between the two paths.
 *
 * What it does not prove, and must not be read as proving: anything about rows, types, constraint
 * enforcement, query plans or actual SQLite acceptance of the DDL. Statement-string parity with iOS
 * is asserted separately and directly (`BaselineAppendOnlyMigrationTest` and friends), and real
 * end-to-end migration behaviour is exercised on iOS against a real connection.
 */
class SchemaSimulator {

    private data class Obj(val type: String, val name: String, val table: String, var sql: String)

    /** Keyed by object name — SQLite shares one name space between tables and indexes per file. */
    private val objects = LinkedHashMap<String, Obj>()

    fun apply(migration: Migration) {
        for (statement in migration.statements) apply(statement)
    }

    fun apply(statement: String) {
        val sql = normalize(statement)
        if (sql.isEmpty()) return

        CREATE_TABLE.matchEntire(sql)?.let { m ->
            val (ifNotExists, name) = m.groupValues[1] to m.groupValues[2]
            val existing = objects[name]
            if (existing != null) {
                if (ifNotExists.isEmpty()) fail("table $name already exists")
                return
            }
            objects[name] = Obj(type = "table", name = name, table = name, sql = sql)
            return
        }

        CREATE_INDEX.matchEntire(sql)?.let { m ->
            val unique = m.groupValues[1].isNotEmpty()
            val ifNotExists = m.groupValues[2].isNotEmpty()
            val name = m.groupValues[3]
            val table = m.groupValues[4]
            val existing = objects[name]
            if (existing != null) {
                if (!ifNotExists) fail("index $name already exists")
                return
            }
            val target = objects[table] ?: fail("no such table: $table (creating index $name)")
            if (target.type != "table") fail("$table is not a table (creating index $name)")
            objects[name] = Obj(type = if (unique) "unique index" else "index", name = name, table = table, sql = sql)
            return
        }

        DROP_TABLE.matchEntire(sql)?.let { m ->
            val ifExists = m.groupValues[1].isNotEmpty()
            val name = m.groupValues[2]
            val existing = objects[name]
            if (existing == null || existing.type != "table") {
                if (!ifExists) fail("no such table: $name")
                return
            }
            objects.values.removeAll { it.type != "table" && it.table == name }
            objects.remove(name)
            return
        }

        DROP_INDEX.matchEntire(sql)?.let { m ->
            val ifExists = m.groupValues[1].isNotEmpty()
            val name = m.groupValues[2]
            val existing = objects[name]
            if (existing == null || existing.type == "table") {
                if (!ifExists) fail("no such index: $name")
                return
            }
            objects.remove(name)
            return
        }

        ALTER_ADD_COLUMN.matchEntire(sql)?.let { m ->
            val table = m.groupValues[1]
            val column = m.groupValues[2]
            val target = objects[table] ?: fail("no such table: $table (adding column $column)")
            if (target.type != "table") fail("$table is not a table (adding column $column)")
            // Real SQLite rewrites sqlite_master.sql for ADD COLUMN, appending the column text to
            // the stored CREATE TABLE — so the dump reflects it here too.
            target.sql = target.sql.dropLast(1).trimEnd() + ", $column)"
            return
        }

        // Row-level statements change data, not schema. Migrations use them (iOS main v3's two
        // dedup DELETEs); they are correctly invisible to a sqlite_master dump.
        if (DML.containsMatchIn(sql)) return
        // Non-schema housekeeping a migration list may legitimately carry.
        if (NO_OP.containsMatchIn(sql)) return

        fail("SchemaSimulator does not model this statement — extend it deliberately rather than " +
            "letting it pass unmodelled: $sql")
    }

    /** `sqlite_master`-shaped: type, name, target table, normalized SQL — sorted, so two paths that
     *  produced the same schema in different orders still compare equal. */
    fun dump(): List<String> = objects.values
        .map { "${it.type}|${it.name}|${it.table}|${it.sql}" }
        .sorted()

    private fun fail(message: String): Nothing = throw IllegalStateException(message)

    private companion object {
        val OPT = setOf(RegexOption.IGNORE_CASE)

        val CREATE_TABLE = Regex("""CREATE TABLE (IF NOT EXISTS )?(\w+) ?\(.*\)""", OPT)
        val CREATE_INDEX = Regex("""CREATE (UNIQUE )?INDEX (IF NOT EXISTS )?(\w+) ON (\w+) ?\(.*""", OPT)
        val DROP_TABLE = Regex("""DROP TABLE (IF EXISTS )?(\w+)""", OPT)
        val DROP_INDEX = Regex("""DROP INDEX (IF EXISTS )?(\w+)""", OPT)
        val ALTER_ADD_COLUMN = Regex("""ALTER TABLE (\w+) ADD COLUMN (.+)""", OPT)
        val DML = Regex("""^(DELETE|INSERT|UPDATE|REPLACE|WITH)\b""", OPT)
        val NO_OP = Regex("""^(PRAGMA|ANALYZE|VACUUM)\b""", OPT)

        fun normalize(sql: String): String =
            sql.trim().replace(Regex("""\s+"""), " ").trim().removeSuffix(";").trim()
    }
}
