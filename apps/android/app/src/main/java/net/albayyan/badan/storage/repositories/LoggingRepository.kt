package net.albayyan.badan.storage.repositories

import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.Condition
import net.albayyan.badan.domain.ConditionStatus
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.MealType
import net.albayyan.badan.domain.MedicationRegimen
import net.albayyan.badan.domain.MedicationSchedule
import net.albayyan.badan.domain.NoteEntry
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.SkipReason
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.storage.JsonCoding
import net.albayyan.badan.storage.sqlite.Row
import net.albayyan.badan.storage.sqlite.SqliteConnection
import net.albayyan.badan.storage.sqlite.Sql

/**
 * All structured logging. Meds / symptoms / conditions live in the **sensitive** DB so
 * disabling those modules is a file deletion (D-9). Workouts / nutrition / notes are normal
 * sensitivity and live in the main DB.
 */
class LoggingRepository(
    private val main: SqliteConnection,
    private val sensitive: SqliteConnection,
) {

    // MARK: - Medications (sensitive)

    fun upsertRegimen(r: MedicationRegimen) {
        sensitive.run(
            """
            INSERT OR REPLACE INTO medication_regimens
              (id, name, strength, form, schedule, started_at, ended_at, notes, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                r.id, r.name, r.strength, r.form, JsonCoding.encode(r.schedule),
                r.startedAt, r.endedAt, r.notes, r.updatedAt, r.originDeviceId, r.deletedAt,
            ),
        )
    }

    // Intentionally unbounded: a user's medication regimen list stays small (dozens at most,
    // not a per-datum log) — see LoggingRepository.conditions() for the same reasoning.
    fun regimens(activeOnly: Boolean = false): List<MedicationRegimen> {
        var sql = "SELECT * FROM medication_regimens WHERE deleted_at IS NULL"
        if (activeOnly) sql += " AND ended_at IS NULL"
        sql += " ORDER BY name ASC;"
        return sensitive.query(sql).map { readRegimen(it) }
    }

    fun regimen(id: String): MedicationRegimen? =
        sensitive.query("SELECT * FROM medication_regimens WHERE id = ?;", listOf(id)).firstOrNull()?.let { readRegimen(it) }

    fun deleteRegimen(id: String, at: Long) {
        sensitive.run("UPDATE medication_regimens SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    fun insertAdherence(e: AdherenceEvent) {
        sensitive.run(
            """
            INSERT OR REPLACE INTO adherence_events
              (id, regimen_id, kind, scheduled_for, occurred_at, tz_id, skip_reason, skip_note, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                e.id, e.regimenId, e.kind.code, e.scheduledFor, e.occurredAt,
                e.tzId, e.skipReason?.code, e.skipNote, e.updatedAt, e.originDeviceId, e.deletedAt,
            ),
        )
    }

    fun adherence(from: Long, to: Long): List<AdherenceEvent> =
        sensitive.query(
            "SELECT * FROM adherence_events WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
            listOf(from, to),
        ).map { readAdherence(it) }

    fun adherence(regimenId: String, from: Long, to: Long): List<AdherenceEvent> =
        sensitive.query(
            "SELECT * FROM adherence_events WHERE regimen_id = ? AND occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
            listOf(regimenId, from, to),
        ).map { readAdherence(it) }

    // MARK: - Symptoms (sensitive)

    fun insertSymptom(s: SymptomEntry) {
        sensitive.run(
            """
            INSERT OR REPLACE INTO symptom_entries
              (id, symptom_id, custom_label, severity, occurred_at, tz_id, duration_s, body_location, triggers, note, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                s.id, s.symptomId, s.customLabel, s.severity.toLong(), s.occurredAt,
                s.tzId, s.durationSeconds, s.bodyLocation, JsonCoding.encode(s.triggers),
                s.note, s.updatedAt, s.originDeviceId, s.deletedAt,
            ),
        )
    }

    fun symptoms(from: Long, to: Long): List<SymptomEntry> =
        sensitive.query(
            "SELECT * FROM symptom_entries WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
            listOf(from, to),
        ).map { readSymptom(it) }

    fun allSymptoms(): List<SymptomEntry> =
        sensitive.query("SELECT * FROM symptom_entries WHERE deleted_at IS NULL ORDER BY occurred_at DESC;").map { readSymptom(it) }

    fun deleteSymptom(id: String, at: Long) {
        sensitive.run("UPDATE symptom_entries SET deleted_at = ?, updated_at = ? WHERE id = ?;", listOf(at, at, id))
    }

    // MARK: - Conditions (sensitive)

    fun upsertCondition(c: Condition) {
        sensitive.run(
            """
            INSERT OR REPLACE INTO conditions
              (id, label, status, onset_at, linked_regimen_ids, linked_symptom_ids, notes, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                c.id, c.label, c.status.code, c.onsetAt,
                JsonCoding.encode(c.linkedRegimenIds), JsonCoding.encode(c.linkedSymptomIds),
                c.notes, c.updatedAt, c.originDeviceId, c.deletedAt,
            ),
        )
    }

    // Intentionally unbounded: a user's tracked-conditions list stays small, not a per-datum log.
    fun conditions(): List<Condition> =
        sensitive.query("SELECT * FROM conditions WHERE deleted_at IS NULL ORDER BY label ASC;").map { r ->
            Condition(
                id = r.requireString("id"), label = r.requireString("label"),
                status = ConditionStatus.fromCode(r.requireString("status")), onsetAt = r.getDate("onset_at"),
                linkedRegimenIds = JsonCoding.decodeOrNull<List<String>>(r.getString("linked_regimen_ids")) ?: emptyList(),
                linkedSymptomIds = JsonCoding.decodeOrNull<List<String>>(r.getString("linked_symptom_ids")) ?: emptyList(),
                notes = r.getString("notes"), updatedAt = r.requireDate("updated_at"),
                originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )
        }

    // MARK: - Workouts (main)

    fun upsertWorkout(w: WorkoutEntry) {
        main.run(
            """
            INSERT OR REPLACE INTO workout_entries
              (id, activity_type, start_at, end_at, tz_id, energy_kcal, distance_m, avg_hr, max_hr, perceived_effort, note, ingestion_path, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                w.id, w.activityType, w.startAt, w.endAt, w.tzId,
                w.energyKcal, w.distanceM, w.avgHr, w.maxHr, w.perceivedEffort?.toLong(),
                w.note, w.ingestionPath.code, w.updatedAt, w.originDeviceId, w.deletedAt,
            ),
        )
    }

    fun workouts(from: Long, to: Long): List<WorkoutEntry> =
        main.query(
            "SELECT * FROM workout_entries WHERE start_at >= ? AND start_at <= ? AND deleted_at IS NULL ORDER BY start_at DESC;",
            listOf(from, to),
        ).map { readWorkout(it) }

    // MARK: - Nutrition (main)

    fun upsertNutrition(n: NutritionEntry) {
        main.run(
            """
            INSERT OR REPLACE INTO nutrition_entries
              (id, description, meal_type, energy_kcal, protein_g, carbs_g, fat_g, fiber_g, water_ml, caffeine_mg, low_detail, occurred_at, tz_id, note, updated_at, origin_device_id, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            listOf(
                n.id, n.description, n.mealType.code, n.energyKcal, n.proteinG,
                n.carbsG, n.fatG, n.fiberG, n.waterMl, n.caffeineMg,
                Sql.bool(n.lowDetail), n.occurredAt, n.tzId, n.note, n.updatedAt,
                n.originDeviceId, n.deletedAt,
            ),
        )
    }

    fun nutrition(from: Long, to: Long): List<NutritionEntry> =
        main.query(
            "SELECT * FROM nutrition_entries WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
            listOf(from, to),
        ).map { readNutrition(it) }

    // MARK: - Notes (main)

    fun upsertNote(note: NoteEntry) {
        main.run(
            "INSERT OR REPLACE INTO note_entries (id, text, occurred_at, tz_id, tags, updated_at, origin_device_id, deleted_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
            listOf(
                note.id, note.text, note.occurredAt, note.tzId,
                JsonCoding.encode(note.tags), note.updatedAt, note.originDeviceId, note.deletedAt,
            ),
        )
    }

    fun notes(from: Long, to: Long): List<NoteEntry> =
        main.query(
            "SELECT * FROM note_entries WHERE occurred_at >= ? AND occurred_at <= ? AND deleted_at IS NULL ORDER BY occurred_at DESC;",
            listOf(from, to),
        ).map { r ->
            NoteEntry(
                id = r.requireString("id"), text = r.requireString("text"), occurredAt = r.requireDate("occurred_at"),
                tzId = r.requireString("tz_id"), tags = JsonCoding.decodeOrNull<List<String>>(r.getString("tags")) ?: emptyList(),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )
        }

    // MARK: - Readers

    companion object {
        fun readRegimen(r: Row): MedicationRegimen =
            MedicationRegimen(
                id = r.requireString("id"), name = r.requireString("name"), strength = r.getString("strength"),
                form = r.getString("form"),
                schedule = JsonCoding.decodeOrNull<MedicationSchedule>(r.getString("schedule")) ?: MedicationSchedule.AsNeeded,
                startedAt = r.requireDate("started_at"), endedAt = r.getDate("ended_at"), notes = r.getString("notes"),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"),
                deletedAt = r.getDate("deleted_at"),
            )

        fun readAdherence(r: Row): AdherenceEvent =
            AdherenceEvent(
                id = r.requireString("id"), regimenId = r.requireString("regimen_id"),
                kind = AdherenceKind.fromCode(r.requireString("kind")), scheduledFor = r.getDate("scheduled_for"),
                occurredAt = r.requireDate("occurred_at"), tzId = r.requireString("tz_id"),
                skipReason = r.getString("skip_reason")?.let { SkipReason.fromCode(it) }, skipNote = r.getString("skip_note"),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )

        fun readSymptom(r: Row): SymptomEntry =
            SymptomEntry(
                id = r.requireString("id"), symptomId = r.getString("symptom_id"), customLabel = r.getString("custom_label"),
                severity = r.getInt("severity") ?: 0, occurredAt = r.requireDate("occurred_at"), tzId = r.requireString("tz_id"),
                durationSeconds = r.getDouble("duration_s"), bodyLocation = r.getString("body_location"),
                triggers = JsonCoding.decodeOrNull<List<String>>(r.getString("triggers")) ?: emptyList(), note = r.getString("note"),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )

        fun readWorkout(r: Row): WorkoutEntry =
            WorkoutEntry(
                id = r.requireString("id"), activityType = r.requireString("activity_type"),
                startAt = r.requireDate("start_at"), endAt = r.requireDate("end_at"), tzId = r.requireString("tz_id"),
                energyKcal = r.getDouble("energy_kcal"), distanceM = r.getDouble("distance_m"), avgHr = r.getDouble("avg_hr"),
                maxHr = r.getDouble("max_hr"), perceivedEffort = r.getInt("perceived_effort"), note = r.getString("note"),
                ingestionPath = IngestionPath.fromCode(r.requireString("ingestion_path")),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )

        fun readNutrition(r: Row): NutritionEntry =
            NutritionEntry(
                id = r.requireString("id"), description = r.requireString("description"),
                mealType = MealType.fromCode(r.requireString("meal_type")), energyKcal = r.getDouble("energy_kcal"),
                proteinG = r.getDouble("protein_g"), carbsG = r.getDouble("carbs_g"), fatG = r.getDouble("fat_g"), fiberG = r.getDouble("fiber_g"),
                waterMl = r.getDouble("water_ml"), caffeineMg = r.getDouble("caffeine_mg"), lowDetail = r.getBool("low_detail"),
                occurredAt = r.requireDate("occurred_at"), tzId = r.requireString("tz_id"), note = r.getString("note"),
                updatedAt = r.requireDate("updated_at"), originDeviceId = r.requireString("origin_device_id"), deletedAt = r.getDate("deleted_at"),
            )
    }
}
