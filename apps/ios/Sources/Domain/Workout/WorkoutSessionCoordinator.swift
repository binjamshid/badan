import Foundation
import Observation

/// Coordinator-specific errors that don't correspond to a `WorkoutStateMachine` transition.
///
/// `recordStrengthSet` has no `WorkoutEvent` of its own — logging a set runs through
/// `StrengthSessionRunner`/`StrengthSetRepository` in parallel with the lifecycle machine, never
/// through `WorkoutStateMachine.apply` — so calling it with no active recording session gets its
/// own typed error rather than a misleading `WorkoutStateMachineError.illegalTransition` naming an
/// event that never actually fired.
public enum WorkoutSessionCoordinatorError: Error, Equatable, Sendable {
    case noActiveRecordingSession(state: WorkoutLifecycleState)
}

/// The engine half of EPIC-42 slice 2's live exercise monitor — drives a single `WorkoutStateMachine`
/// through a live BADAN-tracked workout, ticked by `LiveWorkoutAdapter`, and on `finalize()` persists
/// the result into BADAN's own storage. This is the EXACT cross-lane contract the SwiftUI lane was
/// given (see this slice's task doc) — observable property names and action method names are frozen
/// and must not change; only this file's PRIVATE implementation is this lane's to decide.
///
/// **Constructor access.** The class, its observed properties, and its action methods are `public`,
/// matching the frozen contract literally. `init` itself is declared WITHOUT `public` (so, plain
/// `internal`) — its four repository parameters (`WorkoutCheckpointRepository`, `StrengthSetRepository`,
/// `MeasurementRepository`, `DerivationRepository`) are themselves `internal` types, and Swift will not
/// compile a `public init` whose parameters are less visible than `public` regardless of module
/// structure. Bumping four repository classes to `public` purely for this one signature was rejected
/// as unnecessary, out-of-scope surface growth (none of them are owned by this slice); since BADAN is
/// a single application target with no separate framework consumer, `internal` already gives the
/// SwiftUI lane (same module, different file) exactly the same reach `public` would have.
///
/// **Ownership.** This type owns the ONE live `WorkoutStateMachine` instance for whatever session is
/// in flight (nil at true idle). `LiveWorkoutAdapter` (constructed here, never exposed publicly) owns
/// the periodic tick/poll cadence and drives this type back via closures — see that type's own doc
/// for the concurrency split. `adapter` is kept `internal` (not `private`) purely so
/// `WorkoutSessionCoordinatorTests` can simulate a tick/callback deterministically instead of racing
/// the real timer, matching this codebase's existing "internal, not private, for tests" convention.
@MainActor
@Observable
public final class WorkoutSessionCoordinator {
    // MARK: - Observable state (frozen names)

    public private(set) var lifecycleState: WorkoutLifecycleState = .idle
    public private(set) var activityType: String?
    public private(set) var elapsedActiveSeconds: TimeInterval = 0
    /// bpm, nil whenever unavailable (no watch/strap, no permission, or nothing read yet in the
    /// last read window) — NEVER a fabricated 0. Set only via `LiveWorkoutAdapter.onHeartRateUpdate`.
    public private(set) var liveHeartRateBpm: Double?
    public private(set) var degradedConditions: Set<WorkoutDegradedCondition> = []
    /// Only meaningful/populated when `activityType` is a strength modality — empty otherwise.
    public private(set) var strengthSets: [StrengthSet] = []
    /// Set on init if `WorkoutCheckpointRepository` has a recoverable draft from an unclean
    /// shutdown. The UI must surface this and let the user explicitly `resumeFromRecoverableDraft()`
    /// or `discardRecoverableDraft()` — never silently resumed (`WorkoutStateMachine`'s own doc).
    public private(set) var recoverableDraft: WorkoutCheckpoint?
    /// EPIC-42 interval engine. The structured plan the person chose before starting, or nil for an
    /// open workout (the overwhelmingly common case). Set by `start(activityType:plan:)` and never
    /// changed mid-session: editing the structure while running would invalidate every segment
    /// already recorded against it.
    public private(set) var intervalPlan: IntervalPlan?
    /// Where the session currently sits inside `intervalPlan`, recomputed from
    /// `elapsedActiveSeconds` on every tick. `nil` when there is no plan, or when the plan has run
    /// past its end — which does NOT end the session; see `IntervalEngine.position`.
    public private(set) var intervalPosition: IntervalPosition?

    // MARK: - Dependencies

