package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.journal.BehaviorValueKind
import net.albayyan.badan.domain.journal.ContextStatus
import net.albayyan.badan.domain.journal.JournalEntry
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Storage for the behavior journal and the context statuses (EPIC-29, plan §9.9/§9.10), over the
 * `journal_entries` and `context_statuses` tables created by sensitive migration v3. Mirror of iOS
 * `JournalRepository`, same queries and same semantics.
 *
 * **This repository holds the sensitive connection and nothing else.** That is the I7 enforcement,
 * and it is structural rather than a rule someone has to remember: there is no `main` connection in
 * scope here, so no statement in this file can address `badan.db` even by accident. A journal row
 * landing in the main database would silently downgrade `Database.purgeSensitiveNamespace()` — a
 * literal file deletion — to a best-effort row sweep for the two most lifestyle-revealing tables
 * BADAN has.
 *
 * The purge needs no extension for these families: it deletes and recreates `badan_sensitive.db`
 * wholesale, so every table in the sensitive migration list — v1's meds/symptoms/conditions and
 * v3's journal/context/cycle alike — is covered by construction. `JournalTest` pins that property
 * so a future "purge only these tables" optimization cannot quietly leave the journal behind.
 *
 * Deletes are tombstones (`deleted_at`), matching [LoggingRepository]: the ADR-0003 sync columns
 * only mean something if a removal is a recorded event, and a correction to yesterday's journal
 * should not erase what the user first said.
 */
