import Foundation

/// EPIC-25 — the morning Readiness composite (`readiness.score` v2), the recovery-equivalent that
/// answers "how do your overnight signals compare with your *own* usual pattern this morning?" on a
/// 0–100 scale. It is the product's transparency differentiator against WHOOP's black box: every
/// score ships with a published formula (`docs/algorithms/readiness.md`), a versioned
/// `AlgorithmVersion`, an `InputManifest` of exactly which records fed it, and a confidence flag.
///
/// **Four inputs, each read against the person, never a population norm:**
/// - overnight HRV (`heart.hrv`), RHR (`heart.rhr`) and respiratory rate (`respiratory.rate`) enter
///   as a personal **z-position** against their EPIC-23 baselines — where your own median is the
///   neutral 50, above/below moves the sub-score up or down by direction (higher HRV is favourable,
///   higher RHR/RR is not).
/// - `sleep.performance` (from the concurrent `SleepIntelligenceEngine`) enters as its **own
///   normalized value**: it already expresses last night against your personal need (itself a
///   baseline-derived quantity), so re-baselining it would double-count. It is a **soft dependency**
///   — absent, its term drops and the score runs as a labelled reduced-input variant, never imputed.
///
/// The weights (HRV 0.5, RHR 0.2, RR 0.1, sleep 0.2) are **BADAN's own launch weights, deliberately
/// not WHOOP's** — they live in `algorithms.json` as versioned DATA (`composite.readiness_score`) and
/// are loaded identically on both platforms via `ReadinessSpec`, so a divergence is
/// impossible-by-construction and a change is a reviewable diff + semver bump. The rationale and the
/// "why our number differs from WHOOP's" narrative are published in `docs/algorithms/readiness.md`.
///
/// The composite math (`ReadinessEngine.composite`) is pure and static so the pure-JVM Android port
/// produces byte-identical numbers from the same inputs — that cross-platform identity is the
/// acceptance golden. Everything is append-only and driven by an injected `Clock` (INVARIANT I2): a
/// morning compute writes a fresh `DerivedValue`; if late overnight data lands, a recompute APPENDS a
/// new row with a fresh `computedAt` and the old row keeps its own algorithm id — free auditability.
final class ReadinessEngine {
    private let derivation: DerivationRepository
    private let measurements: MeasurementRepository
    private let clock: Clock
    private let deviceId: String
    /// Resolved per compute rather than frozen at construction (D-35), so switching method takes
    /// effect on the next derivation instead of at the next launch. The default provider returns
    /// the spec passed in, which is exactly the old behaviour for every existing call site.
    private let specProvider: @Sendable () -> ReadinessSpec
    private var spec: ReadinessSpec { specProvider() }
    /// Source-priority resolver, mirroring the closure `DedupLite.reconcile` already takes. When two
    /// devices report the same night's HRV (a phone and a watch), the interval-record table keeps
    /// BOTH — dedup-lite only reconciles *sessions*, not vitals — so the engine resolves the conflict
    /// at read time by the SAME priority order ingestion assigns (watch > phone), and the winning
    /// record's id is what the manifest carries, so the anatomy lineage shows which device fed the
    /// score (plan §18 "conflicting HRV same-night → priority source wins … anatomy sheet shows which
    /// device"). The default `{ _ in 0 }` makes every source equal, falling back to the deterministic
    /// updatedAt/sourceId tie-break — the composition root injects the real priority map.
    private let priorityForSource: (String) -> Int
    /// EPIC-29 (plan §18 "`ContextStatus` … annotate confidence and copy … never the stored value").
    /// Resolves what the user declared over the day being scored. A FUNCTION, not a repository: the
    /// statuses live in the sensitive database and this engine holds only the main one — see
    /// `ContextAnnotationResolver` for why the boundary is crossed this way. Defaults to "no context
    /// ever", so an engine constructed without the seam annotates nothing rather than guessing.
    private let contextAnnotations: ContextAnnotationResolver
    /// D-36. Optional so an engine built without it (every existing test, and any build where the
    /// feature is off) simply never calibrates — the same "wired or inert" shape `phaseEstimates`
    /// and the score-backfill collaborators already use.
    private let feedbackRepo: FeedbackRepository?
    /// Whether the user has calibration switched on. A closure rather than a stored `Bool` because
    /// derivation runs off the main actor and must not read `@Observable` profile state; it reads
    /// `UserDefaults` at call time, exactly like `RouteConsentStore`.
    private let calibrationEnabled: @Sendable () -> Bool

