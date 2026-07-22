import Foundation

/// EPIC-39 CYCLE-06 — phase-conditioned baseline wiring. This is the FIRST real caller of the
/// `covariateContext` hook `BaselineEngine.recompute(metricId:asOf:tz:context:)` already carries
/// (see that method's own header, "EPIC-39 prep"): the hook was built "additive... for free" and,
/// before this file, nothing in production code ever passed anything but the default `"default"`
/// context. Per that same plan claim, `BaselineEngine` and `DerivationRepository` need NO CODE
/// changes to support this, and this file makes none — every read/write below goes through their
/// existing, unmodified public surface.
///
/// **I7, corrected after audit**: a phase-conditioned `covariate_context` value ("menstrual",
/// "follicular", "ovulatory", "luteal") is itself cycle-derived, reproductive-health information —
/// exactly the class of "the identifier itself is the disclosure" case
/// `Storage/Repositories/CorrelationRepository.swift`'s own header already documents for
/// `journal.correlation.*` finding ids. An EARLIER version of this file passed the shared,
/// MAIN-DB-backed `BaselineEngine` straight through, which would have stored the phase word in
/// `badan.db`'s `baselines` table — outside `Database.purgeSensitiveNamespace()`'s reach forever.
/// The fix mirrors `CorrelationRepository` exactly rather than inventing a new pattern: sensitive
/// migration v6 (`Migrations.swift`) now ALSO creates a `baselines` table — byte-identical DDL/index
/// to the main one — inside `badan_sensitive.db`. `DerivationRepository`'s SQL references the bare
/// table name `baselines` with no schema qualifier, so it works unmodified against either
/// connection; the composition root is responsible for constructing a SEPARATE `BaselineEngine`
/// instance wired to `DerivationRepository(sensitive)` (reading raw metric values from the ordinary,
/// non-sensitive `MeasurementRepository(main)` — HRV/RHR/sleep readings are not sensitive
/// themselves, only the phase LABEL attached to them here is) and passing THAT INSTANCE, never the
/// shared main-DB one, as this function's `baselines:` parameter. This mirrors
/// `AppEnvironment`'s own existing `LoggingRepository(main:sensitive:)` composition style (mixing
/// connections within one feature is already this codebase's established pattern, not a new one).
/// `Database.purgeSensitiveNamespace()` needs no extension for this: it deletes and recreates the
/// whole `badan_sensitive.db` file, so the new `baselines` table there is covered by construction,
/// exactly like every other table `Schema.sensitiveMigrations` declares.
///
/// Scope, deliberately narrow:
/// - This type does **not** compute cycle phase. That is `CyclePredictionEngine.estimatePhase`
///   (`Domain/Cycle/`), which produces the `CyclePhaseEstimate` this coordinator is always handed
///   as an input, never one it goes looking for itself.
/// - This type does **not** decide when the existing unconditioned recompute runs. That stays
///   `DerivationCoordinator`'s job, and this coordinator's write side runs ADDITIONALLY to it —
///   never instead of it. A caller should invoke `DerivationCoordinator.recompute`/`recomputeAll`
///   for `asOf` first (as it already does today) and call
///   `maybeRecomputePhaseConditionedBaselines` afterward for the same `asOf`, so the unconditioned
///   `"default"` band (in `badan.db`, wholly unaffected by any of this) is always current even on a
///   day this coordinator declines to do extra work.
///
/// A plain enum with static functions, not a class or `@MainActor` type: unlike the engines it
/// composes with (`BaselineEngine`, `DeviationEngine`, ...), this coordinator holds no dependency as
/// stored state of its own — every repository/engine is passed in per call — so there is nothing
/// here an instance would own. It needs no main-actor isolation either: `BaselineEngine` itself is
/// already a plain synchronous class the ingest pipeline calls off the main actor
/// (`DerivationCoordinator`'s own header makes the same call for the same reason), and this
/// coordinator runs on that same thread.
enum CyclePhaseCovariateCoordinator {

    // MARK: - Tunable constants

