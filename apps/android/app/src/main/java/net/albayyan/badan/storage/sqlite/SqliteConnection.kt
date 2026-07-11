package net.albayyan.badan.storage.sqlite

import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

/**
 * A thin wrapper over the framework `SQLiteDatabase` — the exact parity of the iOS
 * `SQLiteConnection` seam (ADR-0007). No ORM, no KSP: the plan's storage design is raw DDL with
 * explicit provenance columns and named indexes, run verbatim on both platforms. This wrapper is
 * the single seam a future Room/SQLCipher swap targets.
 *
 * Bind-arg convention (for `run`): pass `Long` (incl. epoch-millis and 0/1 booleans — use
 * [Sql.bool]), `Double`, `String`, or `null`. Never `Int`/`Boolean` directly. Read args are
 * stringified (SQLite applies column affinity), so reads never bind null (use literal `IS NULL`).
 *
 * Locking: a [ReentrantReadWriteLock] guards the mutable [db] handle rather than a single
 * `@Synchronized` monitor, so concurrent [query] calls (readers) don't serialize against each
 * other — matching the concurrent-reader guarantee WAL was turned on for. Writes ([execute],
 * [run], [transaction]) and lifecycle transitions ([closeHandle], [reopen]) still take the
 * exclusive write lock.
 */
class SqliteConnection(val path: String) {
    private var db: SQLiteDatabase = open()
    private val lock = ReentrantReadWriteLock()

    private fun open(): SQLiteDatabase {
        val d = SQLiteDatabase.openOrCreateDatabase(path, null)
        // WAL + synchronous=NORMAL match the iOS wrapper and make bulk writes (the 90-day seed)
        // fast — the default rollback journal fsyncs on every insert.
        d.enableWriteAheadLogging()
        d.execSQL("PRAGMA synchronous = NORMAL;")
        d.execSQL("PRAGMA foreign_keys = ON;")
        return d
    }

    fun execute(sql: String) = lock.write { db.execSQL(sql) }

    fun run(sql: String, args: List<Any?> = emptyList()) = lock.write {
        if (args.isEmpty()) db.execSQL(sql) else db.execSQL(sql, args.toTypedArray())
    }

    fun query(sql: String, args: List<Any?> = emptyList()): List<Row> = lock.read {
        val selectionArgs = if (args.isEmpty()) null else args.map { it.toString() }.toTypedArray()
        val rows = ArrayList<Row>()
        db.rawQuery(sql, selectionArgs).use { c ->
            val cols = c.columnNames
            while (c.moveToNext()) rows.add(Row.from(c, cols))
        }
        rows
    }

    fun <T> transaction(block: () -> T): T = lock.write {
        db.beginTransaction()
        try {
            val result = block()
            db.setTransactionSuccessful()
            result
        } finally {
            db.endTransaction()
        }
    }

    /** Close the handle (so the file can be deleted) without destroying this object, so
     *  repositories holding a reference stay valid across a purge/reset (mirror of iOS). */
    fun closeHandle() = lock.write { db.close() }

    fun reopen() = lock.write { db = open() }
}

/** Bind-arg helpers matching the iOS `SQLValue` conveniences. */
object Sql {
    fun bool(value: Boolean): Long = if (value) 1L else 0L
}