    init(derivation: DerivationRepository, measurements: MeasurementRepository,
         clock: Clock, deviceId: String, spec: ReadinessSpec = .defaultShared,
         specProvider: (@Sendable () -> ReadinessSpec)? = nil,
         priorityForSource: @escaping (String) -> Int = { _ in 0 },
         contextAnnotations: @escaping ContextAnnotationResolver = noContextAnnotations,
         feedbackRepo: FeedbackRepository? = nil,
         calibrationEnabled: @escaping @Sendable () -> Bool = { false }) {
        self.derivation = derivation
        self.measurements = measurements
        self.clock = clock
        self.deviceId = deviceId
        self.specProvider = specProvider ?? { spec }
        self.priorityForSource = priorityForSource
        self.contextAnnotations = contextAnnotations
        self.feedbackRepo = feedbackRepo
        self.calibrationEnabled = calibrationEnabled
    }

    /// Frozen v2 identity, resolved from the contract (never hand-written — a change is a contract
    /// diff + semver bump). Superseding the legacy `composite.readiness_score@1.0.0` (the interim MVP
    /// composite `BaselineEngine` still appends) is an I2 migration, not a rewrite: this engine writes
    /// NEW rows stamped `@2.0.0`; every row already computed under `@1.0.0` keeps its old id and is
    /// never touched. The "latest `computedAt` wins" read then naturally surfaces the v2 value.
    var algorithm: AlgorithmVersion { spec.algorithm }

    // MARK: - Morning compute (trigger point)

    /// Compute the morning Readiness score for the local day containing `asOf` and, when it is
    /// scoreable, APPEND it as a `readiness.score` `DerivedValue` (v2). Returns the rich result (for
    /// the anatomy sheet and tests) or `nil` when the day cannot be honestly scored — fewer than
    /// `minInputsToScoreAtAll` inputs present, or the spec did not load. **An honest absence beats a
    /// confident number built from one input.**
    ///
    /// The composition lane owns the actual schedule (this is called once per morning when overnight
    /// data lands); a later call with late-arriving data recomputes and appends a fresh row (I2). The
    /// write is skipped only when an identical v2 row already exists for the day, so a repeat trigger
    /// over unchanged data does not grow the table — but a v1 row never blocks the first v2 write.
    @discardableResult
    func compute(asOf: Date, tz: String = TimeZone.current.identifier) throws -> ReadinessResult? {
        guard spec.isLoaded else { return nil }
        let dayKey = DayAttribution.localDayKey(asOf, tz: tz)

        let samples = try resolveInputs(dayKey: dayKey, asOf: asOf, tz: tz)
        guard let computation = Self.composite(present: samples, params: spec.params) else { return nil }
        // The declared context for the day being scored. Resolved AFTER the composite, and kept
        // beside it rather than inside it: `ReadinessComputation` is the pure, golden-tested output
        // and a context must not be able to reach into it. See `persist` for what it is allowed to
        // touch (the confidence, and only on the way to the row).
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let context = try contextAnnotations(dayStart, DayAttribution.addingDays(1, to: dayStart, tz: tz))
        let result = ReadinessResult(periodDayKey: dayKey, computation: computation, context: context)

        try persist(result: result)
        return result
    }

    // MARK: - Input resolution (I/O; the conflict + soft-dependency layer)

    /// The day's inputs, for the method preview (D-35).
    ///
    /// Read-only by construction: it returns samples and writes nothing, which is what lets
    /// `MethodPickerScreen` compute every candidate's number from ONE read without being able to
    /// append a row — `composite(present:params:)` takes no repository either.
    func inputSamplesForPreview(asOf: Date, tz: String = TimeZone.current.identifier) throws -> [ReadinessInputSample] {
        try resolveInputs(dayKey: DayAttribution.localDayKey(asOf, tz: tz), asOf: asOf, tz: tz)
    }

