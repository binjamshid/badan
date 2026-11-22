import Foundation

// MARK: - Pure inputs (platform-identical)

/// The two sleep episode kinds this engine distinguishes. A `SessionKind.workout` never reaches
/// here; the mapping from the storage enum happens at the DB edge (`recompute`), so the pure core
/// never has to know the full session taxonomy.
enum SleepSessionKind: Sendable, Hashable { case primary, nap }

/// A half-open interval on the epoch-seconds line, used for awake-stage episodes. Kept as plain
/// `Double` seconds (not `Date`) so the disturbance state machine is byte-identical to the Kotlin
/// mirror — the acceptance golden is that both platforms count the same episodes from the same
/// numbers.
struct SleepInterval: Sendable, Hashable {
    let start: Double
    let end: Double
    init(start: Double, end: Double) { self.start = start; self.end = end }
    var durationSeconds: Double { end - start }
}

/// One sleep episode reduced to the primitives the pure state machine needs. The DB edge builds
/// these from `Session` + `SessionStage`; everything downstream is timezone-aware arithmetic over
/// `Double` epoch seconds and an IANA `tzId`, so nap attribution, split-night merge, DST and travel
/// all fall out of the same code on both platforms.
struct SleepSessionInput: Sendable, Hashable {
    let sessionId: String
    let kind: SleepSessionKind
    let startEpoch: Double
    let endEpoch: Double
    let tzId: String
    /// Time actually asleep in seconds, as the source reported it (`detail.timeAsleepSeconds`).
    /// Never re-derived from the duration here — "in bed 8h, asleep 6h" is a claim the source made
    /// and we preserve, not one we reconstruct (I1).
    let asleepSeconds: Double
    let inBedSeconds: Double
    /// The awake-stage rows for this episode. Empty is not the same as `hasStages == false`: a
    /// staged night with no awake episodes legitimately has zero disturbances, whereas an unstaged
    /// night's disturbance count is *unknown* and must render as a gap, never a zero.
    let awakeIntervals: [SleepInterval]
    let hasStages: Bool

    init(sessionId: String, kind: SleepSessionKind, startEpoch: Double, endEpoch: Double,
         tzId: String, asleepSeconds: Double, inBedSeconds: Double,
         awakeIntervals: [SleepInterval] = [], hasStages: Bool = false) {
        self.sessionId = sessionId; self.kind = kind
        self.startEpoch = startEpoch; self.endEpoch = endEpoch; self.tzId = tzId
        self.asleepSeconds = asleepSeconds; self.inBedSeconds = inBedSeconds
        self.awakeIntervals = awakeIntervals; self.hasStages = hasStages
    }
}

/// One assembled local night: every primary cluster for that night folded into a single record,
/// with the naps kept out (they credit a *later* night — see `SleepAssembly`). This is the output
/// of the split-night / travel / DST state machine and the unit the score pass iterates.
struct SleepNight: Sendable, Hashable {
    let localNight: String
    /// Primary cluster session ids, earliest first — the lineage a derived row references (I1).
    let sessionIds: [String]
    /// Sum of asleep seconds across every primary cluster of the night (a split night is one
    /// night's sleep, not two).
    let asleepSeconds: Double
    let inBedSeconds: Double
    /// Wall-clock second-of-day of the earliest cluster's start / latest cluster's end, computed in
    /// each cluster's OWN timezone. Wall-clock (not elapsed-since-midnight) so a DST night's 07:00
    /// wake is 25200 both before and after the transition and consistency is not thrown by the
    /// hour that never existed.
    let bedSecondsOfDay: Double
    let wakeSecondsOfDay: Double
    /// Awake episodes = explicit awake stages ∪ the gaps *between* clusters (the time you were up
    /// mid-night on a split night is a disturbance, even though no stage row spans it).
    let awakeIntervals: [SleepInterval]
    let hasStages: Bool

    var primarySessionId: String { sessionIds.first ?? "" }
}

/// The whole assembly: the nights that have primary sleep, plus a nap ledger keyed by the nap's own
/// local day. Naps are surfaced separately because a 2pm nap does not shorten the sleep you already
/// had last night — it lowers the need for the night to *come*, which the score pass looks up as
/// `napSecondsByDayKey[previousDayKey(thisNight)]`.
struct SleepAssembly: Sendable, Hashable {
    let nights: [SleepNight]
    let napSecondsByDayKey: [String: Double]
}

// MARK: - Pure results (platform-identical)

/// Sleep need as an honest range, never a fake-exact minutes target (plan §4 principle 9). `center`
/// is the point estimate; `low`/`high` are the band the surface must render instead of the point.
/// The band widens as `confidence` drops (a thin baseline or a missing effort input), so an
/// estimate the engine is unsure of *looks* unsure.
struct SleepNeedRange: Sendable, Hashable {
    let centerSeconds: Double
    let lowSeconds: Double
    let highSeconds: Double
    let confidence: Double
    /// False when the prior-day Effort input was absent — the reduced-input variant (plan §11:
    /// "the need model must run without it"). Carried so the surface can label it distinctly rather
    /// than silently degrade.
    let effortPresent: Bool
}

/// Sleep performance = actual ÷ need, as a percentage. `center` is stored UNCAPPED (the paramNote
/// is explicit: values above the cap are clamped at the presentation edge only, so the raw ratio
/// stays inspectable); `cappedCenter` is what the surface shows. `low`/`high` propagate the need
/// band (more need ⇒ lower performance), and `showRange` is the honest-render flag: below the
/// confidence threshold the surface shows the band, not the point.
struct SleepPerformance: Sendable, Hashable {
    let centerPercent: Double
    let cappedCenterPercent: Double
    let lowPercent: Double
    let highPercent: Double
    let confidence: Double
    let showRange: Bool
}

