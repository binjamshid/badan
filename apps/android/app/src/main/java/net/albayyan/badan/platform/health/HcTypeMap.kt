package net.albayyan.badan.platform.health

import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.BodyFatRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.FloorsClimbedRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.LeanBodyMassRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RespiratoryRateRecord
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SkinTemperatureRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.TotalCaloriesBurnedRecord
import androidx.health.connect.client.records.Vo2MaxRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.Device
import net.albayyan.badan.domain.Aggregation
import net.albayyan.badan.domain.MetricId
import java.time.ZoneOffset
import kotlin.reflect.KClass

/**
 * The data-driven Health Connect record-type table (EPIC-02) — the Android sibling of iOS's
 * `HKTypeMap.swift`. Everything that used to be implied by a hand-written `readX()` method per
 * type (which metric it becomes, in what unit, at what shape, under which consent family, behind
 * which permission, and under which `read_anchors.platform_type` key) is stated once here, as
 * data, so the adapter is a loop over the table rather than a list of near-identical methods.
 *
 * Why a separate object rather than fields on the adapter: everything in this file is pure — no
 * `Context`, no `HealthConnectClient`, no coroutines — so the parity fixtures can assert the
 * mapping without a device or a Health Connect provider. `HealthConnectAdapter` is not JVM
 * testable and never will be; the decisions that can actually be *wrong* (metric id, unit,
 * aggregation, id construction) live here where a test can reach them. That is what makes the
 * "identical canonical output on both platforms" Phase-0 criterion checkable at all.
 *
 * The mapping helpers below take primitives (a Double, two epoch-millis, a package name) rather
 * than Health Connect record objects on purpose: `Metadata` and the `units.*` value types drag in
 * SDK construction ceremony that would make every fixture a chore to write, and the extraction of
 * `record.energy.inKilojoules` is the one part that genuinely cannot be wrong without the compiler
 * saying so. Extraction stays in the adapter; interpretation lives here.
 */
object HcTypeMap {

    /** Which BADAN table a record type lands in, and therefore which DTO the adapter builds. */
    enum class Shape { SAMPLE, INTERVAL, SLEEP_SESSION, WORKOUT_SESSION }

    /**
     * The consent family a type belongs to. These are the groups the user is asked for in stages
     * (plan §13.1/§14) and the groups `AndroidManifest.xml` is commented by — keep the two in the
     * same shape so "what did BADAN ask for, and why" has one answer in both files.
     */
    enum class Family(val code: String) {
        ACTIVITY("activity"),
        VITALS("vitals"),
        SLEEP("sleep"),
        BODY("body"),
        WORKOUT("workout"),
    }

    /**
     * One record type's complete mapping.
     *
     * [metricId] is null exactly when a type is declared but deliberately not ingested; the
     * reason is then mandatory in [deferredReason], because a silently absent type and a
     * deliberately absent one look identical six months later.
     */
    data class Entry(
        /**
         * The `read_anchors.platform_type` key for this type — the Health Connect record class's
         * simple name. Paired with `store = "healthConnect"` it is unique, and it is stable across
         * SDK versions in a way an ordinal or a list index would not be. Never renamed: the value
         * is persisted, so changing it silently orphans a token and forces a full re-read.
         */
        val platformType: String,
        val recordType: KClass<out Record>,
        val metricId: String?,
        /**
         * The unit the adapter emits for this type, as received — `IngestionPipeline` converts to
         * the registry's canonical unit and keeps this as `original_unit` (I1 lineage). Chosen to
         * be whichever Health Connect accessor is exact rather than whichever is canonical: for
         * energy `inKilojoules` is emitted (not `inKilocalories`) because the registry canonical
         * *is* kJ, so the common path does no floating-point conversion at all.
         */
        val unit: String,
        val shape: Shape,
        /**
         * How multiple readings for one period combine. Meaningless for [Shape.SAMPLE] (raw
         * samples are not aggregated) — [Aggregation.LATEST] is used there as an inert filler
         * rather than making the field nullable and forcing every call site to unwrap it.
         */
        val aggregation: Aggregation,
        val family: Family,
        val deferredReason: String? = null,
    ) {
        /**
         * The manifest permission this type needs, resolved through the SDK's own table rather
         * than spelled as a literal, so a typo is impossible and an SDK rename is a compile
         * error. `HcTypeMapTest` asserts every value here is also declared in AndroidManifest.xml
         * — a permission the adapter requests but the manifest omits fails silently at request
         * time, which presents to the user as "I granted it and nothing happened".
         */
        val readPermission: String get() = HealthPermission.getReadPermission(recordType)

        /** True when this type actually produces rows. See [metricId]/[deferredReason]. */
        val isIngested: Boolean get() = deferredReason == null
    }