    /// Resolve the present inputs for `dayKey`. Missing inputs are simply absent from the returned
    /// array — never zero, never imputed (plan §18 "no imputation of physiological inputs, ever;
    /// missing-input days render as gaps"). A vital with no personal baseline is treated as absent
    /// too: scoring it would require a population norm, which v1 forbids.
    private func resolveInputs(dayKey: String, asOf: Date, tz: String) throws -> [ReadinessInputSample] {
        var samples: [ReadinessInputSample] = []
        // The three vitals: personal z-position against the EPIC-23 baseline.
        for slot in [ReadinessInput.hrv, .rhr, .respiratoryRate] {
            if let sample = try resolveVital(slot: slot, dayKey: dayKey, asOf: asOf, tz: tz) {
                samples.append(sample)
            }
        }
        // Sleep performance: soft dependency from the sibling engine, read from the derived store.
        if let sample = try resolveSleepPerformance(dayKey: dayKey) {
            samples.append(sample)
        }
        return samples
    }

    /// The winning day-record for a vital (source-priority resolved), turned into a personal
    /// z-position against its baseline. `nil` when there is no reading for the day or no baseline yet.
    private func resolveVital(slot: ReadinessInput, dayKey: String, asOf: Date, tz: String) throws -> ReadinessInputSample? {
        guard let record = try winningRecord(metricId: slot.metricId, dayKey: dayKey, asOf: asOf, tz: tz),
              let baseline = try derivation.latestBaseline(metricId: slot.metricId) else { return nil }
        let maturity = baseline.windowDays > 0
            ? min(1.0, Double(baseline.nPoints) / Double(baseline.windowDays)) : 0
        return ReadinessInputSample(
            input: slot, measuredValue: record.value, z: baseline.z(of: record.value),
            maturity: maturity, provisional: baseline.provisional,
            recordId: record.id, sourceId: record.provenance.sourceId)
    }

    /// The latest `sleep.performance` derived value for the day, if the sleep engine produced one.
    /// Its own `confidence`/`provisional` flags flow through so a shaky need estimate can't silently
    /// firm up the Readiness number.
    private func resolveSleepPerformance(dayKey: String) throws -> ReadinessInputSample? {
        guard let perf = try derivation.latestDerived(metricId: MetricID.sleepPerformance, periodKey: "day:" + dayKey) else { return nil }
        return ReadinessInputSample(
            input: .sleepPerformance, measuredValue: perf.value, z: nil,
            maturity: perf.confidence ?? 1.0, provisional: perf.provisional,
            recordId: perf.id, sourceId: nil)
    }

    /// Pick the day's winning interval record for a vital when more than one source reported it.
    ///
    /// Interval-record vitals are NOT run through dedup-lite (that reconciles sleep/workout
    /// *sessions*), so a phone and a watch each writing last night's HRV both survive as live rows.
    /// The winner is the **highest-priority source**; ties break by most-recent `updatedAt`, then the
    /// lexicographically smaller `sourceId` — deterministic, and priority-FIRST (unlike
    /// `BaselineEngine.latestPerDay`, which is recency-first because a baseline band does not need a
    /// single authoritative device). The chosen record's id rides into the manifest, so "which device
    /// fed the score" is answerable from lineage (I1/I5).
    private func winningRecord(metricId: String, dayKey: String, asOf: Date, tz: String) throws -> IntervalRecord? {
        // A padded window catches an overnight aggregate whose start sits in the prior evening; each
        // record is then attributed by its OWN timezone to the local day, exactly as everywhere else.
        let dayStart = DayAttribution.startOfDay(asOf, tz: tz)
        let from = DayAttribution.addingDays(-1, to: dayStart, tz: tz)
        let to = DayAttribution.addingDays(2, to: dayStart, tz: tz)
        let onDay = try measurements.intervalRecords(metricId: metricId, from: from, to: to)
            .filter { DayAttribution.localDayKey($0.startAt, tz: $0.tzId) == dayKey }
        return onDay.max { a, b in self.loses(a, to: b) }
    }

