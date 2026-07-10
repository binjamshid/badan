package net.albayyan.badan.domain

/**
 * Typed constants for the metric ids that BADAN code references directly (seeding, ingestion,
 * derivation). Apps never scatter raw metric-id strings; everything else comes from the
 * data-driven registry. Keep in sync with `packages/metric-ontology/registry.json`.
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

    // Activity
    const val steps = "activity.steps"
    const val distance = "activity.distance"
    const val activeEnergy = "activity.active_energy"
    const val exerciseMinutes = "activity.exercise_minutes"

    // Body
    const val weight = "body.weight"
    const val bmi = "body.bmi"

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