    private let checkpointRepository: WorkoutCheckpointRepository
    private let strengthSetRepository: StrengthSetRepository
    private let intervalRepository: WorkoutIntervalRepository?
    private let measurementRepository: MeasurementRepository
    private let derivationRepository: DerivationRepository
    private let deviceId: String
    private let clock: Clock
    private let strengthRunner: StrengthSessionRunner
    let adapter: LiveWorkoutAdapter

    /// The one live machine, or nil at true idle (never started, or the current one was already
    /// nulled out — in practice this stays non-nil once any session has ever started, since a
    /// terminal machine is left in place for `lifecycleState`/`activityType` to keep describing it).
    private var machine: WorkoutStateMachine?
    /// Live HR readings observed during the current session, appended whenever
    /// `LiveWorkoutAdapter.onHeartRateUpdate` reports a real (non-nil) value. Coarse and periodic
    /// (see `LiveWorkoutAdapter.hrPollInterval`) — used at `finalize()` to report an honest, if
    /// sparse, avg/max HR rather than none at all; never a substitute for a real continuous trace.
    private var hrReadings: [Double] = []

    /// `intervalRepository` is optional so every existing call site and test that constructs a
    /// coordinator without one keeps working unchanged — with it nil, a structured plan still runs
    /// and still drives the live screen, its segments simply are not persisted. That degradation is
    /// the same "no repository, no recording, everything else works" contract `IngestionPipeline`
    /// already uses for its optional dependencies.
    init(checkpointRepository: WorkoutCheckpointRepository, strengthSetRepository: StrengthSetRepository,
         measurementRepository: MeasurementRepository, derivationRepository: DerivationRepository,
         healthStore: HealthStorePort?, deviceId: String, clock: Clock,
         intervalRepository: WorkoutIntervalRepository? = nil) {
        self.checkpointRepository = checkpointRepository
        self.strengthSetRepository = strengthSetRepository
        self.intervalRepository = intervalRepository
        self.measurementRepository = measurementRepository
        self.derivationRepository = derivationRepository
        self.deviceId = deviceId
        self.clock = clock
        self.strengthRunner = StrengthSessionRunner(repository: strengthSetRepository, clock: clock,
                                                    deviceId: deviceId)
        self.adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository,
                                          healthStore: healthStore, clock: clock)

        // Crash recovery: `WorkoutStateMachine.init(restoringFrom:)` is the ONLY path into
        // `.recoveryDraft`, and it always lands there regardless of what was captured — never
        // silently resumed. `loadAll()` orders newest-first; a stray SECOND checkpoint (the
        // repository's own doc: "two crashes in a row before either was resolved") is a known,
        // accepted limitation of this contract's single `recoverableDraft` property — only the
        // newest is surfaced.
        if let checkpoint = (try? checkpointRepository.loadAll())?.first {
            let recovered = WorkoutStateMachine(restoringFrom: checkpoint, clock: clock)
            machine = recovered
            recoverableDraft = checkpoint
            activityType = recovered.activityType
            lifecycleState = recovered.state
            degradedConditions = recovered.degradedConditions
            elapsedActiveSeconds = recovered.accumulatedActiveSeconds
        }

