import Foundation

/// A daily 1–5 estimate of how the body is trending, on the same scale the user logs their own mood
/// on — so the two can be compared rather than confused.
///
/// ## Why this is not "mood from HRV"
///
/// The obvious build — read HRV, print a mood — is the thing `StressEngine` was written to refuse.
/// Its doc names a real-time index built on wearable HRV as "the biggest false-precision trap in the
/// plan", and the reason is physical rather than editorial: an Apple-Watch-class device writes a
/// handful of HRV samples a day, most of them overnight. That engine therefore runs a density gate
/// and, below it, shows nothing at all — the default state for Apple-Watch-only users.
///
/// So this estimate is deliberately multi-input, and the autonomic term rides on the SAME gate. Three
/// consequences, all intended:
///
/// 1. It cannot become a back door to the intraday stress index `StressEngine` declines to compute.
/// 2. On a device whose HRV sampling is too sparse, the autonomic term is simply dropped and the
///    estimate still exists — from sleep and resting heart rate — instead of vanishing. That
///    graceful degradation is the whole reason this is additive rather than a rename of
///    `stress.day_trend`.
/// 3. It never rests on one term. `minComponents` is 2, because a 1–5 "mood" computed from resting
///    heart rate alone would be indefensible.
///
/// ## What it does not claim
///
/// It does not read emotion. Physiology constrains how a day is likely to feel; it does not
/// determine it, and a bad number here is not a verdict on anyone's inner life. The metric is named
/// `mood_estimate`, is reported on the user's own logging scale, and never writes to
/// `subjective.mood` — the self-report is the record, and this is BADAN's guess beside it.
enum MoodEstimateEngine {

    /// The 1–5 estimate plus the terms it came from. Components ride along for the same reason
    /// `SleepScore`'s do: a bare number is uninspectable, and this one is more interpretive than
    /// most, so being able to see which term moved it matters more, not less.
    struct Estimate: Sendable, Hashable, Equatable {
        /// 1.0…5.0, matching `subjective.mood`'s scale.
        let value: Double
        /// Each 0–1 before weighting, or nil if that term was unavailable and dropped.
        let sleepComponent: Double?
        let autonomicComponent: Double?
        let restingHeartRateComponent: Double?
        /// True when any term was absent and the weights were renormalised over the rest.
        let partial: Bool
    }

    /// Everything the estimate needs, already normalised by the caller.
    struct Inputs: Sendable, Equatable {
        /// Last night's `sleep.score`, 0–100, or nil.
        var sleepScore: Double?
        /// Autonomic load 0–100 where HIGHER means MORE load (i.e. `stress.day_trend`'s convention),
        /// or nil when the density gate does not permit saying anything about daytime HRV.
        var autonomicLoad: Double?
        /// Today's resting heart rate expressed as sigmas above the personal baseline. Positive is
        /// elevated. nil when no baseline exists yet.
        var restingHeartRateSigmas: Double?

        init(sleepScore: Double? = nil, autonomicLoad: Double? = nil,
             restingHeartRateSigmas: Double? = nil) {
            self.sleepScore = sleepScore
            self.autonomicLoad = autonomicLoad
            self.restingHeartRateSigmas = restingHeartRateSigmas
        }
    }

    /// Contract-loaded constants. Mirrors `SleepSpec`'s posture: if the entry is missing, this
    /// computes nothing rather than falling back to hardcoded numbers.
    struct Spec: Sendable, Hashable {
        let sleepWeight: Double
        let autonomicWeight: Double
        let restingHeartRateWeight: Double
        let rhrZeroScoreSigmas: Double
        let minComponents: Int
        let output: SleepOutputSpec
        let isLoaded: Bool

        static func load(from registry: AlgorithmRegistry) -> Spec {
            guard let def = registry.definition("subjective.mood_estimate"),
                  let sleepW = def.params["sleepWeight"],
                  let autoW = def.params["autonomicWeight"],
                  let rhrW = def.params["restingHeartRateWeight"],
                  let rhrZero = def.params["rhrZeroScoreSigmas"],
                  let minComp = def.params["minComponents"] else { return .unavailable }
            return Spec(sleepWeight: sleepW, autonomicWeight: autoW, restingHeartRateWeight: rhrW,
                        rhrZeroScoreSigmas: rhrZero, minComponents: Int(minComp),
                        output: SleepOutputSpec(algorithm: def.algorithmVersion,
                                                provisional: def.provisional),
                        isLoaded: true)
        }

        static let defaultShared = load(from: .shared)

        static let unavailable = Spec(
            sleepWeight: 0, autonomicWeight: 0, restingHeartRateWeight: 0,
            rhrZeroScoreSigmas: 1, minComponents: .max,
            output: SleepOutputSpec(
                algorithm: AlgorithmVersion(algorithmId: "subjective.mood_estimate",
                                            semver: "0.0.0", introducedIn: "0.0.0"),
                provisional: true),
            isLoaded: false)
    }

