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