        wireAdapter()
        refreshStrengthSets()
    }

    private func wireAdapter() {
        adapter.checkpointProvider = { [weak self] in
            guard let self, let machine = self.machine, !machine.state.isTerminal else { return nil }
            let checkpoint = machine.checkpoint(originDeviceId: self.deviceId)
            self.elapsedActiveSeconds = checkpoint.hotState.activeSeconds
            return checkpoint
        }
        adapter.onHeartRateUpdate = { [weak self] bpm in
            guard let self else { return }
            self.liveHeartRateBpm = bpm
            if let bpm { self.hrReadings.append(bpm) }
        }
        adapter.onDegradedConditionBegan = { [weak self] condition in
            guard let self, let machine = self.machine else { return }
            try? machine.apply(.degradedConditionBegan(condition))
            self.degradedConditions = machine.degradedConditions
        }
        adapter.onDegradedConditionEnded = { [weak self] condition in
            guard let self, let machine = self.machine else { return }
            try? machine.apply(.degradedConditionEnded(condition))
            self.degradedConditions = machine.degradedConditions
        }
    }

    // MARK: - Actions

    public func start(activityType: String, plan: IntervalPlan? = nil) throws {
        if let machine, !machine.state.isTerminal {
            throw WorkoutStateMachineError.illegalTransition(from: machine.state, event: .begin)
        }
        let fresh = WorkoutStateMachine(sessionId: ULID.newID(clock: clock), activityType: activityType,
                                        clock: clock)
        machine = fresh
        self.activityType = activityType
        strengthSets = []
        liveHeartRateBpm = nil
        hrReadings.removeAll()
        // EPIC-42: fixed for the life of the session (see `intervalPlan`'s own doc). Position is
        // primed at zero rather than left nil so the live screen has the first segment to draw
        // during the countdown, before any tick has fired.
        intervalPlan = plan
        intervalPosition = plan.flatMap { IntervalEngine.position(in: $0, elapsed: 0) }

        // `.begin` ONLY — leaves the machine (and the observable `lifecycleState`) sitting at
        // `.preparing`. FIX 4: this used to also apply `.countdownFinished` immediately, back to
        // back, which meant no UI could ever actually observe `.preparing` — the countdown was
        // instantaneous from the engine's perspective regardless of what a screen drew on top of
        // it. `confirmCountdownFinished()` below is the real second half: the countdown is now a
        // REAL elapsed interval (plan §7A.5's "countdown default 3s"), and `adapter.start()` moves
        // there too — nothing should tick, checkpoint, or poll a live HR sample before the
        // countdown actually finishes.
        try fresh.apply(.begin)
        syncObservableState()
    }

    /// Confirms the `.preparing` countdown has elapsed (or was explicitly skipped) and moves the
    /// machine to `.active`, THEN starts the adapter's tick loop. Splitting this out of
    /// `start(activityType:)` (FIX 4) is what makes `.preparing` a real, reachable phase: the
    /// SwiftUI lane shows a real ~3s countdown while `lifecycleState == .preparing` (with a Cancel
    /// button calling `discard()`) and calls this automatically once it elapses.
    public func confirmCountdownFinished() throws {
        try applyAndSync(.countdownFinished)
        adapter.start()
    }

    public func requestPause() throws { try applyAndSync(.userPaused) }
    public func requestResume() throws { try applyAndSync(.userResumed) }
    public func requestStop() throws { try applyAndSync(.stopRequested) }

    public func discard() throws {
        try applyAndSync(.discardRequested)
        adapter.stop()
        if let machine {
            try checkpointRepository.clear(sessionId: machine.sessionId)
        }
        recoverableDraft = nil
        liveHeartRateBpm = nil
        hrReadings.removeAll()
    }

    /// Runs the platform "end sequence" analog (stop -> finalize): applies `.recordingStopped`
    /// (`.stopping` -> `.finalizing`) IF that transition hasn't already happened on a prior, failed
    /// attempt; computes the strength quality summary and any new PRs; persists them together with
    /// the `sessions` upsert in ONE transaction (see ATOMICITY below); clears the checkpoint;
    /// applies `.persistCompleted` (`.finalizing` -> `.persisted`); and returns the summary.
    ///
    /// Legal from EITHER `.stopping` (the ordinary first call — call `requestStop()` first,
    /// matching the real end-sequence's own two-phase shape, plan §7A.5:
    /// "stopActivity→stopped→endCollection→finishWorkout→end") OR `.finalizing` (a RETRY after a
    /// previous call's persistence transaction threw). FIX 2/5: before this, `.recordingStopped`
    /// was applied unconditionally up front, so a failure partway through the writes below left the
    /// machine at `.finalizing` with no legal way back in — a second call threw
    /// `illegalTransition` immediately, permanently stranding the session (neither
    /// `LiveWorkoutScreen` nor `StrengthLoggingScreen` renders any control for `.finalizing`, and
    /// even a crash-recovered checkpoint captured mid-`.finalizing` restores to `.recoveryDraft`
    /// whose `stateBeforeInterruption` is still `.finalizing`). Retrying is now simply calling
    /// `finalize()` again once the underlying failure is resolved.
    ///
    /// **Atomicity.** The PR-append (`WorkoutQuality.recordIfPR`), the `workout_quality` row
    /// insert (`checkpointRepository.insertQualityRow`), and the `sessions` upsert
    /// (`measurementRepository.upsertSession`) all commit or roll back TOGETHER inside one
    /// `measurementRepository.transaction { ... }`. `checkpointRepository`, `derivationRepository`
    /// (whose own `.transaction` wraps the PR append inside `recordIfPR`), and
    /// `measurementRepository` are all constructed over the SAME `SQLiteConnection`
    /// (`env.database.main`, see `makeWorkoutSessionCoordinator`) — `SQLiteConnection.transaction`'s
    /// same-thread nesting (OPT-186) means the nested `derivation.transaction` call inside
    /// `recordIfPR` joins this outer transaction rather than committing independently. Before this
    /// fix these were three separate, non-atomic writes: if `upsertSession` threw after the first
    /// two had already committed, a PR/quality row would permanently reference a session that never
    /// became real, with no cleanup path (`discardRecoverableDraft()` only ever clears the
    /// checkpoint, never these derived rows).
    public func finalize() async throws -> WorkoutSessionSummary {
        guard let machine, machine.state == .stopping || machine.state == .finalizing else {
            throw WorkoutStateMachineError.illegalTransition(from: lifecycleState, event: .recordingStopped)
        }
        if machine.state == .stopping {
            try machine.apply(.recordingStopped)
            lifecycleState = machine.state
        }
        adapter.stop()

        let sessionId = machine.sessionId
        let sessionActivityType = machine.activityType
        let now = clock.now()

        // Strength quality + PRs — pure/no-op for a non-strength session (no live sets to read).
        let liveSets = try strengthSetRepository.liveSets(sessionId: sessionId)
        let qualitySummary = WorkoutQuality.computeStrengthQuality(sets: liveSets, computedAt: now)
        // nil means "nothing to measure" — see that doc. Reserving the id here is a pure compute,
        // not a DB write, so it's safe ahead of the transaction below regardless of retry.
        let qualityId: String? = qualitySummary.completeness != nil ? ULID.newID(clock: clock) : nil

        // Honest, coarse HR totals from whatever periodic readings actually arrived — never a
        // fabricated continuous-trace statistic. Empty (all-nil `WorkoutTotals`) when nothing was
        // ever read (no store, no permission, no watch/strap for the whole session).
        let totals: WorkoutTotals = hrReadings.isEmpty
            ? WorkoutTotals()
            : WorkoutTotals(avgHeartRateBpm: hrReadings.reduce(0, +) / Double(hrReadings.count),
                           maxHeartRateBpm: hrReadings.max())

        let detail = WorkoutDetail(
            activityType: sessionActivityType, totals: totals,
            // I8/PERSISTENCE contract: no platform source id exists for a BADAN-tracked live
            // session, so the session's own ULID fills `sourceWorkoutUUID` (kept non-optional
            // rather than made optional, which would retype an existing field against
            // `WorkoutDetail`'s own additive-only rule).
            sourceWorkoutUUID: sessionId,
            routeRef: nil,      // no GPS/route in this slice — see LiveWorkoutAdapter's own doc
            hrSeriesRef: nil,   // this slice never ingests into the canonical `heart.hr` series
            stateHistory: machine.stateHistory, degradedConditions: machine.degradedConditions,
            qualitySummaryRef: qualityId)

        let tz = TimeZone.current.identifier
        let provenance = Provenance(sourceId: deviceId, deviceId: deviceId, ingestionPath: .manual,
                                   measuredAt: machine.startedAt, measuredTimezone: tz,
                                   recordedAt: now, ingestedAt: now)
        let session = Session(id: sessionId, kind: .workout, subtype: sessionActivityType,
                              startAt: machine.startedAt, endAt: now, tzId: tz,
                              detail: SessionDetail(workout: detail), provenance: provenance,
                              updatedAt: now, originDeviceId: deviceId)

        var newPRs: [PersonalRecord] = []
        try measurementRepository.transaction {
            newPRs = []
            for set in liveSets {
                let outcome = try WorkoutQuality.recordIfPR(candidate: set, derivation: derivationRepository,
                                                            clock: clock, deviceId: deviceId)
                if case .newRecord(let record) = outcome { newPRs.append(record) }
            }
            if let qualityId {
                try checkpointRepository.insertQualityRow(id: qualityId, sessionId: sessionId,
                                                          summary: qualitySummary, updatedAt: now,
                                                          originDeviceId: deviceId)
            }
            try measurementRepository.upsertSession(session)
            // EPIC-42: only the segments that actually FINISHED (see
            // `IntervalEngine.completedSegments`) — a plan abandoned in round 3 records three
            // rounds, never the eight it planned. Inside the same transaction as the session row,
            // so a session can never persist with a partial set of its own segments.
            if let intervalRepository, let intervalPlan {
                let segments = IntervalEngine.completedSegments(
                    in: intervalPlan, elapsed: machine.accumulatedActiveSeconds,
                    sessionId: sessionId, startedAt: machine.startedAt, originDeviceId: deviceId)
                for segment in segments { try intervalRepository.insert(segment) }
            }
        }
        try checkpointRepository.clear(sessionId: sessionId)

        try machine.apply(.persistCompleted)
        lifecycleState = machine.state

        let summary = WorkoutSessionSummary(
            sessionId: sessionId, activityType: sessionActivityType,
            durationSeconds: machine.accumulatedActiveSeconds, strengthSetCount: liveSets.count,
            newPersonalRecords: newPRs, degradedConditions: machine.degradedConditions)

        liveHeartRateBpm = nil
        hrReadings.removeAll()
        return summary
    }

    /// Records one strength set against the current recording session. FIX 3: `weightValue` is
    /// stored EXACTLY as the caller reports it, in the caller's own `unit` — never pre-converted to
    /// kilograms before this call (the previous `weightKg` parameter name was itself the bug: it
    /// invited exactly that pre-conversion at the one real call site,
    /// `StrengthLoggingScreen.logSet()`, which threw away the as-logged unit permanently). Canonical
    /// kilograms are derived ONLY on read, via `StrengthSet.weightKg`'s computed property
    /// (`weightUnit.toKilograms(weightValue)`) — exactly what `WorkoutQuality.evaluatePR`/e1RM
    /// already read (slice 1), so PR/e1RM math is unaffected either way. Storing what was actually
    /// logged is what lets a set be redisplayed later in the SAME unit the lifter entered it in
    /// (e.g. "220.0 lb"), instead of a silently converted "99.8 kg" with no indication a conversion
    /// ever happened.
    public func recordStrengthSet(movementId: String?, customLabel: String?, kind: StrengthSetKind,
                                  weightValue: Double?, reps: Int?, unit: WeightUnit,
                                  supersetGroup: String?) throws {
        guard let machine, machine.state.isRecording else {
            throw WorkoutSessionCoordinatorError.noActiveRecordingSession(state: lifecycleState)
        }
        _ = try strengthRunner.recordSet(sessionId: machine.sessionId, movementId: movementId,
                                         customLabel: customLabel, kind: kind,
                                         supersetGroup: supersetGroup, reps: reps,
                                         weightValue: weightValue, weightUnit: unit)
        refreshStrengthSets()
    }

    public func resumeFromRecoverableDraft() throws {
        guard let machine, machine.state == .recoveryDraft else {
            throw WorkoutStateMachineError.illegalTransition(from: lifecycleState, event: .resumeFromRecovery)
        }
        try machine.apply(.resumeFromRecovery)
        syncObservableState()
        activityType = machine.activityType
        refreshStrengthSets()
        recoverableDraft = nil
        adapter.start()
    }

    public func discardRecoverableDraft() throws {
        guard let machine, machine.state == .recoveryDraft else {
            throw WorkoutStateMachineError.illegalTransition(from: lifecycleState, event: .discardRequested)
        }
        try machine.apply(.discardRequested)
        syncObservableState()
        try checkpointRepository.clear(sessionId: machine.sessionId)
        recoverableDraft = nil
    }

    // MARK: - Helpers

    private func applyAndSync(_ event: WorkoutEvent) throws {
        guard let machine else {
            throw WorkoutStateMachineError.illegalTransition(from: lifecycleState, event: event)
        }
        try machine.apply(event)
        syncObservableState()
    }

    /// Mirrors the machine's own truth onto the observed properties right after any `apply(_:)` —
    /// safe to read `accumulatedActiveSeconds` directly here (rather than via `checkpoint()`)
    /// because `apply` already banks the elapsed time of the phase just LEFT before returning, so
    /// immediately after any transition nothing is left un-banked in the current phase.
    private func syncObservableState() {
        guard let machine else { return }
        lifecycleState = machine.state
        degradedConditions = machine.degradedConditions
        elapsedActiveSeconds = machine.accumulatedActiveSeconds
        // EPIC-42: derived from the machine's own clock on every sync, never from a second timer.
        // `elapsedActiveSeconds` excludes paused time by construction, which is the behaviour an
        // interval plan needs — pausing mid-round must hold the round, not let it run out while
        // the person is standing still.
        intervalPosition = intervalPlan.flatMap { IntervalEngine.position(in: $0, elapsed: machine.accumulatedActiveSeconds) }
    }

    private func refreshStrengthSets() {
        guard let machine else { strengthSets = []; return }
        strengthSets = (try? strengthSetRepository.liveSets(sessionId: machine.sessionId)) ?? []
    }
}

// `Hashable` in addition to the frozen `Sendable`: the SwiftUI lane's `LiveWorkoutScreen`/
// `StrengthLoggingScreen` push it via `.navigationDestination(item: $summary)`, which requires the
// item type to be `Hashable`. Every stored property is already Hashable, so this is free.
public struct WorkoutSessionSummary: Sendable, Hashable {
    public let sessionId: String
    public let activityType: String
    public let durationSeconds: TimeInterval
    public let strengthSetCount: Int
    public let newPersonalRecords: [PersonalRecord]
    public let degradedConditions: Set<WorkoutDegradedCondition>
}
