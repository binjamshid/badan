package net.albayyan.badan.storage.repositories

import java.time.LocalDate
import java.time.ZoneId
import net.albayyan.badan.domain.hydration.BeverageDefinition
import net.albayyan.badan.domain.hydration.ContainerPreset
import net.albayyan.badan.domain.hydration.GoalEngine
import net.albayyan.badan.domain.hydration.HydrationDailySummary
import net.albayyan.badan.domain.hydration.HydrationEntry
import net.albayyan.badan.domain.hydration.HydrationGoal
import net.albayyan.badan.domain.hydration.HydrationGoalKind
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.Sql
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * Storage for the hydration module (EPIC-38): the append-first drink ledger, its beverage/container
 * catalogs, goals, and per-day summaries. All in the **main** DB — a logged drink is normal-class,
 * not sensitive-plus (§9.14). Byte-equivalent behavior to iOS `HydrationRepository`.
 *
 * The ledger is append-first: [insertEntry] only ever adds a row; an edit is a *new* row built by
 * `HydrationLedger.makeRevision`. [undoEntry] tombstones one row (revert / quick-log undo),
 * [deleteEntry] tombstones a whole chain (remove the drink), and [liveEntries] derives the visible
 * set from those tombstones and the supersedes links, never from a mutated flag.
 */
