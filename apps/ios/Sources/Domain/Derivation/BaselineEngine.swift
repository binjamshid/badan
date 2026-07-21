import Foundation

/// Recomputes personal "normal" bands and the two MVP composites (sleep efficiency, readiness
/// score). Bands are robust median + MAD over a PER-METRIC trailing window and transform, driven
/// entirely by `BaselineSpec` (the algorithm contract) rather than by constants baked in here:
/// HRV is banded in the log domain over 60 days, RHR/RR/temp over 14, sleep-need inputs over 28,
/// everything else over the default window (plan §18). MAD-based outlier rejection removes single
/// wild readings before the band is drawn, and a band stays `provisional` until it has enough
/// points to be honest about. Everything is append-only and driven by an injected `Clock`, so
/// recompute is deterministic and auditable (INVARIANT I2).
///
/// The heavy math (`computeBaseline`, `classifyTier`) is pure and static so the pure-JVM Android
/// port produces byte-identical numbers from the same inputs — that cross-platform identity is the
/// acceptance golden, not an incidental nicety.
final class BaselineEngine {
    /// Frozen algorithm identity, resolved from the contract (never hand-written here — a change is
    /// a contract diff + semver bump, and old baseline rows keep their old id under I2).
    static var baselineAlgorithm: AlgorithmVersion { BaselineSpec.defaultShared.algorithm }
    /// The two legacy MVP composites keep their own frozen identities: they are pre-EPIC-24/25
    /// scaffolding (a real `SleepIntelligenceEngine`/`ReadinessEngine` supersede them), carry no
    /// tuning constants, and must not be rewired onto the Phase-2 contract entries here.
    static let efficiencyAlgorithm = AlgorithmVersion(
        algorithmId: "composite.sleep_efficiency", semver: "1.0.0", introducedIn: "1.0.0")
    static let readinessAlgorithm = AlgorithmVersion(
        algorithmId: "composite.readiness_score", semver: "1.0.0", introducedIn: "1.0.0")

