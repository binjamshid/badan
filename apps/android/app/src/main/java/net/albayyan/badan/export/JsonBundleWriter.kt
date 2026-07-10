package net.albayyan.badan.export

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import net.albayyan.badan.domain.AdherenceEvent
import net.albayyan.badan.domain.Baseline
import net.albayyan.badan.domain.DerivedValue
import net.albayyan.badan.domain.ExportManifest
import net.albayyan.badan.domain.IntervalRecord
import net.albayyan.badan.domain.NutritionEntry
import net.albayyan.badan.domain.Provenance
import net.albayyan.badan.domain.RawSample
import net.albayyan.badan.domain.Session
import net.albayyan.badan.domain.SessionDetail
import net.albayyan.badan.domain.SymptomEntry
import net.albayyan.badan.domain.WorkoutEntry
import net.albayyan.badan.storage.JsonCoding

/**
 * Serializes a full export as one self-describing JSON bundle. Raw and derived are **physically
 * separated** into distinct top-level arrays (never merged into shared columns), and the manifest
 * travels inside the bundle so the artifact is reproducible from its own description (D-8).
 * Mirror of iOS `JSONBundleWriter`.
 *
 * Encoding is deterministic (kotlinx emits keys in declaration order, dates are plain epoch-millis
 * `Long`s) so identical data yields identical bytes — the property the manifest checksum relies on.
 *
 * The domain entities are plain data classes (they live in their own tables, not JSON columns, so
 * the domain port did not annotate them `@Serializable`). The export subsystem therefore owns the
 * `@Serializable` mirrors below; field names are the domain's own camelCase, matching the iOS
 * Codable encoding. `Provenance`, `SessionDetail`, and `ExportManifest` are already `@Serializable`
 * and are nested directly.
 */
class JsonBundleWriter {

    /**
     * User-entered structured logs, kept apart from the measurement chain. Symptoms and adherence
     * are sensitive-class; workouts and nutrition are normal-class.
     */
    @Serializable
    data class Logs(
        val symptoms: List<SymptomEntryJson>,
        val adherence: List<AdherenceEventJson>,
        val workouts: List<WorkoutEntryJson>,
        val nutrition: List<NutritionEntryJson>,
    )

    /**
     * The bundle envelope. Top-level keys are snake_case to match the export contract; nested
     * domain objects keep their own natural (camelCase) encoding.
     */
    @Serializable
    data class Bundle(
        val manifest: ExportManifest,
        @SerialName("raw_samples") val rawSamples: List<RawSampleJson>,
        @SerialName("interval_records") val intervalRecords: List<IntervalRecordJson>,
        val sessions: List<SessionJson>,
        @SerialName("derived_values") val derivedValues: List<DerivedValueJson>,
        val baselines: List<BaselineJson>,
        val logs: Logs,
    )

    /** Assemble the bundle from its already-scoped parts. */
    fun makeBundle(
        manifest: ExportManifest,
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sessions: List<Session>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
        symptoms: List<SymptomEntry>,
        adherence: List<AdherenceEvent>,
        workouts: List<WorkoutEntry>,
        nutrition: List<NutritionEntry>,
    ): Bundle = Bundle(
        manifest = manifest,
        rawSamples = rawSamples.map { it.toJson() },
        intervalRecords = intervalRecords.map { it.toJson() },
        sessions = sessions.map { it.toJson() },
        derivedValues = derivedValues.map { it.toJson() },
        baselines = baselines.map { it.toJson() },
        logs = Logs(
            symptoms = symptoms.map { it.toJson() },
            adherence = adherence.map { it.toJson() },
            workouts = workouts.map { it.toJson() },
            nutrition = nutrition.map { it.toJson() },
        ),
    )

    /** Deterministic JSON string for the assembled bundle. */
    fun json(
        manifest: ExportManifest,
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sessions: List<Session>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
        symptoms: List<SymptomEntry>,
        adherence: List<AdherenceEvent>,
        workouts: List<WorkoutEntry>,
        nutrition: List<NutritionEntry>,
    ): String = JsonCoding.encode(
        makeBundle(
            manifest, rawSamples, intervalRecords, sessions, derivedValues, baselines,
            symptoms, adherence, workouts, nutrition,
        )
    )

    /** Deterministic UTF-8 bytes for the assembled bundle. */
    fun data(
        manifest: ExportManifest,
        rawSamples: List<RawSample>,
        intervalRecords: List<IntervalRecord>,
        sessions: List<Session>,
        derivedValues: List<DerivedValue>,
        baselines: List<Baseline>,
        symptoms: List<SymptomEntry>,
        adherence: List<AdherenceEvent>,
        workouts: List<WorkoutEntry>,
        nutrition: List<NutritionEntry>,
    ): ByteArray = json(
        manifest, rawSamples, intervalRecords, sessions, derivedValues, baselines,
        symptoms, adherence, workouts, nutrition,
    ).toByteArray(Charsets.UTF_8)
}

// ===== Serializable mirrors of the domain entities (camelCase keys; epoch-millis Long dates) =====

