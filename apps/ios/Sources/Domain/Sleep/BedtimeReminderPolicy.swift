import Foundation

/// Plans the evening wind-down from the user's own sleep need instead of a fixed 21:00, mirroring
/// `HydrationReminderPolicy` in shape: a pure `enum` namespace, a `Suppression` reason so a settings
/// screen can explain silence, and a `nil`-returning `nextFireDate`.
///
/// Takes primitives (`sleepNeedSeconds`, `needConfidence`, `habitualBedMinute`) rather than
/// `SleepNeedRange` — the policy needs a number and a confidence, not the sleep engine's type, and
/// staying off that type is what keeps this `public` and independently testable.
///
/// ## Degrading honestly is the hard part
///
/// `SleepNightScore.need`, `.performance` and `.debtSeconds` are all `nil` until a personal
/// sleep-duration baseline exists, and `.consistency` is `nil` below two nights. A new install
/// therefore has NO need estimate, and a derived bedtime would be a number invented to look
/// personal. Three tiers, most-earned first:
///
///   1. **Derived** — a target wake time the user set, and a need estimate confident enough to
///      subtract from it.
///   2. **Habitual** — no usable need, but the user's own recent bedtimes are on record. Their
///      actual habit is a better answer than the app's guess about it.
///   3. **Fixed hour** — nothing on record at all. The 21:00 the app has always used, unchanged, so
///      an existing user's reminder does not move under them on upgrade.
///
/// A wide need band is treated as no estimate rather than as a confident one: `minConfidence` is
/// what stops tier 1 dressing up a guess as a derivation.
public enum BedtimeReminderPolicy {

    /// Why no wind-down is scheduled. Mirrors `HydrationReminderPolicy.Suppression`.
    public enum Suppression: String, Hashable, Sendable {
        case notEnabled
        case paused
        /// Every candidate time in the search window fell inside quiet hours.
        case quietHours
    }

    /// Which tier produced the time. Surfaced so the UI can say "based on your recent nights"
    /// instead of implying a precision the inputs do not support — the same reason
    /// `SleepNeedRange` carries `confidence` and `effortPresent` at all.
    public enum Basis: String, Hashable, Sendable {
        case derivedFromNeed
        case habitualBedtime
        case fixedHour
    }

    /// Below this, a need estimate is treated as absent. A band wide enough to be uncertain is not
    /// a basis for telling someone when to go to bed.
    public static let defaultMinConfidence: Double = 0.4

    /// The next wind-down instant, or `nil` when none may fire within `withinDays`.
    public static func nextFireDate(after now: Date,
                                    settings: BedtimeReminderSettings,
                                    sleepNeedSeconds: Double?,
                                    needConfidence: Double,
                                    habitualBedMinute: Int?,
                                    quietHours: NotificationQuietHours,
                                    fallbackHour: Int,
                                    enabled: Bool,
                                    calendar: Calendar = .current,
                                    minConfidence: Double = defaultMinConfidence,
                                    withinDays: Int = 14) -> Date? {
        plan(after: now, settings: settings, sleepNeedSeconds: sleepNeedSeconds,
             needConfidence: needConfidence, habitualBedMinute: habitualBedMinute,
             quietHours: quietHours, fallbackHour: fallbackHour, enabled: enabled,
             calendar: calendar, minConfidence: minConfidence, withinDays: withinDays).first
    }

