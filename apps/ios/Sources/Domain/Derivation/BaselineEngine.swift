import Foundation

/// Recomputes personal "normal" bands (rolling median + MAD over a 14-day window) and the
/// two MVP composites (sleep efficiency, readiness score). Everything is append-only and
/// driven by an injected `Clock`, so recompute is deterministic and auditable (INVARIANT I2).
final class BaselineEngine {
    /// Frozen identity of the baseline method — carried on every baseline row for traceability.
    static let baselineAlgorithm = AlgorithmVersion(
        algorithmId: "baseline.rolling_median_mad", semver: "1.0.0",
        params: ["windowDays": 14], introducedIn: "1.0.0")
    static let efficiencyAlgorithm = AlgorithmVersion(
        algorithmId: "composite.sleep_efficiency", semver: "1.0.0", introducedIn: "1.0.0")
    static let readinessAlgorithm = AlgorithmVersion(
        algorithmId: "composite.readiness_score", semver: "1.0.0", introducedIn: "1.0.0")

    /// Rolling window length in days and the "enough to be honest" threshold below which a
    /// baseline stays provisional (wellness-safe honesty about thin data).
    static let windowDays = 14
    static let minPointsForConfident = 7

    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         registry: MetricRegistry, clock: Clock, deviceId: String) {
        self.derivation = derivation
        self.measurements = measurements
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
    }

    // MARK: - Single-metric baseline

    /// Rebuild the baseline band for one metric as of `asOf`. Gathers up to the last 14 daily
    /// values (latest record per local day) and materializes a fresh baseline row. No-op when
    /// the metric has no interval data in the window.
    func recompute(metricId: String, asOf: Date) throws {
        let from = asOf.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let byDay = try latestPerDay(metricId: metricId, from: from, to: asOf)
        guard !byDay.isEmpty else { return }

        // Most recent `windowDays` distinct days, in day order.
        let days = byDay.keys.sorted().suffix(Self.windowDays)
        let values = days.compactMap { byDay[$0]?.value }
        guard !values.isEmpty else { return }

        let center = Self.median(values)
        let spread = Self.mad(values, center: center)
        let scaled = 1.4826 * spread
        let unit = registry.definitionOrFallback(metricId).canonicalUnit
        let n = values.count

        let baseline = Baseline(
            id: ULID.newID(), metricId: metricId, windowDays: Self.windowDays,
            center: center, spread: spread, bandLow: center - scaled, bandHigh: center + scaled,
            nPoints: n, provisional: n < Self.minPointsForConfident,
            algorithmVersion: Self.baselineAlgorithm.id, validFrom: asOf,
            computedAt: clock.now(), unit: unit)

        // Append-only should still mean "append only when something actually changed": skip
        // the write when the latest existing baseline is numerically identical, so a future
        // periodic recompute doesn't grow baselines/derived_values unboundedly by re-confirming
        // unchanged days on every run.
        if let existing = try derivation.latestBaseline(metricId: metricId), existing.nPoints == n,
           Self.approximatelyEqual(existing.center, center), Self.approximatelyEqual(existing.bandLow, baseline.bandLow),
           Self.approximatelyEqual(existing.bandHigh, baseline.bandHigh) {
            return
        }
        try derivation.upsertBaseline(baseline)
    }

    // MARK: - Full recompute + composites

    /// Rebuild every baseline-eligible metric that has interval data, then append the two
    /// per-day composites (sleep efficiency and readiness score) as derived values. When
    /// `metricIds` is given, only those baseline-eligible metrics are recomputed (the
    /// composites still consider the full window, since they read across metrics); `nil`
    /// (the default) recomputes everything, preserving today's full-recompute behavior.
    func recomputeAll(asOf: Date, metricIds: [String]? = nil) throws {
        let eligible = metricIds.map { ids in registry.baselineEligible.filter { ids.contains($0.metricId) } }
            ?? registry.baselineEligible
        for def in eligible {
            try recompute(metricId: def.metricId, asOf: asOf)
        }
        // Fetched once and shared: both composites below independently need time_asleep for
        // the same window, so this avoids querying it twice per recompute cycle.
        let from = asOf.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let asleepByDay = try latestPerDay(metricId: MetricID.timeAsleep, from: from, to: asOf)
        try appendSleepEfficiency(asleepByDay: asleepByDay, asOf: asOf)
        try appendReadinessScore(asleepByDay: asleepByDay, asOf: asOf)
    }

    /// sleep.efficiency = time_asleep / time_in_bed * 100, per local day, for every day that
    /// has both inputs. Each row carries an InputManifest referencing the two interval ids.
    private func appendSleepEfficiency(asleepByDay: [String: IntervalRecord], asOf: Date) throws {
        let from = asOf.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let inBedByDay = try latestPerDay(metricId: MetricID.timeInBed, from: from, to: asOf)

        for day in asleepByDay.keys.sorted() {
            guard let asleep = asleepByDay[day], let inBed = inBedByDay[day], inBed.value > 0 else { continue }
            let efficiency = min(100, max(0, asleep.value / inBed.value * 100))
            let periodKey = "day:" + day
            if let existing = try derivation.latestDerived(metricId: MetricID.sleepEfficiency, periodKey: periodKey),
               Self.approximatelyEqual(existing.value, efficiency) {
                continue
            }
            let manifest = InputManifest(id: ULID.newID(), inputs: [
                InputManifest.Input(recordId: asleep.id, metricId: MetricID.timeAsleep, value: asleep.value),
                InputManifest.Input(recordId: inBed.id, metricId: MetricID.timeInBed, value: inBed.value),
            ])
            try derivation.insertManifest(manifest)
            try derivation.appendDerived(makeDerived(
                metricId: MetricID.sleepEfficiency, value: efficiency, unit: "percent",
                day: day, provisional: false, algorithm: Self.efficiencyAlgorithm,
                manifestId: manifest.id))
        }
    }

    /// readiness.score (0–100), per local day, from how time_asleep and rhr sit against their
    /// baselines: more sleep within/above band lifts it, higher rhr above band lowers it.
    private func appendReadinessScore(asleepByDay: [String: IntervalRecord], asOf: Date) throws {
        let from = asOf.addingTimeInterval(-Double(Self.windowDays) * 86_400)
        let rhrByDay = try latestPerDay(metricId: MetricID.restingHeartRate, from: from, to: asOf)

        let sleepBaseline = try derivation.latestBaseline(metricId: MetricID.timeAsleep)
        let rhrBaseline = try derivation.latestBaseline(metricId: MetricID.restingHeartRate)

        for day in asleepByDay.keys.sorted() {
            guard let sleep = asleepByDay[day], let rhr = rhrByDay[day] else { continue }

            var score = 50.0
            if let sb = sleepBaseline { score += Self.clamp(sb.z(of: sleep.value), -2, 2) * 12.5 }
            if let rb = rhrBaseline { score -= Self.clamp(rb.z(of: rhr.value), -2, 2) * 12.5 }
            score = min(100, max(0, score))
            let provisional = (sleepBaseline?.provisional ?? true) || (rhrBaseline?.provisional ?? true)

            let periodKey = "day:" + day
            if let existing = try derivation.latestDerived(metricId: "readiness.score", periodKey: periodKey),
               Self.approximatelyEqual(existing.value, score), existing.provisional == provisional {
                continue
            }
            let manifest = InputManifest(id: ULID.newID(), inputs: [
                InputManifest.Input(recordId: sleep.id, metricId: MetricID.timeAsleep, value: sleep.value),
                InputManifest.Input(recordId: rhr.id, metricId: MetricID.restingHeartRate, value: rhr.value),
            ])
            try derivation.insertManifest(manifest)
            try derivation.appendDerived(makeDerived(
                metricId: "readiness.score", value: score, unit: "score_0_100",
                day: day, provisional: provisional, algorithm: Self.readinessAlgorithm,
                manifestId: manifest.id))
        }
    }

    private func makeDerived(metricId: String, value: Double, unit: String, day: String,
                             provisional: Bool, algorithm: AlgorithmVersion, manifestId: String) -> DerivedValue {
        let now = clock.now()
        return DerivedValue(
            id: ULID.newID(), metricId: metricId, value: value, unit: unit,
            periodKey: "day:" + day, provisional: provisional,
            algorithmId: algorithm.algorithmId, algorithmVersion: algorithm.semver,
            inputManifestId: manifestId, computedAt: now, updatedAt: now, originDeviceId: deviceId)
    }

    // MARK: - Helpers

    /// Latest interval record per local day (attributed in the record's own timezone) for a
    /// metric over a window. "Latest" means most recently written (`updatedAt`), not latest
    /// start time — a corrected aggregate that supersedes an earlier-starting one must win
    /// even if its own `startAt` is earlier than the value it corrects.
    private func latestPerDay(metricId: String, from: Date, to: Date) throws -> [String: IntervalRecord] {
        let records = try measurements.intervalRecords(metricId: metricId, from: from, to: to)
        var byDay: [String: IntervalRecord] = [:]
        for r in records {
            let day = DayAttribution.localDayKey(r.startAt, tz: r.tzId)
            if let existing = byDay[day], existing.updatedAt >= r.updatedAt { continue }
            byDay[day] = r
        }
        return byDay
    }

    /// Floating-point equality with tolerance, used to decide whether a freshly-recomputed
    /// baseline/derived value actually changed from what's already stored.
    private static func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }

    static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Median absolute deviation about `center` — the robust spread the band is built from.
    static func mad(_ xs: [Double], center: Double) -> Double {
        median(xs.map { abs($0 - center) })
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
}
