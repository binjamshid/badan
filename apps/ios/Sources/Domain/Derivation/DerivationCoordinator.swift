import Foundation

/// EPIC-23/24/25/26 — the ONE place the score engines are run in their cross-metric order.
///
/// The engines were built and tested in isolation (stages 1–2); this composes them, and nothing
/// else. It owns no scoring logic of its own — it decides only *what runs, in what order, over what
/// window*, so a divergence from the published order is a one-file diff a reviewer can check against
/// plan §18 rather than something spread across five call sites. Every engine it calls is
/// append-only and skip-if-identical (I2), so a repeat run over unchanged data writes nothing and
/// the read model (latest row per period) is unchanged — the coordinator adds no state that could
/// break that property.
///
/// **The order is load-bearing.** The plan's guidance chain reads "sleep → readiness → effort
/// guidance" (§18, line 1221), but that describes what is *displayed*, not the order scores are
/// *produced* in. The stored-value dependency graph has one edge the display chain hides: the
/// EPIC-24 sleep-need model consumes the **prior day's `effort.day`** as a published soft input
/// (absent → reduced-input, never imputed). So `effort.day` must be produced BEFORE sleep, or a
/// single recompute would compute sleep without the effort term and only pick it up on the *next*
/// run — a convergence lag that breaks single-pass idempotency. The correct produce order is:
/// 1. **Baselines first.** Every score is read against a personal baseline (never a population
///    norm, v1); sleep need, readiness z-positions and the effort guidance ceiling all resolve
///    `Baseline` rows, so those rows must be current before any score reads them.
/// 2. **Effort.** `effort.day` is a pure function of HR + profile — it reads no other score — so it
///    can (and must) be produced first among the composites, because sleep-need consumes it.
/// 3. **Sleep.** Reads the prior day's `effort.day` (now present, from step 2) and produces
///    `sleep.performance`, which readiness consumes.
/// 4. **Readiness.** Reads today's `sleep.performance` (step 3) plus the vitals baselines (step 1).
/// 5. **Stress (EPIC-34).** Reads raw daytime `heart.hrv` and nothing else — no baseline, no sibling
///    score — so its position is free; it runs LAST because it is the only step whose common outcome
///    is to write nothing at all, and a reader tracing the produce order should meet the four
///    composites before the gate. On a day the gate refuses (the default for Apple-Watch-class data)
///    `compute` persists nothing: no zero, no null row, no "no data" sentinel.
///
/// The display chain is still honoured end to end: readiness runs after sleep, and the
/// readiness-linked effort **guidance** (`EffortEngine.guidance`) is a READ model the UI calls on
/// demand — it reads whatever readiness this pass just wrote, so producing the effort *score* before
/// readiness never staled the *guidance* that depends on it. No stored value reads readiness except
/// that on-demand read model, so there is no cycle.
///
/// `DeviationEngine` (EPIC-27) is deliberately NOT run here: it writes nothing (it is a pure read
/// model over the `Baseline` rows step 1 already refreshed, built on demand by the Health Monitor
/// surface). Wiring a call to it here would compute a read model and discard it — so it is
/// constructed in the composition root and read by the UI, never "recomputed". See its own header.
///
/// Threading: the coordinator is synchronous and does no dispatching. Every caller already runs it
/// off the main actor inside the ingest→derive serialization (`SeedController.deriveAndGenerateInsights`
/// on iOS is only ever called from a detached task or the background queue), exactly as the bare
/// `BaselineEngine.recomputeAll` it replaces was.
final class DerivationCoordinator {
    private let baselines: BaselineEngine
    private let sleep: SleepIntelligenceEngine
    private let readiness: ReadinessEngine
    private let effort: EffortEngine
    /// EPIC-34. Optional only so the many test fixtures that predate it keep constructing a
    /// coordinator without one; the composition root always passes the real engine, so `nil` here
    /// means "a test that isn't exercising stress", never a shipped configuration.
    private let stress: StressEngine?
    /// Optional and defaulted nil for the same reason `stress` is: every existing construction site
    /// and test keeps compiling, and a build without it simply produces no mood estimate.
    private let mood: MoodEstimateWriter?
    private let config: Config