    /// The "enough to be honest" point count below which a baseline stays provisional. Kept as a
    /// static (sourced from the contract, not a literal) because the Home calibration UI reads it
    /// (`BaselineEngine.minPointsForConfident`); it is the floor of the per-metric provisional gate,
    /// which also requires filling half the window (see `classifyTier`).
    static var minPointsForConfident: Int { BaselineSpec.defaultShared.minPoints }

    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String
    private let spec: BaselineSpec

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         registry: MetricRegistry, clock: Clock, deviceId: String,
         spec: BaselineSpec = .defaultShared) {
        self.derivation = derivation
        self.measurements = measurements
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
        self.spec = spec
    }

    // MARK: - Single-metric baseline

    /// Rebuild the baseline band for one metric as of `asOf`, under a covariate context (EPIC-39
    /// prep — `"default"` is the unconditioned baseline; a cycle phase or other context stores a
    /// PARALLEL band additively, never overwriting the default). Gathers the metric's per-day
    /// values over ITS OWN window and materializes a fresh baseline row. No-op when the metric has
    /// no data in the window, or when the spec did not load (a missing contract computes nothing
    /// rather than inventing a band).
    ///
    /// `tz` defaults to the device's current timezone (matching every other `TimeZone.current
    /// .identifier`-defaulted call site in this app) since callers today don't thread a per-record
    /// timezone through; it's used only for calendar day-stepping (DATA-11), not to re-attribute
    /// any record's own day (each record is still keyed by its own `tzId` in `latestPerDay`).
    func recompute(metricId: String, asOf: Date, tz: String = TimeZone.current.identifier,
                   context: String = "default") throws {
        guard spec.isLoaded else { return }
        let resolution = spec.resolve(metricId)

        // (DATA-10) Exclude the evaluation day itself from the window its own baseline band is
        // built from — otherwise today's value is judged against a band that contains today's own
        // value. (DATA-11) Day-stepping goes through `DayAttribution.addingDays` (Calendar-based,
        // DST-safe) instead of raw `86_400`-second arithmetic.
        let (from, to) = Self.baselineWindow(asOf: asOf, windowDays: resolution.windowDays, tz: tz)
        let byDay = try latestPerDay(metricId: metricId, from: from, to: to)
        guard !byDay.isEmpty else { return }

        // Most recent `windowDays` distinct days, in day order.
        let days = byDay.keys.sorted().suffix(resolution.windowDays)
        let values = days.compactMap { byDay[$0]?.value }
        guard let comp = Self.computeBaseline(values: values, resolution: resolution, spec: spec) else { return }

        let unit = registry.definitionOrFallback(metricId).canonicalUnit
        let baseline = Baseline(
            id: ULID.newID(), metricId: metricId, covariateContext: context,
            windowDays: resolution.windowDays, method: .medianMAD,
            center: comp.center, spread: comp.spread, bandLow: comp.bandLow, bandHigh: comp.bandHigh,
            nPoints: comp.nPoints, provisional: comp.provisional,
            algorithmVersion: spec.algorithm.id, validFrom: asOf,
            computedAt: clock.now(), unit: unit)

        // Append-only should still mean "append only when something actually changed": skip the
        // write when the latest existing baseline FOR THIS CONTEXT is numerically identical, so a
        // periodic recompute doesn't grow baselines unboundedly by re-confirming unchanged days.
        // The algorithm version is part of "identical": a version bump that reproduces the same band
        // must still append, or this metric's latest baseline would keep the OLD version id and the
        // recompute would go unrecorded (auditability; mirrors ReadinessEngine.persist).
        if let existing = try derivation.latestBaseline(metricId: metricId, context: context),
           existing.algorithmVersion == baseline.algorithmVersion,
           existing.nPoints == comp.nPoints,
           Self.approximatelyEqual(existing.center, comp.center),
           Self.approximatelyEqual(existing.bandLow, comp.bandLow),
           Self.approximatelyEqual(existing.bandHigh, comp.bandHigh) {
            return
        }
        try derivation.upsertBaseline(baseline)
    }

    // MARK: - Full recompute + composites (backfill entry point)

    /// Rebuild every baseline-eligible metric that has data, then append the two per-day
    /// composites. This is the clean recompute API the background lane (BGProcessing/Worker) calls
    /// for both the nightly pass and a post-import backfill: it is idempotent (a repeat run over
    /// unchanged data writes nothing) and append-only (a run over NEW history appends fresh rows,
    /// never mutating prior ones — I2), so a backfill job needs no special path. When `metricIds`
    /// is given, only those baseline-eligible metrics are recomputed; `nil` recomputes everything.
    /// `includeInterimReadinessComposite` gates ONLY the pre-EPIC-25 `readiness.score` composite this
    /// engine appends. Once the real `ReadinessEngine` (v2) is wired into the pipeline, BOTH would
    /// write `readiness.score` every recompute with different values, and — since each one's
    /// skip-if-identical check reads the LATEST row regardless of version — they would ping-pong a
    /// fresh row apiece on every run (an I2/idempotency break). The composition root passes `false` so
    /// the v2 engine owns `readiness.score` outright; the flag defaults to `true` so every existing
    /// direct caller (and the headless seed path that has no v2 engine) keeps the interim composite.
    /// `sleep.efficiency` is unaffected: it is a distinct metric with no other writer, still consumed
    /// by the score intents, so it is always emitted.
    func recomputeAll(asOf: Date, metricIds: [String]? = nil,
                      tz: String = TimeZone.current.identifier, context: String = "default",
                      includeInterimReadinessComposite: Bool = true) throws {
        guard spec.isLoaded else { return }
        // One transaction for the whole recompute instead of a commit+fsync per row: `derivation`
        // is the only repo written here (PERF-02 (audit 2026-07-12)).
        try derivation.transaction {
            let eligible = metricIds.map { ids in registry.baselineEligible.filter { ids.contains($0.metricId) } }
                ?? registry.baselineEligible
            for def in eligible {
                try recompute(metricId: def.metricId, asOf: asOf, tz: tz, context: context)
            }
            // Interim MVP composites (superseded by EPIC-24/25). Their lookback is the sleep-input
            // window — they are sleep/RHR-anchored — read from the spec rather than a literal.
            // Unlike the single-metric baseline window this INCLUDES the evaluation day: the
            // composites need TODAY's own values to score today against the (today-excluding)
            // baselines just computed.
            let lookback = spec.resolve(MetricID.timeAsleep).windowDays
            let from = DayAttribution.addingDays(-lookback, to: asOf, tz: tz)
            let asleepByDay = try latestPerDay(metricId: MetricID.timeAsleep, from: from, to: asOf)
            try appendSleepEfficiency(asleepByDay: asleepByDay, lookback: lookback, asOf: asOf, tz: tz)
            if includeInterimReadinessComposite {
                try appendReadinessScore(asleepByDay: asleepByDay, lookback: lookback, asOf: asOf, tz: tz)
            }
        }
    }

    /// sleep.efficiency = time_asleep / time_in_bed * 100, per local day, for every day that has
    /// both inputs. Each row carries an InputManifest referencing the two interval ids.
    private func appendSleepEfficiency(asleepByDay: [String: IntervalRecord], lookback: Int,
                                       asOf: Date, tz: String) throws {
        let from = DayAttribution.addingDays(-lookback, to: asOf, tz: tz)
        let inBedByDay = try latestPerDay(metricId: MetricID.timeInBed, from: from, to: asOf)

        for day in asleepByDay.keys.sorted() {
            guard let asleep = asleepByDay[day], let inBed = inBedByDay[day], inBed.value > 0 else { continue }
            let efficiency = min(100, max(0, asleep.value / inBed.value * 100))
            let periodKey = "day:" + day
            // Version-aware skip (mirrors ReadinessEngine.persist): re-appending an identical value
            // is wasteful, but a value that happens to be unchanged across an algorithm-VERSION bump
            // must still append, or this period's latest row keeps the old version id and the change
            // goes unrecorded — the auditability gap the anatomy fix closes elsewhere. sleep.efficiency
            // is a live surfaced score, so the guard has to check the version, not just the value.
            if let existing = try derivation.latestDerived(metricId: MetricID.sleepEfficiency, periodKey: periodKey),
               existing.algorithmId == Self.efficiencyAlgorithm.algorithmId,
               existing.algorithmVersion == Self.efficiencyAlgorithm.semver,
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
    ///
    /// Every day in the window is scored against the SAME latest (today-anchored) baseline — a
    /// historical day earlier in the window doesn't get its own contemporaneous band. That's an
    /// accepted approximation for now (the same simplification `InsightEngine.generate` makes).
    private func appendReadinessScore(asleepByDay: [String: IntervalRecord], lookback: Int,
                                      asOf: Date, tz: String) throws {
        let from = DayAttribution.addingDays(-lookback, to: asOf, tz: tz)
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
            // Version-aware skip, same reasoning as appendSleepEfficiency above: an unchanged value
            // across a version bump must still append so the latest row carries the new version id.
            if let existing = try derivation.latestDerived(metricId: "readiness.score", periodKey: periodKey),
               existing.algorithmId == Self.readinessAlgorithm.algorithmId,
               existing.algorithmVersion == Self.readinessAlgorithm.semver,
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

    // MARK: - Calibration read model

    /// The calibration state of a metric's current baseline (for the given context), for the score
    /// cards and anatomy sheet — "day 9 of 14", tier, window, transform. `nil` when no baseline
    /// exists yet. Pure read; the UI lane owns the bilingual strings.
    func calibration(metricId: String, context: String = "default") throws -> BaselineCalibration? {
        guard let baseline = try derivation.latestBaseline(metricId: metricId, context: context) else { return nil }
        return BaselineCalibration.from(baseline: baseline, spec: spec)
    }

    // MARK: - Pure baseline math (identical on both platforms — golden-tested)

    /// Compute the robust band for a metric's windowed per-day values. Pure and deterministic:
    /// transform → MAD-based outlier rejection → robust centre/spread → band → confidence tier.
    /// Returns `nil` when nothing usable survives (e.g. a log metric whose only values are ≤0).
    ///
    /// For a `log` transform the median and MAD are taken on `ln(value)` and the centre/band are
    /// exponentiated back, giving an ASYMMETRIC linear band (correct for a right-skewed vital). The
    /// stored `spread` is the linear-equivalent upper half-width divided by `madToSigma·bandSigmas`
    /// — for an identity metric that is exactly the MAD, and for a log metric it keeps
    /// `(bandHigh − centre)/spread == madToSigma·bandSigmas` so the anatomy sheet's derived
    /// multiplier and `Baseline.z(of:)` stay meaningful without the band having to be symmetric.
    static func computeBaseline(values: [Double], resolution: BaselineWindowResolution,
                                spec: BaselineSpec) -> BaselineComputation? {
        let isLog = resolution.transform == .log
        // A log-normal vital cannot take a non-positive value; drop rather than clamp so a sensor
        // zero is treated as missing, not as ln(0) = −∞ dragging the whole band down.
        let usable = isLog ? values.filter { $0 > 0 } : values
        guard !usable.isEmpty else { return nil }
        let working = isLog ? usable.map { Foundation.log($0) } : usable

        // MAD-based outlier rejection in the working (post-transform) domain. Skipped when MAD is
        // exactly 0: a zero spread cannot define an outlier, and a lone differing value in an
        // otherwise-flat window is data, not noise (keeps the FIX-07 "steady then spike" case whole).
        let med0 = median(working)
        let mad0 = mad(working, center: med0)
        let kept: [Double]
        if mad0 > 0 {
            let threshold = spec.outlierMadThreshold * mad0
            kept = working.filter { abs($0 - med0) <= threshold }
        } else {
            kept = working
        }
        guard !kept.isEmpty else { return nil }

        let center = median(kept)
        let spread = mad(kept, center: center)
        let half = spec.madToSigma * spec.bandSigmas * spread

        let outCenter = isLog ? Foundation.exp(center) : center
        let outLow = isLog ? Foundation.exp(center - half) : center - half
        let outHigh = isLog ? Foundation.exp(center + half) : center + half
        let denom = spec.madToSigma * spec.bandSigmas
        let outSpread = denom > 0 ? (outHigh - outCenter) / denom : 0

        let n = kept.count
        let tier = classifyTier(nPoints: n, windowDays: resolution.windowDays, spec: spec)
        return BaselineComputation(center: outCenter, spread: outSpread,
                                   bandLow: outLow, bandHigh: outHigh, nPoints: n, tier: tier)
    }

    /// Confidence tier from point count and window (plan §18): `provisional` until there are at
    /// least `minPoints` points AND at least `establishingFraction` of the window filled;
    /// `established` once the window is full; `establishing` in between. Nothing renders as a score
    /// while a contributing baseline is provisional.
    static func classifyTier(nPoints: Int, windowDays: Int, spec: BaselineSpec) -> BaselineTier {
        let halfWindow = Int(ceil(Double(windowDays) * spec.establishingFraction))
        let clearThreshold = max(spec.minPoints, halfWindow)
        if nPoints < clearThreshold { return .provisional }
        if nPoints < windowDays { return .establishing }
        return .established
    }

    /// Whether a per-day derived value was "computed later from history": its `computedAt` day is
    /// more than `retroactiveGraceDays` after the day it describes (e.g. a readiness day recomputed
    /// once an import backfilled that week). Derived from the two stored fields rather than a stored
    /// column — the fact is answerable directly from the row (I1), needs no migration, and the
    /// `QualityFlag.retroactive` label is attached at read/export time exactly as
    /// `provisionalBaseline` is derived from `provisional`. See `docs/algorithms/baselines.md`.
    static func isRetroactive(periodDayKey: String, computedAt: Date, tz: String, spec: BaselineSpec) -> Bool {
        guard let periodDay = DayAttribution.date(fromDayKey: periodDayKey, tz: tz) else { return false }
        let computedDayStart = DayAttribution.startOfDay(computedAt, tz: tz)
        let graceEnd = DayAttribution.addingDays(spec.retroactiveGraceDays, to: periodDay, tz: tz)
        return computedDayStart > graceEnd
    }

    // MARK: - Helpers

    /// (DATA-10 + DATA-11) The window a single metric's baseline band is built from: the
    /// `windowDays` calendar days strictly BEFORE `asOf`'s own day, stepped via
    /// `DayAttribution.addingDays` rather than fixed 86,400s multiples so it survives DST. `to`
    /// sits one second before local midnight of `asOf`'s day — excluding the evaluation day itself.
    private static func baselineWindow(asOf: Date, windowDays: Int, tz: String) -> (from: Date, to: Date) {
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let to = dayStart.addingTimeInterval(-1)
        let from = DayAttribution.addingDays(-windowDays, to: dayStart, tz: tz)
        return (from, to)
    }

    /// Latest interval record per local day (attributed in the record's own timezone) for a metric
    /// over a window. "Latest" means most recently written (`updatedAt`), not latest start time — a
    /// corrected aggregate that supersedes an earlier-starting one must win even if its own
    /// `startAt` is earlier than the value it corrects.
    ///
    /// (DATA-09) Same-day ties (identical `updatedAt`) fall back to the record's own
    /// `provenance.sourceId` as a stable, deterministic key so the choice no longer depends on
    /// incidental query order.
    private func latestPerDay(metricId: String, from: Date, to: Date) throws -> [String: IntervalRecord] {
        let records = try measurements.intervalRecords(metricId: metricId, from: from, to: to)
        var byDay: [String: IntervalRecord] = [:]
        for r in records {
            let day = DayAttribution.localDayKey(r.startAt, tz: r.tzId)
            if let existing = byDay[day], !Self.isPreferred(r, over: existing) { continue }
            byDay[day] = r
        }
        return byDay
    }

    /// True when `candidate` should replace `incumbent` as the day's value: strictly newer
    /// `updatedAt` wins outright; an exact tie falls back to the lexicographically smaller
    /// `sourceId` (deterministic, not priority-aware).
    private static func isPreferred(_ candidate: IntervalRecord, over incumbent: IntervalRecord) -> Bool {
        if candidate.updatedAt != incumbent.updatedAt { return candidate.updatedAt > incumbent.updatedAt }
        return candidate.provenance.sourceId < incumbent.provenance.sourceId
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
