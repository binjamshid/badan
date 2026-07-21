import Foundation

// MARK: - e1RM formulas

/// Which published formula produced an estimated one-rep max. Both are real, named, published
/// formulas — never invented — shown side by side rather than one replacing the other, since they
/// diverge meaningfully at higher rep counts and neither is universally more accurate than the
/// other (`docs/algorithms/strength.md`).
enum E1RMFormula: String, Codable, Hashable, Sendable, CaseIterable {
    case epley, brzycki
}

/// A labeled e1RM estimate. Per this codebase's I1/I2 convention, a computed number is never
/// carried alone — every value states the exact algorithm identity that produced it, so a stored
/// or displayed estimate can always be traced back to its formula and version.
struct EstimatedOneRepMax: Sendable, Hashable {
    let formula: E1RMFormula
    let valueKg: Double
    let algorithmId: String
    let algorithmVersion: String
}

// MARK: - Rep-range bucket

/// A PR is tracked PER rep bracket ("keyed by movement_id, rep_range" per plan), never as one
/// global number per movement. "Heaviest ever for 1 rep" and "heaviest ever for 10 reps" are
/// different claims about different kinds of strength; collapsing them into a single PR would
/// silently decide a question ("is 200kg x1 more impressive than 120kg x10?") this module has no
/// business answering.
enum RepRangeBucket: String, Codable, Hashable, Sendable, CaseIterable {
    case one = "1"
    case twoToThree = "2-3"
    case fourToSix = "4-6"
    case sevenToTen = "7-10"
    case elevenToFifteen = "11-15"
    case sixteenToTwenty = "16-20"
    case twentyOnePlus = "21+"

    /// The bucket a rep count falls into, or nil for a non-positive/nonsensical rep count (never
    /// silently clamped into a bucket it does not belong in).
    static func bucket(forReps reps: Int) -> RepRangeBucket? {
        switch reps {
        case 1: return .one
        case 2...3: return .twoToThree
        case 4...6: return .fourToSix
        case 7...10: return .sevenToTen
        case 11...15: return .elevenToFifteen
        case 16...20: return .sixteenToTwenty
        case 21...: return .twentyOnePlus
        default: return nil
        }
    }
}

// MARK: - Personal record (read model over an appended DerivedValue + InputManifest)

/// One (movement, rep-range) bucket's current record, as reconstructed from storage. Mirrors
/// `CorrelationFinding` in shape: `workout.strength.pr`'s registry row is `kind: "event"`,
/// `canonicalUnit: "count"` — the DerivedValue itself is an occurrence flag (`value == 1`), and
/// the actual weight/reps that earned it ride in the `InputManifest` under the same `stat:`
/// convention `CorrelationEngine.manifestInputs` established.
struct PersonalRecord: Sendable, Hashable {
    let movementId: String
    let bucket: RepRangeBucket
    let weightKg: Double
    let reps: Int
    let setId: String
    let achievedAt: Date
}

enum PRRefusalReason: Sendable, Hashable {
    case contractUnavailable
    case partialData
    case warmUpSet
    case unrecognizedReps
}

enum PRNotARecordReason: Sendable, Hashable {
    case notHeavierEnough(previousWeightKg: Double)
}

enum PROutcome: Sendable, Hashable {
    case newRecord(PersonalRecord)
    case notARecord(PRNotARecordReason)
    case refused(PRRefusalReason)
}

/// `workout.strength.pr`'s `periodKey` convention: `(movementId, RepRangeBucket)` encoded as
/// `"movement:<id>:reps:<bucket>"`. Mirrors `CorrelationMetricID`'s namespace-encoding idea, but
/// over `periodKey` rather than `metricId` — `workout.strength.pr` is already a single, complete
/// registry row (not a namespace awaiting per-pair suffixes the way `journal.correlation` is), so
/// the (movement, bucket) dimension belongs in the field `DerivedValue.periodKey` already uses for
/// non-time keys elsewhere (`"session:<ulid>"`).
enum StrengthPRPeriodKey {
    private static let prefix = "movement:"
    private static let repsMarker = ":reps:"