    // MARK: - The table

    val entries: List<Entry> = listOf(
        // --- Activity ---
        Entry("StepsRecord", StepsRecord::class, MetricId.steps, "count",
            Shape.INTERVAL, Aggregation.SUM, Family.ACTIVITY),
        Entry("ActiveCaloriesBurnedRecord", ActiveCaloriesBurnedRecord::class, MetricId.activeEnergy, "kJ",
            Shape.INTERVAL, Aggregation.SUM, Family.ACTIVITY),
        Entry("DistanceRecord", DistanceRecord::class, MetricId.distance, "m",
            Shape.INTERVAL, Aggregation.SUM, Family.ACTIVITY),
        Entry("FloorsClimbedRecord", FloorsClimbedRecord::class, MetricId.floors, "count",
            Shape.INTERVAL, Aggregation.SUM, Family.ACTIVITY),
        // Neither permitted nor ingested, deliberately. Health Connect's
        // TotalCaloriesBurnedRecord is *total* expenditure (basal + active); the registry has
        // `activity.active_energy` and `activity.resting_energy` and no metric for the total.
        //
        // The three tempting shortcuts are all wrong and all silent:
        //   * mapping it to `activity.active_energy` overstates active burn by a whole BMR —
        //     roughly 1,500-2,000 kcal/day for an adult — and the number looks plausible;
        //   * mapping it to `activity.resting_energy` claims a basal figure Health Connect never
        //     reported;
        //   * computing `resting = total - active` is a derivation, not an ingestion. It would
        //     need an algorithm version, an input manifest, and append-only semantics (I2), and
        //     the two records' windows do not align, so the subtraction is not even well-defined
        //     per row.
        // The honest resolution is a registry metric for total expenditure, which is a
        // `registry.json` contract change (iOS-affecting) and therefore not this epic's to make.
        // Until then the type is named here so the gap is visible rather than inferred from an
        // absence.
        //
        // AndroidManifest.xml used to declare READ_TOTAL_CALORIES_BURNED anyway, which contradicted
        // the [permissions] rule three lines of doc below it and, worse, would have declared the
        // data type on the Play Data Safety form — the form is built from the manifest, not from
        // this table. The declaration was removed (audit finding #7). The entry below stays: a
        // deferral that is written down is documentation, a permission that is asked for is a
        // disclosure, and only the second one had to go.
        Entry("TotalCaloriesBurnedRecord", TotalCaloriesBurnedRecord::class, null, "kJ",
            Shape.INTERVAL, Aggregation.SUM, Family.ACTIVITY,
            deferredReason = "Health Connect reports total (basal+active) energy; the metric " +
                "registry has no total-expenditure metric, and total-minus-active is a derivation, " +
                "not an ingestion. Needs a registry contract change."),

        // --- Vitals ---
        Entry("HeartRateRecord", HeartRateRecord::class, MetricId.heartRate, "bpm",
            Shape.SAMPLE, Aggregation.LATEST, Family.VITALS),
        Entry("RestingHeartRateRecord", RestingHeartRateRecord::class, MetricId.restingHeartRate, "bpm",
            Shape.INTERVAL, Aggregation.LATEST, Family.VITALS),
        Entry("HeartRateVariabilityRmssdRecord", HeartRateVariabilityRmssdRecord::class, MetricId.hrv, "ms",
            Shape.INTERVAL, Aggregation.LATEST, Family.VITALS),
        Entry("RespiratoryRateRecord", RespiratoryRateRecord::class, MetricId.respiratoryRate, "breaths/min",
            Shape.INTERVAL, Aggregation.LATEST, Family.VITALS),
        Entry("OxygenSaturationRecord", OxygenSaturationRecord::class, MetricId.spo2, "%",
            Shape.SAMPLE, Aggregation.LATEST, Family.VITALS),
        // Skin temperature maps to a *deviation* metric, and the record type cooperates: Health
        // Connect models a session as a baseline plus a list of `Delta`s, so BADAN ingests the
        // deltas and never the absolute. That matches plan §4 rule 9 (directional bands, not
        // false-precision absolutes) without BADAN having to compute a personal baseline first.
        //
        // The unit is "degC" and must stay "degC" even if a future accessor offers Fahrenheit:
        // `Units`' degF spec carries the freezing-point offset (-32 x 5/9), which is correct for
        // a temperature and catastrophically wrong for a temperature *difference* — a +0.5 degF
        // deviation would canonicalize to about -17.5 degC. `TemperatureDelta.celsius` is already
        // the difference in Celsius, so no conversion happens on this path at all.
        Entry("SkinTemperatureRecord", SkinTemperatureRecord::class, MetricId.wristTempDeviation, "degC",
            Shape.INTERVAL, Aggregation.MEAN, Family.VITALS),

        // --- Sleep ---
        Entry("SleepSessionRecord", SleepSessionRecord::class, null, "s",
            Shape.SLEEP_SESSION, Aggregation.DURATION, Family.SLEEP),

        // --- Body ---
        Entry("WeightRecord", WeightRecord::class, MetricId.weight, "kg",
            Shape.SAMPLE, Aggregation.LATEST, Family.BODY),
        Entry("BodyFatRecord", BodyFatRecord::class, MetricId.bodyFatPct, "%",
            Shape.SAMPLE, Aggregation.LATEST, Family.BODY),
        Entry("LeanBodyMassRecord", LeanBodyMassRecord::class, MetricId.leanMass, "kg",
            Shape.SAMPLE, Aggregation.LATEST, Family.BODY),
        // VO2 max is a sample, not an interval, and never blended across sources (plan §4 rule 7):
        // Garmin's FirstBeat estimate, Samsung's, and a lab metabolic cart are three different
        // algorithms answering the same question, and averaging them produces a number no method
        // ever measured. Per-source trends only; the measurement method travels as the subtype.
        Entry("Vo2MaxRecord", Vo2MaxRecord::class, MetricId.vo2Max, "mL/kg/min",
            Shape.SAMPLE, Aggregation.LATEST, Family.BODY),

        // --- Workout ---
        // Lands in `sessions` with kind=workout plus typed detail JSON (plan §9.1), not in
        // `interval_records` — hence the null metricId, same as sleep above.
        Entry("ExerciseSessionRecord", ExerciseSessionRecord::class, null, "s",
            Shape.WORKOUT_SESSION, Aggregation.DURATION, Family.WORKOUT),
    )

