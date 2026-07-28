import Foundation

// EPIC-42's interval/HIIT engine (plan §7A.5; research doc §"Interval screen" and its
// `WorkoutInterval` model). Migration 9 already created `workout_intervals` — this is the type
// layer that finally uses it.
//
// Scope, stated plainly: this is the STRUCTURE and the CLOCK. It answers "which segment am I in,
// how long is left, what comes next, and what did each segment actually cost." It deliberately does
// not do audio/haptic cue delivery (research §"Audio/haptic settings" wants cue modes, throttling,
// and headphone routing — a real feature with its own settings surface, not something to bolt on
// here), and it does not auto-lap from GPS, since this build records no route (Phase 3C slice 2's
// standing boundary — the shipped privacy copy promises no new route recording).
//
// The engine is a pure function of (plan, elapsed time). It holds no timer and no state of its own:
// `WorkoutSessionCoordinator` already owns the authoritative `elapsedActiveSeconds` clock, and a
// second clock here would be a second answer to "how far in are we" — the exact duplicate-source
// problem the workout state machine was built to avoid. Ask it where you are; it tells you.

/// What a segment is for. Mirrors the research doc's `kind (work/rest/lap/manual segment/
/// transition)` and is stored verbatim in `workout_intervals.kind`.
public enum IntervalSegmentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case warmUp
    case work
    case recovery
    case coolDown

    public var displayName: LocalizedString {
        switch self {
        case .warmUp: return LocalizedString(en: "Warm-up", ar: "إحماء")
        case .work: return LocalizedString(en: "Work", ar: "جهد")
        case .recovery: return LocalizedString(en: "Recovery", ar: "استعادة")
        case .coolDown: return LocalizedString(en: "Cool-down", ar: "تهدئة")
        }
    }

    /// Whether this segment is the effortful part. Used only for copy and summary counts — never
    /// to score or grade the session.
    public var isEffort: Bool { self == .work }
}

/// One segment of a plan, before it is laid out on a timeline.
public struct IntervalStep: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: IntervalSegmentKind
    public var durationSeconds: Int
    /// Optional user-authored target, e.g. "hard", "easy jog", "zone 3". Free text on purpose:
    /// BADAN has no way to verify adherence to a pace or power target in this build (no route, no
    /// power meter integration on the live path), and a structured target the app cannot check
    /// would be a promise the summary could not keep. Shown as the person's own note, nothing more.
    public var targetNote: String?

    public init(id: String = ULID.newID(), kind: IntervalSegmentKind, durationSeconds: Int,
                targetNote: String? = nil) {
        self.id = id
        self.kind = kind
        // A zero-or-negative segment is meaningless and would make `IntervalPlan` produce
        // zero-width windows that `segment(atElapsed:)` could never land inside — clamped here so
        // no caller has to defend against it.
        self.durationSeconds = max(1, durationSeconds)
        self.targetNote = targetNote
    }
}

/// A structured session: an optional warm-up, a repeated work/recovery cycle, an optional
/// cool-down. Deliberately this shape rather than a free-form step list — it is what the classic
/// "8 × 400m with 90s recovery" and "20 min HIIT, 30 on / 30 off" cases both reduce to, and it
/// keeps the builder UI to four numbers instead of a step editor.
public struct IntervalPlan: Codable, Hashable, Sendable {
    public var name: String?
    public var warmUp: IntervalStep?
    public var work: IntervalStep
    public var recovery: IntervalStep?
    public var repeats: Int
    public var coolDown: IntervalStep?

    public init(name: String? = nil, warmUp: IntervalStep? = nil, work: IntervalStep,
                recovery: IntervalStep? = nil, repeats: Int, coolDown: IntervalStep? = nil) {
        self.name = name
        self.warmUp = warmUp
        self.work = work
        self.recovery = recovery
        self.repeats = max(1, repeats)
        self.coolDown = coolDown
    }

