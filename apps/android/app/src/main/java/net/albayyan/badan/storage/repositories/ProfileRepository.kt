package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.CustomizationProfile
import net.albayyan.badan.domain.Goal
import net.albayyan.badan.domain.GoalDirection
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Sql
import net.albayyan.badan.storage.sqlite.SqliteConnection

/**
 * The single presentation/preferences record (dual-altitude switch, units, language, theme,
 * dashboard layout) plus metric pins and goals. Stored as a JSON singleton so preference
 * evolution never needs a migration.
 */
class ProfileRepository(private val db: SqliteConnection) {

    fun load(): CustomizationProfile {
        val row = db.query("SELECT json FROM customization_profile WHERE id = 1;").firstOrNull()
        if (row != null) {
            val profile = JsonCoding.decodeOrNull<CustomizationProfile>(row.getString("json"))
            if (profile != null) return profile
        }
        val fresh = CustomizationProfile()
        save(fresh)
        return fresh
    }

    fun save(profile: CustomizationProfile) {
        db.run(
            "INSERT OR REPLACE INTO customization_profile (id, json) VALUES (1, ?);",
            listOf(JsonCoding.encode(profile)),
        )
    }

    // MARK: - Metric pins

    fun pinnedMetrics(): Set<String> =
        db.query("SELECT metric_id FROM metric_pins;").mapNotNull { it.getString("metric_id") }.toSet()

    fun setPinned(metricId: String, pinned: Boolean, at: Long) {
        if (pinned) {
            db.run("INSERT OR REPLACE INTO metric_pins (metric_id, pinned_at) VALUES (?, ?);", listOf(metricId, at))
        } else {
            db.run("DELETE FROM metric_pins WHERE metric_id = ?;", listOf(metricId))
        }
    }

    // MARK: - Goals

    fun goals(): List<Goal> =
        db.query("SELECT * FROM goals ORDER BY created_at ASC;").map { r ->
            Goal(
                id = r.requireString("id"), metricId = r.requireString("metric_id"), target = r.requireDouble("target"),
                unit = r.requireString("unit"), direction = GoalDirection.fromCode(r.requireString("direction")),
                active = r.getBool("active"), createdAt = r.requireDate("created_at"),
            )
        }

    fun upsertGoal(g: Goal) {
        db.run(
            "INSERT OR REPLACE INTO goals (id, metric_id, target, unit, direction, active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
            listOf(g.id, g.metricId, g.target, g.unit, g.direction.code, Sql.bool(g.active), g.createdAt),
        )
    }

    fun deleteGoal(id: String) {
        db.run("DELETE FROM goals WHERE id = ?;", listOf(id))
    }
}