    /// True when `a` should lose to `b`: lower source priority loses; on equal priority the older
    /// `updatedAt` loses; on an exact tie the lexicographically larger `sourceId` loses.
    private func loses(_ a: IntervalRecord, to b: IntervalRecord) -> Bool {
        let pa = priorityForSource(a.provenance.sourceId)
        let pb = priorityForSource(b.provenance.sourceId)
        if pa != pb { return pa < pb }
        if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
        return a.provenance.sourceId > b.provenance.sourceId
    }

    // MARK: - Persistence (append-only, I2)

    private func persist(result: ReadinessResult) throws {
        let periodKey = "day:" + result.periodDayKey
        // The ONE line a declared context affects, anywhere in this engine. `result.score` below is
        // `result.computation.score` verbatim — a context has no expression that could change it
        // (`ContextAnnotation` carries a ceiling and sentences and no value field at all), and this
        // is the only place the annotation is read. Capped confidence also enters the skip check, so
        // declaring travel after the fact APPENDS a re-annotated row (I2) instead of being ignored
        // because the value happened to be unchanged.
        let confidence = result.publishedConfidence

        // D-36. The personal offset in force for THIS metric under THIS method, if any. `nil` means
        // no calibration applies — below the event floor, feedback given about another method, the
        // feature switched off, or (fail-closed) no contract entry at all.
        let calibration = try activeCalibration()
        let published = calibrationApplied(result.computation.score, calibration)

        // Skip only when an identical *v2* row already exists — a v1 legacy row (from the interim
        // BaselineEngine composite) must never block the first v2 write, or the migration would stall.
        //
        // D-36 adds the CALIBRATION ID to this comparison, for exactly the reason the version check
        // is already here: if a calibration changes but the adjusted value happens to round to the
        // same number, skipping would leave the latest row pointing at the OLD calibration through
        // its manifest — a row misreporting its own provenance. Costs one manifest read per period.
        //
        // Folding the calibration id into `algorithmVersion` ("2.0.0+cal.<id>") would have made the
        // existing comparison do this for free, and was rejected: it corrupts a semver field the
        // contract, `AlgorithmRegistryTests` and `DerivationPipelineTests` all compare against.
        if let existing = try derivation.latestDerived(metricId: MetricID.readinessScore, periodKey: periodKey),
           existing.algorithmId == algorithm.algorithmId, existing.algorithmVersion == algorithm.semver,
           Self.approximatelyEqual(existing.value, published),
           Self.approximatelyEqual(existing.confidence ?? -1, confidence),
           existing.provisional == result.computation.provisional,
           try existingCalibrationId(of: existing) == calibration?.id {
            return
        }

        try derivation.transaction {
            // One manifest input per PRESENT input. `value` is the raw measured reading (lineage: it
            // resolves through `recordId` to the very record, and its device, that fed the score);
            // `weight` carries that input's ADDITIVE CONTRIBUTION to the composite (points out of
            // 100), so the anatomy sheet renders contribution bars straight from the manifest and
            // Σ(weights) == the score by construction. See `docs/algorithms/readiness.md`.
            var inputs = result.computation.contributions.map {
                InputManifest.Input(recordId: $0.recordId, metricId: $0.metricId,
                                    value: $0.measuredValue, weight: $0.contribution)
            }
            // D-36 disclosure. A reserved synthetic `recordId`, following the convention
            // `CorrelationEngine` already documents for `stat:<name>` — the manifest is the surface
            // that explains a number, so a personally-adjusted number explains itself there. A
            // calibrated row therefore ALWAYS carries a manifest; it can never have a nil
            // `inputManifestId`, which is what would make the adjustment undisclosable.
            if let calibration {
                inputs.append(InputManifest.Input(recordId: calibration.manifestRecordId,
                                                  metricId: MetricID.readinessScore,
                                                  value: calibration.offset, weight: calibration.offset))
            }
            let manifest = InputManifest(id: ULID.newID(), inputs: inputs)
            try derivation.insertManifest(manifest)

            let now = clock.now()
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(), metricId: MetricID.readinessScore, value: published,
                unit: "score_0_100", periodKey: periodKey, confidence: confidence,
                provisional: result.computation.provisional, algorithmId: algorithm.algorithmId,
                algorithmVersion: algorithm.semver, inputManifestId: manifest.id,
                computedAt: now, updatedAt: now, originDeviceId: deviceId))
        }
    }

    // MARK: - Calibration (D-36)

    /// The offset in force, or `nil` for an uncalibrated row.
    ///
    /// Every gate is fail-closed: no feedback repository wired, the user switched calibration off,
    /// no contract entry, or too little feedback all resolve to "apply nothing" rather than to a
    /// default offset.
    ///
    /// This is the ONLY place in the app where a stored calibration reaches a computed value, which
    /// is why `readiness.score` is the only member of `CalibrationConsumers`. The hardcoded metric
    /// id below is not an oversight to be generalised in passing: an engine that wants a
    /// calibration has to read one here-shaped way and then be added to that list, in that order.
    private func activeCalibration() throws -> MetricCalibration? {
        guard let feedbackRepo, calibrationEnabled() else { return nil }
        return try feedbackRepo.latestCalibration(metricId: MetricID.readinessScore,
                                                  algorithmId: algorithm.algorithmId)
    }

    /// The calibration id an already-stored row was computed under, read from its manifest.
    private func existingCalibrationId(of existing: DerivedValue) throws -> String? {
        guard let manifestId = existing.inputManifestId,
              let manifest = try derivation.manifest(id: manifestId) else { return nil }
        return manifest.inputs
            .first { $0.recordId.hasPrefix(MetricCalibration.manifestRecordIdPrefix) }
            .map { String($0.recordId.dropFirst(MetricCalibration.manifestRecordIdPrefix.count)) }
    }

    /// The score with the offset applied, clamped back into the metric's own 0-100 range so a
    /// calibrated readiness is still a readiness.
    private func calibrationApplied(_ score: Double, _ calibration: MetricCalibration?) -> Double {
        guard let calibration else { return score }
        return min(100, max(0, score + calibration.offset))
    }

    // MARK: - Pure composite (identical on both platforms — golden-tested)

    /// The weighted composite, pure and deterministic. Given the PRESENT inputs (missing ones are
    /// simply absent from `present`) and the published params:
    ///
    /// 1. Each input → a 0–100 **sub-score**. Vitals: `50 + direction · clamp(z, ±zClamp)/zClamp · 50`
    ///    (own median = neutral 50). Sleep performance: its own value clamped to `[0, 100]` (100% of
    ///    need met = a full sub-score, not a neutral one — the deliberate frame difference documented
    ///    in `readiness.md`).
    /// 2. Present weights are **renormalized** over whatever is available (a dropped input redistributes
    ///    its weight; it is never replaced by a default), so the composite is the weighted mean of the
    ///    present sub-scores — always in `[0, 100]`.
    /// 3. **Confidence = weight-coverage × baseline-maturity.** Weight-coverage is the fraction of the
    ///    intended weight mass actually present, which caps a reduced-input score *without a separate
    ///    magic constant*: a missing HRV (weight 0.5) can never yield confidence above 0.5.
    ///
    /// Returns `nil` when fewer than `minInputsToScoreAtAll` inputs are present, or the present weights
    /// sum to zero — an honest absence, not a number pretending to be one.
    static func composite(present: [ReadinessInputSample], params: ReadinessParams) -> ReadinessComputation? {
        guard present.count >= params.minInputsToScoreAtAll else { return nil }
        let presentWeight = present.reduce(0.0) { $0 + params.weight(for: $1.input) }
        guard presentWeight > 0 else { return nil }

        let contributions: [ReadinessContribution] = present.map { sample in
            let sub = Self.subScore(sample, zClamp: params.zClampSigmas)
            let normalizedWeight = params.weight(for: sample.input) / presentWeight
            return ReadinessContribution(
                input: sample.input, metricId: sample.input.metricId, recordId: sample.recordId,
                measuredValue: sample.measuredValue, z: sample.z, subScore: sub,
                normalizedWeight: normalizedWeight, contribution: normalizedWeight * sub,
                sourceId: sample.sourceId)
        }

        let score = min(100, max(0, contributions.reduce(0.0) { $0 + $1.contribution }))
        // Weight-coverage is a ratio of fixed 2-decimal contract weights, so its only honest values
        // are points on the weight grid (multiples of 0.1 here). But IEEE-754 summation of the
        // present weights — 0.2 + 0.1 + 0.2 — overshoots 0.5 by one ULP, which pushes a missing-HRV
        // score's confidence just above the 0.5 cap THIS fraction is meant to enforce (see the doc
        // comment above: "a missing HRV can never yield confidence above 0.5"). Round the sub-nano
        // noise away so the published invariant holds exactly, on both platforms identically. No
        // legitimate value is disturbed: every real coverage is a multiple of 0.1 and rounds to itself.
        let weightCoverage = (presentWeight / params.totalWeight * 1_000_000).rounded() / 1_000_000
        let maturity = present.map(\.maturity).min() ?? 0
        let confidence = min(1.0, max(0.0, weightCoverage * maturity))

        // The variant is the coarse "is this the full model or a degraded one" flag; confidence is
        // the fine signal. Full requires the HRV anchor AND at least `minInputsForFullScore` inputs —
        // so any missing-HRV score, and any two-input score, is a distinctly-labelled reduced variant.
        let present0 = Set(present.map(\.input))
        let hasHrv = present0.contains(.hrv)
        let variant: ReadinessVariant = (hasHrv && present.count >= params.minInputsForFullScore)
            ? .full
            : .reducedInput(missing: ReadinessInput.allCases.filter { !present0.contains($0) })

        // Provisional is a cold-start / not-yet-validated fact, independent of completeness: the
        // algorithm being provisional, or ANY contributing baseline (or the sleep term) still
        // provisional, means nothing may render as a confident score yet.
        let provisional = params.algorithmProvisional || present.contains { $0.provisional }

        return ReadinessComputation(score: score, confidence: confidence, provisional: provisional,
                                    variant: variant, contributions: contributions)
    }

    /// One input's 0–100 sub-score. Vitals map their clamped, direction-applied z through the neutral
    /// 50; sleep performance is already personal-need-relative, so its own value carries through.
    static func subScore(_ sample: ReadinessInputSample, zClamp: Double) -> Double {
        if sample.input.scoresFromValueDirectly {
            return min(100, max(0, sample.measuredValue))
        }
        guard zClamp > 0 else { return 50 }
        let directedZ = sample.input.direction * clamp(sample.z ?? 0, -zClamp, zClamp)
        return 50 + directedZ / zClamp * 50
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

    private static func approximatelyEqual(_ a: Double, _ b: Double, tolerance: Double = 1e-9) -> Bool {
        abs(a - b) < tolerance
    }
}