    private val byPlatformType: Map<String, Entry> = entries.associateBy { it.platformType }

    fun entry(platformType: String): Entry? = byPlatformType[platformType]

    /** The types the adapter actually reads. Deferred entries are documentation, not work. */
    val ingested: List<Entry> = entries.filter { it.isIngested }

    /**
     * READ permissions for every ingested type. Deferred types are excluded deliberately: asking
     * for a permission BADAN does not act on spends the user's trust on nothing, and Play Data
     * Safety would then declare a data type that never enters the app.
     */
    val permissions: Set<String> = ingested.map { it.readPermission }.toSet()

    /** Permissions for one consent family — the unit the staged request flow asks in. */
    fun permissions(family: Family): Set<String> =
        ingested.filter { it.family == family }.map { it.readPermission }.toSet()

    // MARK: - History-window honesty (Phase-0 exit criterion)

    /**
     * How far back Health Connect will serve reads without `READ_HEALTH_DATA_HISTORY`.
     *
     * BADAN deliberately does not request that permission (see the AndroidManifest comment), so
     * 30 days is the real, achievable window for every type — a first connect cannot produce the
     * 90 days of history the ingest range asks for, no matter what the range says. This constant
     * exists so the backfill banner can state that instead of the app quietly showing a 90-day
     * chart that is two-thirds empty and letting the user conclude their watch was not recording.
     *
     * It is per type rather than a single global constant because that is the honest shape: if a
     * future type ever carries a different limit (or the history permission is granted for some
     * families and not others), the banner must be able to say so per type without this becoming
     * a lie by aggregation. Today every type returns the same number, and that is a fact about
     * Health Connect, not an accident of the code.
     */
    const val defaultHistoryWindowDays: Int = 30

