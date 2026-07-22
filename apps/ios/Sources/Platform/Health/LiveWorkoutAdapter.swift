import Foundation
import UIKit

// EPIC-42 slice 2 (live exercise monitor). This file is BADAN's OWN foreground timer/tick driver
// for a live-tracked workout — matching the plan's description of Android's approach ("BADAN-owned
// capture engine... separate from HC persistence"), because a real, standalone-on-iPhone
// `HKWorkoutSession` is not available pre-iOS 26 (Apple's own WWDC materials: on iOS 17 through 25
// `HKWorkoutSession` is watchOS-only, with iOS only able to MIRROR a watch-driven session — there is
// no watch companion target yet; that is Phase 4). This file therefore:
//   - does NOT import CoreLocation (no GPS/route recording in this slice — see the Info.plist
//     location-usage string this would otherwise contradict),
//   - does NOT call HKWorkoutSession / HKLiveWorkoutBuilder / HKLiveWorkoutDataSource anywhere,
//   - reads a live-ish heart rate only via the EXISTING read-only `HealthStorePort` abstraction
//     (a periodic best-effort poll, never a continuous streaming query, and never a new HealthKit
//     capability),
//   - is foreground-only, honestly: `Info.plist`'s `UIBackgroundModes` is `[fetch, processing]`
//     only, so this stops ticking the moment the app is suspended, and nothing here pretends
//     otherwise.

/// Battery-level source, abstracted so `LiveWorkoutAdapterTests` can simulate low/high battery
/// without a real device — `UIDevice.current.batteryLevel` reports -1 ("unknown") on the
/// simulator and can't be forced low from a test otherwise.
protocol BatteryLevelProviding {
    /// 0...1, or negative when unknown — mirrors `UIDevice.current.batteryLevel`'s own contract.
    /// The adapter treats "unknown" as nothing to report, never as a fabricated full/empty reading.
    var batteryLevel: Float { get }
}

/// The real device battery, via `UIDevice`. Enables battery monitoring on first use —
/// `UIDevice.current.batteryLevel` reads -1 until `isBatteryMonitoringEnabled` is set `true`.
final class DeviceBatteryLevel: BatteryLevelProviding {
    init() { UIDevice.current.isBatteryMonitoringEnabled = true }
    var batteryLevel: Float { UIDevice.current.batteryLevel }
}

/// The foreground tick loop behind a live BADAN-tracked workout.
///
/// **Ownership split (documented per this slice's own instructions, since either shape was
/// allowed):** this type does NOT own a `WorkoutStateMachine` instance. `WorkoutSessionCoordinator`
/// does, because pause/resume/stop/discard are direct, synchronous, THROWING user actions the
/// Coordinator must apply immediately in response to a tap — routing them through a periodic tick
/// would make "pause" laggy and would give a tap no way to report `WorkoutStateMachineError.
/// illegalTransition` back to its caller. Instead this adapter exposes four closures the Coordinator
/// wires once at construction: a checkpoint-snapshot PULL (`checkpointProvider`, evaluated fresh
/// every tick) and three PUSH callbacks (`onHeartRateUpdate`, `onDegradedConditionBegan/Ended`) it
/// invokes from its own tick loop. This keeps the state machine's real owner singular while letting
/// the adapter own everything that actually IS periodic: the checkpoint cadence, the HR poll
/// cadence, and battery sampling.
///
/// **Concurrency.** This class is deliberately NOT `@MainActor`. `HealthKitAdapter.readSamples`
/// blocks its calling thread on a `DispatchSemaphore` by design (see that type's own doc: "callers
/// already run ingestion off the main actor... so blocking there is safe and never touches the UI
/// thread") — calling it FROM the main actor would freeze the live-workout screen for the length of
/// each query. `tick()`'s repeating `Task { }` is created from a nonisolated context, so it runs on
/// the cooperative thread pool, off the main thread, exactly matching that expectation. The four
/// closures are typed `@MainActor` instead: `Coordinator` (a `@MainActor @Observable` class) mutates
/// its own observed state inside them, so each is invoked with `await` from this class's nonisolated
/// tick loop, hopping onto the main actor for just that one call.
final class LiveWorkoutAdapter {
    /// Supplies a fresh checkpoint snapshot to persist on this tick, or nil when there is nothing
    /// worth checkpointing (no session, or the session has already reached a terminal state —
    /// see the doc on why the terminal check matters even though `stop()` is also called at
    /// finalize/discard time).
    var checkpointProvider: (@MainActor () -> WorkoutCheckpoint?)?
    /// Called with a freshly-read HR sample's bpm, or nil when nothing could be read this window
    /// (no store, no permission, no watch/strap, or nothing new) — NEVER a fabricated 0.
    var onHeartRateUpdate: (@MainActor (Double?) -> Void)?
    var onDegradedConditionBegan: (@MainActor (WorkoutDegradedCondition) -> Void)?
    var onDegradedConditionEnded: (@MainActor (WorkoutDegradedCondition) -> Void)?

