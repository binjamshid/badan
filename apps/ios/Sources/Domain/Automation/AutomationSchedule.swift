import Foundation

// MARK: - §9.7 AutomationSchedule — the user's declared automation intent, with an honest tier
//
// EPIC-15. This file is the *domain* of scheduling honesty: the entity, its enums, and the two
// PURE decision functions the engine turns into runs. It deliberately imports nothing but
// Foundation and touches no database, no `BGTaskScheduler`, no `WorkManager` — those live in the
// engine and the substrate wiring — so every rule below is exercised the same way on both
// platforms by a plain unit test (the split `ExportRunnerTemplateTest` documents: shared decisions
// tested decision-for-decision, platform I/O tested separately).
//
// The anti-HAE thesis (plan §4.10 / §13.7) is enforced structurally here:
//   • `tier` is a stored PROMISE, never inferred, so the UI can label reliability honestly.
//   • `nextExpectedWindow` is a DISPLAY-ONLY estimate — it is computed as a courtesy and NEVER
//     read back as a due-time to fire on (that would quietly turn a best-effort tier into a
//     wall-clock claim the platform cannot keep).
//   • "paused after repeated failure" is DERIVED from `consecutiveFailures`, not a second stored
//     flag — see `isPaused`. The schema (§9.7 / migration v4) deliberately carries no `paused`
//     column for exactly this reason: one number is the single source of truth, so "paused" and
//     "not paused" can never disagree with the failure count that caused them.

/// §9.7 `tier` — the reliability promise BADAN makes for this schedule, labeled honestly at every
/// surface (plan §13.7). The engine's background-wake path only ever auto-runs
/// `opportunisticBackground`; `shortcutDriven` fires from an App Intent (device unlocked) and
/// `manualOnly` fires only from a user tap — neither is a thing a background wake may run, or the
/// tier label would be a lie.
enum AutomationTier: String, Codable, Hashable, Sendable, CaseIterable {
    /// iOS best-effort `BGAppRefresh` / Android `WorkManager` periodic. System-decided timing;
    /// labeled "best-effort background" (iOS) / "usually within the hour" (Android).
    case opportunisticBackground
    /// Runs via Shortcuts at a user-set time — phone must be unlocked. Fired by EPIC-19's intent,
    /// never by this engine.
    case shortcutDriven
    /// Runs only when the user taps it. Stored so the UI can offer it; never auto-fired.
    case manualOnly
}

/// §9.7 `desiredCadence` — how often the user wants this to run. `onNewData` is data-driven (fire
/// when there is something new to export); the three best-effort tiers are elapsed-time-driven.
/// None of them is a wall-clock promise — the tier carries the truth about *whether* a wake
/// happens; the cadence is only the floor between attempts.
enum AutomationCadence: String, Codable, Hashable, Sendable, CaseIterable {
    case onNewData
    case hourlyBestEffort
    case dailyBestEffort
    case weeklyBestEffort

    /// The minimum time that must elapse since the last success before a time-driven cadence is
    /// eligible again. `onNewData` has no time floor (it is gated on data, not the clock) and
    /// returns 0.
    var minimumInterval: TimeInterval {
        switch self {
        case .onNewData: return 0
        case .hourlyBestEffort: return 3_600
        case .dailyBestEffort: return 86_400
        case .weeklyBestEffort: return 604_800
        }
    }

    /// A DISPLAY-ONLY estimate of when this cadence would next become eligible after `lastSuccess`.
    /// `nil` for `onNewData` (there is no time to estimate — it depends on when data arrives) and
    /// whenever there is no prior success to anchor from. Never consulted by the engine when
    /// deciding to fire; it exists purely so a surface can show "next: ~tomorrow" without the
    /// engine ever behaving as if it had a wall clock (§9.7).
    func estimatedNextWindow(afterLastSuccess lastSuccess: Date?) -> Date? {
        guard self != .onNewData, let lastSuccess else { return nil }
        return lastSuccess.addingTimeInterval(minimumInterval)
    }
}

/// §9.7 `quietHours` — a local wall-clock window during which the schedule must not fire. Stored as
/// a compact canonical string (`"HH:mm-HH:mm"`) rather than JSON so the two platforms' stored
/// values are byte-identical and human-inspectable in an export. Minutes are minutes-since-local-
/// midnight; a window whose start is after its end wraps midnight (e.g. `22:00-07:00`).
struct QuietHours: Codable, Hashable, Sendable {
    /// Minutes since local midnight, `0...1439`.
    var startMinute: Int
    var endMinute: Int

    init(startMinute: Int, endMinute: Int) {
        self.startMinute = ((startMinute % 1_440) + 1_440) % 1_440
        self.endMinute = ((endMinute % 1_440) + 1_440) % 1_440
    }