    /// Minimum `CyclePhaseEstimate.confidence` required before a SECOND, phase-conditioned
    /// recompute is worth the extra baseline row. `0.5` — a coin-flip-or-better floor — matches the
    /// research doc's own graceful-degradation rule: phase should be "attached to baseline contexts
    /// only when confidence exceeds a minimum threshold... If confidence is low, BADAN should either
    /// widen the covariate band or fall back to unconditioned baselines rather than applying a
    /// misleading phase label" (`docs/BADAN_PERIOD_TRACKER_RESEARCH.md` §7). Below this floor, a
    /// phase-conditioned band would be built under a phase label BADAN itself is no more confident
    /// about than a coin flip — worse than simply not having one, since a stored band reads as a
    /// deliberate personal calibration to any future consumer. This is deliberately the SAME loose
    /// floor as a coin flip, not a stricter one: the READ side (`phaseAwareCalibration`) applies its
    /// own, separate point-count gate that catches a confidently-labelled-but-data-thin band, so
    /// this write-side gate only needs to keep out phase calls BADAN considers no-better-than-
    /// guessing in the first place.
    static let minPhaseConfidenceForConditionedRecompute: Double = 0.5

    /// The metrics this coordinator maintains a parallel phase-conditioned band for. A short,
    /// explicit list — mirroring `MetricID.correlatedScores`'s own "closed list, not every derived
    /// metric" reasoning (`Domain/MetricID.swift`) — rather than iterating every baseline-eligible
    /// metric in the registry: these three are exactly the vitals the research doc names as the
    /// WHOOP-gap-closing set ("BADAN should maintain parallel baselines such as `hrv baseline
    /// overall`, `hrv baseline follicular`, and `hrv baseline luteal`... Recovery, HRV, resting
    /// heart rate, sleep temperature deviation, and sleep-related readiness should all support
    /// phase-conditioned baselines", §7 "Baseline-aware recovery and vitals"). Widening this list to
    /// more of the registry is a deliberate product decision for a later slice, not an incidental
    /// side effect of this coordinator walking the whole registry.
    static let phaseConditionedMetricIds: [String] = [
        MetricID.hrv, MetricID.restingHeartRate, MetricID.sleepEfficiency,
    ]

    /// The floor a phase-conditioned baseline's `nPoints` must clear before `phaseAwareCalibration`
    /// treats it as trustworthy enough to surface AS a phase-conditioned reading, rather than
    /// silently falling back to `"default"`. Reuses `BaselineEngine.minPointsForConfident` — the
    /// SAME "enough to be honest" floor the unconditioned band itself is judged by — rather than a
    /// bespoke, looser constant: a phase-conditioned band earns no lower a bar than an ordinary one.
    /// It can only ever be MORE data-starved than the default band (it is drawn from a subset of the
    /// same history plus a phase-membership filter), never given an easier pass.
    static var minPointsForConditionedBaseline: Int { BaselineEngine.minPointsForConfident }

    // MARK: - Write side

    /// Given today's `CyclePhaseEstimate`, additionally recompute a phase-conditioned baseline
    /// (`context: phaseEstimate.phase.rawValue`) for every metric in `phaseConditionedMetricIds` —
    /// ON TOP OF, never instead of, the `"default"`-context recompute `DerivationCoordinator`
    /// already performs elsewhere in the same pass. See the type header for call-order expectations.
    ///
    /// `baselines` MUST be constructed with a SENSITIVE-backed `DerivationRepository` — see the type
    /// header's "I7, corrected after audit" note. Passing the shared main-DB `BaselineEngine` here
    /// would persist the phase word itself into `badan.db`, unreachable by
    /// `Database.purgeSensitiveNamespace()`.
    ///
    /// GATE (both must hold — the research doc's graceful-degradation section, §7):
    /// - `phaseEstimate.confidence >= minPhaseConfidenceForConditionedRecompute`.
    /// - `phaseEstimate.evidenceBasis == .calendarOnly`. `.insufficientHistory` and
    ///   `.suppressedDueToContext` fall back to `"default"` ONLY — conditioning a baseline on a
    ///   phase label BADAN itself is choosing not to stand behind (too little history logged yet,
    ///   or deliberately suppressed for a contraceptive/postpartum/other context) would manufacture
    ///   a personal band from exactly the situations `CyclePhaseEvidenceBasis` exists to admit
    ///   uncertainty about.
    ///
    /// Below the gate this is a deliberate no-op: it neither clears nor touches any previously
    /// written phase-conditioned rows (append-only derived data is never retracted, I2) — it simply
    /// performs no NEW work, and every read still goes through `phaseAwareCalibration`'s own,
    /// separate fallback logic. Above the gate, a metric with no data in its window is ALSO a silent
    /// no-op (`BaselineEngine.recompute`'s own existing behavior) — this coordinator adds no error
    /// path `recompute` didn't already have.
    static func maybeRecomputePhaseConditionedBaselines(
        phaseEstimate: CyclePhaseEstimate,
        baselines: BaselineEngine,
        asOf: Date,
        tz: String = TimeZone.current.identifier
    ) throws {
        guard phaseEstimate.confidence >= minPhaseConfidenceForConditionedRecompute,
              phaseEstimate.evidenceBasis == .calendarOnly else { return }

        let context = phaseEstimate.phase.rawValue
        for metricId in phaseConditionedMetricIds {
            try baselines.recompute(metricId: metricId, asOf: asOf, tz: tz, context: context)
        }
    }

