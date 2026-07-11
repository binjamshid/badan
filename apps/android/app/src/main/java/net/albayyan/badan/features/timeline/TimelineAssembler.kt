package net.albayyan.badan.features.timeline

import net.albayyan.badan.app.AppEnvironment
import net.albayyan.badan.core.AppLanguage
import net.albayyan.badan.core.Loc
import net.albayyan.badan.core.LocalizedString
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.AdherenceKind
import net.albayyan.badan.domain.IngestionPath
import net.albayyan.badan.domain.MedicationRegimen
import net.albayyan.badan.domain.MetricId
import net.albayyan.badan.domain.NoteEntry
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionKind
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.TimelineEvent
import net.albayyan.badan.domain.TimelineEventType
import kotlin.math.roundToInt

/**
 * Gathers the recent past from every store into a single, chronological `List<TimelineEvent>` —
 * BADAN's anti-fragmentation spine. Sleep and workouts come from measurement sessions; symptoms,
 * medications, meals and notes from the logging repository; body weight from raw samples. Every
 * row carries its own provenance ([IngestionPath]) so the Timeline can show "where this came
 * from" without a join. Sensitive rows (meds / symptoms) are gated behind the same module
 * switches that govern the sensitive database. Faithful port of the iOS `TimelineAssembler`.
 */
class TimelineAssembler(private val env: AppEnvironment) {

    /** Assemble every event in the window, sorted newest-first. */
    fun assemble(): List<TimelineEvent> {
        val now = env.now()
        val from = now - windowDays.toLong() * MILLIS_PER_DAY
        val to = now
        val events = mutableListOf<TimelineEvent>()

        // Sleep + workout episodes (auto-ingested; provenance-locked).
        for (session in env.measurements.sessions(kind = SessionKind.SLEEP_PRIMARY, from = from, to = to)) {
            events.add(sleepEvent(session))
        }
        for (session in env.measurements.sessions(kind = SessionKind.WORKOUT, from = from, to = to)) {
            events.add(workoutEvent(session))
        }

        // Meds + symptoms live in the sensitive store — only read when that module is on.
        if (env.profile.sensitiveModulesEnabled) {
            for (symptom in env.logging.symptoms(from, to)) {
                events.add(symptomEvent(symptom))
            }
            val regimenById: Map<String, MedicationRegimen> = env.logging.regimens().associateBy { it.id }
            for (adherence in env.logging.adherence(from, to)) {
                events.add(medicationEvent(adherence, regimenById[adherence.regimenId]))
            }
        }

        // Meals are gated behind the nutrition module.
        if (env.profile.nutritionEnabled) {
            for (meal in env.logging.nutrition(from, to)) {
                events.add(mealEvent(meal))
            }
        }

        // Notes (normal sensitivity).
        for (note in env.logging.notes(from, to)) {
            events.add(noteEvent(note))
        }

        // Body weight measurements.
        for (sample in env.measurements.rawSamples(metricId = MetricId.weight, from = from, to = to)) {
            events.add(weightEvent(sample))
        }

        return events.sortedByDescending { it.occurredAt }
    }

    // MARK: - Event builders

    private fun sleepEvent(s: Session): TimelineEvent {
        val asleep = s.detail.timeAsleepSeconds ?: s.durationSeconds
        // Sleep is attributed to the morning it ends (the "last night" anchor).
        return TimelineEvent(
            id = "sleep:${s.id}", type = TimelineEventType.SLEEP, occurredAt = s.endAt, tzId = s.tzId,
            title = TimelineEventType.SLEEP.displayName,
            valueText = env.format.duration(asleep),
            sourceRecordId = s.id, ingestionPath = s.provenance.ingestionPath,
            sensitive = false, deletable = false,
        )
    }