// MARK: - Inputs

/// The four Readiness inputs. Each declares which contract weight it draws, whether higher-than-normal
/// is favourable (`direction`), and whether it is already a personal-need-relative value that scores
/// from itself rather than from a baseline z-position (`scoresFromValueDirectly`, sleep only).
enum ReadinessInput: String, CaseIterable, Sendable, Hashable {
    case hrv
    case rhr
    case respiratoryRate
    case sleepPerformance

    var metricId: String {
        switch self {
        case .hrv: return MetricID.hrv
        case .rhr: return MetricID.restingHeartRate
        case .respiratoryRate: return MetricID.respiratoryRate
        case .sleepPerformance: return MetricID.sleepPerformance
        }
    }

    /// +1 when a reading above the personal baseline is favourable (HRV), −1 when it is not (RHR, RR).
    /// Unused for `sleepPerformance`, which scores from its own value.
    var direction: Double {
        switch self {
        case .hrv: return 1
        case .rhr, .respiratoryRate: return -1
        case .sleepPerformance: return 1
        }
    }

    var scoresFromValueDirectly: Bool { self == .sleepPerformance }

    /// The `algorithms.json` param name carrying this input's launch weight.
    var weightKey: String {
        switch self {
        case .hrv: return "weightHrv"
        case .rhr: return "weightRhr"
        case .respiratoryRate: return "weightRespiratoryRate"
        case .sleepPerformance: return "weightSleepPerformance"
        }
    }
}

