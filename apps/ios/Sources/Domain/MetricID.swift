import Foundation

/// Typed constants for the metric ids that BADAN code references directly (seeding,
/// ingestion, derivation). Apps never scatter raw metric-id strings; everything else comes
/// from the data-driven registry. Keep in sync with `packages/metric-ontology/registry.json`.
public enum MetricID {
    // Sleep
    public static let timeAsleep = "sleep.time_asleep"
    public static let timeInBed = "sleep.time_in_bed"
    public static let sleepEfficiency = "sleep.efficiency"
    public static let sleepDeep = "sleep.deep"
    public static let sleepRem = "sleep.rem"
    public static let sleepLight = "sleep.light"
    public static let sleepAwake = "sleep.awake"

    // Heart
    public static let heartRate = "heart.hr"
    public static let restingHeartRate = "heart.rhr"
    public static let hrv = "heart.hrv"

    // Activity
    public static let steps = "activity.steps"
    public static let distance = "activity.distance"
    public static let activeEnergy = "activity.active_energy"
    public static let exerciseMinutes = "activity.exercise_minutes"

    // Body
    public static let weight = "body.weight"
    public static let bmi = "body.bmi"

    // Respiratory
    public static let respiratoryRate = "respiratory.rate"
    public static let spo2 = "respiratory.spo2"

    // Nutrition (from logged meals, aggregated daily)
    public static let energyIn = "nutrition.energy_in"
    public static let protein = "nutrition.protein"
    public static let water = "nutrition.water"

    /// Metrics that get seeded with time-series data in the demo dataset.
    public static let seededTimeSeries: [String] = [
        restingHeartRate, hrv, steps, activeEnergy, weight, spo2, respiratoryRate,
    ]
}