/// Everything computed for one night. `need`/`performance`/`debtSeconds` are nil when there is no
/// personal sleep-duration baseline yet (honest cold start — they cannot exist without it), while
/// `consistency` and `disturbanceCount` do not depend on the baseline and can stand alone.
struct SleepNightScore: Sendable, Hashable {
    let localNight: String
    let primarySessionId: String
    let actualAsleepSeconds: Double
    let need: SleepNeedRange?
    let performance: SleepPerformance?
    let debtSeconds: Double?
    /// 0–100 timing-regularity score, nil when fewer than two nights are in the trailing window
    /// (a spread needs at least two points to exist).
    let consistency: Double?
    let consistencyNights: Int
    let consistencySufficient: Bool
    /// Nights that fed the consistency window, for the manifest.
    let consistencyWindowSessionIds: [String]
    /// nil when the night carried no stage data — unknown, not zero.
    let disturbanceCount: Int?
    /// The 0–100 composite, or nil when it cannot honestly be formed (see `SleepScore.compute`).
    let score: SleepScore?
}

/// The 0–100 sleep composite and, just as importantly, what went into it.
///
/// The components are carried alongside the number because a bare score is the least inspectable
/// thing this engine produces — "68" answers nothing on its own, and a user who slept well but
/// irregularly deserves to see which term cost them. It is also what keeps the score from becoming
/// the kind of opaque proprietary number BADAN exists as an alternative to.
struct SleepScore: Sendable, Hashable {
    let value: Double
    /// Sub-scores actually used, each 0–100. A nil component was absent and was dropped from the
    /// weighted mean rather than defaulted — defaulting a missing term to zero would punish someone
    /// for their watch not recording stages, and defaulting it to 100 would flatter them.
    let performanceComponent: Double?
    let consistencyComponent: Double?
    let continuityComponent: Double?
    /// True when any component was missing and the weights were renormalised over the rest, or when
    /// the contract itself is still provisional. Surfaces must not present a partial composite as
    /// though it were the full one.
    let partial: Bool
}

extension SleepScore {
    /// Form the composite, or return nil if it cannot be formed honestly.
    ///
    /// Two rules do the work:
    ///
    /// 1. **Performance is required.** It is the dominant term, and it is nil until a personal
    ///    sleep-duration baseline exists — so a new install gets no score rather than a fabricated
    ///    one. A "sleep score" computed without any notion of whether you slept enough would be a
    ///    timing score wearing the wrong label.
    /// 2. **Missing optional terms are dropped, not defaulted.** Consistency is nil below the
    ///    engine's minimum nights; disturbances are nil without stage data. Each absent term is
    ///    removed from the weighted mean and the remaining weights renormalised, and the result is
    ///    marked `partial` so no surface can pass it off as the whole picture.
    static func compute(performance: SleepPerformance?,
                        consistency: Double?,
                        disturbanceCount: Int?,
                        spec: SleepSpec) -> SleepScore? {
        guard spec.isLoaded, let performance else { return nil }

        let perfComponent = min(performance.cappedCenterPercent, spec.performanceCapPercent)
        var terms: [(weight: Double, value: Double)] = [(spec.performanceWeight, perfComponent)]

        var consComponent: Double?
        if let consistency {
            let c = clamp01to100(consistency)
            consComponent = c
            terms.append((spec.consistencyWeight, c))
        }

        var contComponent: Double?
        if let disturbanceCount, spec.disturbanceZeroScoreCount > 0 {
            let ratio = Double(disturbanceCount) / spec.disturbanceZeroScoreCount
            let c = clamp01to100(100 * (1 - ratio))
            contComponent = c
            terms.append((spec.continuityWeight, c))
        }

        let totalWeight = terms.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let value = terms.reduce(0) { $0 + $1.weight * $1.value } / totalWeight

        let missingAny = consComponent == nil || contComponent == nil
        return SleepScore(value: clamp01to100(value),
                          performanceComponent: perfComponent,
                          consistencyComponent: consComponent,
                          continuityComponent: contComponent,
                          partial: missingAny || spec.score.provisional)
    }

    private static func clamp01to100(_ v: Double) -> Double { min(max(v, 0), 100) }
}

// MARK: - Contract-loaded parameters

/// One derived output's frozen identity plus whether its constants are still provisional. Every
/// sleep output is provisional today (the constants are seeded defaults, not validated against
/// data — `algorithms.json`), so every row this engine writes carries `provisional = true`; this
/// pairs the version stamped on the row with that fact rather than hardcoding it in the engine.
struct SleepOutputSpec: Sendable, Hashable {
    let algorithm: AlgorithmVersion
    let provisional: Bool
}

/// The data-driven sleep parameters, resolved once from the algorithm contract (the five
/// `sleep.*` entries in `algorithms.json`). This is the ONLY place those constants enter the
/// engine — never hardcoded — so the two platforms cannot drift and a tuning change is a reviewable
/// one-line diff plus a semver bump (plan §15, the whole reason `AlgorithmRegistry` exists).
///
/// A spec that failed to load (`isLoaded == false`) makes the engine COMPUTE NOTHING rather than
/// fall back to invented constants — a missing contract is a packaging bug (gated by
/// `AlgorithmRegistryTests`), and a fabricated score would be indistinguishable, on the stored row,
/// from a published one (mirrors `BaselineSpec`).
struct SleepSpec: Sendable, Hashable {
    let need: SleepOutputSpec
    let performance: SleepOutputSpec
    let debt: SleepOutputSpec
    let consistency: SleepOutputSpec
    let disturbances: SleepOutputSpec
    let score: SleepOutputSpec