    fun achievableWindowDays(@Suppress("UNUSED_PARAMETER") entry: Entry): Int = defaultHistoryWindowDays

    // MARK: - Multi-writer disambiguation (plan §10, Health Connect row)

    /**
     * Baseline dedup priority per writing app.
     *
     * This matters more on Android than on iOS and the asymmetry is structural, not incidental:
     * on iOS the overwhelmingly common case is one Apple-owned writer per metric, so priority is
     * mostly "watch beats phone". On Android, Samsung Health, Google Fit, Fitbit and a vendor app
     * routinely all write steps and sleep for the same night, and Health Connect does not rank
     * them — it hands back every writer's version and expects the reader to decide. Without a
     * table here, `IngestionPipeline.inferredPriority` falls through to its English substring
     * match on a *package name* ("com.sec.android.app.shealth" contains neither "watch" nor
     * "phone") and every writer ties at 0, which makes dedup outcomes depend on id ordering.
     *
     * Values are intentionally coarse and mid-scale so [deviceBonus] and a user override both
     * have room to move a writer without a rewrite. Ordering rationale: a first-party wearable
     * platform that owns the sensor outranks a phone-side aggregator that mostly re-publishes
     * other apps' data, and Health Connect's own package (a re-publisher of last resort, and the
     * id used when a package cannot be determined) sits at the bottom.
     *
     * This is a *default*, not a policy. See [writerPriority]'s `overrides`.
     */
    val writerPriorityDefaults: Map<String, Int> = mapOf(
        "com.google.android.apps.fitness" to 40,        // Google Fit — phone-side aggregator
        "com.google.android.apps.healthdata" to 10,     // Health Connect itself / unknown writer
        "com.sec.android.app.shealth" to 60,            // Samsung Health (Galaxy Watch sensor owner)
        "com.fitbit.FitbitMobile" to 60,
        "com.garmin.android.apps.connectmobile" to 60,
        "com.whoop.android" to 60,
        "com.ouraring.oura" to 60,
        "com.polar.polarflow" to 55,
        "com.withings.wiscale2" to 55,                  // Withings — scales + watches
        "com.xiaomi.wearable" to 50,
        "com.huawei.health" to 50,
    )

    /** Priority for a writer whose package is not in [writerPriorityDefaults]. */
    const val unknownWriterPriority: Int = 30

    /**
     * Device-class adjustment, applied on top of the package baseline. `Metadata.device.type` is
     * the one first-party signal about the hardware that actually took the reading, and it is far
     * more trustworthy than the name-substring heuristics both platforms fall back to — it is an
     * enum the writing app sets, not free text in a user's chosen language.
     *
     * A scale is rated above a phone because the metric it writes (weight, body fat, lean mass) is
     * one it genuinely measures, whereas a phone writing weight is transcribing a number a human
     * typed. It is rated below a wrist device only because wrist devices write far more of the
     * families where dedup actually fires; nothing about this ordering is a claim about accuracy.
     */
    fun deviceBonus(deviceType: Int?): Int = when (deviceType) {
        Device.TYPE_WATCH, Device.TYPE_RING, Device.TYPE_FITNESS_BAND, Device.TYPE_CHEST_STRAP -> 8
        Device.TYPE_SCALE -> 4
        Device.TYPE_PHONE -> 2
        else -> 0
    }

