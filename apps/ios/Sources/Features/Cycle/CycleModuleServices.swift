import Foundation

// MARK: - EPIC-39 (Phase 3F slice 2) — cycle module composition layer.
//
// This is Lane A's own composition root for the cycle module's UI lanes: mirrors
// `LabNotebookServices`'s pattern exactly (`Features/Labs/LabNotebookHomeScreen.swift`) — a
// `@MainActor` struct constructed once per top-level screen instance from `AppEnvironment`,
// NOT added to `AppEnvironment` itself, for the same reason that slice's own doc gives (this
// slice's owned files are a small, closed set; promoting this into `AppEnvironment` is a future,
// separate change once every lane's routing has landed).
//
// Every repository below is constructed against `env.database.sensitive` ONLY — never
// `env.database.main` — per I7 and the reproductive-data threat model's own framing
// (`docs/legal/reproductive-threat-model.md` §1/§5): this is BADAN's single highest-sensitivity
// data family, and a cycle row landing in `badan.db` would silently escape
// `Database.purgeSensitiveNamespace()`'s reach.
//
// Holds a reference to `env` itself (unlike `LabNotebookServices`, which only extracts
// `deviceId`) because `refreshAll` below needs to read `env.profile.cycleModuleEnabled` /
// `cyclePredictionsPaused` LIVE at call time (they can change between construction and a later
// call), and needs `env.measurements`/`env.registry`/`env.clock`/`env.deviceId` to construct a
// fresh, correctly-wired `BaselineEngine` per call. `AppEnvironment` is a reference type, so
// holding it costs nothing extra and never goes stale.
@MainActor
struct CycleModuleServices {
    let cycleRecords: CycleRecordRepository
    let flowLogs: FlowLogRepository
    let contraceptiveContext: ContraceptiveContextRepository
    let predictions: CyclePredictionRepository
    let phaseEstimates: CyclePhaseEstimateRepository
    let anomalies: CycleAnomalyEventRepository
    let deviceId: String

    private let env: AppEnvironment

    /// Frozen algorithm identities for this composition layer's own calls into the pure engines.
    /// Not tied to `BaselineEngine.baselineAlgorithm`'s own versioning scheme (that identifies the
    /// BASELINE math; these identify the cycle engines' own output shape) — a future change to
    /// either engine's math is a semver bump here, independent of the baseline contract.
    static let predictionAlgorithmVersion = "cycle.prediction@1.0.0"
    /// Matches the exact string `CyclePhaseCovariateCoordinatorTests`'s own fixtures already use
    /// for this same conceptual identity, so a shared fixture string never silently drifts between
    /// that suite and this one.
    static let phaseEstimateAlgorithmVersion = "cycle.phase_estimate@1.0.0"
    static let anomalyAlgorithmVersion = "cycle.anomaly@1.0.0"

    init(env: AppEnvironment) {
        let sensitive = env.database.sensitive
        cycleRecords = CycleRecordRepository(sensitive: sensitive)
        flowLogs = FlowLogRepository(sensitive: sensitive)
        contraceptiveContext = ContraceptiveContextRepository(sensitive: sensitive)
        predictions = CyclePredictionRepository(sensitive: sensitive)
        phaseEstimates = CyclePhaseEstimateRepository(sensitive: sensitive)
        anomalies = CycleAnomalyEventRepository(sensitive: sensitive)
        deviceId = env.deviceId
        self.env = env
    }

    // MARK: - refreshAll