    // need
    let debtRepaymentFraction: Double
    /// Half-life of the debt view that feeds NEED. Deliberately shorter than the displayed-debt
    /// half-life: tonight's target should react to the last few nights, while the surfaced debt
    /// trend has a longer memory. Two half-lives, both published, both used.
    let needDebtHalfLifeDays: Double
    let effortFactorSecondsPerPoint: Double
    let napCreditFraction: Double
    let rangeHalfWidthSeconds: Double
    let minNeedSeconds: Double
    let maxNeedSeconds: Double

    // performance
    let upperBoundPercent: Double
    let lowConfidenceThreshold: Double

    // debt (accumulator)
    let displayDebtHalfLifeDays: Double
    let debtLookbackDays: Int
    let maxDebtSeconds: Double

    // consistency
    let consistencyWindowDays: Int
    let consistencyMinNights: Int
    let zeroScoreStdevSeconds: Double
    let bedWakeWeightSplit: Double

    // disturbances
    let minEpisodeSeconds: Double
    let mergeGapSeconds: Double

    // score (the 0–100 composite)
    let performanceWeight: Double
    let consistencyWeight: Double
    let continuityWeight: Double
    let disturbanceZeroScoreCount: Double
    let performanceCapPercent: Double

    let isLoaded: Bool

    /// Resolve from a loaded `AlgorithmRegistry`. Returns `.unavailable` (isLoaded=false) if any of
    /// the five entries or any constant they own is missing — the engine treats that as "compute
    /// nothing", never as a cue to invent numbers.
    /// The score method the engine ran before methods were selectable, and the fallback when a
    /// stored choice cannot be honoured (D-35 — see `MethodResolver`).
    static let scoreContractId = "sleep.score"

    /// `scoreContractId` is a parameter (D-35) so an alternative WEIGHTING of the same composite can
    /// load through this identical path. Only the score entry varies: need, performance, debt,
    /// consistency and disturbances are the inputs every variant shares, and a variant that changed
    /// those would be a different measurement rather than a different weighting of one.
    static func load(from registry: AlgorithmRegistry,
                     scoreContractId: String = SleepSpec.scoreContractId) -> SleepSpec {
        guard let needDef = registry.definition("sleep.need"),
              let perfDef = registry.definition("sleep.performance"),
              let debtDef = registry.definition("sleep.debt"),
              let consDef = registry.definition("sleep.consistency"),
              let distDef = registry.definition("sleep.disturbances"),
              let scoreDef = registry.definition(scoreContractId),
              let repay = needDef.params["debtRepaymentFraction"],
              let needHalf = needDef.params["debtDecayHalfLifeDays"],
              let effortFactor = needDef.params["effortFactorSecondsPerPoint"],
              let napFrac = needDef.params["napCreditFraction"],
              let rangeHalf = needDef.params["rangeHalfWidthSeconds"],
              let minNeed = needDef.params["minNeedSeconds"],
              let maxNeed = needDef.params["maxNeedSeconds"],
              let upperBound = perfDef.params["upperBoundPercent"],
              let lowConf = perfDef.params["lowConfidenceThreshold"],
              let displayHalf = debtDef.params["decayHalfLifeDays"],
              let lookback = debtDef.params["lookbackDays"],
              let maxDebt = debtDef.params["maxDebtSeconds"],
              let consWindow = consDef.params["windowDays"],
              let minNights = consDef.params["minNights"],
              let zeroStdev = consDef.params["zeroScoreStdevSeconds"],
              let bedWakeSplit = consDef.params["bedWakeWeightSplit"],
              let minEpisode = distDef.params["minEpisodeSeconds"],
              let mergeGap = distDef.params["mergeGapSeconds"],
              let perfWeight = scoreDef.params["performanceWeight"],
              let consWeight = scoreDef.params["consistencyWeight"],
              let contWeight = scoreDef.params["continuityWeight"],
              let distZero = scoreDef.params["disturbanceZeroScoreCount"],
              let perfCap = scoreDef.params["performanceCapPercent"] else {
            return .unavailable
        }
        return SleepSpec(
            need: SleepOutputSpec(algorithm: needDef.algorithmVersion, provisional: needDef.provisional),
            performance: SleepOutputSpec(algorithm: perfDef.algorithmVersion, provisional: perfDef.provisional),
            debt: SleepOutputSpec(algorithm: debtDef.algorithmVersion, provisional: debtDef.provisional),
            consistency: SleepOutputSpec(algorithm: consDef.algorithmVersion, provisional: consDef.provisional),
            disturbances: SleepOutputSpec(algorithm: distDef.algorithmVersion, provisional: distDef.provisional),
            score: SleepOutputSpec(algorithm: scoreDef.algorithmVersion, provisional: scoreDef.provisional),
            debtRepaymentFraction: repay, needDebtHalfLifeDays: needHalf,
            effortFactorSecondsPerPoint: effortFactor, napCreditFraction: napFrac,
            rangeHalfWidthSeconds: rangeHalf, minNeedSeconds: minNeed, maxNeedSeconds: maxNeed,
            upperBoundPercent: upperBound, lowConfidenceThreshold: lowConf,
            displayDebtHalfLifeDays: displayHalf, debtLookbackDays: Int(lookback), maxDebtSeconds: maxDebt,
            consistencyWindowDays: Int(consWindow), consistencyMinNights: Int(minNights),
            zeroScoreStdevSeconds: zeroStdev, bedWakeWeightSplit: bedWakeSplit,
            minEpisodeSeconds: minEpisode, mergeGapSeconds: mergeGap,
            performanceWeight: perfWeight, consistencyWeight: consWeight,
            continuityWeight: contWeight, disturbanceZeroScoreCount: distZero,
            performanceCapPercent: perfCap,
            isLoaded: true)
    }