    static func make(movementId: String, bucket: RepRangeBucket) -> String {
        prefix + movementId + repsMarker + bucket.rawValue
    }

    static func parse(_ periodKey: String) -> (movementId: String, bucket: RepRangeBucket)? {
        guard periodKey.hasPrefix(prefix) else { return nil }
        let rest = periodKey.dropFirst(prefix.count)
        guard let markerRange = rest.range(of: repsMarker) else { return nil }
        let movementId = String(rest[rest.startIndex..<markerRange.lowerBound])
        let bucketRaw = String(rest[markerRange.upperBound...])
        guard !movementId.isEmpty, let bucket = RepRangeBucket(rawValue: bucketRaw) else { return nil }
        return (movementId, bucket)
    }
}

// MARK: - Session quality summary (pure, over a session's live sets)

/// One row's shape for `workout_quality` (migration 9), scoped to `metricFamily == "strength"`.
/// Computed here as a PURE function over a session's live `strength_sets` — persisting it belongs
/// to whichever slice writes session-level `workout_quality` rows (this file owns no repository
/// for that table; `StrengthSetRepository` only reaches `strength_sets`). `nil`, never a fabricated
/// `0`/`1`, when a session has nothing to measure yet — a false zero is exactly the kind of
/// precision this codebase refuses to invent.
struct StrengthQualitySummary: Sendable, Hashable {
    let metricFamily: String
    let completeness: Double?
    let continuity: Double?
    let accuracy: Double?
    let primarySourceId: String?
    let algorithmVersion: String
    let computedAt: Date
}

// MARK: - WorkoutQuality

/// EPIC-42/28 — e1RM estimation, PR detection, and per-session strength quality, all as pure,
/// device-free, deterministic functions over already-logged `StrengthSet` rows (fully unit-testable
/// without HealthKit, a live session, or BLE hardware — matches this slice's stated scope).
///
/// **e1RM** (`epley1RM`/`brzycki1RM`) are total functions over `(weightKg, reps)`; both refuse
/// (return nil) rather than guess once inputs stop being physically meaningful.
///
/// **PR detection** (`evaluatePR`) is the pure decision core; `recordIfPR` adds ONLY the
/// read-latest + append I/O around it, mirroring `CorrelationEngine.persist`/`StressEngine.persist`
/// exactly: read the current stored record, decide with the pure function, and on a genuine new
/// record APPEND a `DerivedValue` (I2) — never UPDATE/REPLACE a prior PR row. A repeat evaluation
/// that does not beat the stored record appends nothing.
enum WorkoutQuality {

    // MARK: e1RM

    /// Epley: `weight * (1 + reps/30)`. `epleyDivisor` (30) is the published constant; only the
    /// reps CEILING above which no estimate is emitted is tunable
    /// (`spec.params.epleyMaxRepsForEstimate`, `algorithms.json`'s `workout.strength.e1rm` entry).
    /// Refuses for non-finite/non-positive weight, non-positive reps, or reps past the ceiling —
    /// the same "refuse rather than guess" rule `evaluatePR` applies to partial sets.
    static func epley1RM(weightKg: Double, reps: Int, spec: StrengthSpec = .defaultShared) -> EstimatedOneRepMax? {
        guard spec.isLoaded, weightKg.isFinite, weightKg > 0, reps > 0,
              reps <= spec.params.epleyMaxRepsForEstimate else { return nil }
        let value = weightKg * (1 + Double(reps) / spec.params.epleyDivisor)
        guard value.isFinite, value > 0 else { return nil }
        return EstimatedOneRepMax(formula: .epley, valueKg: value,
                                  algorithmId: spec.epleyAlgorithm.algorithmId,
                                  algorithmVersion: spec.epleyAlgorithm.semver)
    }

