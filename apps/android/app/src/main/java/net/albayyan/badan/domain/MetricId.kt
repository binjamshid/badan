package net.albayyan.badan.domain

/**
 * Typed constants for the key metric ids that BADAN code references directly (seeding, ingestion,
 * derivation) — a subset of the ids in `packages/metric-ontology/registry.json`, not the full set.
 * Deliberately not a count: the registry grows (44 at v0.1.0, 72 at v0.2.0) and a literal here goes
 * stale silently. `MetricRegistry`'s health-check floor is the live assertion. Metric ids outside this list (most `nutrition.*`, all `subjective.*`/`symptoms.*`,
 * and several others) are referenced as raw strings from the registry today; add a constant here
 * when a call site needs compile-time safety for one of them. Keep existing entries in sync with
 * the registry.
 */
object MetricId {
    // Sleep
    const val timeAsleep = "sleep.time_asleep"
    const val timeInBed = "sleep.time_in_bed"
    const val sleepEfficiency = "sleep.efficiency"
    const val sleepDeep = "sleep.deep"
    const val sleepRem = "sleep.rem"
    const val sleepLight = "sleep.light"
    const val sleepAwake = "sleep.awake"

    // Sleep intelligence (EPIC-24, derived per localNight by SleepIntelligenceEngine).
    // `sleepPerformance` is also a soft input to EPIC-25's Readiness composite.
    const val sleepNeed = "sleep.need"
    const val sleepPerformance = "sleep.performance"
    const val sleepDebt = "sleep.debt"
    const val sleepConsistency = "sleep.consistency"
    const val sleepDisturbances = "sleep.disturbances"

    /**
     * BADAN's 1-5 read of how the body is trending, on the SAME scale as the manually logged
     * `subjective.mood`. Deliberately a separate id: the self-report is the record and this is an
     * estimate beside it — a derived value must never be written into the metric the user fills in
     * themselves. Mirror of iOS `MetricID.moodEstimate`.
     */
    const val moodEstimate = "subjective.mood_estimate"

    // Heart
    const val heartRate = "heart.hr"
    const val restingHeartRate = "heart.rhr"
    const val hrv = "heart.hrv"
    const val vo2Max = "heart.vo2max"

    // Activity
    const val steps = "activity.steps"
    const val distance = "activity.distance"
    const val activeEnergy = "activity.active_energy"
    const val exerciseMinutes = "activity.exercise_minutes"
    const val floors = "activity.floors"

    // Body
    const val weight = "body.weight"
    const val bmi = "body.bmi"
    const val bodyFatPct = "body.fat_pct"
    const val leanMass = "body.lean_mass"

    /**
     * Skin/wrist temperature as a *deviation* from the wearer's own baseline, never an absolute
     * temperature (plan §4 rule 9). Both platforms' sources agree with that framing — Health
     * Connect's `SkinTemperatureRecord` is a baseline plus deltas, HealthKit's wrist temperature
     * is documented as sleeping-wrist deviation — so BADAN storing a deviation is not a
     * simplification, it is what the sensor reports.
     */
    const val wristTempDeviation = "body.wrist_temp_deviation"

    /**
     * A blood glucose reading from Health Connect — platform-written only (A21/ADR-0010, D-26):
     * the reading came from a connected sensor/meter/CGM app that already wrote it to Health
     * Connect, never a BADAN-owned vendor integration. `sensitiveClass: sensitivePlus` in the
     * registry (excluded from a default export). Mirror of iOS `MetricID.glucose`.
     */
    const val glucose = "body.glucose"

    // Respiratory
    const val respiratoryRate = "respiratory.rate"
    const val spo2 = "respiratory.spo2"

    // Nutrition (from logged meals, aggregated daily)
    const val energyIn = "nutrition.energy_in"
    const val protein = "nutrition.protein"
    const val water = "nutrition.water"

    // Derived scores
    /**
     * The morning Readiness composite (EPIC-25, `ReadinessEngine`). v2 rows are stamped
     * `composite.readiness_score@2.0.0`; the interim v1 composite `BaselineEngine` still appends keeps
     * its own id under I2. Mirror of iOS `MetricID.readinessScore`.
     */
    const val readinessScore = "readiness.score"

    /**
     * The daily cardiovascular effort score (EPIC-26, `EffortEngine`) — weighted time-in-zone on the
     * published saturating curve. A zone-based day carries the registry's `score_0_100` unit; a
     * sparse-HR (e.g. phone-only) day carries the reduced-input activity load under this SAME id with
     * an activity unit instead, mutually exclusive per day. Mirror of iOS `MetricID.effortDay`.
     */
    const val effortDay = "effort.day"

    /**
     * Per-workout cardiovascular effort (EPIC-26) — the same curve applied over one session's window,
     * keyed `session:<id>`. Mirror of iOS `MetricID.effortWorkout`.
     */
    const val effortWorkout = "effort.workout"

    /**
     * The DAILY autonomic-load trend (EPIC-34, `StressEngine`) — emitted only when the daytime-HRV
     * density gate allows it, always keyed `day:<key>`, and never a live or instantaneous reading.
     * The registry classes it `sensitivePlus`, so it is excluded from any export that does not opt
     * into sensitive data. Mirror of iOS `MetricID.stressDayTrend`.
     */
    const val stressDayTrend = "stress.day_trend"

    /**
     * The NAMESPACE the journal correlation engine writes under (EPIC-29). Never a metric id on
     * its own: concrete findings are `journal.correlation.<behaviorId>.<scoreId>`, composed by
     * [net.albayyan.badan.domain.derivation.CorrelationMetricId]. The registry carries this row
     * (and only this row) for the family, so anything resolving a finding id resolves its unit,
     * name and — load-bearing — `sensitiveClass: sensitivePlus` from here. Mirror of iOS
     * `MetricID.journalCorrelationNamespace`.
     */
    const val journalCorrelationNamespace = "journal.correlation"

    /**
     * The daily scores the correlation engine compares behaviour-present against behaviour-absent
     * days for. Deliberately a short, closed list rather than "every derived metric": each one is
     * a published composite with a documented meaning, and correlating a behaviour against every
     * id in the registry would be a multiple-comparisons machine that manufactures findings.
     */
    val correlatedScores: List<String> = listOf(readinessScore, sleepPerformance, effortDay)

    /** Metrics that get seeded with time-series data in the demo dataset. */
    val seededTimeSeries: List<String> = listOf(
        restingHeartRate, hrv, steps, activeEnergy, weight, spo2, respiratoryRate,
    )
}
