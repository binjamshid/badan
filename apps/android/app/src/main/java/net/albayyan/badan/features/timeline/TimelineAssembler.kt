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
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
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

    /**
     * Assemble every event in the window, sorted newest-first. The underlying repository calls
     * are independent reads across different tables/connections, so they run concurrently
     * (`coroutineScope` + `async`) rather than paying the sum of all their latencies.
     */
    suspend fun assemble(): List<TimelineEvent> = coroutineScope {
        val now = env.now()
        val from = now - windowDays.toLong() * MILLIS_PER_DAY
        val to = now
        val events = mutableListOf<TimelineEvent>()

        // Sleep + workout episodes (auto-ingested; provenance-locked).
        val sleepDeferred = async { env.measurements.sessions(kind = SessionKind.SLEEP_PRIMARY, from = from, to = to) }
        val workoutDeferred = async { env.measurements.sessions(kind = SessionKind.WORKOUT, from = from, to = to) }

        // Meds + symptoms live in the sensitive store — only read when that module is on.
        val sensitiveEnabled = env.profile.sensitiveModulesEnabled
        val symptomsDeferred = if (sensitiveEnabled) async { env.logging.symptoms(from, to) } else null
        val regimensDeferred = if (sensitiveEnabled) async { env.logging.regimens() } else null
        val adherenceDeferred = if (sensitiveEnabled) async { env.logging.adherence(from, to) } else null

        // Meals are gated behind the nutrition module.
        val nutritionEnabled = env.profile.nutritionEnabled
        val nutritionDeferred = if (nutritionEnabled) async { env.logging.nutrition(from, to) } else null

        // Notes (normal sensitivity) + body weight measurements.
        val notesDeferred = async { env.logging.notes(from, to) }
        val weightDeferred = async { env.measurements.rawSamples(metricId = MetricId.weight, from = from, to = to) }

        for (session in sleepDeferred.await()) {
            events.add(sleepEvent(session))
        }
        for (session in workoutDeferred.await()) {
            events.add(workoutEvent(session))
        }

        if (sensitiveEnabled) {
            for (symptom in symptomsDeferred!!.await()) {
                events.add(symptomEvent(symptom))
            }
            val regimenById: Map<String, MedicationRegimen> = regimensDeferred!!.await().associateBy { it.id }
            for (adherence in adherenceDeferred!!.await()) {
                events.add(medicationEvent(adherence, regimenById[adherence.regimenId]))
            }
        }

        if (nutritionEnabled) {
            for (meal in nutritionDeferred!!.await()) {
                events.add(mealEvent(meal))
            }
        }

        for (note in notesDeferred.await()) {
            events.add(noteEvent(note))
        }

        for (sample in weightDeferred.await()) {
            events.add(weightEvent(sample))
        }

        events.sortedByDescending { it.occurredAt }
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