    /// Windows the coordinator scores over. Not algorithm constants (those live in `algorithms.json`
    /// per engine) — these are orchestration bounds: how far back a routine post-ingest/nightly pass
    /// re-scores the per-day composites so a just-completed night and any late-arriving overnight data
    /// are always picked up, without re-walking history on every debounced ingest.
    struct Config: Sendable, Hashable {
        /// How many recent local days (including `asOf`) a routine `recompute` re-scores for readiness
        /// and effort. Small on purpose: sleep already emits its own window of nights, baselines read
        /// their own trailing windows, and readiness/effort are the two per-day composites whose latest
        /// day flips as overnight data lands. Two days covers "this morning" plus a post-midnight sync
        /// that still belongs to yesterday. Deep historical (re)scoring is `backfill(from:to:)`, not this.
        let recentScoreDays: Int

        static let `default` = Config(recentScoreDays: 2)
    }

    init(baselines: BaselineEngine, sleep: SleepIntelligenceEngine, readiness: ReadinessEngine,
         effort: EffortEngine, stress: StressEngine? = nil,
         mood: MoodEstimateWriter? = nil, config: Config = .default) {
        self.baselines = baselines
        self.sleep = sleep
        self.readiness = readiness
        self.effort = effort
        self.stress = stress
        self.mood = mood
        self.config = config
    }

    // MARK: - Routine recompute (post-ingest debounced + nightly)

    /// Recompute baselines and the score cluster for `asOf`, in the cross-metric order above. This is
    /// what every ingest→derive path funnels through (replacing the bare `baselines.recomputeAll`).
    /// Idempotent at the read model: re-running over unchanged data appends nothing (each engine skips
    /// a write when its latest row for the period is already identical), so a debounced burst of
    /// ingests does not grow the derived log.
    func recompute(asOf: Date, tz: String = TimeZone.current.identifier) throws {
        // 1. Baselines — every score below reads these; they must be current first. The interim
        //    `readiness.score` composite is suppressed because the real `ReadinessEngine` (step 4) owns
        //    that id now; leaving both on would ping-pong a fresh row each per recompute (see the flag's
        //    doc on `recomputeAll`). `sleep.efficiency` is still emitted — a distinct, still-read metric.
        try baselines.recomputeAll(asOf: asOf, tz: tz, includeInterimReadinessComposite: false)

        // The last `recentScoreDays` local days, so a just-completed day and any late overnight data
        // are re-scored (a changed value APPENDS a fresh row, I2; an unchanged one is skipped).
        let days = recentDayStarts(asOf: asOf, tz: tz)

        // 2. Effort — produced BEFORE sleep because sleep-need consumes the prior day's `effort.day`.
        //    `effort.day` reads only HR + profile, so nothing it needs is missing at this point.
        for day in days {
            try effort.computeDay(asOf: day, tz: tz)
        }
        // Per-session workouts over the same window: a session synced from last night must still be
        // scored, and re-scoring an unchanged session is a no-op. Keyed `session:<id>`, so this never
        // competes with the per-day `effort.day` rows above.
        if let earliest = days.first {
            _ = try effort.computeWorkouts(from: earliest, to: asOf, tz: tz)
        }

        // 3. Sleep — reads the prior-day `effort.day` produced in step 2 and emits `sleep.performance`
        //    (+ need/debt/consistency/disturbances) for its own window of nights.
        try sleep.recompute(asOf: asOf, tz: tz)

        // 4. Readiness — reads today's `sleep.performance` (step 3) plus the vitals baselines (step 1).
        for day in days {
            try readiness.compute(asOf: day, tz: tz)
        }

        // 5. Stress — the density gate, then (only if it clears) a `stress.day_trend` row. A day the
        //    gate refuses writes nothing, which is the common case on phone-and-watch-class data.
        for day in days {
            try stress?.compute(asOf: day, tz: tz)
        }

        // 6. Mood estimate — LAST, because it reads what steps 3 and 5 wrote (`sleep.score` and, when
        //    the density gate allowed one, `stress.day_trend`) plus the resting-heart-rate baseline
        //    from step 1. It reads those rows rather than recomputing them, which is what keeps the
        //    stress density gate authoritative: a day that gate refused simply has no autonomic term
        //    here, and there is no path from this engine to the intraday index `StressEngine`
        //    declines to compute. Writes nothing when fewer than two terms exist, which is the normal
        //    state of a fresh install.
        for day in days {
            _ = try mood?.compute(asOf: day, tz: tz)
        }
    }