    /// Brzycki: `weight * 36 / (37 - reps)`. The formula has its OWN singularity at
    /// `brzyckiRepsCeiling` (37) — the denominator hits zero there and goes negative beyond it —
    /// so this refuses at or beyond that reps count regardless of the separately tunable estimate
    /// ceiling (`maxRepsForEstimate`, lower than Epley's — Brzycki is widely considered less
    /// reliable at higher rep counts).
    static func brzycki1RM(weightKg: Double, reps: Int, spec: StrengthSpec = .defaultShared) -> EstimatedOneRepMax? {
        guard spec.isLoaded, weightKg.isFinite, weightKg > 0, reps > 0,
              reps <= spec.params.brzyckiMaxRepsForEstimate,
              Double(reps) < spec.params.brzyckiRepsCeiling else { return nil }
        let value = weightKg * spec.params.brzyckiConstant / (spec.params.brzyckiRepsCeiling - Double(reps))
        guard value.isFinite, value > 0 else { return nil }
        return EstimatedOneRepMax(formula: .brzycki, valueKg: value,
                                  algorithmId: spec.brzyckiAlgorithm.algorithmId,
                                  algorithmVersion: spec.brzyckiAlgorithm.semver)
    }

    /// Both published estimates for one set, each refusing independently (a set past Brzycki's
    /// lower cap can still return an Epley estimate). Empty — never guessed — for a partial set
    /// (`StrengthSet.isComplete == false`): estimating a max off a set missing its own weight or
    /// reps is exactly the false precision this module exists to refuse.
    static func estimatedOneRepMaxes(for set: StrengthSet, spec: StrengthSpec = .defaultShared) -> [EstimatedOneRepMax] {
        guard set.isComplete, let weightKg = set.weightKg, let reps = set.reps else { return [] }
        return [epley1RM(weightKg: weightKg, reps: reps, spec: spec),
                brzycki1RM(weightKg: weightKg, reps: reps, spec: spec)].compactMap { $0 }
    }

    // MARK: PR detection (pure core)

    /// Decides whether `candidate` sets a new PR against `previous` (the current stored record for
    /// its (movement, bucket), or nil if there is none). Pure — no I/O, no repository, injected
    /// `now` — so every named edge case (tie, unit switch, deload, partial data, warm-up) is a
    /// plain value-in/value-out assertion in `WorkoutQualityTests`.
    ///
    /// Refuses (never guesses) for: the contract failing to load, a warm-up set (excluded from PR
    /// logic BY DEFAULT per plan §7A.5/§9.18), a partial/incomplete set (missing movement, weight,
    /// reps, or unit), or a rep count with no defined bucket.
    ///
    /// A `previous` record older than `spec.params.prLookbackDays` no longer gates a new one — see
    /// `StrengthParams.prLookbackDays`'s doc for why a long-inactive PR should not stand forever as
    /// an unbeatable historical ceiling. Otherwise the comparison is STRICT and floor-gated:
    /// `candidate` must exceed `previous.weightKg * (1 + prMinImprovementFraction)`, so a
    /// floating-point tie (or a rounding-noise "improvement" of a hundredth of a kilogram) never
    /// registers as a new record, and — because the comparison always happens in canonical
    /// kilograms via `StrengthSet.weightKg` — a unit switch (kg logged, then lb logged, or vice
    /// versa) can never fabricate a PR from a raw-number artifact.
    static func evaluatePR(candidate: StrengthSet, previous: PersonalRecord?, now: Date,
                          spec: StrengthSpec = .defaultShared) -> PROutcome {
        guard spec.isLoaded else { return .refused(.contractUnavailable) }
        guard !candidate.isWarmUp else { return .refused(.warmUpSet) }
        guard candidate.isComplete, let weightKg = candidate.weightKg, let reps = candidate.reps,
              let movementId = candidate.movementId else { return .refused(.partialData) }
        guard let bucket = RepRangeBucket.bucket(forReps: reps) else { return .refused(.unrecognizedReps) }

        let effectivePrevious: PersonalRecord? = previous.flatMap { prev in
            guard prev.movementId == movementId, prev.bucket == bucket else { return nil }
            let ageDays = now.timeIntervalSince(prev.achievedAt) / 86_400
            return ageDays <= Double(spec.params.prLookbackDays) ? prev : nil
        }

        guard let effectivePrevious else {
            // No comparable prior record (none at all, a different bucket/movement, or aged out of
            // the lookback window) — the first complete, non-warm-up set in a bucket IS a record.
            return .newRecord(PersonalRecord(movementId: movementId, bucket: bucket, weightKg: weightKg,
                                             reps: reps, setId: candidate.id, achievedAt: candidate.recordedAt))
        }

        let threshold = effectivePrevious.weightKg * (1 + spec.params.prMinImprovementFraction)
        guard weightKg > threshold else {
            return .notARecord(.notHeavierEnough(previousWeightKg: effectivePrevious.weightKg))
        }
        return .newRecord(PersonalRecord(movementId: movementId, bucket: bucket, weightKg: weightKg,
                                         reps: reps, setId: candidate.id, achievedAt: candidate.recordedAt))
    }

