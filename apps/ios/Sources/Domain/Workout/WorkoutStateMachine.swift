import Foundation

// MARK: - Lifecycle state

/// The SEQUENTIAL phase of a live workout (EPIC-42, plan §7A.5: "IDLE → … → PERSISTED"). Moves
/// forward toward `.persisted` or `.discarded`, except for the pause/resume/interruption loop,
/// which can revisit `.active` many times within one session.
///
/// This is one of TWO independent axes the state machine tracks — see `WorkoutDegradedCondition`
/// for the other. Deliberately not conflated: a dropped HR strap does not stop a workout, it
/// degrades what the workout can honestly claim, and folding that into this enum would force a
/// false choice between "recording" and "sensor issue" when a session is very often both.
public enum WorkoutLifecycleState: String, Codable, Hashable, Sendable, CaseIterable {
    /// No session exists yet — before `WorkoutEvent.begin`.
    case idle
    /// Countdown warm-up before recording starts (plan §7A.5: "countdown default 3s", Apple's
    /// `HKWorkoutSession.prepare()`). Cancellable; nothing has been recorded yet.
    case preparing
    /// Recording, healthy. The only state real live samples are being collected in.
    case active
    /// The platform/heuristic layer detected a pause (e.g. stopped at a light) without the user
    /// tapping anything. Distinguished from `.manuallyPaused` because a post-workout notebook
    /// should be able to say which kind of pause happened (plan §7A.5's auto-pause item).
    case autoPaused
    /// The user explicitly tapped pause. Wins over an auto-pause if both would otherwise apply —
    /// see `WorkoutStateMachine.nextState`'s `(.autoPaused, .userPaused)` case.
    case manuallyPaused
    /// An external interruption (phone call, OS killed the audio/location session, app was
    /// force-backgrounded) suspended recording without the user or the auto-pause heuristic
    /// deciding anything. Remembers what it interrupted (`stateBeforeInterruption`) so ending the
    /// interruption restores the SPECIFIC prior state, not a generic "resume".
    case interrupted
    /// The user (or an end-of-session trigger) asked to stop; the platform's end sequence is in
    /// flight (plan §7A.5: "stopActivity→stopped→endCollection→finishWorkout→end"). Recording has
    /// stopped but nothing is summarized yet.
    case stopping
    /// The end sequence landed; BADAN is computing the summary, quality rows, and child rows
    /// before the session becomes a durable `sessions` row.
    case finalizing
    /// Terminal success: the session is a `sessions(kind=workout)` row. Safe to clear the
    /// checkpoint (`WorkoutCheckpointRepository.clear`).
    case persisted
    /// Terminal, deliberate non-save: the user discarded the session (during countdown, mid-workout,
    /// or from a recovered draft). Nothing is written to `sessions`.
    case discarded
    /// Reached ONLY via `WorkoutStateMachine.init(restoringFrom:clock:)` — the process died and
    /// relaunched mid-session. Never entered any other way, and never assumed to silently resume:
    /// see that initializer's doc for why "ask the user" is the only safe default after a crash.
    case recoveryDraft

    public var isRecording: Bool { self == .active }
    public var isPaused: Bool { self == .autoPaused || self == .manuallyPaused }
    public var isTerminal: Bool { self == .persisted || self == .discarded }

    public var displayLabel: LocalizedString {
        switch self {
        case .idle: return LocalizedString(en: "Not started", ar: "لم يبدأ")
        case .preparing: return LocalizedString(en: "Get ready", ar: "استعد")
        case .active: return LocalizedString(en: "In progress", ar: "قيد التنفيذ")
        case .autoPaused: return LocalizedString(en: "Paused (auto)", ar: "متوقف مؤقتًا (تلقائي)")
        case .manuallyPaused: return LocalizedString(en: "Paused", ar: "متوقف مؤقتًا")
        case .interrupted: return LocalizedString(en: "Interrupted", ar: "تمت مقاطعته")
        case .stopping: return LocalizedString(en: "Stopping", ar: "يتم الإيقاف")
        case .finalizing: return LocalizedString(en: "Saving", ar: "جارٍ الحفظ")
        case .persisted: return LocalizedString(en: "Saved", ar: "تم الحفظ")
        case .discarded: return LocalizedString(en: "Discarded", ar: "تم التجاهل")
        case .recoveryDraft: return LocalizedString(en: "Recovered draft", ar: "مسودة مستعادة")
        }
    }
}

