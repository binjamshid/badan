package net.albayyan.badan.smoke

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import net.albayyan.badan.storage.sqlite.SqliteConnection
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * Robolectric smoke test — the first line of Android-framework code this module has ever executed
 * in a JVM test.
 *
 * Why it matters more than what it asserts: until B1-1 there was no Robolectric and no
 * `androidTest` source set, so `android.database.sqlite.SQLiteDatabase` — the entire storage
 * substrate under ADR-0007 — was unreachable from any test. Around 20 unit-test files in this
 * module carry an explicit comment saying so. This test proves the harness works end to end:
 * a real [SqliteConnection] against a real file, a real DDL statement, a real round trip through
 * the framework's cursor.
 *
 * It deliberately touches only [SqliteConnection], not `Schema` or any repository. A smoke test
 * that also asserted schema behaviour would fail for two unrelated reasons and stop being a
 * signal about the harness.
 */
@RunWith(RobolectricTestRunner::class)
class SqliteConnectionRobolectricTest {

    private lateinit var dbFile: File
    private lateinit var conn: SqliteConnection

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        dbFile = File(context.cacheDir, "smoke_${System.nanoTime()}.db")
        conn = SqliteConnection(dbFile.absolutePath)
    }

    @After
    fun tearDown() {
        conn.closeHandle()
        dbFile.delete()
        // WAL is enabled by SqliteConnection.open(), so the sidecar files are real files too.
        File("${dbFile.absolutePath}-wal").delete()
        File("${dbFile.absolutePath}-shm").delete()
    }

    @Test
    fun `opens a database and round-trips a row`() {
        conn.execute("CREATE TABLE smoke (id INTEGER PRIMARY KEY, label TEXT NOT NULL);")
        conn.run("INSERT INTO smoke (id, label) VALUES (?, ?);", listOf(1L, "badan"))

        val rows = conn.query("SELECT id, label FROM smoke;")

        assertEquals(1, rows.size)
        assertEquals(1L, rows[0].getLong("id") as Long?)
        assertEquals("badan", rows[0].getString("label"))
    }

    @Test
    fun `transaction commits and is visible to a subsequent query`() {
        conn.execute("CREATE TABLE smoke_tx (n INTEGER NOT NULL);")

        conn.transaction {
            conn.run("INSERT INTO smoke_tx (n) VALUES (?);", listOf(7L))
        }

        assertEquals(7L, conn.query("SELECT n FROM smoke_tx;").single().getLong("n") as Long?)
    }
}
