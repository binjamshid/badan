import Foundation

/// Decides whether the morning summary should be raised NOW, because the user just woke up, rather
/// than at a fixed clock hour they may have slept through or risen long before.
///
/// Pure: no clock, no storage, no HealthKit. Everything it needs is passed in, which is what lets
/// the recency window and the once-a-day rule be tested without a device or a sleep sample.
///
/// ## Where the wake time comes from
///
/// NOT from `SleepNightScore`, and not from any derived row. `SleepNight` — the only type that
/// carries `wakeSecondsOfDay` — is an in-memory intermediate inside `SleepIntelligenceEngine`;
/// `appendScore` persists five derived metrics (`sleep.need`, `sleep.performance`, `sleep.debt`,
/// `sleep.consistency`, `sleep.disturbances`) and none of them is a wake time. The wake instant
/// lives in the raw `sessions` table, where the adapter reads it: the last primary sleep session for
/// the night, `endAt` in its own `tzId`. Persisting a new derived metric instead would mean new
/// `MetricID`s, new `registry.json`/`algorithms.json` contract entries and Android mirror parity,
/// for a number the sessions table already holds exactly.
///
/// ## The locked-device limitation, stated rather than papered over
///
/// A watch syncs the night when it next connects, which is frequently while the phone is still
/// locked. `BackgroundCoordinator.performObserverFollowUp` checks
/// `protectedData.isProtectedDataAvailable` first and, when the store is locked, records
/// `.storeLocked` and reads nothing — iOS data protection working as designed. So on a locked phone
/// the summary is produced at FIRST UNLOCK, not at the literal moment of waking. That is inherent to
/// the platform and is not worked around; the foreground evaluation is what makes first unlock
/// reliable rather than accidental.
public enum WakeSummaryPolicy {

    /// What the caller should do, and when it should do nothing, WHY. Named reasons rather than a
    /// bare `Bool` so "why didn't I get my summary?" is answerable from a log line, which is the
    /// same standard the `notification_deliveries` suppression rows already hold themselves to.
    public enum Outcome: String, Equatable, Sendable {
        /// Nothing is booked for today — raise the morning summary now.
        case fire
        /// A reservation for later today already exists and has NOT fired. Move it to now: cancel
        /// the pending request, re-issue it immediately, keep the same ledger row.
        ///
        /// This case is the whole reason the wake trigger works at all. Reconcile books today's
        /// 08:00 slot the previous evening, and `evaluateAndScheduleDecision` refuses to schedule a
        /// second row for the same class and day — so treating an existing reservation as "already
        /// handled" would silently discard every wake trigger that happened before its fixed hour,
        /// which is nearly all of them. The user would keep getting 08:00 and the feature would
        /// appear to do nothing.
        case retarget
        /// The class is switched off — nothing to decide.
        case notEnabled
        /// No primary sleep session has been recorded for the night yet.
        case noWakeRecorded
        /// A wake was recorded, but long enough ago that announcing "good morning" would be odd.
        /// The fixed-hour path is the backstop for this case, not this one.
        case wakeTooOld
        /// The wake is in the future relative to `now` — a clock change, a bad sample, or a session
        /// still open. Treated as "not yet", never as a reason to fire early.
        case wakeInFuture
        /// Today's summary has already been committed. This is what keeps the wake trigger and the
        /// fixed-hour fallback from both firing on the same day.
        case alreadySentToday
    }

    /// The default window in which a wake still counts as "just now". Four hours is deliberately
    /// generous: the phone may have been locked when the watch synced, so the app's first chance to
    /// see the night can be well after the user actually got up.
    public static let defaultRecencyWindow: TimeInterval = 4 * 3600

    /// - Parameters:
    ///   - now: the evaluation instant.
    ///   - wakeInstant: end of the latest primary sleep session, or `nil` if none is recorded.
    /// Today's existing morning-summary reservation, as the ledger holds it.
    public struct Reservation: Equatable, Sendable {
        /// When the reservation currently points at.
        public var scheduledFor: Date
        /// Whether the app has observed it actually reaching the user.
        public var delivered: Bool

        public init(scheduledFor: Date, delivered: Bool) {
            self.scheduledFor = scheduledFor
            self.delivered = delivered
        }
    }

    /// - Parameters:
    ///   - reservation: today's row from `notification_deliveries`, or `nil` if the day is unbooked.
    ///     The ledger is the source of truth rather than a `UserDefaults` flag, because it is what
    ///     already survives process death and what the budget is counted against — two mechanisms
    ///     disagreeing about whether today's summary went out is exactly how a user ends up with two.
    public static func evaluate(now: Date,
                                wakeInstant: Date?,
                                reservation: Reservation?,
                                enabled: Bool,
                                recencyWindow: TimeInterval = defaultRecencyWindow) -> Outcome {
        guard enabled else { return .notEnabled }
        // Delivered is final: never send a second summary for a day the user already got one.
        if let reservation, reservation.delivered { return .alreadySentToday }
        guard let wakeInstant else { return .noWakeRecorded }

        let elapsed = now.timeIntervalSince(wakeInstant)
        guard elapsed >= 0 else { return .wakeInFuture }
        guard elapsed <= recencyWindow else { return .wakeTooOld }

        guard let reservation else { return .fire }
        // A reservation whose time has already passed without being marked delivered is treated as
        // spent, not as retargetable. `markNotificationDelivered` only runs when the app observes a
        // presentation or a tap, so a notification that fired while the app was never opened stays
        // `scheduled` forever — and re-issuing it would send a second copy of a summary the user has
        // already seen on their lock screen. Failing towards silence is the correct direction here,
        // and matches how the ledger reservation itself already fails.
        guard reservation.scheduledFor > now else { return .alreadySentToday }
        return .retarget
    }
}