/// One resolved, present input feeding the composite. `z` is `nil` for `sleepPerformance` (it scores
/// from `measuredValue` directly); `maturity`/`provisional` carry the contributing baseline's (or the
/// sleep term's) calibration state so confidence and the provisional flag stay honest.
struct ReadinessInputSample: Sendable, Hashable {
    let input: ReadinessInput
    let measuredValue: Double
    let z: Double?
    let maturity: Double
    let provisional: Bool
    let recordId: String
    let sourceId: String?

    init(input: ReadinessInput, measuredValue: Double, z: Double?, maturity: Double,
         provisional: Bool, recordId: String, sourceId: String?) {
        self.input = input; self.measuredValue = measuredValue; self.z = z
        self.maturity = maturity; self.provisional = provisional
        self.recordId = recordId; self.sourceId = sourceId
    }
}

// MARK: - Result read models

/// Which model produced the score. `full` used the HRV anchor and at least `minInputsForFullScore`
/// inputs; `reducedInput` names the missing inputs so the surface labels the degradation DISTINCTLY
/// rather than passing a thinner score off as the full one (plan §18 cold-start rule).
enum ReadinessVariant: Sendable, Hashable {
    case full
    case reducedInput(missing: [ReadinessInput])
}

/// One input's line in the anatomy sheet: its raw value, its z-position (vitals), its 0–100 sub-score,
/// the renormalized weight actually applied, and the additive `contribution` (= `normalizedWeight ·
/// subScore`) whose sum is the score. `sourceId` names the device the winning record came from.
struct ReadinessContribution: Sendable, Hashable {
    let input: ReadinessInput
    let metricId: String
    let recordId: String
    let measuredValue: Double
    let z: Double?
    let subScore: Double
    let normalizedWeight: Double
    let contribution: Double
    let sourceId: String?
}

