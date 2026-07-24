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

    // Sleep intelligence (EPIC-24, derived per localNight by SleepIntelligenceEngine).
    // `sleepPerformance` is also a soft input to EPIC-25's Readiness composite.
    public static let sleepNeed = "sleep.need"
    public static let sleepPerformance = "sleep.performance"
    public static let sleepDebt = "sleep.debt"
    public static let sleepConsistency = "sleep.consistency"
    public static let sleepDisturbances = "sleep.disturbances"

    // Heart
    public static let heartRate = "heart.hr"
    public static let restingHeartRate = "heart.rhr"
    public static let hrv = "heart.hrv"
    public static let vo2Max = "heart.vo2max"

    // Activity
    public static let steps = "activity.steps"
    public static let distance = "activity.distance"
    public static let activeEnergy = "activity.active_energy"
    public static let restingEnergy = "activity.resting_energy"
    public static let floors = "activity.floors"
    public static let exerciseMinutes = "activity.exercise_minutes"

    // Body
    public static let weight = "body.weight"
    public static let bmi = "body.bmi"
    public static let bodyFatPercentage = "body.fat_pct"
    public static let leanMass = "body.lean_mass"
    /// Overnight wrist temperature expressed as a DEVIATION from the person's own usual level, in
    /// °C — never an absolute skin temperature (registry marks it non-baseline-eligible for exactly
    /// this reason). The Health Monitor (EPIC-27) renders it deviation-only; Android already carries
    /// the mirror constant `MetricId.wristTempDeviation`.
    public static let wristTempDeviation = "body.wrist_temp_deviation"
    /// A blood glucose reading from HealthKit's `bloodGlucose` type — platform-written only (A21/
    /// ADR-0010, D-26): the reading came from a connected sensor/meter/CGM app that already wrote
    /// it to Apple Health, never a BADAN-owned vendor integration. `sensitiveClass: sensitivePlus`
    /// in the registry (excluded from a default export), but storage is `badan.db` via the same
    /// `IngestionPipeline` every other widened HealthKit metric uses — see the registry's own
    /// v0.2.2 note and `docs/DECISIONS.md`'s D-26 scope note for why. Every surface that renders
    /// this value must also render `GlucoseDisclaimer.text` ("never for treatment decisions").
    public static let glucose = "body.glucose"

    // Respiratory
    public static let respiratoryRate = "respiratory.rate"
    public static let spo2 = "respiratory.spo2"

    // Nutrition (from logged meals, aggregated daily)
    public static let energyIn = "nutrition.energy_in"
    public static let protein = "nutrition.protein"
    public static let water = "nutrition.water"

    // Derived scores
    /// The morning Readiness composite (EPIC-25, `ReadinessEngine`). v2 rows are stamped
    /// `composite.readiness_score@2.0.0`; the interim v1 composite `BaselineEngine` still appends
    /// keeps its own id under I2. Android carries the mirror constant `MetricId.readinessScore`.
    public static let readinessScore = "readiness.score"

    /// The daily cardiovascular effort score (EPIC-26, `EffortEngine`) — weighted time-in-zone on the
    /// published saturating curve. A zone-based day carries the registry's `score_0_100` unit; a
    /// sparse-HR (e.g. phone-only) day carries the reduced-input activity load under this SAME id with
    /// an activity unit instead, mutually exclusive per day (see `EffortEngine`). Mirror: `MetricId.effortDay`.
    public static let effortDay = "effort.day"

    /// Per-workout cardiovascular effort (EPIC-26) — the same curve applied over one session's window,
    /// keyed `session:<id>`. Mirror: `MetricId.effortWorkout`.
    public static let effortWorkout = "effort.workout"

    /// The DAILY autonomic-load trend (EPIC-34, `StressEngine`) — emitted only when the daytime-HRV
    /// density gate allows it, always keyed `day:<key>`, and never a live or instantaneous reading.
    /// The registry classes it `sensitivePlus`, so it is excluded from any export that does not opt
    /// into sensitive data. Mirror: `MetricId.stressDayTrend`.
    public static let stressDayTrend = "stress.day_trend"

    /// The NAMESPACE the journal correlation engine writes under (EPIC-29). Never a metric id on
    /// its own: concrete findings are `journal.correlation.<behaviorId>.<scoreId>`, composed by
    /// `CorrelationMetricID`. The registry carries this row (and only this row) for the family, so
    /// anything resolving a finding id resolves its unit, name and — load-bearing —
    /// `sensitiveClass: sensitivePlus` from here. Mirror: `MetricId.journalCorrelationNamespace`.
    public static let journalCorrelationNamespace = "journal.correlation"

    /// The daily scores the correlation engine compares behaviour-present against behaviour-absent
    /// days for. Deliberately a short, closed list rather than "every derived metric": each one is
    /// a published composite with a documented meaning, and correlating a behaviour against every
    /// id in the registry would be a multiple-comparisons machine that manufactures findings.
    public static let correlatedScores: [String] = [readinessScore, sleepPerformance, effortDay]

    /// Metrics that get seeded with time-series data in the demo dataset.
    public static let seededTimeSeries: [String] = [
        restingHeartRate, hrv, steps, activeEnergy, weight, spo2, respiratoryRate,
    ]
}