class JournalRepository(
    private val sensitive: SqliteConnection,
) {

    // MARK: - Journal entries

    /**
     * Inserts one behavior tag. `INSERT OR REPLACE` is idempotent on the ULID primary key, so a
     * retried write is a no-op rather than a duplicate — and since a correction is a NEW row plus a
     * tombstone on the old one (never an in-place edit), it can never overwrite a different logical
     * entry.
     */
    fun insertEntry(e: JournalEntry) {
        sensitive.run(
            """
            INSERT OR REPLACE INTO journal_entries
              ($ENTRY_COLUMNS, ${Rows.provColumns}, ${Rows.convColumns})
            VALUES ($ENTRY_PLACEHOLDERS, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
            """,
            listOf(
                e.id, e.behaviorId, e.customLabel, e.valueKind.code, e.value, e.unit,
                e.occurredAt, e.tzId, e.note,
            ) + Rows.provParams(e.provenance) + Rows.convParams(e.updatedAt, e.originDeviceId, e.deletedAt),
        )
    }

    /**
     * Live entries whose `occurred_at` falls in the window, newest first.
     *
     * The window is on `occurred_at`, never on `recorded_at`: an entry the user backdated to
     * yesterday belongs to yesterday, which is the whole point of yesterday-recall. Filtering on
     * when it was typed would file it under today and quietly poison the day arms every correlation
     * is built from.
     */
    fun entries(from: Long, to: Long): List<JournalEntry> =
        sensitive.query(
            """
            SELECT * FROM journal_entries
            WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL
            ORDER BY occurred_at DESC;
            """,
            listOf(from, to),
        ).map { readEntry(it) }

    /**
     * Live entries for one behavior across a window — the read the correlation engine's per-behavior
     * arms are built from. Backed by `idx_journal_behavior_occurred`.
     */
    fun entries(behaviorId: String, from: Long, to: Long): List<JournalEntry> =
        sensitive.query(
            """
            SELECT * FROM journal_entries
            WHERE behavior_id = ? AND occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL
            ORDER BY occurred_at DESC;
            """,
            listOf(behaviorId, from, to),
        ).map { readEntry(it) }

    /**
     * Every live entry, newest first. Unbounded on purpose, matching `LoggingRepository.allSymptoms`:
     * a hand-tapped journal is tens of rows per week, and both the export and the correlation engine
     * need the whole history rather than a page of it.
     */
    fun allEntries(): List<JournalEntry> =
        sensitive.query("SELECT * FROM journal_entries WHERE deleted_at IS NULL ORDER BY occurred_at DESC;")
            .map { readEntry(it) }

    /** One row by id, tombstone or not — for inspecting what a correction superseded. */
    fun entry(id: String): JournalEntry? =
        sensitive.query("SELECT * FROM journal_entries WHERE id = ?;", listOf(id)).firstOrNull()?.let { readEntry(it) }

    /**
     * Tombstones one entry. Not a hard delete: the row stays so "the user logged this, then took it
     * back" is recoverable and so a synced peer learns the entry went away rather than inferring it
     * from absence.
     */
    fun deleteEntry(id: String, at: Long) {
        sensitive.run("UPDATE journal_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    // MARK: - Context statuses

    /**
     * Inserts or updates one declared interval.
     *
     * Unlike journal entries, a status legitimately CHANGES in place — closing an open-ended status
     * ("I'm back") sets `end_at` on the same row rather than appending a second one, because the
     * interval is one fact whose end was simply not known yet. That is not an I2 concern: I2 governs
     * derived values, and a status is a raw user assertion, not a computation.
     */
    fun upsertStatus(s: ContextStatus) {
        sensitive.run(
            """
            INSERT OR REPLACE INTO context_statuses
              ($STATUS_COLUMNS, ${Rows.provColumns}, ${Rows.convColumns})
            VALUES ($STATUS_PLACEHOLDERS, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
            """,
            listOf(s.id, s.statusId, s.customLabel, s.startAt, s.endAt, s.tzId, s.note)
                + Rows.provParams(s.provenance) + Rows.convParams(s.updatedAt, s.originDeviceId, s.deletedAt),
        )
    }

    /**
     * Closes an open-ended status at [endAt]. Separate from [upsertStatus] so the common "I'm back
     * from the trip" action can't accidentally rewrite `start_at` or the note.
     */
    fun closeStatus(id: String, endAt: Long, updatedAt: Long) {
        sensitive.run(
            "UPDATE context_statuses SET end_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL;",
            listOf(endAt, updatedAt, id),
        )
    }

    /** Every live status, most recently started first. */
    fun allStatuses(): List<ContextStatus> =
        sensitive.query("SELECT * FROM context_statuses WHERE deleted_at IS NULL ORDER BY start_at DESC;")
            .map { readStatus(it) }

    /**
     * Statuses open at [instant].
     *
     * `end_at IS NULL` is matched explicitly rather than relying on a comparison, because SQL
     * comparisons against NULL are NULL (not true) — an open-ended status is the NORMAL case here,
     * and a plain `end_at > ?` would silently return none of them, which is the failure mode where
     * "I'm travelling right now" annotates nothing at all.
     */
    fun activeStatuses(instant: Long): List<ContextStatus> =
        sensitive.query(
            """
            SELECT * FROM context_statuses
            WHERE deleted_at IS NULL AND start_at <= ? AND (end_at IS NULL OR end_at > ?)
            ORDER BY start_at DESC;
            """,
            listOf(instant, instant),
        ).map { readStatus(it) }

    /** Statuses overlapping `[from, to)` — the window query a nightly score asks. */
    fun statusesOverlapping(from: Long, to: Long): List<ContextStatus> =
        sensitive.query(
            """
            SELECT * FROM context_statuses
            WHERE deleted_at IS NULL AND start_at < ? AND (end_at IS NULL OR end_at > ?)
            ORDER BY start_at DESC;
            """,
            listOf(to, from),
        ).map { readStatus(it) }

    /**
     * Statuses that STARTED inside the window — the export's range read. Distinct from
     * [statusesOverlapping] on purpose: an export window asks "what did the user declare in this
     * period", not "what was in force during it", so a year-long open status does not get dragged
     * into every month's file.
     */
    fun statuses(from: Long, to: Long): List<ContextStatus> =
        sensitive.query(
            """
            SELECT * FROM context_statuses
            WHERE start_at >= ? AND start_at <= ? AND deleted_at IS NULL
            ORDER BY start_at DESC;
            """,
            listOf(from, to),
        ).map { readStatus(it) }

    fun status(id: String): ContextStatus? =
        sensitive.query("SELECT * FROM context_statuses WHERE id = ?;", listOf(id)).firstOrNull()?.let { readStatus(it) }

    fun deleteStatus(id: String, at: Long) {
        sensitive.run("UPDATE context_statuses SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    companion object {
        private const val ENTRY_COLUMNS =
            "id, behavior_id, custom_label, value_kind, value, unit, occurred_at, tz_id, note"
        private const val ENTRY_PLACEHOLDERS = "?, ?, ?, ?, ?, ?, ?, ?, ?"
        private const val STATUS_COLUMNS = "id, status_id, custom_label, start_at, end_at, tz_id, note"
        private const val STATUS_PLACEHOLDERS = "?, ?, ?, ?, ?, ?, ?"

        fun readEntry(r: Row): JournalEntry = JournalEntry(
            id = r.requireString("id"),
            behaviorId = r.getString("behavior_id"),
            customLabel = r.getString("custom_label"),
            // An unrecognized stored kind folds to boolean — the shape that claims the least — so a
            // row written by a newer build reads as "this happened" rather than as a number in an
            // unknown unit (see `BehaviorValueKind.fromCode`).
            valueKind = BehaviorValueKind.fromCode(r.getString("value_kind")),
            value = r.getDouble("value"),
            unit = r.getString("unit"),
            occurredAt = r.requireDate("occurred_at"),
            tzId = r.requireString("tz_id"),
            note = r.getString("note"),
            provenance = Rows.readProvenance(r),
            updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )

        fun readStatus(r: Row): ContextStatus = ContextStatus(
            id = r.requireString("id"),
            statusId = r.getString("status_id"),
            customLabel = r.getString("custom_label"),
            startAt = r.requireDate("start_at"),
            // Null for a NULL column, which is exactly the open-ended case — kept as null rather
            // than defaulted to anything, since "still active" and "ended at the epoch" are
            // opposite claims.
            endAt = r.getDate("end_at"),
            tzId = r.requireString("tz_id"),
            note = r.getString("note"),
            provenance = Rows.readProvenance(r),
            updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )
    }
}