    /// The plan flattened into the exact sequence a session will run, in order.
    ///
    /// The final round deliberately drops its trailing recovery: nobody wants to stand still for 90
    /// seconds after the last rep before the cool-down starts, and a plan that says "8 × 400m with
    /// 90s recovery" means 7 recoveries, not 8. Getting this wrong is the classic off-by-one in
    /// every interval timer, so it is asserted directly in `IntervalEngineTests`.
    public var steps: [IntervalStep] {
        var result: [IntervalStep] = []
        if let warmUp { result.append(warmUp) }
        for round in 0..<repeats {
            // Each round needs its own step identity — reusing `work.id` across 8 rounds would make
            // `workout_intervals` rows indistinguishable by id and break any per-round lookup.
            result.append(IntervalStep(id: "\(work.id)-r\(round)", kind: .work,
                                       durationSeconds: work.durationSeconds, targetNote: work.targetNote))
            if let recovery, round < repeats - 1 {
                result.append(IntervalStep(id: "\(recovery.id)-r\(round)", kind: .recovery,
                                          durationSeconds: recovery.durationSeconds,
                                          targetNote: recovery.targetNote))
            }
        }
        if let coolDown { result.append(coolDown) }
        return result
    }

    public var totalSeconds: Int { steps.reduce(0) { $0 + $1.durationSeconds } }
    public var workRoundCount: Int { repeats }

    /// A plain HIIT plan — the "Quick Start HIIT" the research doc's activity table asks for.
    public static func hiit(workSeconds: Int = 30, recoverySeconds: Int = 30, rounds: Int = 8,
                            warmUpSeconds: Int = 180, coolDownSeconds: Int = 180) -> IntervalPlan {
        IntervalPlan(
            warmUp: warmUpSeconds > 0 ? IntervalStep(kind: .warmUp, durationSeconds: warmUpSeconds) : nil,
            work: IntervalStep(kind: .work, durationSeconds: workSeconds),
            recovery: recoverySeconds > 0 ? IntervalStep(kind: .recovery, durationSeconds: recoverySeconds) : nil,
            repeats: rounds,
            coolDown: coolDownSeconds > 0 ? IntervalStep(kind: .coolDown, durationSeconds: coolDownSeconds) : nil)
    }
}

/// Where a session is, right now, inside its plan.
public struct IntervalPosition: Hashable, Sendable {
    /// Index into `IntervalPlan.steps`.
    public let stepIndex: Int
    public let step: IntervalStep
    /// Seconds already spent inside this step.
    public let elapsedInStep: Int
    /// Seconds left in this step. Never negative.
    public let remainingInStep: Int
    /// The step after this one, if any — the "next segment" the interval screen shows so a person
    /// knows what is coming before it arrives.
    public let nextStep: IntervalStep?
    /// 1-based round number for a `.work` step, so the screen can say "round 3 of 8". `nil` for
    /// warm-up/cool-down, which belong to no round.
    public let workRound: Int?

    public var fractionComplete: Double {
        guard step.durationSeconds > 0 else { return 1 }
        return min(1, max(0, Double(elapsedInStep) / Double(step.durationSeconds)))
    }
}

public enum IntervalEngine {
    /// Where `elapsed` seconds of active time places you in `plan`, or `nil` once the plan is
    /// finished.
    ///
    /// `nil` means "the structure is done", NOT "the workout is over" — the session keeps running
    /// and recording until the person ends it. An interval plan is a guide the person chose, and
    /// running past the end of it is a completely ordinary thing to do; treating the end of the
    /// plan as the end of the workout would stop recording someone mid-effort.
    public static func position(in plan: IntervalPlan, elapsed: TimeInterval) -> IntervalPosition? {
        let elapsedSeconds = max(0, Int(elapsed))
        let steps = plan.steps
        var consumed = 0
        var round = 0

        for (index, step) in steps.enumerated() {
            if step.kind == .work { round += 1 }
            let stepEnd = consumed + step.durationSeconds
            if elapsedSeconds < stepEnd {
                let inStep = elapsedSeconds - consumed
                return IntervalPosition(
                    stepIndex: index, step: step, elapsedInStep: inStep,
                    remainingInStep: max(0, step.durationSeconds - inStep),
                    nextStep: index + 1 < steps.count ? steps[index + 1] : nil,
                    workRound: step.kind == .work ? round : nil)
            }
            consumed = stepEnd
        }
        return nil
    }