// MARK: - Degraded conditions

/// The OTHER axis: independently-toggleable quality problems that can be true or false at ANY
/// lifecycle phase without changing it (plan §7A.5: "sensor-degraded, route-degraded,
/// low-battery"). A set rather than three booleans so the machine and its tests can reason about
/// "which conditions are active right now" generically, and so a future fourth condition is one
/// new case, not a new stored property plus a migration.
///
/// These feed `workout_quality` (per-metric-family completeness/continuity/accuracy) and the
/// post-workout notebook's honest quality notes ("HR unavailable first 2 min") — never a fake
/// zero, never a silently-dropped tile (plan's "no false precision").
public enum WorkoutDegradedCondition: String, Codable, Hashable, Sendable, CaseIterable {
    /// A required live sensor (HR strap, cadence, power meter…) stopped reporting mid-session.
    case sensorDegraded
    /// GPS accuracy fell below the usable threshold, or the signal was lost outright.
    case routeDegraded
    /// The device's battery crossed the low-battery threshold during the session (plan §7A.5's
    /// "offline + battery" modes).
    case lowBattery

    public var displayLabel: LocalizedString {
        switch self {
        case .sensorDegraded: return LocalizedString(en: "Sensor unavailable", ar: "الحساس غير متاح")
        case .routeDegraded: return LocalizedString(en: "GPS signal weak", ar: "إشارة GPS ضعيفة")
        case .lowBattery: return LocalizedString(en: "Battery low", ar: "البطارية منخفضة")
        }
    }
}

// MARK: - Events

/// Every input a platform adapter (a future `HKWorkoutSession`/`HKLiveWorkoutBuilder` wrapper, or
/// Android's foreground-service capture engine) can hand the machine. This enum, plus `apply(_:)`,
/// is the ENTIRE surface an adapter needs — nothing else in this file is adapter-facing.
public enum WorkoutEvent: Hashable, Sendable {
    case begin
    case countdownFinished
    case autoPauseDetected
    case autoResumeDetected
    case userPaused
    case userResumed
    case interruptionBegan
    case interruptionEnded
    case degradedConditionBegan(WorkoutDegradedCondition)
    case degradedConditionEnded(WorkoutDegradedCondition)
    case stopRequested
    /// Apple's `stopActivity` → `.stopped` (or Android's capture-engine stop) landed.
    case recordingStopped
    /// The summary/child rows finished writing and the session became a durable `sessions` row.
    case persistCompleted
    case discardRequested
    /// The user's explicit decision, after a crash-recovered `.recoveryDraft`, to keep going.
    case resumeFromRecovery
}

/// A machine refused an event that is not legal from its current state — an adapter bug (e.g. a
/// stray `.userResumed` while `.idle`), surfaced loudly rather than silently reclassifying the
/// session or reordering its history.
public enum WorkoutStateMachineError: Error, Equatable {
    case illegalTransition(from: WorkoutLifecycleState, event: WorkoutEvent)
}

// MARK: - History & hot state

/// One entry in a session's lifecycle audit trail — what the post-workout notebook's "auto-paused
/// at 12:03, resumed at 12:05" line reads from (plan §7A.5).
public struct WorkoutStateTransition: Codable, Hashable, Sendable {
    public var state: WorkoutLifecycleState
    public var at: Date
    /// Free-form, VALUE-FREE context ("resumed from checkpoint after unclean shutdown"). Never a
    /// health value — mirrors `background_runs.work_done`'s counts-only contract.
    public var note: String?

    public init(state: WorkoutLifecycleState, at: Date, note: String? = nil) {
        self.state = state
        self.at = at
        self.note = note
    }
}

/// The small, cheap-to-serialize blob `workout_checkpoints.hot_state` holds — everything a
/// relaunched app needs to redraw a live/paused workout screen and know what to resume into,
/// without recomputing it from `stateHistory` on every tick.
public struct WorkoutHotState: Codable, Hashable, Sendable {
    public var degradedConditions: Set<WorkoutDegradedCondition>
    /// The lifecycle state to return to when the CURRENT interruption/recovery ends — the state
    /// the machine was actually in the instant it was last interrupted or checkpointed. Never
    /// `.interrupted` or `.recoveryDraft` themselves (see `WorkoutStateMachine.nextState`).
    public var stateBeforeInterruption: WorkoutLifecycleState
    /// Seconds spent in `.active`, banked as of this checkpoint — NOT counting time the app spent
    /// dead between a crash and its relaunch (see `WorkoutStateMachine.init(restoringFrom:clock:)`).
    public var activeSeconds: Double
    /// Seconds spent in any paused/interrupted state, banked as of this checkpoint.
    public var pausedSeconds: Double

