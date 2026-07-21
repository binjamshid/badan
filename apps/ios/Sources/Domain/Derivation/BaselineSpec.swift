import Foundation
import os

/// How a metric's values are transformed before the robust median/MAD band is drawn over them.
///
/// `identity` bands the values directly. `log` takes the median and MAD on `ln(value)` and
/// exponentiates the result back — the honest shape for a log-normal vital like HRV (RMSSD/SDNN),
/// whose distribution is right-skewed, so a symmetric linear band would put the lower edge below
/// what the body ever produces and clip the long upper tail (plan §18, `whoop.md` §5). The band
/// that comes back is therefore ASYMMETRIC in linear units, which is the point.
enum BaselineTransform: String, Sendable, Hashable {
    case identity
    case log

    /// An unknown transform string from a future contract revision reads as `identity` rather than
    /// failing — a metric BADAN does not yet know how to log-band still gets a plain band instead
    /// of no baseline at all.
    init(contract raw: String) { self = BaselineTransform(rawValue: raw) ?? .identity }
}

/// The calibration maturity of a baseline, surfaced so a score card can say "day 9 of 14" and a
/// still-thin band is never dressed up as an established personal normal (plan §18 cold-start rule).
///
/// `provisional` — not enough points to be honest about; NOTHING renders as a score while a
/// contributing baseline is provisional. `establishing` — past the provisional gate but the window
/// is not yet full. `established` — the window is full.
enum BaselineTier: String, Sendable, Hashable {
    case provisional
    case establishing
    case established
}

/// The window (in days) and transform a given metric's baseline is built over, resolved from the
/// contract's per-metric `windowTable` with a fallback to the default window / identity transform.
struct BaselineWindowResolution: Sendable, Hashable {
    let windowDays: Int
    let transform: BaselineTransform
    init(windowDays: Int, transform: BaselineTransform) {
        self.windowDays = windowDays
        self.transform = transform
    }
}

/// The pure output of the baseline math for one metric's windowed values — everything the engine
/// needs to materialize a `Baseline` row, with no I/O or clock in sight, so both platforms compute
/// byte-identical numbers from the same inputs (the acceptance goldens assert exactly this).
struct BaselineComputation: Sendable, Hashable {
    let center: Double
    let spread: Double
    let bandLow: Double
    let bandHigh: Double
    /// Count of daily points that actually fed the band, AFTER outlier rejection — this is what
    /// the tier and `provisional` are judged on, so a window padded with rejected spikes does not
    /// read as more-calibrated than it is.
    let nPoints: Int
    let tier: BaselineTier

    var provisional: Bool { tier == .provisional }

    init(center: Double, spread: Double, bandLow: Double, bandHigh: Double,
                nPoints: Int, tier: BaselineTier) {
        self.center = center; self.spread = spread
        self.bandLow = bandLow; self.bandHigh = bandHigh
        self.nPoints = nPoints; self.tier = tier
    }
}

/// The data-driven baseline parameters, resolved once from the algorithm contract
/// (`baseline.rolling_median_mad` in `algorithms.json`). This is the *only* place the window
/// table, MAD constants, outlier threshold and confidence thresholds enter the engine — they are
/// never hardcoded in `BaselineEngine`, so the two platforms cannot drift and a change is a
/// reviewable one-line diff in the contract plus a semver bump (plan §15; the whole reason
/// `AlgorithmRegistry` exists — audit finding #5).
///
/// A spec that failed to load (`isLoaded == false`) makes the engine COMPUTE NOTHING rather than
/// fall back to invented constants — a missing contract is a packaging bug (gated by
/// `AlgorithmRegistryTests`), and a fabricated band would be indistinguishable, on the stored row,
/// from a published one.
struct BaselineSpec: Sendable, Hashable {
    let algorithm: AlgorithmVersion
    let defaultWindowDays: Int
    let minPoints: Int
    let madToSigma: Double
    let bandSigmas: Double
    let outlierMadThreshold: Double
    let establishingFraction: Double
    let retroactiveGraceDays: Int
    let isLoaded: Bool
    private let byMetric: [String: BaselineWindowResolution]

    private static let logger = Logger(subsystem: "net.albayyan.badan", category: "Derivation")
    private static let contractId = "baseline.rolling_median_mad"

    init(algorithm: AlgorithmVersion, defaultWindowDays: Int, minPoints: Int,
                madToSigma: Double, bandSigmas: Double, outlierMadThreshold: Double,
                establishingFraction: Double, retroactiveGraceDays: Int,
                byMetric: [String: BaselineWindowResolution], isLoaded: Bool) {
        self.algorithm = algorithm; self.defaultWindowDays = defaultWindowDays
        self.minPoints = minPoints; self.madToSigma = madToSigma; self.bandSigmas = bandSigmas
        self.outlierMadThreshold = outlierMadThreshold; self.establishingFraction = establishingFraction
        self.retroactiveGraceDays = retroactiveGraceDays; self.byMetric = byMetric; self.isLoaded = isLoaded
    }