    /// Whether `elapsed` has just crossed into a new step relative to `previousElapsed` — the seam a
    /// caller uses to fire a transition (a haptic, a row written to `workout_intervals`).
    ///
    /// Comparing resolved step INDICES rather than doing arithmetic on the tick interval is what
    /// makes this correct when the app was backgrounded: a coordinator that resumes after 40
    /// seconds away may jump several steps at once, and a naive "did the remaining time hit zero"
    /// check would miss every transition in between. It returns the step that is current NOW, which
    /// is the only honest answer after a gap — BADAN does not claim to have observed the ones it
    /// slept through.
    public static func transition(in plan: IntervalPlan, from previousElapsed: TimeInterval,
                                  to elapsed: TimeInterval) -> IntervalPosition? {
        let before = position(in: plan, elapsed: previousElapsed)
        let after = position(in: plan, elapsed: elapsed)
        guard let after else { return nil }
        guard before?.stepIndex != after.stepIndex else { return nil }
        return after
    }

    /// The completed segments of `plan` after `elapsed` seconds, as rows ready for
    /// `workout_intervals`. Only segments the session actually finished are included — a plan
    /// abandoned in round 3 records three rounds, never eight.
    public static func completedSegments(in plan: IntervalPlan, elapsed: TimeInterval,
                                         sessionId: String, startedAt: Date,
                                         originDeviceId: String) -> [WorkoutInterval] {
        let elapsedSeconds = max(0, Int(elapsed))
        var consumed = 0
        var result: [WorkoutInterval] = []

        for (index, step) in plan.steps.enumerated() {
            let stepEnd = consumed + step.durationSeconds
            guard elapsedSeconds >= stepEnd else { break }
            result.append(WorkoutInterval(
                // Derived from (sessionId, seq), NOT from `step.id`. Both are stable within a
                // single plan object, but only this one is stable across two plans built from the
                // same numbers — and `insert` relies on the id to make re-recording a no-op.
                // Keying on the plan object's identity would mean a rebuilt plan silently wrote a
                // second copy of every segment; a test caught exactly that. Identity here belongs
                // to "segment 3 of session X", which is the fact being recorded.
                id: "\(sessionId)-seg\(index)", sessionId: sessionId, seq: index, kind: step.kind,
                startAt: startedAt.addingTimeInterval(TimeInterval(consumed)),
                endAt: startedAt.addingTimeInterval(TimeInterval(stepEnd)),
                target: step.targetNote,
                // Result is the plain observed fact — this segment ran to its planned length.
                // Deliberately not an adherence grade: with no pace or power on this path there is
                // nothing to compare against, and a "met target" flag nothing checked would be a
                // fabricated assessment (I5).
                result: "completed",
                originDeviceId: originDeviceId))
            consumed = stepEnd
        }
        return result
    }
}

/// One recorded segment of a structured session (`workout_intervals`, migration 9).
///
/// Carries no provenance columns of its own, for the reason migration 9's own comment gives: it is
/// a child of a `sessions` row that already carries full embedded provenance (I1), and stamping
/// twelve provenance columns on every lap of a 20-lap session would duplicate an answer the parent
/// already gives — and could drift from it.
public struct WorkoutInterval: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var seq: Int
    public var kind: IntervalSegmentKind
    public var startAt: Date
    public var endAt: Date?
    public var target: String?
    public var result: String?
    public var updatedAt: Date
    public var originDeviceId: String
    public var deletedAt: Date?

    public init(id: String = ULID.newID(), sessionId: String, seq: Int, kind: IntervalSegmentKind,
                startAt: Date, endAt: Date? = nil, target: String? = nil, result: String? = nil,
                updatedAt: Date = Date(), originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.seq = seq
        self.kind = kind
        self.startAt = startAt
        self.endAt = endAt
        self.target = target
        self.result = result
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }

    public var durationSeconds: Int {
        guard let endAt else { return 0 }
        return max(0, Int(endAt.timeIntervalSince(startAt)))
    }
}