class HydrationRepository(
    private val main: SqliteConnection,
) {

    // MARK: - Ledger (hydration_entries)

    /**
     * Appends one row (an original or a revision — both are inserts; a revision carries a `supersedes`
     * link and a bumped `revision`). `INSERT OR REPLACE` is idempotent on the ULID PK, and never
     * overwrites a *different* logical version because a revision always gets a new id.
     */
    fun insertEntry(e: HydrationEntry) {
        main.run(
            """
            INSERT OR REPLACE INTO hydration_entries
              ($ENTRY_COLUMNS, ${Rows.provColumns}, ${Rows.convColumns})
            VALUES ($ENTRY_PLACEHOLDERS, ${Rows.provPlaceholders}, ${Rows.convPlaceholders});
            """,
            listOf(
                e.id, e.volumeMl, e.fluidType, e.beverageId, e.containerId, e.occurredAt, e.tzId,
                e.note, e.originalId, e.supersedes, e.revision.toLong(),
            ) + Rows.provParams(e.provenance) + Rows.convParams(e.updatedAt, e.originDeviceId, e.deletedAt),
        )
    }

    /**
     * The LIVE entries in a time window: not tombstoned, and not superseded by a non-deleted revision.
     * The subquery is global (not range-bounded) so a revision that moved its `occurred_at` still
     * suppresses the row it replaced. Mirrors `HydrationLedger.liveEntries`.
     */
    fun liveEntries(from: Long, to: Long): List<HydrationEntry> =
        main.query(
            """
            SELECT * FROM hydration_entries
            WHERE deleted_at IS NULL AND occurred_at >= ? AND occurred_at <= ?
              AND id NOT IN (SELECT supersedes FROM hydration_entries WHERE supersedes IS NOT NULL AND deleted_at IS NULL)
            ORDER BY occurred_at DESC;
            """,
            listOf(from, to),
        ).map { readEntry(it) }

    /** The full audit chain of one logical drink — every revision, tombstoned/superseded included. */
    fun history(originalId: String): List<HydrationEntry> =
        main.query("SELECT * FROM hydration_entries WHERE original_id = ? ORDER BY revision ASC, updated_at ASC;", listOf(originalId))
            .map { readEntry(it) }

    /** The current live head of a chain (what a revise edits), or null if fully deleted. */
    fun liveEntry(originalId: String): HydrationEntry? =
        net.albayyan.badan.domain.hydration.HydrationLedger.liveEntries(history(originalId)).firstOrNull()

    /** Any single row by id, tombstone or not — for building a revision or inspecting one version. */
    fun entry(id: String): HydrationEntry? =
        main.query("SELECT * FROM hydration_entries WHERE id = ?;", listOf(id)).firstOrNull()?.let { readEntry(it) }

    /**
     * Tombstones ONE row — the quick-log "Undo", and the way to revert a revision (tombstone the
     * revision → its prior version becomes live again). Not a hard delete: the row stays for the
     * audit chain (I3-flavored).
     */
    fun undoEntry(id: String, at: Long) {
        main.run("UPDATE hydration_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    /** Tombstones a WHOLE chain — "delete this drink" — so no revision of it stays live. */
    fun deleteEntry(originalId: String, at: Long) {
        main.run(
            "UPDATE hydration_entries SET deleted_at = ?, updated_at = ? WHERE original_id = ? AND deleted_at IS NULL;",
            listOf(at, at, originalId),
        )
    }

    // MARK: - Beverage definitions

    fun upsertBeverage(b: BeverageDefinition) {
        main.run(
            """
            INSERT OR REPLACE INTO beverage_definitions
              (id, name_en, name_ar, fluid_type, default_volume_ml, caffeine_mg_per_100ml, alcohol_pct, electrolyte_note, is_builtin, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(
                b.id, b.nameEn, b.nameAr, b.fluidType, b.defaultVolumeMl, b.caffeineMgPer100ml,
                b.alcoholPct, b.electrolyteNote, Sql.bool(b.isBuiltin),
            ) + Rows.convParams(b.updatedAt, b.originDeviceId, b.deletedAt),
        )
    }

    fun beverages(): List<BeverageDefinition> =
        main.query("SELECT * FROM beverage_definitions WHERE deleted_at IS NULL ORDER BY name_en ASC;").map { readBeverage(it) }

    fun beverage(id: String): BeverageDefinition? =
        main.query("SELECT * FROM beverage_definitions WHERE id = ? AND deleted_at IS NULL;", listOf(id)).firstOrNull()?.let { readBeverage(it) }

    fun deleteBeverage(id: String, at: Long) {
        main.run("UPDATE beverage_definitions SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    // MARK: - Container presets

    fun upsertContainer(c: ContainerPreset) {
        main.run(
            """
            INSERT OR REPLACE INTO container_presets
              (id, name_en, name_ar, volume_ml, beverage_id, sort_order, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(c.id, c.nameEn, c.nameAr, c.volumeMl, c.beverageId, c.sortOrder.toLong())
                + Rows.convParams(c.updatedAt, c.originDeviceId, c.deletedAt),
        )
    }

    fun containers(): List<ContainerPreset> =
        main.query("SELECT * FROM container_presets WHERE deleted_at IS NULL ORDER BY sort_order ASC, name_en ASC;").map { readContainer(it) }

    fun deleteContainer(id: String, at: Long) {
        main.run("UPDATE container_presets SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    // MARK: - Goals

    fun upsertGoal(g: HydrationGoal) {
        main.run(
            """
            INSERT OR REPLACE INTO hydration_goals
              (id, kind, target_ml, day_type, active, created_at, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(g.id, g.kind.code, g.targetMl, g.dayType, Sql.bool(g.active), g.createdAt)
                + Rows.convParams(g.updatedAt, g.originDeviceId, g.deletedAt),
        )
    }

    /** All active, non-tombstoned goals. No-goal is an active `kind = none` row OR the absence of any. */
    fun activeGoals(): List<HydrationGoal> =
        main.query("SELECT * FROM hydration_goals WHERE active = 1 AND deleted_at IS NULL ORDER BY created_at DESC;").map { readGoal(it) }

    fun allGoals(): List<HydrationGoal> =
        main.query("SELECT * FROM hydration_goals WHERE deleted_at IS NULL ORDER BY created_at DESC;").map { readGoal(it) }

    /** Deactivates the currently-active goal(s) for a day type (null = the default) before a new one. */
    fun deactivateGoals(dayType: String?, at: Long) {
        if (dayType != null) {
            main.run("UPDATE hydration_goals SET active = 0, updated_at = ? WHERE active = 1 AND day_type = ?;", listOf(at, dayType))
        } else {
            main.run("UPDATE hydration_goals SET active = 0, updated_at = ? WHERE active = 1 AND day_type IS NULL;", listOf(at))
        }
    }

    // MARK: - Daily summaries

    fun upsertSummary(s: HydrationDailySummary) {
        main.run(
            """
            INSERT OR REPLACE INTO hydration_daily_summaries
              (day_key, tz_id, manual_ml, imported_ml, estimated_ml, entry_count, goal_kind, goal_target_ml, goal_id, ${Rows.convColumns})
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ${Rows.convPlaceholders});
            """,
            listOf(
                s.dayKey, s.tzId, s.manualMl, s.importedMl, s.estimatedMl, s.entryCount.toLong(),
                s.goalKind.code, s.goalTargetMl, s.goalId,
            ) + Rows.convParams(s.updatedAt, s.originDeviceId, s.deletedAt),
        )
    }

    fun summary(dayKey: String): HydrationDailySummary? =
        main.query("SELECT * FROM hydration_daily_summaries WHERE day_key = ? AND deleted_at IS NULL;", listOf(dayKey)).firstOrNull()?.let { readSummary(it) }

    fun summaries(from: String, to: String): List<HydrationDailySummary> =
        main.query("SELECT * FROM hydration_daily_summaries WHERE day_key >= ? AND day_key <= ? AND deleted_at IS NULL ORDER BY day_key ASC;", listOf(from, to))
            .map { readSummary(it) }

    /**
     * Recomputes one local day's summary from its live entries and persists it. Totals are always
     * refreshed; the goal snapshot is frozen unless [forceGoalResnapshot] (the caller does that only
     * for the current day when the user edits their goal). [dayType]/[originDeviceId]/[now] are
     * caller-supplied so this repo stays storage-focused.
     */
    fun recomputeSummary(
        dayKey: String, tzId: String, dayType: String? = null, now: Long, originDeviceId: String,
        forceGoalResnapshot: Boolean = false,
    ): HydrationDailySummary {
        val (start, end) = dayBounds(dayKey, tzId)
        val live = liveEntries(start, end).filter { GoalEngine.dayKey(it.occurredAt, tzId) == dayKey }
        val resolved = GoalEngine.resolveGoal(dayType, activeGoals())
        val existing = if (forceGoalResnapshot) null else summary(dayKey)
        val summary = GoalEngine.makeSummary(dayKey, tzId, live, resolved, existing, now, originDeviceId)
        upsertSummary(summary)
        return summary
    }

    companion object {
        private const val ENTRY_COLUMNS =
            "id, volume_ml, fluid_type, beverage_id, container_id, occurred_at, tz_id, note, original_id, supersedes, revision"
        private const val ENTRY_PLACEHOLDERS = "?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?"

        /** The [start, next-day-start) instants of a local day key, for scoping the entry query. */
        fun dayBounds(dayKey: String, tzId: String): Pair<Long, Long> {
            val zone = runCatching { ZoneId.of(tzId) }.getOrElse { ZoneId.of("UTC") }
            val d = LocalDate.parse(dayKey)
            val start = d.atStartOfDay(zone).toInstant().toEpochMilli()
            val end = d.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
            return start to end
        }

        fun readEntry(r: Row): HydrationEntry = HydrationEntry(
            id = r.requireString("id"), volumeMl = r.requireDouble("volume_ml"),
            fluidType = r.requireString("fluid_type"), beverageId = r.getString("beverage_id"),
            containerId = r.getString("container_id"), occurredAt = r.requireDate("occurred_at"),
            tzId = r.requireString("tz_id"), note = r.getString("note"),
            originalId = r.requireString("original_id"), supersedes = r.getString("supersedes"),
            revision = r.getInt("revision") ?: 1, provenance = Rows.readProvenance(r),
            updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )

        fun readBeverage(r: Row): BeverageDefinition = BeverageDefinition(
            id = r.requireString("id"), nameEn = r.requireString("name_en"), nameAr = r.requireString("name_ar"),
            fluidType = r.requireString("fluid_type"), defaultVolumeMl = r.getDouble("default_volume_ml"),
            caffeineMgPer100ml = r.getDouble("caffeine_mg_per_100ml"), alcoholPct = r.getDouble("alcohol_pct"),
            electrolyteNote = r.getString("electrolyte_note"), isBuiltin = r.getBool("is_builtin"),
            updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )

        fun readContainer(r: Row): ContainerPreset = ContainerPreset(
            id = r.requireString("id"), nameEn = r.requireString("name_en"), nameAr = r.requireString("name_ar"),
            volumeMl = r.requireDouble("volume_ml"), beverageId = r.getString("beverage_id"),
            sortOrder = r.getInt("sort_order") ?: 0, updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
        )

        fun readGoal(r: Row): HydrationGoal = HydrationGoal(
            id = r.requireString("id"), kind = HydrationGoalKind.fromCode(r.requireString("kind")),
            targetMl = r.getDouble("target_ml"), dayType = r.getString("day_type"), active = r.getBool("active"),
            createdAt = r.requireDate("created_at"), updatedAt = r.requireDate("updated_at"),
            originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
        )

        fun readSummary(r: Row): HydrationDailySummary = HydrationDailySummary(
            dayKey = r.requireString("day_key"), tzId = r.requireString("tz_id"),
            manualMl = r.requireDouble("manual_ml"), importedMl = r.requireDouble("imported_ml"),
            estimatedMl = r.requireDouble("estimated_ml"), entryCount = r.getInt("entry_count") ?: 0,
            goalKind = HydrationGoalKind.fromCode(r.requireString("goal_kind")),
            goalTargetMl = r.getDouble("goal_target_ml"), goalId = r.getString("goal_id"),
            updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
            deletedAt = r.getDate("deleted_at"),
        )
    }
}