    /// Every permitted wind-down instant in the next `withinDays`, ascending.
    public static func plan(after now: Date,
                            settings: BedtimeReminderSettings,
                            sleepNeedSeconds: Double?,
                            needConfidence: Double,
                            habitualBedMinute: Int?,
                            quietHours: NotificationQuietHours,
                            fallbackHour: Int,
                            enabled: Bool,
                            calendar: Calendar = .current,
                            minConfidence: Double = defaultMinConfidence,
                            withinDays: Int = 14) -> [Date] {
        guard enabled else { return [] }

        var floor = now
        if let paused = settings.pausedUntil, paused > floor { floor = paused }

        let raw = fireMinuteOfDay(settings: settings, sleepNeedSeconds: sleepNeedSeconds,
                                  needConfidence: needConfidence,
                                  habitualBedMinute: habitualBedMinute,
                                  fallbackHour: fallbackHour, minConfidence: minConfidence).minute
        guard let fireMinute = resolveAgainstQuietHours(raw, quietHours: quietHours) else { return [] }

        var results: [Date] = []
        for dayOffset in 0...max(0, withinDays) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset,
                                          to: calendar.startOfDay(for: now)),
                  let fire = calendar.date(byAdding: .minute, value: fireMinute, to: day),
                  fire > floor
            else { continue }
            results.append(fire)
        }
        return results
    }

    /// The wind-down minute-of-day and which tier produced it. Separated from `plan` so the tier is
    /// assertable directly — the cold-start fallbacks are the part most likely to regress, and they
    /// are invisible through a `Date` alone.
    public static func fireMinuteOfDay(settings: BedtimeReminderSettings,
                                       sleepNeedSeconds: Double?,
                                       needConfidence: Double,
                                       habitualBedMinute: Int?,
                                       fallbackHour: Int,
                                       minConfidence: Double = defaultMinConfidence)
        -> (minute: Int, basis: Basis) {
        // Tier 1: the user told us when they want to wake, and the need estimate is worth trusting.
        if let wake = settings.targetWakeMinute,
           let need = sleepNeedSeconds, need > 0, needConfidence >= minConfidence {
            let bedMinute = wake - Int((need / 60).rounded())
            return (wrap(bedMinute - settings.leadMinutes), .derivedFromNeed)
        }
        // Tier 2: their own recent bedtimes beat our guess about their bedtimes.
        if let habitual = habitualBedMinute {
            return (wrap(habitual - settings.leadMinutes), .habitualBedtime)
        }
        // Tier 3: exactly what the app did before this existed.
        return (wrap(fallbackHour * 60), .fixedHour)
    }

    /// Why the wind-down is silent, or `nil` when one is actually scheduled.
    public static func suppressionReason(at instant: Date,
                                         settings: BedtimeReminderSettings,
                                         sleepNeedSeconds: Double?,
                                         needConfidence: Double,
                                         habitualBedMinute: Int?,
                                         quietHours: NotificationQuietHours,
                                         fallbackHour: Int,
                                         enabled: Bool,
                                         minConfidence: Double = defaultMinConfidence) -> Suppression? {
        guard enabled else { return .notEnabled }
        if let paused = settings.pausedUntil, paused > instant { return .paused }
        let minute = fireMinuteOfDay(settings: settings, sleepNeedSeconds: sleepNeedSeconds,
                                     needConfidence: needConfidence,
                                     habitualBedMinute: habitualBedMinute,
                                     fallbackHour: fallbackHour, minConfidence: minConfidence).minute
        // Only a quiet window the clamp cannot clear is a real suppression.
        if resolveAgainstQuietHours(minute, quietHours: quietHours) == nil { return .quietHours }
        return nil
    }

    /// How far earlier the wind-down may be pulled to clear a quiet-hours window before it is
    /// abandoned instead. Ninety minutes still reads as "a lead-in to bed"; earlier than that and
    /// the nudge no longer means what it says.
    public static let defaultQuietHoursClamp = 90

    /// Reconcile a wind-down minute with quiet hours, or `nil` if it cannot be.
    ///
    /// The obvious implementation — suppress anything inside the window — is wrong here, and wrong
    /// in a way that only shows up once the time is DERIVED. The default window is 22:00→07:00 and
    /// the default fixed hour is 21:00, so the current wind-down clears it comfortably; that is what
    /// `testDefaultFireHoursFallOutsideTheDefaultQuietWindow` was written to protect. But a user
    /// whose real bedtime is 23:00 derives a 22:30 wind-down, which lands inside that same window —
    /// and plain suppression would ship them a toggle that is on, correct, and permanently silent.
    ///
    /// A wind-down is by definition the lead-in to bed, so the honest fix is to nudge EARLIER, to
    /// the last minute before quiet hours begin, rather than not at all. Bounded by
    /// `defaultQuietHoursClamp`: past that the reminder would be so far from bedtime that firing it
    /// would be worse than silence, and silence is then the honest answer.
    static func resolveAgainstQuietHours(_ minute: Int, quietHours: NotificationQuietHours,
                                         clampLimit: Int = defaultQuietHoursClamp) -> Int? {
        guard isQuiet(minute: minute, quietHours: quietHours) else { return minute }
        let candidate = wrap(quietHours.startHour * 60 - 1)
        guard !isQuiet(minute: candidate, quietHours: quietHours) else { return nil }
        // How far back the clamp actually moves it, measured the short way round the clock.
        let day = 24 * 60
        let shift = ((minute - candidate) % day + day) % day
        return shift <= clampLimit ? candidate : nil
    }

    // MARK: - Helpers

    /// Fold a minute-of-day into 0..<1440. Subtracting a sleep need from a morning wake time
    /// routinely goes negative (07:00 minus 8h is the previous evening), which is the normal case
    /// here, not an edge case.
    static func wrap(_ minute: Int) -> Int {
        let day = 24 * 60
        return ((minute % day) + day) % day
    }

    /// Minute-resolution quiet hours, deliberately NOT `NotificationQuietHours.contains`, which
    /// compares whole hours. Same reason `HydrationReminderPolicy.isQuiet` reimplements it: a
    /// derived bedtime lands on arbitrary minutes, and rounding 22:45 down to hour 22 would silence
    /// a reminder that is legitimately outside a window ending at 22:30.
    static func isQuiet(minute: Int, quietHours: NotificationQuietHours) -> Bool {
        let start = quietHours.startHour * 60
        let end = quietHours.endHour * 60
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }
}