    init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.init(startMinute: startHour * 60 + startMinute, endMinute: endHour * 60 + endMinute)
    }

    /// Whether `instant`, read in `calendar`'s (device-local) time zone, falls inside the window.
    ///
    /// A zero-length window (`start == end`) means "no quiet hours" and never contains anything —
    /// the honest reading of a window a user collapsed to a point, and it keeps a mis-saved
    /// `00:00-00:00` from silently suppressing the schedule forever.
    func contains(_ instant: Date, calendar: Calendar) -> Bool {
        guard startMinute != endMinute else { return false }
        let comps = calendar.dateComponents([.hour, .minute], from: instant)
        let m = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if startMinute < endMinute {
            return m >= startMinute && m < endMinute
        } else {
            // Wraps midnight: inside if at/after the start OR before the end.
            return m >= startMinute || m < endMinute
        }
    }

    /// `"HH:mm-HH:mm"`. The persisted form and the parity token.
    var storageString: String {
        func hhmm(_ minute: Int) -> String {
            String(format: "%02d:%02d", minute / 60, minute % 60)
        }
        return "\(hhmm(startMinute))-\(hhmm(endMinute))"
    }

    /// Parse `"HH:mm-HH:mm"`, returning `nil` for any malformed or out-of-range value rather than
    /// guessing — a corrupt quiet-hours string must not silently become a real window that
    /// suppresses a schedule.
    init?(storageString: String) {
        let halves = storageString.split(separator: "-", maxSplits: 1)
        guard halves.count == 2,
              let start = Self.parseMinute(String(halves[0])),
              let end = Self.parseMinute(String(halves[1])) else { return nil }
        self.init(startMinute: start, endMinute: end)
    }

    private static func parseMinute(_ s: String) -> Int? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }
}

/// §9.7 `AutomationSchedule`. A configuration row plus the small amount of mutable bookkeeping the
/// failure budget needs (`consecutiveFailures`, `lastSuccessAt`). Unlike a derived value (I2), this
/// bookkeeping is legitimately mutated in place — it is scheduler state, not a health datum, and
/// the audit trail of what an automation *did* lives append-only in `export_runs`, not here.
struct AutomationSchedule: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var templateId: String
    var tier: AutomationTier
    var desiredCadence: AutomationCadence
    var quietHours: QuietHours?
    var enabled: Bool
    /// Failures since the last success. The failure budget is the load-bearing honesty feature:
    /// at `failureBudget` the schedule is VISIBLY paused and the user is notified — never a silent
    /// death (the exact HAE complaint EPIC-15 answers).
    var consecutiveFailures: Int
    var lastSuccessAt: Date?
    /// DISPLAY-ONLY estimate (§9.7). Never read back as a fire time — see `AutomationCadence`.
    var nextExpectedWindow: Date?
    var createdAt: Date
    var updatedAt: Date
    var originDeviceId: String
    var deletedAt: Date?

    init(id: String, templateId: String, tier: AutomationTier,
         desiredCadence: AutomationCadence, quietHours: QuietHours? = nil,
         enabled: Bool = true, consecutiveFailures: Int = 0, lastSuccessAt: Date? = nil,
         nextExpectedWindow: Date? = nil, createdAt: Date, updatedAt: Date,
         originDeviceId: String, deletedAt: Date? = nil) {
        self.id = id
        self.templateId = templateId
        self.tier = tier
        self.desiredCadence = desiredCadence
        self.quietHours = quietHours
        self.enabled = enabled
        self.consecutiveFailures = consecutiveFailures
        self.lastSuccessAt = lastSuccessAt
        self.nextExpectedWindow = nextExpectedWindow
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.deletedAt = deletedAt
    }

    /// Three consecutive failures pause the schedule (plan §12 EPIC-15 / §13.7). A constant, not a
    /// tunable knob per install: the number is part of the promise the design makes to the user,
    /// and a schedule paused at a different count on different devices is not the same promise.
    static let failureBudget = 3

    /// Whether repeated failures have paused this schedule. DERIVED, not stored (see the file
    /// header): the pause and the count that caused it can therefore never disagree, and "resume"
    /// is simply resetting the count to 0. The UI shows this state; the engine skips a paused
    /// schedule instead of hammering a destination that keeps failing.
    var isPaused: Bool { consecutiveFailures >= Self.failureBudget }
}

// MARK: - Pure decision 1: is this schedule due?

/// Why a schedule was not run this wake. A closed vocabulary so a diagnostics surface (and a test)
/// can reason about the decision without parsing prose.
enum AutomationSkipReason: String, Equatable, Sendable {
    case disabled
    case paused
    /// Not an `opportunisticBackground` schedule — a Shortcut/manual tier a background wake must
    /// never auto-run.
    case notBackgroundTier
    case quietHours
    case cadenceNotElapsed
    case noNewData
}