    public init(degradedConditions: Set<WorkoutDegradedCondition> = [],
                stateBeforeInterruption: WorkoutLifecycleState, activeSeconds: Double = 0,
                pausedSeconds: Double = 0) {
        self.degradedConditions = degradedConditions
        self.stateBeforeInterruption = stateBeforeInterruption
        self.activeSeconds = activeSeconds
        self.pausedSeconds = pausedSeconds
    }
}

/// The domain shape of one `workout_checkpoints` row (migration 9). `WorkoutCheckpointRepository`
/// owns turning this to/from SQL; this type is storage-agnostic so `WorkoutStateMachine` and its
/// tests never need a database.
public struct WorkoutCheckpoint: Codable, Hashable, Sendable {
    public var sessionId: String
    public var activityType: String
    public var state: WorkoutLifecycleState
    public var startedAt: Date
    public var stateHistory: [WorkoutStateTransition]
    public var hotState: WorkoutHotState
    public var lastCheckpointAt: Date
    public var originDeviceId: String

    public init(sessionId: String, activityType: String, state: WorkoutLifecycleState, startedAt: Date,
                stateHistory: [WorkoutStateTransition], hotState: WorkoutHotState, lastCheckpointAt: Date,
                originDeviceId: String) {
        self.sessionId = sessionId
        self.activityType = activityType
        self.state = state
        self.startedAt = startedAt
        self.stateHistory = stateHistory
        self.hotState = hotState
        self.lastCheckpointAt = lastCheckpointAt
        self.originDeviceId = originDeviceId
    }
}

// MARK: - The machine

/// Platform-neutral lifecycle state machine for a single live workout session (EPIC-42, plan
/// §7A.5). Pure and storage-free: it holds the current state, the accumulated history, and the
/// hot ephemeral state a crash needs to recover, and exposes one mutating entry point (`apply`)
/// that is the ENTIRE surface a platform adapter drives. A future `HKWorkoutSession`/
/// `HKLiveWorkoutBuilder` adapter (or Android's foreground-service capture engine) turns platform
/// delegate callbacks into `WorkoutEvent`s and calls `apply` — this file never imports HealthKit,
/// CoreLocation, or any platform framework, so it is fully unit-testable with no simulator, no
/// live HealthKit session, and no BLE hardware.
///
/// The transition RULES live in the static, pure `nextState(from:event:stateBeforeInterruption:)`
/// — same shape as `StressEngine.evaluate`/`classify` — so the whole rule table can be asserted
/// directly in tests without constructing a machine at all. The instance wraps that pure table
/// with the bookkeeping a live session actually needs: append-only history, active/paused-time
/// accounting, and the degraded-condition set.
///
/// CRASH RECOVERY is the machine's other reason to exist. `init(restoringFrom:clock:)` is the
/// ONLY way to construct a machine besides starting fresh, and it always lands on
/// `.recoveryDraft` — never silently back into `.active` — because process death means nobody
/// actually knows the true state of the sensors, the countdown, or the paused clock the instant
/// it happened; the safe assumption is "ask the user", never "assume it kept running". Calling
/// `apply(.resumeFromRecovery)` is what an explicit user decision drives, restoring exactly the
/// state the checkpoint captured; `apply(.discardRequested)` ends the draft instead. Either way,
/// dead time between the crash and the relaunch is never folded into `activeSeconds`/
/// `pausedSeconds` — see the initializer's own doc.
public final class WorkoutStateMachine {
    public let sessionId: String
    public let activityType: String
    public let startedAt: Date
    private let clock: Clock

    public private(set) var state: WorkoutLifecycleState
    public private(set) var stateHistory: [WorkoutStateTransition]
    public private(set) var degradedConditions: Set<WorkoutDegradedCondition>
    public private(set) var accumulatedActiveSeconds: Double
    public private(set) var accumulatedPausedSeconds: Double