    private let checkpointRepository: WorkoutCheckpointRepository
    private let healthStore: HealthStorePort?
    private let clock: Clock
    private let battery: BatteryLevelProviding

    private var tickTask: Task<Void, Never>?
    private var lastHRPollAt: Date?
    private var lowBatteryActive = false

    /// Checkpoint/elapsed-time cadence — "frequent checkpoints, draft always recoverable" (plan
    /// §7A.5) without checkpointing on every single UI frame.
    static let tickInterval: TimeInterval = 5
    /// HR poll cadence, per this slice's own instructions ("every ~10-15s"), not every tick — a
    /// live HR reading is best-effort and coarse by design, never a continuous stream.
    static let hrPollInterval: TimeInterval = 12
    /// How far back each HR poll looks for a sample. Generous on purpose: `readSamples` returns
    /// everything HealthKit has NEW since the last-persisted anchor (see the doc below on why this
    /// adapter never commits that anchor), so a wide window costs nothing extra — the MOST RECENT
    /// sample by `start` wins regardless of how many fall inside it.
    static let hrLookbackSeconds: TimeInterval = 5 * 60
    static let lowBatteryThreshold: Float = 0.20

    init(checkpointRepository: WorkoutCheckpointRepository, healthStore: HealthStorePort?,
         clock: Clock, battery: BatteryLevelProviding = DeviceBatteryLevel()) {
        self.checkpointRepository = checkpointRepository
        self.healthStore = healthStore
        self.clock = clock
        self.battery = battery
    }

    /// Starts the repeating tick. A no-op if already running (idempotent — `WorkoutSessionCoordinator`
    /// calls this from both `start()` and `resumeFromRecoverableDraft()`).
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled else { return }
                await self.tick()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    /// Cancels the repeating tick. Cooperative — an in-flight `tick()` call finishes rather than
    /// being interrupted mid-call, which is why `checkpointProvider`'s terminal-state check exists
    /// (see its doc): it is the actual guarantee that a stray tick landing just after `stop()` can
    /// never resurrect a checkpoint the caller is about to (or just did) clear.
    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Whether the repeating tick loop is currently running. `internal`, not `private`, purely so
    /// `WorkoutSessionCoordinatorTests` can assert the FIX 4 countdown split: `start(activityType:)`
    /// alone must NOT start this loop — only `confirmCountdownFinished()` does — matching this
    /// class's existing "internal, not private, for tests" convention (see `tick()`'s own doc).
    var isTicking: Bool { tickTask != nil }

    /// One tick's work. Kept `internal` (not `private`) so `LiveWorkoutAdapterTests` can drive it
    /// deterministically instead of racing the real timer — matches this codebase's existing
    /// convention for test-reachable internals (e.g. `WorkoutLogViewModel.fetch`).
    func tick() async {
        await checkBattery()
        if let checkpoint = await checkpointProvider?() {
            try? checkpointRepository.save(checkpoint)
        }
        await pollHeartRateIfDue()
    }

    private func checkBattery() async {
        let level = battery.batteryLevel
        guard level >= 0 else { return }   // unknown — nothing to report either way
        let isLow = level <= Self.lowBatteryThreshold
        if isLow, !lowBatteryActive {
            lowBatteryActive = true
            await onDegradedConditionBegan?(.lowBattery)
        } else if !isLow, lowBatteryActive {
            lowBatteryActive = false
            await onDegradedConditionEnded?(.lowBattery)
        }
    }

    private func pollHeartRateIfDue() async {
        let now = clock.now()
        if let last = lastHRPollAt, now.timeIntervalSince(last) < Self.hrPollInterval { return }
        lastHRPollAt = now

        guard let healthStore else {
            await onHeartRateUpdate?(nil)
            return
        }

        // (HealthKitAdapter's own doc) reads here run on THIS call's thread — the cooperative
        // pool, per this type's concurrency doc above — never the main actor.
        //
        // Deliberately never calls `commitPendingAnchors()`: doing so would advance the SAME
        // incremental read cursor `IngestionPipeline`'s real background/foreground sync depends
        // on, based on a read this adapter took purely for a live, transient display value. Without
        // a commit, `loadAnchor` inside `readSamples` keeps handing back whatever was last
        // PERSISTED (by a real ingest), so polling repeatedly here is idempotent — it can re-read
        // the same "new since last real sync" window many times over a session without ever
        // skipping or double-counting anything a subsequent real sync will later commit for real.
        let range = HealthDateRange(start: now.addingTimeInterval(-Self.hrLookbackSeconds), end: now)
        let value = healthStore.readSamples(range)
            .filter { $0.metricId == MetricID.heartRate }
            .max(by: { $0.start < $1.start })?
            .value
        await onHeartRateUpdate?(value)
    }
}