/// The verdict for one schedule at one instant.
enum AutomationDueVerdict: Equatable, Sendable {
    case due
    case skip(AutomationSkipReason)
}

/// The pure "is it due?" gate. All inputs are values; no I/O. `hasNewData` is supplied by the
/// caller (the engine reads it from the ingested-measurement axis) and is only consulted for the
/// `onNewData` cadence — the engine passes `false` for the time-driven cadences, where it is
/// unused, rather than paying a database read it will not look at.
///
/// The gates, in order, mirror the plan's phrasing ("cadence satisfied? outside quiet hours? data
/// new since the cursor?") and each earns its place:
///   1. `enabled` / `notBackgroundTier` / `paused` — this schedule is not a candidate at all.
///   2. `quietHours` — a hard gate for every cadence: the user asked not to be touched now.
///   3. cadence — `onNewData` is gated on `hasNewData`; the best-effort tiers on elapsed time.
enum AutomationDueEvaluator {
    /// A small slack on the elapsed-time gate so a periodic wake landing a few minutes short of the
    /// interval (WorkManager's hourly flex can fire anywhere in the hour) still counts as due,
    /// rather than skipping and drifting the effective cadence out to two wake intervals. The tier
    /// label already discloses that best-effort timing is approximate, so a few minutes early is
    /// within the promise; it is deliberately small so it cannot collapse a daily into an hourly.
    static let cadenceSlack: TimeInterval = 5 * 60

    static func verdict(for schedule: AutomationSchedule, now: Date,
                               hasNewData: Bool, calendar: Calendar) -> AutomationDueVerdict {
        guard schedule.enabled else { return .skip(.disabled) }
        guard schedule.tier == .opportunisticBackground else { return .skip(.notBackgroundTier) }
        guard !schedule.isPaused else { return .skip(.paused) }
        if let quiet = schedule.quietHours, quiet.contains(now, calendar: calendar) {
            return .skip(.quietHours)
        }
        switch schedule.desiredCadence {
        case .onNewData:
            return hasNewData ? .due : .skip(.noNewData)
        case .hourlyBestEffort, .dailyBestEffort, .weeklyBestEffort:
            // No prior success ⇒ infinitely overdue ⇒ due. Otherwise require the interval (less a
            // small slack) to have elapsed.
            guard let last = schedule.lastSuccessAt else { return .due }
            let elapsed = now.timeIntervalSince(last)
            return elapsed >= schedule.desiredCadence.minimumInterval - cadenceSlack
                ? .due : .skip(.cadenceNotElapsed)
        }
    }
}

// MARK: - Pure decision 2: the failure budget

/// What one run's outcome does to the schedule's bookkeeping. Success and `skippedNoData` are both
/// clean terminal states (the automation did its job — including the honest "nothing to export"),
/// so both reset the counter and stamp `lastSuccessAt`. `isFailure` outcomes spend a strike.
/// Everything else — locked store, throttled, cancelled — is neutral: the run never really
/// happened, so it neither advances the success clock nor spends a strike.
enum AutomationOutcomeKind: Equatable, Sendable {
    case success
    case failure
    case neutral
}

/// The computed bookkeeping change. `didJustPause` is true only on the transition INTO the paused
/// state (the count crossing `failureBudget`), so the notification fires exactly once — a paused
/// schedule is skipped on subsequent wakes and can never re-notify without a resume first.
struct AutomationOutcomeUpdate: Equatable, Sendable {
    var kind: AutomationOutcomeKind
    var consecutiveFailures: Int
    var lastSuccessAt: Date?
    var didJustPause: Bool
}

enum AutomationBudget {
    static func applyOutcome(_ outcome: ExportOutcome, to schedule: AutomationSchedule,
                                    now: Date) -> AutomationOutcomeUpdate {
        if outcome.isFailure {
            let newCount = schedule.consecutiveFailures + 1
            let wasPaused = schedule.consecutiveFailures >= AutomationSchedule.failureBudget
            let nowPaused = newCount >= AutomationSchedule.failureBudget
            return AutomationOutcomeUpdate(kind: .failure, consecutiveFailures: newCount,
                                           lastSuccessAt: schedule.lastSuccessAt,
                                           didJustPause: nowPaused && !wasPaused)
        }
        switch outcome {
        case .success, .skippedNoData:
            return AutomationOutcomeUpdate(kind: .success, consecutiveFailures: 0,
                                           lastSuccessAt: now, didJustPause: false)
        default:
            // .skippedLocked / .throttled / .cancelled — neutral, nothing changes.
            return AutomationOutcomeUpdate(kind: .neutral,
                                           consecutiveFailures: schedule.consecutiveFailures,
                                           lastSuccessAt: schedule.lastSuccessAt, didJustPause: false)
        }
    }
}