    /// The state to return to when the current `.interrupted`/`.recoveryDraft` ends. Maintained
    /// continuously (not just at interruption time) so a checkpoint written from ANY state can
    /// always answer "what was I doing" even if that checkpoint is itself later loaded after a
    /// second, nested crash.
    private var stateBeforeInterruption: WorkoutLifecycleState
    /// The instant `state` was last entered — the anchor `apply`/`checkpoint` measure elapsed time
    /// from when banking seconds into the active/paused buckets.
    private var phaseEnteredAt: Date

    /// Starts a brand-new session at `.idle`. `sessionId` is the ULID this becomes as
    /// `sessions.id` once the session finalizes (I8: minted on-device, never server-assigned).
    public init(sessionId: String, activityType: String, clock: Clock) {
        self.sessionId = sessionId
        self.activityType = activityType
        self.clock = clock
        let now = clock.now()
        self.startedAt = now
        self.state = .idle
        self.stateHistory = [WorkoutStateTransition(state: .idle, at: now)]
        self.degradedConditions = []
        self.accumulatedActiveSeconds = 0
        self.accumulatedPausedSeconds = 0
        self.stateBeforeInterruption = .idle
        self.phaseEnteredAt = now
    }

    /// Reconstructs a machine from a persisted checkpoint after an unclean shutdown — the ONLY
    /// path into `.recoveryDraft`. `checkpoint.state` is never trusted as directly resumable: if
    /// it was already `.interrupted` (a phone call in progress when the crash happened) or, in a
    /// defensive double-crash case, already `.recoveryDraft`, the state to fall back to on
    /// `.resumeFromRecovery` is `checkpoint.hotState.stateBeforeInterruption` — the state BEFORE
    /// that interruption — never `.interrupted`/`.recoveryDraft` themselves, which are not
    /// meaningful "resume into" targets. For every other captured state (`.active`, a pause
    /// variant, `.stopping`, `.finalizing`…) the checkpoint's own `state` is exactly what should
    /// be resumed into, since nothing interrupted it before the crash.
    ///
    /// `phaseEnteredAt` is reset to `clock.now()` rather than `checkpoint.lastCheckpointAt`, so the
    /// wall-clock gap between the crash and this relaunch is never banked as active or paused time
    /// — dead time is dead time, not silently credited to the workout either way.
    public init(restoringFrom checkpoint: WorkoutCheckpoint, clock: Clock) {
        self.sessionId = checkpoint.sessionId
        self.activityType = checkpoint.activityType
        self.startedAt = checkpoint.startedAt
        self.clock = clock
        self.degradedConditions = checkpoint.hotState.degradedConditions
        self.accumulatedActiveSeconds = checkpoint.hotState.activeSeconds
        self.accumulatedPausedSeconds = checkpoint.hotState.pausedSeconds
        self.stateBeforeInterruption = (checkpoint.state == .interrupted || checkpoint.state == .recoveryDraft)
            ? checkpoint.hotState.stateBeforeInterruption
            : checkpoint.state
        self.state = .recoveryDraft
        let now = clock.now()
        self.phaseEnteredAt = now
        self.stateHistory = checkpoint.stateHistory
            + [WorkoutStateTransition(state: .recoveryDraft, at: now,
                                      note: "resumed from checkpoint after unclean shutdown")]
    }

    // MARK: - Pure transition table