    // MARK: - Historical backfill (EPIC-23 score backfill, EPIC-26 HR-max edit)

    /// Re-derive baselines and the score cluster across `[from, to]`. Two callers, one shape:
    /// - EPIC-23: on first connect / after an import, score the freshly-ingested history so a user
    ///   does not open to a wall of "still settling in" for days that already have the data behind them.
    /// - EPIC-26: an HR-max/zone edit changes every effort score, so the whole window is re-derived;
    ///   because derivation is append-only (I2) that is a plain re-run, not a mutating path — the old
    ///   rows keep their `computed_at`/value/algorithm id and the latest-wins read surfaces the new ones.
    ///
    /// Ordered oldest→newest so an interrupted run (a background task hitting its budget) resumes
    /// cleanly from the last day it wrote. Returns a touched-day/session count for the caller's
    /// `BackgroundRun` bookkeeping. Idempotent: a re-run over unchanged data writes nothing.
    @discardableResult
    func backfill(from: Date, to: Date, tz: String = TimeZone.current.identifier) throws -> Int {
        // Same produce order as `recompute`, over the whole window: baselines, then effort (so sleep
        // sees the backfilled `effort.day`), then sleep, then readiness. Baselines and sleep are
        // anchored at `to` — `recomputeAll` reads each metric's own trailing window ending at `to`, and
        // sleep's gather window reaches back over the recent nights. (Nights older than sleep's fixed
        // window are not re-scored here — that is the nature of a bounded rolling measure, not a gap
        // this method can close by widening `from`.)
        try baselines.recomputeAll(asOf: to, tz: tz, includeInterimReadinessComposite: false)

        var touched = 0
        // Effort owns its own oldest→newest day+workout loop over the FULL window (append + supersede,
        // I2), so every backfilled day has an `effort.day` before sleep reads it as a prior-day input.
        touched += try effort.recompute(from: from, to: to, tz: tz)

        try sleep.recompute(asOf: to, tz: tz)

        var day = DayAttribution.startOfDay(from, tz: tz)
        let lastDayStart = DayAttribution.startOfDay(to, tz: tz)
        while day <= lastDayStart {
            if try readiness.compute(asOf: day, tz: tz) != nil { touched += 1 }
            // Stress over the same walk, so an import or a first-connect backfill leaves a real
            // `stress.day_trend` history rather than only today's row. Days the gate refuses are
            // skipped silently — they are not "touched", because nothing was written for them.
            if let stress, try stress.compute(asOf: day, tz: tz).trend != nil { touched += 1 }
            day = DayAttribution.addingDays(1, to: day, tz: tz)
        }
        return touched
    }

    // MARK: - Helpers

    /// The last `recentScoreDays` local-day starts up to and including `asOf`'s day, oldest first.
    /// Day-stepped via `DayAttribution` (DST-safe), matching every other calendar walk in the app.
    private func recentDayStarts(asOf: Date, tz: String) -> [Date] {
        let count = max(1, config.recentScoreDays)
        let today = DayAttribution.startOfDay(asOf, tz: tz)
        return (0..<count).reversed().map { DayAttribution.addingDays(-$0, to: today, tz: tz) }
    }
}