    // MARK: PR detection (I/O: read-latest, decide, append-if-new)

    private static let prMetricId = "workout.strength.pr"   // registered in packages/metric-ontology/registry.json

    /// Reads the stored record for `candidate`'s (movement, bucket), decides via the pure
    /// `evaluatePR`, and — only on a genuine `.newRecord` — APPENDS it as a `DerivedValue` (I2):
    /// never UPDATE/REPLACE, so an earlier PR row keeps describing exactly what BADAN believed the
    /// record was at the time it was computed. Shape mirrors `CorrelationEngine.persist`/
    /// `StressEngine.compute` precisely: read-latest, pure-decide, append-if-changed.
    @discardableResult
    static func recordIfPR(candidate: StrengthSet, derivation: DerivationRepository, clock: Clock,
                          deviceId: String, spec: StrengthSpec = .defaultShared) throws -> PROutcome {
        guard spec.isLoaded else { return .refused(.contractUnavailable) }
        guard !candidate.isWarmUp else { return .refused(.warmUpSet) }
        guard candidate.isComplete, let movementId = candidate.movementId, let reps = candidate.reps
        else { return .refused(.partialData) }
        guard let bucket = RepRangeBucket.bucket(forReps: reps) else { return .refused(.unrecognizedReps) }

        let periodKey = StrengthPRPeriodKey.make(movementId: movementId, bucket: bucket)
        let previous = try readStoredRecord(periodKey: periodKey, derivation: derivation)
        let now = clock.now()
        let outcome = evaluatePR(candidate: candidate, previous: previous, now: now, spec: spec)
        guard case .newRecord(let record) = outcome else { return outcome }

        let manifest = InputManifest(id: ULID.newID(clock: clock), inputs: [
            .init(recordId: "stat:weight_kg", metricId: prMetricId, value: record.weightKg),
            .init(recordId: "stat:reps", metricId: prMetricId, value: Double(record.reps)),
            .init(recordId: "set:" + record.setId, metricId: prMetricId, value: record.weightKg),
        ])
        try derivation.transaction {
            try derivation.insertManifest(manifest)
            try derivation.appendDerived(DerivedValue(
                id: ULID.newID(clock: clock), metricId: prMetricId, value: 1, unit: "count",
                periodKey: periodKey, confidence: nil, provisional: spec.params.prProvisional,
                algorithmId: spec.prAlgorithm.algorithmId, algorithmVersion: spec.prAlgorithm.semver,
                inputManifestId: manifest.id, computedAt: now, updatedAt: now, originDeviceId: deviceId))
        }
        return outcome
    }