    private fun workoutEvent(s: Session): TimelineEvent {
        val activity = s.subtype?.let { LocalizedString(en = it, ar = it) }
        return TimelineEvent(
            id = "workout:${s.id}", type = TimelineEventType.WORKOUT, occurredAt = s.startAt, tzId = s.tzId,
            title = TimelineEventType.WORKOUT.displayName, subtitle = activity,
            valueText = env.format.duration(s.durationSeconds),
            sourceRecordId = s.id, ingestionPath = s.provenance.ingestionPath,
            sensitive = false, deletable = false,
        )
    }

    private fun symptomEvent(s: SymptomEntry): TimelineEvent =
        TimelineEvent(
            id = "symptom:${s.id}", type = TimelineEventType.SYMPTOM, occurredAt = s.occurredAt, tzId = s.tzId,
            title = env.symptoms.displayName(forId = s.symptomId, customLabel = s.customLabel),
            valueText = severityLabel(s.severity)?.let { env.s(it) },
            sourceRecordId = s.id, ingestionPath = IngestionPath.MANUAL,
            sensitive = true, deletable = false,
        )

    private fun medicationEvent(a: AdherenceEvent, regimen: MedicationRegimen?): TimelineEvent {
        val title = regimen?.let { LocalizedString(en = it.name, ar = it.name) } ?: Loc.logMedication
        val strength = regimen?.strength?.let { LocalizedString(en = it, ar = it) }
        return TimelineEvent(
            id = "medication:${a.id}", type = TimelineEventType.MEDICATION, occurredAt = a.occurredAt, tzId = a.tzId,
            title = title, subtitle = strength, valueText = env.s(kindLabel(a.kind)),
            sourceRecordId = a.id, ingestionPath = IngestionPath.MANUAL,
            sensitive = true, deletable = true,
        )
    }

    private fun mealEvent(m: NutritionEntry): TimelineEvent =
        TimelineEvent(
            id = "meal:${m.id}", type = TimelineEventType.MEAL, occurredAt = m.occurredAt, tzId = m.tzId,
            title = LocalizedString(en = m.description, ar = m.description),
            subtitle = m.mealType.displayName,
            valueText = m.energyKcal?.let { caloriesText(it) },
            sourceRecordId = m.id, ingestionPath = IngestionPath.MANUAL,
            sensitive = false, deletable = true,
        )

    private fun noteEvent(n: NoteEntry): TimelineEvent =
        TimelineEvent(
            id = "note:${n.id}", type = TimelineEventType.NOTE, occurredAt = n.occurredAt, tzId = n.tzId,
            title = LocalizedString(en = n.text, ar = n.text),
            sourceRecordId = n.id, ingestionPath = IngestionPath.MANUAL,
            sensitive = false, deletable = true,
        )

    private fun weightEvent(sample: RawSample): TimelineEvent {
        val def = env.registry.definitionOrFallback(MetricId.weight)
        return TimelineEvent(
            id = "weight:${sample.id}", type = TimelineEventType.MEASUREMENT, occurredAt = sample.startAt, tzId = sample.tzId,
            title = def.displayName,
            valueText = env.format.full(metricId = MetricId.weight, canonicalValue = sample.value),
            sourceRecordId = sample.id, ingestionPath = sample.provenance.ingestionPath,
            sensitive = false, deletable = false,
        )
    }

    // MARK: - Localized value helpers

    private fun severityLabel(severity: Int): LocalizedString? = when {
        severity < 1 -> null
        severity <= 3 -> Loc.mild
        severity <= 6 -> Loc.moderate
        else -> Loc.severe
    }

    private fun kindLabel(kind: AdherenceKind): LocalizedString = when (kind) {
        AdherenceKind.TAKEN -> Loc.taken
        AdherenceKind.SKIPPED -> Loc.skipped
        AdherenceKind.LATE -> LocalizedString(en = "Taken late", ar = "تم تناوله متأخراً")
    }

    private fun caloriesText(kcal: Double): String {
        val unit = if (env.language == AppLanguage.AR) "سعرة" else "kcal"
        return "${env.format.integer(kcal.roundToInt())} $unit"
    }

    companion object {
        /** How far back the unified spine reaches. */
        const val windowDays = 21
        private const val MILLIS_PER_DAY = 86_400_000L
    }
}