    /**
     * Final dedup priority for one writer, in the same "higher wins" scale
     * `SourceDescriptor.priority` uses.
     *
     * [overrides] is the editable layer the plan requires ("provenance shows package id, priority
     * editable", §20 EPIC-02 risks): a user who trusts their Garmin over Samsung Health for sleep
     * must be able to say so, because no defensible default ordering exists for that pair. An
     * override is absolute — it replaces the computed value rather than nudging it — so a user's
     * stated preference cannot be silently outvoted by a [deviceBonus] they never saw.
     *
     * Known limitation, stated rather than hidden: priority is per *writer*, not per
     * (writer, family). Garmin might deserve to win sleep while Samsung Health wins steps, and
     * this signature cannot express that. Making it possible means `DedupLite.reconcile`'s
     * `priorityForSource` lambda takes a family, which is a change to a rule shared with iOS and
     * therefore a cross-platform contract change, not an Android detail. Deliberately deferred
     * while the only two dedup rules (sleep and workout overlap) would order writers identically.
     */
    fun writerPriority(
        packageName: String,
        deviceType: Int? = null,
        overrides: Map<String, Int> = emptyMap(),
    ): Int {
        overrides[packageName]?.let { return it }
        val base = writerPriorityDefaults[packageName] ?: unknownWriterPriority
        return base + deviceBonus(deviceType)
    }

    // MARK: - Identity

    /**
     * The `external_id` an ingested Health Connect row is keyed by — the idempotency key that
     * makes re-ingest a no-op (`MeasurementRepository` looks a row up by
     * (metric_id, external_id, source_id) before inserting).
     *
     * `Metadata.id` is Health Connect's own stable per-record UUID and survives the record being
     * updated by its writer, which is exactly the property needed: a corrected weight entry
     * updates BADAN's row instead of appearing beside it. It is deliberately NOT prefixed with
     * the metric or the package — both are already columns in the identity lookup, and folding
     * them into the id here would mean an id that changes shape if either is ever renamed.
     */
    fun externalId(recordId: String): String = recordId

    /**
     * Per-sample external id for record types that carry a series of readings inside one record
     * (heart rate, skin temperature deltas). The parent record's id alone is not unique across
     * its own samples, so every sample would upsert on top of the previous one and a 500-sample
     * heart-rate record would store exactly one reading.
     *
     * Keyed by the sample's timestamp rather than its index because Health Connect does not
     * guarantee sample order within a record, and an index-keyed id would reshuffle every row's
     * identity when a re-read returns the same samples in a different order.
     */
    fun sampleExternalId(recordId: String, sampleTimeMillis: Long): String = "$recordId#$sampleTimeMillis"

    /**
     * Route id for a workout's GPS trace: derived from the session's record id rather than a
     * fresh ULID, so re-reading the same workout replaces its route instead of accumulating a new
     * copy of the same trace on every sync. (Routes are stored wholesale — see the `route_points`
     * comment in Schema.kt — so replacement is the only correct update.)
     */
    fun routeExternalId(sessionRecordId: String): String = "route:$sessionRecordId"

    // MARK: - Measured timezone (DATA-07 parity)

    /**
     * The zone id stamped on a row's provenance, and the value `DayAttribution` buckets days and
     * nights by.
     *
     * Health Connect stores a `ZoneOffset` per record — the offset in force where and when the
     * reading was taken — not an IANA zone name, so this returns a fixed-offset id ("GMT+03:00")
     * rather than "Asia/Riyadh". That is less information than iOS's `HKMetadataKeyTimeZone`
     * gives, and it is deliberately not upgraded by guessing a region from the offset: a dozen
     * IANA zones share +03:00, so any such guess would be a fabricated fact on a provenance row
     * whose entire purpose is to not contain fabricated facts. The offset is exactly what day
     * attribution needs and no more than what Health Connect actually knows.
     *
     * `TimeZone.getTimeZone` accepts the "GMT+hh:mm" form and silently falls back to GMT for
     * anything it does not recognize, which is why the string is built in that form here rather
     * than passed through as `ZoneOffset.getId()` ("+03:00", which would silently resolve to UTC
     * and misfile every night by the offset).
     *
     * Returns null when the record carries no offset; the caller then falls back to the device's
     * current zone and stamps `QualityFlag.TZ_ASSUMED`, the same contract as iOS's
     * `measuredTimeZone(for:)`.
     */
    fun zoneId(offset: ZoneOffset?): String? {
        val id = offset?.id ?: return null
        // ZoneOffset.getId() renders UTC as "Z"; "GMT" + "Z" is not a zone.
        return if (id == "Z") "GMT" else "GMT$id"
    }
}