    /// Reconstructs the current stored record from the latest `workout.strength.pr` row for
    /// `periodKey` plus its manifest — the reader half of the `stat:` contract `recordIfPR` writes.
    /// Fails closed exactly like `CorrelationFinding.from(derived:manifest:)`: a manifest missing
    /// or short of its own stats is corruption, not a record to compare against, so nothing here is
    /// trusted from it and the caller proceeds as if there were no prior record.
    private static func readStoredRecord(periodKey: String, derivation: DerivationRepository) throws -> PersonalRecord? {
        guard let derived = try derivation.latestDerived(metricId: prMetricId, periodKey: periodKey),
              let (movementId, bucket) = StrengthPRPeriodKey.parse(derived.periodKey),
              let manifestId = derived.inputManifestId,
              let manifest = try derivation.manifest(id: manifestId) else { return nil }
        let stats = Dictionary(manifest.inputs.map { ($0.recordId, $0.value) }, uniquingKeysWith: { a, _ in a })
        guard let weightKg = stats["stat:weight_kg"], weightKg.isFinite, weightKg > 0,
              let repsValue = stats["stat:reps"], repsValue.isFinite, repsValue > 0 else { return nil }
        let setId = manifest.inputs.first { $0.recordId.hasPrefix("set:") }
            .map { String($0.recordId.dropFirst("set:".count)) } ?? ""
        return PersonalRecord(movementId: movementId, bucket: bucket, weightKg: weightKg,
                              reps: Int(repsValue), setId: setId, achievedAt: derived.computedAt)
    }

    // MARK: Session quality (pure)

    static let strengthMetricFamily = "strength"
    private static let qualityAlgorithmVersion = "workout.quality.strength@0.1.0"

    /// Honest quality signals over a session's LIVE strength sets. `nil` — never a fabricated
    /// `0`/`1` — when the session has nothing to measure (no live sets at all).
    ///
    /// - `completeness`: share of logged sets that are NOT partial (`StrengthSet.isComplete`). A
    ///   session interrupted mid-set (crash, phone locked) leaves a real, honest gap here.
    /// - `continuity`: share of the session's `seq` run (1...max) actually present. A hole in the
    ///   sequence — not merely "fewer sets than planned," an actual missing seq number — is the
    ///   signature of a lost write (or a deliberately deleted set); a fully contiguous log scores
    ///   1.0.
    /// - `accuracy`: share of sets tagged with a canonical `movementId` rather than only a
    ///   free-text `customLabel`. A recognized movement is what lets e1RM/PR/volume compute at
    ///   all, so this is a genuine analytical-accuracy signal — never a judgment about the workout
    ///   itself.
    /// - `primarySourceId`: always `"badan.manual"` — every strength set is logged by the lifter
    ///   directly (`StrengthSetRepository`'s header explains why the table carries no provenance
    ///   columns to read a real source from).
    static func computeStrengthQuality(sets: [StrengthSet], computedAt: Date) -> StrengthQualitySummary {
        let live = StrengthSetLedger.liveSets(sets)
        guard !live.isEmpty else {
            return StrengthQualitySummary(metricFamily: strengthMetricFamily, completeness: nil, continuity: nil,
                                          accuracy: nil, primarySourceId: nil,
                                          algorithmVersion: qualityAlgorithmVersion, computedAt: computedAt)
        }
        let completeCount = live.filter(\.isComplete).count
        let completeness = Double(completeCount) / Double(live.count)

        let seqs = Set(live.map(\.seq))
        let maxSeq = live.map(\.seq).max() ?? 0
        let continuity = maxSeq > 0 ? min(Double(seqs.count) / Double(maxSeq), 1.0) : 1.0

        let recognizedCount = live.filter { $0.movementId != nil }.count
        let accuracy = Double(recognizedCount) / Double(live.count)

        return StrengthQualitySummary(metricFamily: strengthMetricFamily, completeness: completeness,
                                      continuity: continuity, accuracy: accuracy,
                                      primarySourceId: "badan.manual", algorithmVersion: qualityAlgorithmVersion,
                                      computedAt: computedAt)
    }
}

// MARK: - Spec (published constants, mirrors ReadinessSpec/EffortSpec/StressSpec)

