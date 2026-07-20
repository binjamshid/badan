package net.albayyan.badan.storage.repositories

import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Persists platform read-query cursors so an adapter can resume an incremental sync instead of
 * re-scanning full history on every launch. Mirror of iOS's `ReadAnchorRepository`, backing the
 * same `read_anchors` table (reserved since migration v1) with the same
 * `(store, platform_type)` key — plan §14 is explicit that Health Connect changes tokens live in
 * the table HealthKit anchors already use, rather than in a parallel Android-only table.
 *
 * Storage-only and platform-agnostic by design: opaque bytes in, opaque bytes out. iOS stores an
 * `NSKeyedArchiver`-encoded `HKQueryAnchor`; Android stores a UTF-8 changes token. Neither
 * encoding is this class's business, and keeping it that way is what lets the two platforms share
 * one table definition without sharing one cursor format.
 */
class ReadAnchorRepository(private val db: SqliteConnection) {

    fun anchor(store: String, platformType: String): ByteArray? =
        db.query(
            "SELECT anchor FROM read_anchors WHERE store = ? AND platform_type = ?;",
            listOf(store, platformType),
        ).firstOrNull()?.getBlob("anchor")

    fun setAnchor(store: String, platformType: String, data: ByteArray, updatedAt: Long) {
        db.run(
            """
            INSERT OR REPLACE INTO read_anchors (store, platform_type, anchor, updated_at)
            VALUES (?, ?, ?, ?);
            """,
            listOf(store, platformType, data, updatedAt),
        )
    }

    /**
     * Drop one cursor so the next read falls back to a full windowed re-read.
     *
     * Called when Health Connect reports a token expired: keeping a token the provider has
     * already rejected would mean every subsequent sync spends a round trip rediscovering that
     * fact. Deleting is safe precisely because the fallback is a full re-read of the requested
     * window and every write on that path is idempotent by upstream identity — the worst outcome
     * of losing a cursor is a slower sync, never a lost or duplicated row.
     */
    fun clearAnchor(store: String, platformType: String) {
        db.run(
            "DELETE FROM read_anchors WHERE store = ? AND platform_type = ?;",
            listOf(store, platformType),
        )
    }

    /** Convenience for string-shaped cursors (Health Connect changes tokens). */
    fun token(store: String, platformType: String): String? =
        anchor(store, platformType)?.toString(Charsets.UTF_8)?.ifEmpty { null }

    fun setToken(store: String, platformType: String, token: String, updatedAt: Long) {
        setAnchor(store, platformType, token.toByteArray(Charsets.UTF_8), updatedAt)
    }
}