/// The pure output of the composite — everything the anatomy sheet needs, with no I/O or clock in
/// sight, so both platforms compute byte-identical numbers (the acceptance goldens assert exactly
/// this). `provisional` mirrors what is stamped on the row; `confidence` is the finer signal.
struct ReadinessComputation: Sendable, Hashable {
    let score: Double
    let confidence: Double
    let provisional: Bool
    let variant: ReadinessVariant
    let contributions: [ReadinessContribution]
}

/// A computed Readiness result for a specific local day — the pure computation, the day it
/// describes, and whatever the user had declared over that day. What `compute(asOf:)` returns and
/// persists.
///
/// The context sits BESIDE the computation, never inside it: `score` is reachable only through
/// `computation`, which no context can touch, while the only context-derived quantity this type
/// exposes is `publishedConfidence`. "The number changed because I said I was travelling" therefore
/// has no expression here — it would take a new stored property, in a review that would have to
/// argue against this paragraph.
struct ReadinessResult: Sendable, Hashable {
    let periodDayKey: String
    let computation: ReadinessComputation
    /// What the user declared over this day (`.none` = an ordinary day, the common case).
    let context: ContextAnnotation

    init(periodDayKey: String, computation: ReadinessComputation, context: ContextAnnotation = .none) {
        self.periodDayKey = periodDayKey
        self.computation = computation
        self.context = context
    }

    /// The confidence that goes on the row: the composite's own, capped by any declared context.
    /// Monotonic downward by `ContextAnnotation.applying(to:)` — a context can only ever make BADAN
    /// less sure. `applying(to:)` returns nil only for a nil input, which this never is.
    var publishedConfidence: Double {
        context.applying(to: computation.confidence) ?? computation.confidence
    }
}

// MARK: - Spec (data-driven params, mirror of BaselineSpec)