    /// The window + transform for a metric: its explicit `windowTable` rule, else the default
    /// window with an identity transform.
    func resolve(_ metricId: String) -> BaselineWindowResolution {
        byMetric[metricId] ?? BaselineWindowResolution(windowDays: defaultWindowDays, transform: .identity)
    }

    /// Resolve the spec from a loaded `AlgorithmRegistry`. Returns `.unavailable` (isLoaded=false)
    /// if the baseline entry or any core constant is missing — the engine treats that as "compute
    /// nothing", never as a cue to invent numbers.
    static func load(from registry: AlgorithmRegistry) -> BaselineSpec {
        guard let def = registry.definition(contractId),
              let windowDays = def.params["windowDays"],
              let minPoints = def.params["minPoints"],
              let madToSigma = def.params["madToSigma"],
              let bandSigmas = def.params["bandSigmas"],
              let outlierMadThreshold = def.params["outlierMadThreshold"],
              let establishingFraction = def.params["establishingFraction"],
              let retroactiveGraceDays = def.params["retroactiveGraceDays"] else {
            logger.fault("BaselineSpec: \(contractId, privacy: .public) missing or incomplete in algorithms.json — baselines will not compute")
            return .unavailable
        }
        var byMetric: [String: BaselineWindowResolution] = [:]
        for rule in def.windowTable {
            let resolution = BaselineWindowResolution(windowDays: rule.windowDays,
                                                      transform: BaselineTransform(contract: rule.transform))
            for metricId in rule.metrics { byMetric[metricId] = resolution }
        }
        return BaselineSpec(
            algorithm: def.algorithmVersion, defaultWindowDays: Int(windowDays), minPoints: Int(minPoints),
            madToSigma: madToSigma, bandSigmas: bandSigmas, outlierMadThreshold: outlierMadThreshold,
            establishingFraction: establishingFraction, retroactiveGraceDays: Int(retroactiveGraceDays),
            byMetric: byMetric, isLoaded: true)
    }

    /// The app-default spec, resolved once from the bundled contract (`AlgorithmRegistry.shared`).
    /// `BaselineEngine`'s constructor defaults to this so the composition root — which EPIC-23 must
    /// not touch — keeps wiring the engine with five arguments while it computes from published data.
    static let defaultShared = load(from: .shared)

    /// The degenerate "the contract did not load" spec. Never produces a baseline.
    static let unavailable = BaselineSpec(
        algorithm: AlgorithmVersion(algorithmId: contractId, semver: "0.0.0", introducedIn: "0.0.0"),
        defaultWindowDays: 0, minPoints: 0, madToSigma: 0, bandSigmas: 0, outlierMadThreshold: 0,
        establishingFraction: 0, retroactiveGraceDays: 0, byMetric: [:], isLoaded: false)
}

/// The plain read model the calibration UI renders — "day 9 of 14", the tier, the window, the
/// transform. Derived entirely from a stored `Baseline` (plus the spec for the transform, which the
/// row itself does not carry — it is reconstructable from the metric id via the published window
/// table, so nothing is stored redundantly; see `docs/algorithms/baselines.md`). No I/O, no
/// formatting: the UI lane owns the bilingual strings, this owns the numbers and the state.
struct BaselineCalibration: Sendable, Hashable {
    let metricId: String
    let tier: BaselineTier
    /// Distinct daily points behind the band (post outlier rejection). The "9" in "day 9 of 14".
    let nPoints: Int
    /// The full window the band aims to fill. The "14" in "day 9 of 14".
    let windowDays: Int
    let transform: BaselineTransform
    /// 0…1 maturity = points / window, clamped. A blunt confidence proxy for the baseline's own
    /// maturity dimension (the score engines multiply this by input completeness and source
    /// quality, per plan §18); it is NOT presented as the whole confidence number here.
    let maturity: Double
    let provisional: Bool

    init(metricId: String, tier: BaselineTier, nPoints: Int, windowDays: Int,
                transform: BaselineTransform, maturity: Double, provisional: Bool) {
        self.metricId = metricId; self.tier = tier; self.nPoints = nPoints
        self.windowDays = windowDays; self.transform = transform
        self.maturity = maturity; self.provisional = provisional
    }

    /// Build the read model from a materialized baseline. The tier is recomputed from the same
    /// thresholds the engine used, so it agrees with the row's stored `provisional` by construction.
    static func from(baseline: Baseline, spec: BaselineSpec) -> BaselineCalibration {
        let tier = BaselineEngine.classifyTier(nPoints: baseline.nPoints,
                                               windowDays: baseline.windowDays, spec: spec)
        let maturity = baseline.windowDays > 0
            ? min(1.0, Double(baseline.nPoints) / Double(baseline.windowDays)) : 0
        return BaselineCalibration(
            metricId: baseline.metricId, tier: tier, nPoints: baseline.nPoints,
            windowDays: baseline.windowDays, transform: spec.resolve(baseline.metricId).transform,
            maturity: maturity, provisional: tier == .provisional)
    }
}