    /// The app-default spec, resolved once from the bundled contract.
    static let defaultShared = load(from: .shared)

    /// The degenerate "the contract did not load" spec. Never produces a score.
    static let unavailable = SleepSpec(
        need: SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: "sleep.need", semver: "0.0.0", introducedIn: "0.0.0"), provisional: true),
        performance: SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: "sleep.performance", semver: "0.0.0", introducedIn: "0.0.0"), provisional: true),
        debt: SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: "sleep.debt", semver: "0.0.0", introducedIn: "0.0.0"), provisional: true),
        consistency: SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: "sleep.consistency", semver: "0.0.0", introducedIn: "0.0.0"), provisional: true),
        disturbances: SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: "sleep.disturbances", semver: "0.0.0", introducedIn: "0.0.0"), provisional: true),
        score: SleepOutputSpec(algorithm: AlgorithmVersion(algorithmId: "sleep.score", semver: "0.0.0", introducedIn: "0.0.0"), provisional: true),
        debtRepaymentFraction: 0, needDebtHalfLifeDays: 1, effortFactorSecondsPerPoint: 0,
        napCreditFraction: 0, rangeHalfWidthSeconds: 0, minNeedSeconds: 0, maxNeedSeconds: 0,
        upperBoundPercent: 0, lowConfidenceThreshold: 0, displayDebtHalfLifeDays: 1,
        debtLookbackDays: 0, maxDebtSeconds: 0, consistencyWindowDays: 0, consistencyMinNights: 0,
        zeroScoreStdevSeconds: 1, bedWakeWeightSplit: 0.5, minEpisodeSeconds: 0, mergeGapSeconds: 0,
        performanceWeight: 0, consistencyWeight: 0, continuityWeight: 0,
        disturbanceZeroScoreCount: 1, performanceCapPercent: 0,
        isLoaded: false)
}