    /// The rule table, as a static pure function over its inputs — testable in complete isolation
    /// from any instance. Returns nil for an event that is not legal from `from` (see
    /// `WorkoutStateMachineError`). Degraded-condition events always succeed and never move the
    /// lifecycle phase (see `WorkoutDegradedCondition`'s doc on the two independent axes) — they
    /// are handled before this switch, in `apply`, and never reach here.
    public static func nextState(from state: WorkoutLifecycleState, event: WorkoutEvent,
                                 stateBeforeInterruption: WorkoutLifecycleState) -> WorkoutLifecycleState? {
        switch (state, event) {
        case (.idle, .begin): return .preparing
        case (.preparing, .countdownFinished): return .active
        case (.preparing, .discardRequested): return .discarded

        case (.active, .autoPauseDetected): return .autoPaused
        case (.active, .userPaused): return .manuallyPaused
        case (.active, .interruptionBegan): return .interrupted
        case (.active, .stopRequested): return .stopping
        case (.active, .discardRequested): return .discarded

        case (.autoPaused, .autoResumeDetected): return .active
        case (.autoPaused, .userResumed): return .active
        // A deliberate user pause is more specific than an automatic one — it wins outright
        // rather than being ignored as "already paused".
        case (.autoPaused, .userPaused): return .manuallyPaused
        case (.autoPaused, .interruptionBegan): return .interrupted
        case (.autoPaused, .stopRequested): return .stopping
        case (.autoPaused, .discardRequested): return .discarded

        case (.manuallyPaused, .userResumed): return .active
        case (.manuallyPaused, .interruptionBegan): return .interrupted
        case (.manuallyPaused, .stopRequested): return .stopping
        case (.manuallyPaused, .discardRequested): return .discarded

        case (.interrupted, .interruptionEnded): return stateBeforeInterruption
        case (.interrupted, .stopRequested): return .stopping
        case (.interrupted, .discardRequested): return .discarded

        case (.stopping, .recordingStopped): return .finalizing

        case (.finalizing, .persistCompleted): return .persisted

        case (.recoveryDraft, .resumeFromRecovery): return stateBeforeInterruption
        case (.recoveryDraft, .discardRequested): return .discarded

        default: return nil
        }
    }

    // MARK: - Instance API

    /// Drives the machine one event forward. Throws `WorkoutStateMachineError.illegalTransition`
    /// rather than silently ignoring an event a real adapter should never send — an out-of-order
    /// HealthKit delegate callback is a bug worth surfacing, not a state to paper over.
    @discardableResult
    public func apply(_ event: WorkoutEvent, at date: Date? = nil) throws -> WorkoutLifecycleState {
        let now = date ?? clock.now()

        // Degraded conditions are the OTHER axis (see `WorkoutDegradedCondition`): they never
        // consult or affect the lifecycle transition table, and always succeed.
        switch event {
        case .degradedConditionBegan(let condition):
            degradedConditions.insert(condition)
            return state
        case .degradedConditionEnded(let condition):
            degradedConditions.remove(condition)
            return state
        default:
            break
        }

        guard let next = Self.nextState(from: state, event: event, stateBeforeInterruption: stateBeforeInterruption) else {
            throw WorkoutStateMachineError.illegalTransition(from: state, event: event)
        }

        // Bank the time just spent in the phase being LEFT, before the clock's context switches.
        let elapsed = max(0, now.timeIntervalSince(phaseEnteredAt))
        switch state {
        case .active: accumulatedActiveSeconds += elapsed
        case .autoPaused, .manuallyPaused, .interrupted: accumulatedPausedSeconds += elapsed
        default: break
        }

        // Capture what is being interrupted BEFORE `state` is overwritten below.
        if event == .interruptionBegan {
            stateBeforeInterruption = state
        }

        state = next
        phaseEnteredAt = now
        stateHistory.append(WorkoutStateTransition(state: next, at: now))
        return next
    }

    /// A cheap, read-only snapshot for `WorkoutCheckpointRepository.save` — safe to call on every
    /// tick the plan's "frequent checkpoints, draft always recoverable" requirement asks for. Folds
    /// in the time elapsed since the current phase began WITHOUT mutating the machine, so calling
    /// this to checkpoint never itself changes what a subsequent `apply` sees.
    public func checkpoint(originDeviceId: String, at date: Date? = nil) -> WorkoutCheckpoint {
        let now = date ?? clock.now()
        let elapsed = max(0, now.timeIntervalSince(phaseEnteredAt))
        var activeSeconds = accumulatedActiveSeconds
        var pausedSeconds = accumulatedPausedSeconds
        switch state {
        case .active: activeSeconds += elapsed
        case .autoPaused, .manuallyPaused, .interrupted: pausedSeconds += elapsed
        default: break
        }
        return WorkoutCheckpoint(
            sessionId: sessionId, activityType: activityType, state: state, startedAt: startedAt,
            stateHistory: stateHistory,
            hotState: WorkoutHotState(degradedConditions: degradedConditions,
                                     stateBeforeInterruption: stateBeforeInterruption,
                                     activeSeconds: activeSeconds, pausedSeconds: pausedSeconds),
            lastCheckpointAt: now, originDeviceId: originDeviceId)
    }
}