    // MARK: - Read side

    /// The read-side helper every future UI/scoring consumer calls: prefer the phase-conditioned
    /// baseline for `metricId` under `phaseEstimate.phase` when one EXISTS and has enough backing
    /// points to be meaningful; otherwise gracefully fall back to the unconditioned `"default"`
    /// context; otherwise `nil`. Never throws for "no baseline yet" — only a genuine storage error
    /// propagates — and never hands back a phase-conditioned reading with too few points as though
    /// it were reliable, mirroring the same honesty rule `BaselineEngine`'s own `provisional` flag
    /// enforces for the unconditioned band (research doc §7: "if confidence is low... fall back to
    /// unconditioned baselines rather than applying a misleading phase label").
    ///
    /// Takes TWO `DerivationRepository` values rather than one, per the type header's "I7,
    /// corrected after audit" note: `sensitiveDerivation` is where a phase-conditioned row was
    /// actually written (the `baselines` table sensitive migration v6 adds), and `defaultDerivation`
    /// is the ordinary main-DB one every other metric's unconditioned `"default"` baseline already
    /// lives in. These are deliberately never the same connection — collapsing them back into one
    /// parameter is exactly the mistake this file was audited for. Takes `DerivationRepository`
    /// rather than `BaselineEngine` for either: `BaselineEngine`'s only baseline-reading method
    /// (`calibration(metricId:context:)`) returns a `BaselineCalibration` — tier/point-count/window
    /// only, no `center`/`spread`/`bandLow`/`bandHigh` — which is not enough for a caller to actually
    /// POSITION a reading against the band (exactly what this helper exists to let a caller do).
    /// Every other consumer of a raw `Baseline` in this codebase already reads
    /// `DerivationRepository.latestBaseline(metricId:context:)` directly for the same reason
    /// (`HomeScreen`, `BodyScreen`, `InsightEngine`, `DeviationEngine`, `ReadinessEngine` all do) —
    /// this follows that same, already-established convention rather than adding a new accessor to
    /// `BaselineEngine`, which this slice must not modify.
    ///
    /// Deliberately does NOT re-check `phaseEstimate.confidence`/`evidenceBasis` here the way the
    /// write side does: those gates decide whether a conditioned row was ever WRITTEN. Once
    /// written, whether it is fit to READ is a question of whether IT has enough of its own backing
    /// points — re-checking the estimate's confidence here would gate the same fact twice under two
    /// different rules, and could reject a perfectly good, well-populated band on a day its
    /// CONTEMPORANEOUS phase estimate happens to read low confidence for an unrelated reason (a
    /// gap in today's logging, say) even though the stored band itself remains exactly as reliable
    /// as it was when it was written.
    static func phaseAwareCalibration(
        metricId: String,
        phaseEstimate: CyclePhaseEstimate,
        sensitiveDerivation: DerivationRepository,
        defaultDerivation: DerivationRepository
    ) throws -> Baseline? {
        let phaseContext = phaseEstimate.phase.rawValue
        if let conditioned = try sensitiveDerivation.latestBaseline(metricId: metricId, context: phaseContext),
           conditioned.nPoints >= minPointsForConditionedBaseline {
            return conditioned
        }
        return try defaultDerivation.latestBaseline(metricId: metricId, context: "default")
    }
}