@Serializable
data class RawSampleJson(
    val id: String,
    val metricId: String,
    val value: Double,
    val unit: String,
    val originalValue: Double,
    val originalUnit: String,
    val startAt: Long,
    val endAt: Long? = null,
    val tzId: String,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class IntervalRecordJson(
    val id: String,
    val metricId: String,
    val value: Double,
    val unit: String,
    val startAt: Long,
    val endAt: Long,
    val tzId: String,
    val aggregation: String,
    val coverage: Double,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class SessionJson(
    val id: String,
    val kind: String,
    val subtype: String? = null,
    val startAt: Long,
    val endAt: Long,
    val tzId: String,
    val localNight: String? = null,
    val detail: SessionDetail,
    val provenance: Provenance,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class DerivedValueJson(
    val id: String,
    val metricId: String,
    val value: Double,
    val unit: String,
    val periodKey: String,
    val confidence: Double? = null,
    val provisional: Boolean,
    val algorithmId: String,
    val algorithmVersion: String,
    val inputManifestId: String? = null,
    val computedAt: Long,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class BaselineJson(
    val id: String,
    val metricId: String,
    val covariateContext: String,
    val windowDays: Int,
    val method: String,
    val center: Double,
    val spread: Double,
    val bandLow: Double,
    val bandHigh: Double,
    val nPoints: Int,
    val provisional: Boolean,
    val algorithmVersion: String,
    val validFrom: Long,
    val computedAt: Long,
    val unit: String,
)

@Serializable
data class SymptomEntryJson(
    val id: String,
    val symptomId: String? = null,
    val customLabel: String? = null,
    val severity: Int,
    val occurredAt: Long,
    val tzId: String,
    val durationSeconds: Double? = null,
    val bodyLocation: String? = null,
    val triggers: List<String> = emptyList(),
    val note: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class AdherenceEventJson(
    val id: String,
    val regimenId: String,
    val kind: String,
    val scheduledFor: Long? = null,
    val occurredAt: Long,
    val tzId: String,
    val skipReason: String? = null,
    val skipNote: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class WorkoutEntryJson(
    val id: String,
    val activityType: String,
    val startAt: Long,
    val endAt: Long,
    val tzId: String,
    val energyKcal: Double? = null,
    val distanceM: Double? = null,
    val avgHr: Double? = null,
    val maxHr: Double? = null,
    val perceivedEffort: Int? = null,
    val note: String? = null,
    val ingestionPath: String,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

@Serializable
data class NutritionEntryJson(
    val id: String,
    val description: String,
    val mealType: String,
    val energyKcal: Double? = null,
    val proteinG: Double? = null,
    val carbsG: Double? = null,
    val fatG: Double? = null,
    val fiberG: Double? = null,
    val waterMl: Double? = null,
    val caffeineMg: Double? = null,
    val lowDetail: Boolean,
    val occurredAt: Long,
    val tzId: String,
    val note: String? = null,
    val updatedAt: Long,
    val originDeviceId: String,
    val deletedAt: Long? = null,
)

private fun RawSample.toJson(): RawSampleJson = RawSampleJson(
    id = id, metricId = metricId, value = value, unit = unit,
    originalValue = originalValue, originalUnit = originalUnit,
    startAt = startAt, endAt = endAt, tzId = tzId, provenance = provenance,
    updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun IntervalRecord.toJson(): IntervalRecordJson = IntervalRecordJson(
    id = id, metricId = metricId, value = value, unit = unit,
    startAt = startAt, endAt = endAt, tzId = tzId, aggregation = aggregation.code,
    coverage = coverage, provenance = provenance,
    updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun Session.toJson(): SessionJson = SessionJson(
    id = id, kind = kind.code, subtype = subtype, startAt = startAt, endAt = endAt,
    tzId = tzId, localNight = localNight, detail = detail, provenance = provenance,
    updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun DerivedValue.toJson(): DerivedValueJson = DerivedValueJson(
    id = id, metricId = metricId, value = value, unit = unit, periodKey = periodKey,
    confidence = confidence, provisional = provisional, algorithmId = algorithmId,
    algorithmVersion = algorithmVersion, inputManifestId = inputManifestId,
    computedAt = computedAt, updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun Baseline.toJson(): BaselineJson = BaselineJson(
    id = id, metricId = metricId, covariateContext = covariateContext, windowDays = windowDays,
    method = method.code, center = center, spread = spread, bandLow = bandLow, bandHigh = bandHigh,
    nPoints = nPoints, provisional = provisional, algorithmVersion = algorithmVersion,
    validFrom = validFrom, computedAt = computedAt, unit = unit,
)

private fun SymptomEntry.toJson(): SymptomEntryJson = SymptomEntryJson(
    id = id, symptomId = symptomId, customLabel = customLabel, severity = severity,
    occurredAt = occurredAt, tzId = tzId, durationSeconds = durationSeconds, bodyLocation = bodyLocation,
    triggers = triggers, note = note, updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun AdherenceEvent.toJson(): AdherenceEventJson = AdherenceEventJson(
    id = id, regimenId = regimenId, kind = kind.code, scheduledFor = scheduledFor,
    occurredAt = occurredAt, tzId = tzId, skipReason = skipReason?.code, skipNote = skipNote,
    updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun WorkoutEntry.toJson(): WorkoutEntryJson = WorkoutEntryJson(
    id = id, activityType = activityType, startAt = startAt, endAt = endAt, tzId = tzId,
    energyKcal = energyKcal, distanceM = distanceM, avgHr = avgHr, maxHr = maxHr,
    perceivedEffort = perceivedEffort, note = note, ingestionPath = ingestionPath.code,
    updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)

private fun NutritionEntry.toJson(): NutritionEntryJson = NutritionEntryJson(
    id = id, description = description, mealType = mealType.code, energyKcal = energyKcal,
    proteinG = proteinG, carbsG = carbsG, fatG = fatG, fiberG = fiberG, waterMl = waterMl,
    caffeineMg = caffeineMg, lowDetail = lowDetail, occurredAt = occurredAt, tzId = tzId, note = note,
    updatedAt = updatedAt, originDeviceId = originDeviceId, deletedAt = deletedAt,
)