    /// Form the estimate, or nil when it cannot be formed honestly.
    static func estimate(_ inputs: Inputs, spec: Spec = .defaultShared) -> Estimate? {
        guard spec.isLoaded else { return nil }

        var terms: [(weight: Double, value: Double)] = []

        var sleepComponent: Double?
        if let s = inputs.sleepScore {
            let c = clamp01(s / 100)
            sleepComponent = c
            terms.append((spec.sleepWeight, c))
        }

        var autonomicComponent: Double?
        if let load = inputs.autonomicLoad {
            // Inverted: `stress.day_trend` is higher-is-more-load, and more load reads as a lower
            // estimate here.
            let c = clamp01(1 - load / 100)
            autonomicComponent = c
            terms.append((spec.autonomicWeight, c))
        }

        var rhrComponent: Double?
        if let sigmas = inputs.restingHeartRateSigmas, spec.rhrZeroScoreSigmas > 0 {
            // Only ELEVATION counts against the estimate. An unusually low resting heart rate is not
            // evidence of a good mood, and rewarding it would invent a signal in the tail where
            // illness and measurement artefacts also live.
            let elevation = max(0, sigmas)
            let c = clamp01(1 - elevation / spec.rhrZeroScoreSigmas)
            rhrComponent = c
            terms.append((spec.restingHeartRateWeight, c))
        }

        guard terms.count >= spec.minComponents else { return nil }
        let totalWeight = terms.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }

        let unit = terms.reduce(0) { $0 + $1.weight * $1.value } / totalWeight
        // 0…1 onto the 1…5 scale `subjective.mood` uses.
        let value = 1 + clamp01(unit) * 4

        let missingAny = sleepComponent == nil || autonomicComponent == nil || rhrComponent == nil
        return Estimate(value: value,
                        sleepComponent: sleepComponent,
                        autonomicComponent: autonomicComponent,
                        restingHeartRateComponent: rhrComponent,
                        partial: missingAny || spec.output.provisional)
    }

    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// The thin adapter: gathers the three terms from storage, asks the pure core, writes one row.
/// Same pure-core / thin-shell split `SleepIntelligenceEngine` and `StressEngine` use.
struct MoodEstimateWriter {
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let registry: MetricRegistry
    private let clock: Clock
    private let deviceId: String
    private let spec: MoodEstimateEngine.Spec

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         registry: MetricRegistry = .shared, clock: Clock, deviceId: String,
         spec: MoodEstimateEngine.Spec = .defaultShared) {
        self.derivation = derivation
        self.measurements = measurements
        self.registry = registry
        self.clock = clock
        self.deviceId = deviceId
        self.spec = spec
    }

    /// Compute and persist the estimate for `asOf`'s local day, or write nothing.
    ///
    /// Writing nothing is the common early case and is not an error: the estimate needs two of its
    /// three terms, and a fresh install has no sleep composite (no baseline yet) and no stress trend
    /// (the density gate refuses). Silence there is the honest output.
    @discardableResult
    func compute(asOf: Date, tz: String = TimeZone.current.identifier) throws -> Bool {
        guard spec.isLoaded else { return false }
        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)
        let periodKey = "day:\(dayKey)"

        let inputs = MoodEstimateEngine.Inputs(
            sleepScore: try derivation.latestDerived(metricId: MetricID.sleepScore,
                                                     periodKey: periodKey)?.value,
            // Read from the row `StressEngine` wrote, NOT recomputed here. A day its density gate
            // refused has no row, so this term is simply absent — which is exactly the intended
            // behaviour, and is why the gate cannot be bypassed from this side.
            autonomicLoad: try derivation.latestDerived(metricId: MetricID.stressDayTrend,
                                                        periodKey: periodKey)?.value,
            restingHeartRateSigmas: try restingHeartRateSigmas())

        guard let estimate = MoodEstimateEngine.estimate(inputs, spec: spec) else { return false }

        let unit = registry.definitionOrFallback(MetricID.moodEstimate).canonicalUnit
        if let existing = try derivation.latestDerived(metricId: MetricID.moodEstimate, periodKey: periodKey),
           abs(existing.value - estimate.value) < 0.0001 {
            return false
        }

        var manifestInputs: [InputManifest.Input] = []
        if let s = estimate.sleepComponent {
            manifestInputs.append(.init(recordId: periodKey, metricId: MetricID.sleepScore, value: s))
        }
        if let a = estimate.autonomicComponent {
            manifestInputs.append(.init(recordId: periodKey, metricId: MetricID.stressDayTrend, value: a))
        }
        if let r = estimate.restingHeartRateComponent {
            manifestInputs.append(.init(recordId: periodKey, metricId: MetricID.restingHeartRate, value: r))
        }

        let manifest = InputManifest(id: ULID.newID(), inputs: manifestInputs)
        try derivation.insertManifest(manifest)
        let now = clock.now()
        // Append, not upsert: derivation is append-only (I2), and the latest-wins read surfaces the
        // newest row. The equality short-circuit above is what keeps a re-run from stacking
        // identical rows.
        try derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.moodEstimate, value: estimate.value, unit: unit,
            periodKey: periodKey,
            confidence: estimate.partial ? 0.5 : 0.8,
            provisional: true,
            algorithmId: spec.output.algorithm.algorithmId,
            algorithmVersion: spec.output.algorithm.semver,
            inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId))
        return true
    }

    /// Today's resting heart rate as sigmas above the personal baseline, or nil without either.
    /// Uses the same three-shape lookup goals use, so "what is this metric's current value?" has one
    /// implementation in the app rather than two that can disagree.
    private func restingHeartRateSigmas() throws -> Double? {
        guard let baseline = try derivation.latestBaseline(metricId: MetricID.restingHeartRate),
              let current = GoalMetricValue.current(for: MetricID.restingHeartRate,
                                                    measurements: measurements,
                                                    derivation: derivation)
        else { return nil }
        return baseline.z(of: current)
    }
}