struct StrengthParams: Sendable, Hashable {
    let epleyDivisor: Double
    let epleyMaxRepsForEstimate: Int
    let brzyckiConstant: Double
    let brzyckiRepsCeiling: Double
    let brzyckiMaxRepsForEstimate: Int
    let prMinImprovementFraction: Double
    let prLookbackDays: Int
    let prProvisional: Bool
}

/// The three `algorithms.json` entries this module reads: Epley e1RM (`workout.strength.e1rm`,
/// already published as of Phase 0), Brzycki e1RM (`workout.strength.e1rm_brzycki`, added
/// alongside this slice), and PR detection (`workout.strength.pr`, already published). Loading all
/// three together — rather than three independent specs — keeps `defaultShared` a single frozen
/// snapshot of the contract, matching `EffortSpec`'s two-algorithm shape.
struct StrengthSpec: Sendable, Hashable {
    let epleyAlgorithm: AlgorithmVersion
    let brzyckiAlgorithm: AlgorithmVersion
    let prAlgorithm: AlgorithmVersion
    let params: StrengthParams
    let isLoaded: Bool

    private static let epleyId = "workout.strength.e1rm"
    private static let brzyckiId = "workout.strength.e1rm_brzycki"
    private static let prId = "workout.strength.pr"

    /// Resolve from a loaded `AlgorithmRegistry`. Returns `.unavailable` if any of the three
    /// entries or any required param is missing — the engine treats that as "compute nothing,"
    /// never as a cue to invent a default (mirrors `ReadinessSpec.load`/`EffortSpec.load`).
    static func load(from registry: AlgorithmRegistry) -> StrengthSpec {
        guard let epley = registry.definition(epleyId),
              let brzycki = registry.definition(brzyckiId),
              let pr = registry.definition(prId) else { return .unavailable }
        guard let epleyDivisor = epley.params["epleyDivisor"],
              let epleyMaxReps = epley.params["maxRepsForEstimate"],
              let brzyckiConstant = brzycki.params["brzyckiConstant"],
              let brzyckiCeiling = brzycki.params["brzyckiRepsCeiling"],
              let brzyckiMaxReps = brzycki.params["maxRepsForEstimate"],
              let minImprovement = pr.params["minImprovementFraction"],
              let lookbackDays = pr.params["lookbackDays"] else { return .unavailable }
        let params = StrengthParams(
            epleyDivisor: epleyDivisor, epleyMaxRepsForEstimate: Int(epleyMaxReps),
            brzyckiConstant: brzyckiConstant, brzyckiRepsCeiling: brzyckiCeiling,
            brzyckiMaxRepsForEstimate: Int(brzyckiMaxReps), prMinImprovementFraction: minImprovement,
            prLookbackDays: Int(lookbackDays), prProvisional: pr.provisional)
        return StrengthSpec(epleyAlgorithm: epley.algorithmVersion, brzyckiAlgorithm: brzycki.algorithmVersion,
                            prAlgorithm: pr.algorithmVersion, params: params, isLoaded: true)
    }

    /// The app-default spec, resolved once from the bundled contract.
    static let defaultShared = load(from: .shared)

    /// The degenerate "the contract did not load" spec. Never produces an estimate or a PR.
    static let unavailable = StrengthSpec(
        epleyAlgorithm: AlgorithmVersion(algorithmId: epleyId, semver: "0.0.0", introducedIn: "0.0.0"),
        brzyckiAlgorithm: AlgorithmVersion(algorithmId: brzyckiId, semver: "0.0.0", introducedIn: "0.0.0"),
        prAlgorithm: AlgorithmVersion(algorithmId: prId, semver: "0.0.0", introducedIn: "0.0.0"),
        params: StrengthParams(epleyDivisor: 0, epleyMaxRepsForEstimate: 0, brzyckiConstant: 0,
                               brzyckiRepsCeiling: 0, brzyckiMaxRepsForEstimate: 0,
                               prMinImprovementFraction: .greatestFiniteMagnitude, prLookbackDays: 0,
                               prProvisional: true),
        isLoaded: false)
}