/// The numeric params the pure composite needs — the weights, the z clamp, the completeness gates,
/// plus whether the algorithm is still provisional. Resolved once from `composite.readiness_score` in
/// `algorithms.json`; the pure function takes THIS, never the registry, so it stays I/O-free.
struct ReadinessParams: Sendable, Hashable {
    let weights: [ReadinessInput: Double]
    let zClampSigmas: Double
    let minInputsForFullScore: Int
    let minInputsToScoreAtAll: Int
    /// From the contract entry's `provisional` flag — a provisional algorithm stamps every row it
    /// produces `provisional = true`, so the surface can say the constants are not yet validated.
    let algorithmProvisional: Bool

    func weight(for input: ReadinessInput) -> Double { weights[input] ?? 0 }
    /// The full intended weight mass. Used for weight-coverage (the confidence cap denominator); read
    /// from the params rather than assumed to be 1.0, so a future re-weighting stays self-consistent.
    var totalWeight: Double { weights.values.reduce(0, +) }
}

/// The data-driven Readiness spec. This is the ONLY place the weights, clamp and gates enter the
/// engine — never hardcoded — so the two platforms cannot drift and a change is a reviewable one-line
/// diff in the contract plus a semver bump. A spec that failed to load (`isLoaded == false`) makes the
/// engine COMPUTE NOTHING rather than invent constants (mirror of `BaselineSpec`).
struct ReadinessSpec: Sendable, Hashable {
    let algorithm: AlgorithmVersion
    let params: ReadinessParams
    let isLoaded: Bool

    /// The method the engine ran before methods were selectable, and still the fallback whenever a
    /// stored choice cannot be honoured (D-35 — see `MethodResolver`).
    static let contractId = "composite.readiness_score"

    /// Resolve from a loaded `AlgorithmRegistry`. Returns `.unavailable` if the entry or any required
    /// param is missing — the engine treats that as "compute nothing", never as a cue to invent one.
    ///
    /// `contractId` is a parameter (D-35) so an alternative weighting can be loaded through the very
    /// same path. That is safe precisely because every alternative is a Class-A variant: identical
    /// computation, identical param NAMES, different constants. An entry that failed to supply a
    /// param resolves to `.unavailable` by the same `guard let` chain below, so fail-closed
    /// behaviour is unchanged and a malformed variant can never quietly fall back to the default's
    /// numbers while claiming to be itself.
    static func load(from registry: AlgorithmRegistry,
                     contractId: String = ReadinessSpec.contractId) -> ReadinessSpec {
        guard let def = registry.definition(contractId) else { return .unavailable }
        var weights: [ReadinessInput: Double] = [:]
        for input in ReadinessInput.allCases {
            guard let w = def.params[input.weightKey] else { return .unavailable }
            weights[input] = w
        }
        guard let zClamp = def.params["zClampSigmas"],
              let minFull = def.params["minInputsForFullScore"],
              let minAny = def.params["minInputsToScoreAtAll"] else { return .unavailable }
        let params = ReadinessParams(
            weights: weights, zClampSigmas: zClamp, minInputsForFullScore: Int(minFull),
            minInputsToScoreAtAll: Int(minAny), algorithmProvisional: def.provisional)
        return ReadinessSpec(algorithm: def.algorithmVersion, params: params, isLoaded: true)
    }

    /// The app-default spec, resolved once from the bundled contract.
    ///
    /// Keeps its exact original meaning: one frozen snapshot of the DEFAULT method. A chosen
    /// alternative is loaded per-derivation by the coordinator, never by mutating this.
    static let defaultShared = load(from: .shared)

    /// The degenerate "the contract did not load" spec. Never produces a score.
    static let unavailable = ReadinessSpec(
        algorithm: AlgorithmVersion(algorithmId: ReadinessSpec.contractId, semver: "0.0.0", introducedIn: "0.0.0"),
        params: ReadinessParams(weights: [:], zClampSigmas: 0, minInputsForFullScore: 0,
                                minInputsToScoreAtAll: .max, algorithmProvisional: true),
        isLoaded: false)
}
