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

    // Respiratory
    const val respiratoryRate = "respiratory.rate"
    const val spo2 = "respiratory.spo2"

    // Nutrition (from logged meals, aggregated daily)
    const val energyIn = "nutrition.energy_in"
    const val protein = "nutrition.protein"
    const val water = "nutrition.water"

    /** Metrics that get seeded with time-series data in the demo dataset. */
    val seededTimeSeries: List<String> = listOf(
        restingHeartRate, hrv, steps, activeEnergy, weight, spo2, respiratoryRate,
    )
}