/// Computes the sleep-intelligence cluster per `localNight` — need (as a range), performance,
/// debt, consistency and disturbances — from the sessions BADAN already ingests, appending one
/// `DerivedValue` per output with an `InputManifest` and a confidence. Every constant is read from
/// `algorithms.json` via `SleepSpec`; nothing is hardcoded, and every output is provisional until
/// its constants are validated, so every row carries `provisional = true` today (`algorithms.json`).
///
/// The hard part is the state machine, and it is deliberately PURE and static (`assembleNights`,
/// `score`, and the five sub-computations): the Kotlin mirror computes byte-identical numbers from
/// the same inputs, and that cross-platform identity is the acceptance golden. The DB orchestration
/// (`recompute`) reads sessions/baselines/effort and appends rows; only iOS exercises it in tests
/// (Android has no DB harness), exactly as `BaselineEngine` splits pure math from DB wiring.
///
/// Soft dependency on Effort (plan §11): the need model runs at a reduced-input version when
/// `effort.day` is absent — it drops the effort term and lowers confidence (which widens the range),
/// never imputes a value. A sibling epic builds Effort concurrently; this engine never hard-depends
/// on its output existing.
final class SleepIntelligenceEngine {
    /// The metric ids this engine wires (already present in registry v0.2). `effortDay` is a soft
    /// input owned by EPIC-26 — referenced by string here rather than adding a shared constant the
    /// concurrent Effort epic would also want to introduce.
    static let effortDay = "effort.day"

    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let clock: Clock
    private let deviceId: String
    /// Resolved per compute rather than frozen at construction (D-35) — see `ReadinessEngine`'s
    /// `specProvider` for why.
    private let specProvider: @Sendable () -> SleepSpec
    private var spec: SleepSpec { specProvider() }
    /// EPIC-29 (plan §18). What the user declared over each night being scored. Resolved PER NIGHT,
    /// not once per run: one recompute emits a fortnight of nights and only some of them may sit
    /// inside a declared interval. A function rather than the sensitive repository — see
    /// `ContextAnnotationResolver`.
    private let contextAnnotations: ContextAnnotationResolver

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         clock: Clock, deviceId: String, spec: SleepSpec = .defaultShared,
         specProvider: (@Sendable () -> SleepSpec)? = nil,
         contextAnnotations: @escaping ContextAnnotationResolver = noContextAnnotations) {
        self.derivation = derivation
        self.measurements = measurements
        self.clock = clock
        self.deviceId = deviceId
        self.specProvider = specProvider ?? { spec }
        self.contextAnnotations = contextAnnotations
    }

    // MARK: - DB orchestration (iOS-tested; Android mirrors the pure core)

    /// Recompute the sleep cluster for the nights up to `asOf` and append the derived rows.
    /// Idempotent and append-only (I2): a repeat run over unchanged data writes nothing, a run over
    /// new/corrected data appends fresh rows and never mutates the old ones.
    ///
    /// The gather window reaches back far enough that the most recent night has full debt and
    /// consistency history behind it (`debtLookbackDays + consistencyWindowDays`); rows are emitted
    /// for every night in that window, with the earliest few honestly under-warmed on debt (a
    /// rolling recent measure is bounded by construction — that is the nature of the quantity, not a
    /// defect).
    func recompute(asOf: Date, tz: String = TimeZone.current.identifier, context: String = "default") throws {
        guard spec.isLoaded else { return }

        let gatherDays = spec.debtLookbackDays + spec.consistencyWindowDays
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let from = DayAttribution.addingDays(-(gatherDays + 1), to: dayStart, tz: tz)
        let sleepSessions = try measurements.sessions(from: from, to: asOf).filter { $0.kind.isSleep }
        guard !sleepSessions.isEmpty else { return }

        let stagesById = try measurements.stages(sessionIds: sleepSessions.map(\.id))
        let inputs: [SleepSessionInput] = sleepSessions.map { s in
            let stages = stagesById[s.id] ?? []
            let awake = stages.filter { $0.stage == .awake }
                .map { SleepInterval(start: $0.startAt.timeIntervalSince1970, end: $0.endAt.timeIntervalSince1970) }
            // Prefer the source's own asleep claim (I1); fall back to the in-bed span only when the
            // source reported no asleep figure at all, never re-derive it when it exists.
            let asleep = s.detail.timeAsleepSeconds ?? s.durationSeconds
            let inBed = s.detail.timeInBedSeconds ?? s.durationSeconds
            return SleepSessionInput(
                sessionId: s.id, kind: s.kind == .sleepNap ? .nap : .primary,
                startEpoch: s.startAt.timeIntervalSince1970, endEpoch: s.endAt.timeIntervalSince1970,
                tzId: s.tzId, asleepSeconds: asleep, inBedSeconds: inBed,
                awakeIntervals: awake, hasStages: !stages.isEmpty)
        }

        let assembly = Self.assembleNights(inputs)
        guard !assembly.nights.isEmpty else { return }

        let baseline = try derivation.latestBaseline(metricId: MetricID.timeAsleep)
        let baselineArg: (center: Double, maturity: Double)? = baseline.map {
            ($0.center, $0.windowDays > 0 ? min(1.0, Double($0.nPoints) / Double($0.windowDays)) : 0)
        }

        // Effort is a SOFT input: read whatever prior-day `effort.day` rows exist; absence is the
        // reduced-input path, not an error.
        var effortById: [String: DerivedValue] = [:]
        var effortByDayKey: [String: Double] = [:]
        for night in assembly.nights {
            let priorKey = Self.previousDayKey(night.localNight)
            if effortByDayKey[priorKey] == nil,
               let dv = try derivation.latestDerived(metricId: Self.effortDay, periodKey: "day:" + priorKey) {
                effortByDayKey[priorKey] = dv.value
                effortById[priorKey] = dv
            }
        }

        let scores = Self.score(assembly: assembly, baseline: baselineArg,
                                effortByDayKey: effortByDayKey, spec: spec)

        try derivation.transaction {
            for s in scores {
                // One resolve per night, over the local day the night is attributed to — the same
                // day-attribution rule every other reader of these rows uses. A status the user
                // declared for the previous day annotates that day's night, not this one's.
                let nightStart = DayAttribution.date(fromDayKey: s.localNight, tz: tz)
                let context = try nightStart.map {
                    try contextAnnotations($0, DayAttribution.addingDays(1, to: $0, tz: tz))
                } ?? .none
                try appendScore(s, baseline: baseline, effortById: effortById, context: context)
            }
        }
    }

    /// Append the rows for one night, cross-referencing them honestly (performance and debt point
    /// at the need row that produced them). Each output skips the write when the latest existing row
    /// is numerically identical, so a nightly recompute doesn't grow the log by re-confirming
    /// unchanged nights — but still returns the existing row's id so the cross-references stay valid.
    private func appendScore(_ s: SleepNightScore, baseline: Baseline?,
                             effortById: [String: DerivedValue],
                             context: ContextAnnotation = .none) throws {
        let priorKey = Self.previousDayKey(s.localNight)

        var needId: String?
        if let need = s.need, let baseline {
            var inputs = [InputManifest.Input(recordId: baseline.id, metricId: MetricID.timeAsleep, value: baseline.center)]
            if let effort = effortById[priorKey] {
                inputs.append(InputManifest.Input(recordId: effort.id, metricId: Self.effortDay, value: effort.value))
            }
            needId = try upsertDerived(
                metricId: MetricID.sleepNeed, value: need.centerSeconds, unit: "s", day: s.localNight,
                confidence: need.confidence, output: spec.need, inputs: inputs, context: context)
        }

        if let perf = s.performance, let needId {
            let inputs = [
                InputManifest.Input(recordId: needId, metricId: MetricID.sleepNeed, value: s.need?.centerSeconds ?? 0),
                InputManifest.Input(recordId: s.primarySessionId, metricId: MetricID.timeAsleep, value: s.actualAsleepSeconds),
            ]
            _ = try upsertDerived(
                metricId: MetricID.sleepPerformance, value: perf.centerPercent, unit: "percent", day: s.localNight,
                confidence: perf.confidence, output: spec.performance, inputs: inputs, context: context)
        }

        if let debt = s.debtSeconds, let needId {
            let inputs = [
                InputManifest.Input(recordId: needId, metricId: MetricID.sleepNeed, value: s.need?.centerSeconds ?? 0),
                InputManifest.Input(recordId: s.primarySessionId, metricId: MetricID.timeAsleep, value: s.actualAsleepSeconds),
            ]
            _ = try upsertDerived(
                metricId: MetricID.sleepDebt, value: debt, unit: "s", day: s.localNight,
                confidence: nil, output: spec.debt, inputs: inputs)
        }

        if let consistency = s.consistency {
            // Confidence carries data sufficiency: below the minimum-nights gate it is 0 so the
            // surface withholds the number rather than scoring someone on two nights (plan §18).
            let confidence = s.consistencySufficient
                ? min(1.0, Double(s.consistencyNights) / Double(spec.consistencyWindowDays)) : 0.0
            let inputs = s.consistencyWindowSessionIds.map {
                InputManifest.Input(recordId: $0, metricId: MetricID.timeAsleep, value: consistency)
            }
            _ = try upsertDerived(
                metricId: MetricID.sleepConsistency, value: consistency, unit: "score_0_100", day: s.localNight,
                confidence: confidence, output: spec.consistency, inputs: inputs, context: context)
        }

        if let disturbances = s.disturbanceCount {
            let inputs = [InputManifest.Input(recordId: s.primarySessionId, metricId: MetricID.sleepAwake, value: Double(disturbances))]
            // Deliberately NOT context-annotated. This confidence means "the stages were there and
            // we counted them", not "here is how confidently this reads against your usual" — a
            // count of observed awake episodes is as true on a travel night as on any other, and
            // capping it would say something about the number that is not so. `sleep.debt` is
            // likewise unannotated for the plainer reason that it stores no confidence at all.
            _ = try upsertDerived(
                metricId: MetricID.sleepDisturbances, value: Double(disturbances), unit: "count", day: s.localNight,
                confidence: 1.0, output: spec.disturbances, inputs: inputs)
        }

        if let score = s.score {
            // The manifest names the components that actually contributed, so "why is my score 68?"
            // resolves to the same three numbers the composite was built from rather than to an
            // opaque total. An absent component contributes no input row, matching the fact that it
            // contributed no weight either.
            var inputs: [InputManifest.Input] = []
            if let p = score.performanceComponent {
                inputs.append(.init(recordId: s.primarySessionId, metricId: MetricID.sleepPerformance, value: p))
            }
            if let c = score.consistencyComponent {
                inputs.append(.init(recordId: s.primarySessionId, metricId: MetricID.sleepConsistency, value: c))
            }
            if let k = score.continuityComponent {
                inputs.append(.init(recordId: s.primarySessionId, metricId: MetricID.sleepDisturbances, value: k))
            }
            // A partial composite carries lower confidence rather than being withheld: two of three
            // terms is still informative, but it must not read as the full picture.
            _ = try upsertDerived(
                metricId: MetricID.sleepScore, value: score.value, unit: "score_0_100", day: s.localNight,
                confidence: score.partial ? 0.6 : 1.0, output: spec.score, inputs: inputs, context: context)
        }
    }

    /// Append a derived row unless the latest one for this metric+day is already numerically
    /// identical; either way return the id to reference. Confidence is part of the equality check so
    /// a night that only changed confidence (e.g. effort arrived late, or a context was declared
    /// afterwards) still appends.
    ///
    /// `context` caps the confidence and NOTHING else — `value` is written through untouched, and
    /// `ContextAnnotation` has no value field it could touch it with. Callers pass `.none` for the
    /// outputs whose confidence is not an interpretation against the person's usual pattern (see
    /// the disturbance-count note above).
    private func upsertDerived(metricId: String, value: Double, unit: String, day: String,
                               confidence rawConfidence: Double?, output: SleepOutputSpec,
                               inputs: [InputManifest.Input],
                               context: ContextAnnotation = .none) throws -> String {
        let confidence = context.applying(to: rawConfidence)
        let periodKey = "day:" + day
        // Skip the append only when the latest row is identical on ALL of value, confidence,
        // provisional AND the algorithm identity — a version bump that yields the same value must
        // still record a fresh row, or that period's latest row would keep the OLD version id and
        // the recompute would go unrecorded (auditability; mirrors ReadinessEngine.persist).
        if let existing = try derivation.latestDerived(metricId: metricId, periodKey: periodKey),
           existing.algorithmId == output.algorithm.algorithmId,
           existing.algorithmVersion == output.algorithm.semver,
           Self.approximatelyEqual(existing.value, value),
           Self.approximatelyEqual(existing.confidence ?? -1, confidence ?? -1),
           existing.provisional == output.provisional {
            return existing.id
        }
        let manifest = InputManifest(id: ULID.newID(), inputs: inputs)
        try derivation.insertManifest(manifest)
        let now = clock.now()
        let dv = DerivedValue(
            id: ULID.newID(), metricId: metricId, value: value, unit: unit, periodKey: periodKey,
            confidence: confidence, provisional: output.provisional,
            algorithmId: output.algorithm.algorithmId, algorithmVersion: output.algorithm.semver,
            inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId)
        try derivation.appendDerived(dv)
        return dv.id
    }

    // MARK: - Pure state machine (identical on both platforms — golden-tested)

    /// Fold sleep sessions into per-night records: primary clusters merge into one night, nap
    /// seconds accrue against their own local day. Grouping is by the local night the episode ENDS
    /// in, computed in the episode's OWN timezone — so a Riyadh night stays a Riyadh night after you
    /// fly to London, and a post-midnight bedtime still lands on the right morning (DATA-11 spirit).
    static func assembleNights(_ sessions: [SleepSessionInput]) -> SleepAssembly {
        var primaryByNight: [String: [SleepSessionInput]] = [:]
        var napByDay: [String: Double] = [:]
        for s in sessions {
            let key = DayAttribution.localNight(sessionEnd: Date(timeIntervalSince1970: s.endEpoch), tz: s.tzId)
            switch s.kind {
            case .primary: primaryByNight[key, default: []].append(s)
            case .nap: napByDay[key, default: 0] += s.asleepSeconds
            }
        }

        var nights: [SleepNight] = []
        for (key, clustersRaw) in primaryByNight {
            let clusters = clustersRaw.sorted { $0.startEpoch < $1.startEpoch }
            let asleep = clusters.reduce(0) { $0 + $1.asleepSeconds }
            let inBed = clusters.reduce(0) { $0 + $1.inBedSeconds }
            let first = clusters.first!
            let last = clusters.last!
            let bedSOD = localSecondsOfDay(epochSeconds: first.startEpoch, tz: first.tzId)
            let wakeSOD = localSecondsOfDay(epochSeconds: last.endEpoch, tz: last.tzId)

            var awake = clusters.flatMap { $0.awakeIntervals }
            // The awake gap between two clusters of a split night is a disturbance the sleeper
            // lived through, even though no stage row spans it.
            for i in 0 ..< (clusters.count - 1) {
                let gapStart = clusters[i].endEpoch
                let gapEnd = clusters[i + 1].startEpoch
                if gapEnd > gapStart { awake.append(SleepInterval(start: gapStart, end: gapEnd)) }
            }
            let hasStages = clusters.contains { $0.hasStages }

            nights.append(SleepNight(
                localNight: key, sessionIds: clusters.map(\.sessionId),
                asleepSeconds: asleep, inBedSeconds: inBed,
                bedSecondsOfDay: bedSOD, wakeSecondsOfDay: wakeSOD,
                awakeIntervals: awake, hasStages: hasStages))
        }
        nights.sort { $0.localNight < $1.localNight }
        return SleepAssembly(nights: nights, napSecondsByDayKey: napByDay)
    }

    /// The forward pass over the assembled nights. Debt is a forward recurrence (tonight's need
    /// depends only on PAST shortfalls, so there is no circularity), computed twice with the two
    /// published half-lives: a short-memory view feeds need, the displayed trend has a longer one.
    /// Consistency and disturbances do not depend on the baseline and are always attempted.
    static func score(assembly: SleepAssembly, baseline: (center: Double, maturity: Double)?,
                      effortByDayKey: [String: Double], spec: SleepSpec) -> [SleepNightScore] {
        let nights = assembly.nights // already sorted ascending
        var shortfalls: [(key: String, seconds: Double)] = []
        var out: [SleepNightScore] = []

        for night in nights {
            let key = night.localNight
            let priorKey = previousDayKey(key)

            var need: SleepNeedRange?
            var performance: SleepPerformance?
            var debt: Double?
            if let baseline {
                let needDebt = accumulateDebt(shortfalls: shortfalls, asOfKey: key,
                                              halfLifeDays: spec.needDebtHalfLifeDays,
                                              lookbackDays: spec.debtLookbackDays,
                                              maxDebtSeconds: spec.maxDebtSeconds, includeAsOf: false)
                let napCredit = spec.napCreditFraction * (assembly.napSecondsByDayKey[priorKey] ?? 0)
                let n = computeNeed(baselineDurationSeconds: baseline.center, needDebtSeconds: needDebt,
                                    priorDayEffort: effortByDayKey[priorKey], napCreditSeconds: napCredit,
                                    baselineMaturity: baseline.maturity, spec: spec)
                need = n
                performance = computePerformance(actualSeconds: night.asleepSeconds, need: n, spec: spec)
                shortfalls.append((key, n.centerSeconds - night.asleepSeconds))
                debt = accumulateDebt(shortfalls: shortfalls, asOfKey: key,
                                      halfLifeDays: spec.displayDebtHalfLifeDays,
                                      lookbackDays: spec.debtLookbackDays,
                                      maxDebtSeconds: spec.maxDebtSeconds, includeAsOf: true)
            }

            // Consistency over the trailing window ending at this night.
            let window = nights.filter {
                let age = daysBetween($0.localNight, key)
                return age >= 0 && age < spec.consistencyWindowDays
            }
            var consistency: Double?
            if window.count >= 2 {
                consistency = computeConsistency(bedTimes: window.map(\.bedSecondsOfDay),
                                                 wakeTimes: window.map(\.wakeSecondsOfDay), spec: spec)
            }

            let disturbances = night.hasStages ? countDisturbances(night.awakeIntervals, spec: spec) : nil

            out.append(SleepNightScore(
                localNight: key, primarySessionId: night.primarySessionId,
                actualAsleepSeconds: night.asleepSeconds,
                need: need, performance: performance, debtSeconds: debt,
                consistency: consistency, consistencyNights: window.count,
                consistencySufficient: window.count >= spec.consistencyMinNights,
                consistencyWindowSessionIds: window.map(\.primarySessionId),
                disturbanceCount: disturbances,
                score: SleepScore.compute(performance: performance, consistency: consistency,
                                          disturbanceCount: disturbances, spec: spec)))
        }
        return out
    }

    /// need = baseline duration + repaymentFraction·debt + priorDayEffort·factor − napCredit,
    /// clamped to [min, max], returned as a range whose half-width grows as confidence falls.
    /// Confidence = baseline maturity × input completeness (½ when the effort term is missing), so a
    /// reduced-input estimate reads as less certain and the band widens honestly.
    static func computeNeed(baselineDurationSeconds: Double, needDebtSeconds: Double,
                            priorDayEffort: Double?, napCreditSeconds: Double,
                            baselineMaturity: Double, spec: SleepSpec) -> SleepNeedRange {
        let effortPresent = priorDayEffort != nil
        let effortTerm = (priorDayEffort ?? 0) * spec.effortFactorSecondsPerPoint
        var center = baselineDurationSeconds + spec.debtRepaymentFraction * needDebtSeconds
            + effortTerm - napCreditSeconds
        center = min(spec.maxNeedSeconds, max(spec.minNeedSeconds, center))

        let completeness = effortPresent ? 1.0 : 0.5
        let confidence = max(0, min(1, baselineMaturity * completeness))
        let halfWidth = spec.rangeHalfWidthSeconds * (2 - confidence)
        return SleepNeedRange(centerSeconds: center, lowSeconds: max(0, center - halfWidth),
                              highSeconds: center + halfWidth, confidence: confidence,
                              effortPresent: effortPresent)
    }

    /// performance = actual ÷ need · 100, stored uncapped, presented capped. The band inverts the
    /// need band (a larger need is a smaller share fulfilled), and `showRange` fires below the
    /// confidence threshold so an uncertain number is never shown as a point.
    static func computePerformance(actualSeconds: Double, need: SleepNeedRange, spec: SleepSpec) -> SleepPerformance {
        let center = need.centerSeconds > 0 ? actualSeconds / need.centerSeconds * 100 : 0
        let low = need.highSeconds > 0 ? actualSeconds / need.highSeconds * 100 : 0
        let high = need.lowSeconds > 0 ? actualSeconds / need.lowSeconds * 100 : center
        return SleepPerformance(
            centerPercent: center, cappedCenterPercent: min(center, spec.upperBoundPercent),
            lowPercent: low, highPercent: high, confidence: need.confidence,
            showRange: need.confidence < spec.lowConfidenceThreshold)
    }

    /// Rolling accumulator of signed shortfall (need − actual) with exponential decay, so old
    /// shortfalls stop counting rather than accumulating forever and a catch-up night pays debt
    /// down. Clamped to [0, max]: a well-rested surplus floors at "no debt", and the surface can
    /// never show an alarming ever-growing number.
    static func accumulateDebt(shortfalls: [(key: String, seconds: Double)], asOfKey: String,
                               halfLifeDays: Double, lookbackDays: Int, maxDebtSeconds: Double,
                               includeAsOf: Bool) -> Double {
        var sum = 0.0
        for (key, seconds) in shortfalls {
            let age = daysBetween(key, asOfKey)
            if age < 0 || age > lookbackDays { continue }
            if age == 0 && !includeAsOf { continue }
            sum += seconds * pow(0.5, Double(age) / halfLifeDays)
        }
        return min(maxDebtSeconds, max(0, sum))
    }

    /// 0–100 from the timing spread of bed and wake times over the window. The spread is a
    /// wrap-aware standard deviation (a 23:50 and a 00:10 bedtime are 20 minutes apart, not 23h40m),
    /// computed by unwrapping each time to within ±12h of the first night and taking the population
    /// stdev — arithmetic only (no trig), so it is bit-identical across platforms.
    static func computeConsistency(bedTimes: [Double], wakeTimes: [Double], spec: SleepSpec) -> Double {
        let bedComp = max(0, 1 - circularSpreadSeconds(bedTimes) / spec.zeroScoreStdevSeconds)
        let wakeComp = max(0, 1 - circularSpreadSeconds(wakeTimes) / spec.zeroScoreStdevSeconds)
        return 100 * (spec.bedWakeWeightSplit * bedComp + (1 - spec.bedWakeWeightSplit) * wakeComp)
    }

    /// Count of awake episodes lasting at least `minEpisodeSeconds`, after merging episodes closer
    /// than `mergeGapSeconds` (so stage-classifier flapping is one disturbance, not five).
    static func countDisturbances(_ intervals: [SleepInterval], spec: SleepSpec) -> Int {
        let sorted = intervals.filter { $0.durationSeconds > 0 }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return 0 }
        var merged: [SleepInterval] = []
        var current = sorted[0]
        for iv in sorted.dropFirst() {
            if iv.start - current.end <= spec.mergeGapSeconds {
                current = SleepInterval(start: current.start, end: max(current.end, iv.end))
            } else {
                merged.append(current)
                current = iv
            }
        }
        merged.append(current)
        return merged.filter { $0.durationSeconds >= spec.minEpisodeSeconds }.count
    }

    // MARK: - Pure helpers (identical on both platforms)

    /// Wrap-aware population standard deviation of times-of-day (seconds). Times are unwrapped to
    /// within ±half a day of the first sample, then a plain stdev is taken — so a tight cluster
    /// straddling midnight reads as tight. Uses only `+ − × ÷` and `sqrt` (IEEE-754 correctly
    /// rounded), keeping it bit-identical to the Kotlin mirror.
    static func circularSpreadSeconds(_ times: [Double]) -> Double {
        guard times.count >= 2 else { return 0 }
        let day = 86_400.0
        let anchor = times[0]
        let unwrapped = times.map { t -> Double in
            var d = (t - anchor).truncatingRemainder(dividingBy: day)
            if d < -day / 2 { d += day }
            if d >= day / 2 { d -= day }
            return anchor + d
        }
        let mean = unwrapped.reduce(0, +) / Double(unwrapped.count)
        let variance = unwrapped.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(unwrapped.count)
        return variance.squareRoot()
    }

    /// Wall-clock second-of-day for an epoch instant in a timezone (DST-correct via `Calendar`). Not
    /// elapsed-seconds-since-midnight: on a spring-forward day 07:00 is 25200 both sides of the
    /// transition, which is what keeps consistency stable across a DST night.
    static func localSecondsOfDay(epochSeconds: Double, tz: String) -> Double {
        let comps = DayAttribution.calendar(tz: tz)
            .dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: epochSeconds))
        let hourSeconds = (comps.hour ?? 0) * 3_600
        let minuteSeconds = (comps.minute ?? 0) * 60
        let seconds = comps.second ?? 0
        return Double(hourSeconds + minuteSeconds + seconds)
    }

    /// The calendar day before a "YYYY-MM-DD" key — the day whose exertion and naps feed this
    /// night's need. Computed over UTC (a civil date has no zone), so it is identical on both
    /// platforms regardless of the device timezone.
    static func previousDayKey(_ key: String) -> String {
        guard let d = DayAttribution.date(fromDayKey: key, tz: "UTC") else { return key }
        return DayAttribution.localDayKey(DayAttribution.addingDays(-1, to: d, tz: "UTC"), tz: "UTC")
    }

    /// Whole days from `a` to `b` (positive when `b` is later). Both keys are UTC midnights, so the
    /// difference is an exact day count — no DST fuzz.
    static func daysBetween(_ a: String, _ b: String) -> Int {
        guard let da = DayAttribution.date(fromDayKey: a, tz: "UTC"),
              let db = DayAttribution.date(fromDayKey: b, tz: "UTC") else { return 0 }
        return Int((db.timeIntervalSince(da) / 86_400).rounded())
    }

    private static func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }
}
