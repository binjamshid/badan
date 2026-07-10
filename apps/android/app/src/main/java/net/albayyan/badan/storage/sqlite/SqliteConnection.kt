package net.albayyan.badan.storage.sqlite

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase

/**
 * A thin wrapper over the framework `SQLiteDatabase` — the exact parity of the iOS
 * `SQLiteConnection` seam (ADR-0007). No ORM, no KSP: the plan's storage design is raw DDL with
 * explicit provenance columns and named indexes, run verbatim on both platforms. This wrapper is
 * the single seam a future Room/SQLCipher swap targets.
 *
 * Bind-arg convention (for `run`): pass `Long` (incl. epoch-millis and 0/1 booleans — use
 * [Sql.bool]), `Double`, `String`, or `null`. Never `Int`/`Boolean` directly. Read args are
 * stringified (SQLite applies column affinity), so reads never bind null (use literal `IS NULL`).
 */
class SqliteConnection(val path: String) {
    private var db: SQLiteDatabase = open()

    private fun open(): SQLiteDatabase {
        val d = SQLiteDatabase.openOrCreateDatabase(path, null)
        d.execSQL("PRAGMA foreign_keys = ON;")
        return d
    }

    @Synchronized
    fun execute(sql: String) = db.execSQL(sql)

    @Synchronized
    fun run(sql: String, args: List<Any?> = emptyList()) {
        if (args.isEmpty()) db.execSQL(sql) else db.execSQL(sql, args.toTypedArray())
    }

    @Synchronized
    fun query(sql: String, args: List<Any?> = emptyList()): List<Row> {
        val selectionArgs = if (args.isEmpty()) null else args.map { it.toString() }.toTypedArray()
        val rows = ArrayList<Row>()
        db.rawQuery(sql, selectionArgs).use { c ->
            val cols = c.columnNames
            while (c.moveToNext()) rows.add(Row.from(c, cols))
        }
        return rows
    }

    @Synchronized
    fun <T> transaction(block: () -> T): T {
        db.beginTransaction()
        return try {
            val result = block()
            db.setTransactionSuccessful()
            result
        } finally {
            db.endTransaction()
        }
    }

    /** Close the handle (so the file can be deleted) without destroying this object, so
     *  repositories holding a reference stay valid across a purge/reset (mirror of iOS). */
    @Synchronized
    fun closeHandle() { db.close() }

    @Synchronized
    fun reopen() { db = open() }
}

/** Bind-arg helpers matching the iOS `SQLValue` conveniences. */
object Sql {
    fun bool(value: Boolean): Long = if (value) 1L else 0L
}