    /// Called by UI after any write action (logging a period/flow/contraceptive-context change).
    /// Five steps, in order — every one of them documented here so a future reader can verify
    /// nothing was skipped:
    ///
    /// 1. Fetch live cycles/flowLogs/contraceptiveContext from the repositories.
    /// 2. `prediction = CyclePredictionEngine.predictNextCycle(...)`; ALWAYS appended via
    ///    `predictions.appendPrediction` (I2 — append-only, matches `DerivedTrend`'s "just append,
    ///    latest wins on read" convention already used elsewhere in this codebase). No
    ///    skip-if-unchanged check — appending on every real write action is the documented safe
    ///    default for this slice.
    /// 3. `phaseEstimate = CyclePredictionEngine.estimatePhase(...)`; always appended via
    ///    `phaseEstimates.appendEstimate`.
    /// 4. IFF `env.profile.cycleModuleEnabled` AND NOT `env.profile.cyclePredictionsPaused`:
    ///    construct a SENSITIVE-backed `BaselineEngine` (derivation over
    ///    `DerivationRepository(env.database.sensitive)`, measurements/registry/clock/deviceId from
    ///    `env`'s own real properties — never `env`'s shared main-DB baselines engine) and call
    ///    `CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines`. This is the ONLY
    ///    place in this slice that touches phase-conditioned baselines; consuming that data from
    ///    HomeScreen/BodyScreen/DeviationEngine's own read paths is explicitly out of scope for this
    ///    slice (tracked as later integration debt, not built here).
    /// 5. `events = CycleAnomalyEngine.detectAnomalies(...)`. **Dedup rule**: a detected event is
    ///    appended via `anomalies.appendEvent` ONLY IF there is no existing LIVE event (fetched via
    ///    `anomalies.liveEvents()`, i.e. not soft-deleted) of the SAME `type` whose `state != .dismissed`
    ///    already on file. `.active`/`.acknowledged`/`.suppressed` all count as "still live" for this
    ///    check — only a user's explicit `.dismissed` lets a fresh detection of the same type land
    ///    again. This is a simple type-based dedup so `refreshAll` can be called liberally (after
    ///    every log action) without spamming duplicate cards for the same ongoing condition.
    func refreshAll(asOf: Date) throws {
        // Step 1.
        let cycles = try cycleRecords.liveRecords()
        let activeContraceptiveContext = try contraceptiveContext.activeContext()
        var allFlowLogs: [FlowLog] = []
        for cycle in cycles {
            allFlowLogs.append(contentsOf: try flowLogs.liveLogs(cycleId: cycle.id))
        }

        // Step 2. `CyclePredictionEngine` has no device-identity input (pure, storage-free — see
        // its own file header's "STATED GAP" note), so every row it returns carries the documented
        // placeholder `CyclePredictionEngine.unstampedOriginDeviceId`. This composition layer is the
        // persistence boundary that note names as responsible for overwriting it with the real
        // device id before the row is ever stored.
        var prediction = CyclePredictionEngine.predictNextCycle(
            history: cycles, contraceptiveContext: activeContraceptiveContext, asOf: asOf,
            algorithmVersion: Self.predictionAlgorithmVersion)
        prediction.originDeviceId = deviceId
        try predictions.appendPrediction(prediction)

        // Step 3. Same stamping responsibility as step 2, above.
        var phaseEstimate = CyclePredictionEngine.estimatePhase(
            history: cycles, contraceptiveContext: activeContraceptiveContext, asOf: asOf,
            algorithmVersion: Self.phaseEstimateAlgorithmVersion)
        phaseEstimate.originDeviceId = deviceId
        try phaseEstimates.appendEstimate(phaseEstimate)

        // Step 4.
        if env.profile.cycleModuleEnabled && !env.profile.cyclePredictionsPaused {
            let sensitiveDerivation = DerivationRepository(env.database.sensitive)
            let sensitiveBaselines = BaselineEngine(
                derivation: sensitiveDerivation, measurements: env.measurements,
                registry: env.registry, clock: env.clock, deviceId: env.deviceId)
            try CyclePhaseCovariateCoordinator.maybeRecomputePhaseConditionedBaselines(
                phaseEstimate: phaseEstimate, baselines: sensitiveBaselines, asOf: asOf)
        }

        // Step 5. `detectAnomalies` already takes `originDeviceId` directly (unlike the two engine
        // calls above), so every returned `CycleAnomalyEvent` already carries the real device id —
        // no stamping needed here.
        let detected = CycleAnomalyEngine.detectAnomalies(
            cycles: cycles, flowLogs: allFlowLogs, prediction: prediction, asOf: asOf,
            algorithmVersion: Self.anomalyAlgorithmVersion, originDeviceId: deviceId)
        let existingLive = try anomalies.liveEvents()
        let typesAlreadyLive = Set(existingLive.filter { $0.state != .dismissed }.map(\.type))
        for event in detected where !typesAlreadyLive.contains(event.type) {
            try anomalies.appendEvent(event)
        }
    }

    // MARK: - purgeCycleData

    /// CYCLE-08's "purge" control — a real per-module purge of the user's own cycle-family rows,
    /// distinct from the whole-`badan_sensitive.db`-file deletion `Database.purgeSensitiveNamespace()`
    /// performs for the "disable all sensitive modules" case. Every step named here so a future
    /// reader can verify nothing was missed, per CYCLE-08's "purge deletes rows AND invalidates
    /// derived values" requirement:
    ///
    /// 1. `DELETE FROM` each of the 6 cycle tables (`cycle_records`, `flow_logs`,
    ///    `contraceptive_context_logs`, `cycle_predictions`, `cycle_phase_estimates`,
    ///    `cycle_anomaly_events`) — plain deletes via `env.database.sensitive` directly, since no
    ///    repository here exposes a "delete everything" method of its own.
    /// 2. ALSO deletes phase-conditioned baseline rows from the sensitive `baselines` table (added
    ///    in migration v6 specifically for `CyclePhaseCovariateCoordinator`) WHERE
    ///    `covariate_context IN (<CyclePhase's own rawValues>)` — read directly off
    ///    `CyclePhase.allCases`, never a hand-copied list, so this can never silently drift from the
    ///    real set of phase words the coordinator ever writes. This is what makes a purge also
    ///    invalidate the derived phase-conditioned bands, not just the raw/derived cycle rows above.
    ///
    /// Both steps run in ONE transaction — a purge either fully lands or fully doesn't, never a
    /// partial one that leaves a stale derived row rendering from data that was supposedly deleted.
    func purgeCycleData() throws {
        let sensitive = env.database.sensitive
        try sensitive.transaction {
            for table in ["cycle_records", "flow_logs", "contraceptive_context_logs",
                          "cycle_predictions", "cycle_phase_estimates", "cycle_anomaly_events"] {
                try sensitive.execute("DELETE FROM \"\(table)\";")
            }
            let phaseContexts = CyclePhase.allCases.map(\.rawValue)
            let placeholders = phaseContexts.map { _ in "?" }.joined(separator: ", ")
            _ = try sensitive.run(
                "DELETE FROM baselines WHERE covariate_context IN (\(placeholders));",
                phaseContexts.map { .text($0) })
        }
    }
}
