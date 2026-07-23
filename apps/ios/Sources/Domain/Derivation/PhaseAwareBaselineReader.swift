import Foundation

/// EPIC-39 CYCLE-06 integration debt, closed. `CycleModuleServices.refreshAll`'s own header names
/// this exact gap: "consuming that data from HomeScreen/BodyScreen/DeviationEngine's own read
/// paths is explicitly out of scope for this slice (tracked as later integration debt, not built
/// here)". This file is that later integration for HomeScreen's and BodyScreen's own baseline read
/// paths (`DeviationEngine` itself is untouched — a separate, still-open future slice).
///
/// This is a thin, pure orchestration layer over TWO already-built, unmodified pieces:
/// `CyclePhaseEstimateRepository.latestEstimate(asOf:)` (today's phase belief) and
/// `CyclePhaseCovariateCoordinator.phaseAwareCalibration` (the phase-vs-default band choice). It
/// adds exactly one thing neither of those provides on its own: the READ-SIDE gate deciding
/// whether today's estimate is even worth asking `phaseAwareCalibration` about in the first place.
///
/// SCOPE, deliberately narrow:
/// - Applies to EXACTLY `CyclePhaseCovariateCoordinator.phaseConditionedMetricIds` — read directly
///   off that closed list (never a hand-copied duplicate), so this consuming side can never
///   silently drift from the set of metrics the coordinator actually maintains a phase-conditioned
///   band for (today: `hrv`, `restingHeartRate`, `sleepEfficiency`). Every other metric id fails
///   the very first guard condition and falls straight through to the plain default read below —
///   bit-for-bit what a caller's own `defaultDerivation.latestBaseline(metricId:)` call would have
///   returned, with no extra query ever issued for it.
/// - A caller must already be about to read `defaultDerivation.latestBaseline(metricId:
///   context:"default")` for `metricId` — `read(...)` returns EXACTLY that value whenever the
///   cycle module is disabled, the metric is outside the closed list, or no confident
///   calendar-only phase estimate exists for `asOf` — so a user who has not enabled the cycle
///   module (or any read for a metric outside the three) observes bit-for-bit the same behavior as
///   before this file existed.
/// - "Confident" reuses `CyclePhaseCovariateCoordinator.minPhaseConfidenceForConditionedRecompute`
///   — the SAME floor the write side already requires before a phase-conditioned band is ever
///   written in the first place — so the read side never trusts an estimate the write side itself
///   would have refused to condition a band on. `phaseAwareCalibration`'s own `nPoints` gate
///   (`minPointsForConditionedBaseline`) is the second, independent honesty check; this type adds
///   no threshold of its own on top of it.
///
/// A plain enum with static functions — no stored state, mirroring `CyclePhaseCovariateCoordinator`
/// itself — safe to call from the `nonisolated` fetch cores running off the main actor
/// (`HomeViewModel.fetch`/`BodyViewModel.fetch`), exactly like that coordinator already is.
enum PhaseAwareBaselineReader {
    /// The outcome of one metric's phase-aware read.
    struct Result {
        /// Exactly what `defaultDerivation.latestBaseline(metricId:context:"default")` would have
        /// returned, UNLESS a phase-conditioned band was actually chosen instead — see `covariate`.
        var baseline: Baseline?
        /// Set ONLY when `baseline` is the phase-CONDITIONED reading, never on a fallback to
        /// default — a caller uses this, and only this, to decide whether to render the
        /// "compared with your usual {phase} pattern" indicator (research doc §7).
        var covariate: PhaseCovariateReading?
    }

    /// `phaseEstimates`/`sensitiveDerivation` are expected `nil` together whenever a caller has
    /// nothing to construct them from (the module is disabled) — kept optional so a caller can
    /// pass the module-disabled case straight through without paying for an ad hoc sensitive
    /// connection it would just discard.
    static func read(
        metricId: String,
        cycleModuleEnabled: Bool,
        phaseEstimates: CyclePhaseEstimateRepository?,
        sensitiveDerivation: DerivationRepository?,
        defaultDerivation: DerivationRepository,
        asOf: Date
    ) throws -> Result {
        guard cycleModuleEnabled,
              CyclePhaseCovariateCoordinator.phaseConditionedMetricIds.contains(metricId),
              let phaseEstimates, let sensitiveDerivation,
              let estimate = try phaseEstimates.latestEstimate(asOf: asOf),
              estimate.evidenceBasis == .calendarOnly,
              estimate.confidence >= CyclePhaseCovariateCoordinator.minPhaseConfidenceForConditionedRecompute
        else {
            return Result(baseline: try defaultDerivation.latestBaseline(metricId: metricId), covariate: nil)
        }

        let baseline = try CyclePhaseCovariateCoordinator.phaseAwareCalibration(
            metricId: metricId, phaseEstimate: estimate,
            sensitiveDerivation: sensitiveDerivation, defaultDerivation: defaultDerivation)
        // `phaseAwareCalibration` itself falls back to `"default"` when the phase-conditioned band
        // is missing or too thin (see its own doc) — only report a covariate when the band it
        // actually returned is the phase-conditioned one, never on that internal fallback.
        let covariate: PhaseCovariateReading? = (baseline?.covariateContext == estimate.phase.rawValue)
            ? PhaseCovariateReading(phase: estimate.phase, confidence: estimate.confidence)
            : nil
        return Result(baseline: baseline, covariate: covariate)
    }
}

/// Which phase a chosen phase-conditioned baseline is actually conditioned on, plus the
/// confidence of the estimate that licensed using it. Carried only when `PhaseAwareBaselineReader
/// .read` actually chose the phase-conditioned reading over the default one, so a caller can
/// render the one-tap-explainable indicator research doc §7 calls for ("Compared with your usual
/// late-luteal pattern" instead of "HRV is low") exactly where it applies, and nowhere else —
/// "Phase context should appear as optional overlay chips..., not forced narrative in every
/// screen" (same section's cross-app implementation rules).
struct PhaseCovariateReading: Equatable {
    var phase: CyclePhase
    /// 0...1 — the `CyclePhaseEstimate.confidence` that licensed this reading. Shown in the
    /// one-tap explainer, never inline in the caption itself (keeps the inline caption calm/short).
    var confidence: Double
}
