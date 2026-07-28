import Foundation

// HYD-004 (notifications) + HYD-012 (fasting/Ramadan profile), per §7 and §13 of
// `docs/BADAN_HYDRATION_WATER_RESEARCH.md`.
//
// What existed before this file: hydration reminders were a single hardcoded 15:00 local fire
// (`AppEnvironment.defaultNotificationHour`), opt-in but otherwise unconfigurable. That is a real
// problem for this app's primary audience rather than a missing nicety — 15:00 falls inside the
// fast on essentially every day of Ramadan, so the one hydration reminder BADAN shipped was
// scheduled to arrive at a moment when acting on it is precisely what the user is not doing. The
// research document names "notifications during an enabled fasting window" in its anti-goals list
// (§17) and asks for "total reminder suppression during the fast" (§13).
//
// Deliberately NOT built here (§7's own phasing puts them later, and each needs data this doesn't
// have): interval reminders keyed to time-since-last-log, post-workout prompts, meal-linked
// prompts, and the opt-in adaptive experiment. This is the fixed-schedule tier (§7's only P0 row)
// plus the suppression rules every other tier would also have to honour.

/// A window during which no hydration reminder may fire, expressed in local minutes-from-midnight.
///
/// Minutes-from-midnight rather than absolute dates because a fast repeats daily at wall-clock
/// times, and because it has to survive a timezone change without rewriting stored rows — the same
/// wall-clock-preserving posture `NotificationQuietHours` already takes for night hours.
public struct HydrationFastingWindow: Codable, Hashable, Sendable {
    /// Inclusive start, minutes from local midnight (0..<1440).
    public var startMinute: Int
    /// Exclusive end, minutes from local midnight (0..<1440). May be LESS than `startMinute`, which
    /// means the window wraps past midnight — an overnight fast is a normal thing to enter, not an
    /// error to reject.
    public var endMinute: Int
    /// Calendar weekdays (1 = Sunday, matching `Calendar.component(.weekday:)`) this window applies
    /// to. Empty means every day, which is what a Ramadan-style daily fast wants.
    public var weekdays: Set<Int>

    public init(startMinute: Int, endMinute: Int, weekdays: Set<Int> = []) {
        self.startMinute = max(0, min(1439, startMinute))
        self.endMinute = max(0, min(1439, endMinute))
        self.weekdays = weekdays
    }

    /// Whether `minute` on `weekday` falls inside this window.
    public func contains(minute: Int, weekday: Int) -> Bool {
        guard weekdays.isEmpty || weekdays.contains(weekday) else { return false }
        if startMinute == endMinute { return false }  // a zero-width window suppresses nothing
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        // Wraps past midnight: inside means "after the start tonight, or before the end this morning".
        return minute >= startMinute || minute < endMinute
    }
}

/// The user's fasting windows. Generic by construction (§13: "never infer faith or hard-code
/// authority") — this type knows nothing about why someone fasts, only when.
public struct HydrationFastingProfile: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var windows: [HydrationFastingWindow]

    public init(enabled: Bool = false, windows: [HydrationFastingWindow] = []) {
        self.enabled = enabled
        self.windows = windows
    }

    public static let off = HydrationFastingProfile()

    public func isFasting(minute: Int, weekday: Int) -> Bool {
        guard enabled else { return false }
        return windows.contains { $0.contains(minute: minute, weekday: weekday) }
    }

    /// A starting point for a dawn-to-sunset daily fast, which the user then edits to their own
    /// times.
    ///
    /// This is a TEMPLATE, in the specific sense §13 requires: nothing computes it, nothing detects
    /// that it should be offered, and nothing turns it on. It is what a settings screen pre-fills
    /// when a person taps "use a daily fasting window", so they adjust two times instead of
    /// entering them from scratch. The default hours are deliberately unremarkable placeholders,
    /// not a claim about when any particular fast begins or ends — real dawn/sunset move daily and
    /// by location, and computing them here would be exactly the inference this type refuses to
    /// make.
    public static func dailyWindowTemplate(startMinute: Int = 4 * 60 + 30,
                                           endMinute: Int = 18 * 60 + 30) -> HydrationFastingProfile {
        HydrationFastingProfile(enabled: true,
                                windows: [HydrationFastingWindow(startMinute: startMinute, endMinute: endMinute)])
    }
}

/// User-configurable hydration reminder schedule.
public struct HydrationReminderSettings: Codable, Hashable, Sendable {
    /// Local minutes-from-midnight the user chose. Empty means no fixed reminders at all, which is
    /// a legitimate configured state and the default — §7's "no reminders until explicit user
    /// opt-in", and this module's wider rule that no-goal and no-reminder are first-class states.
    public var times: [Int]
    /// At most this many hydration reminders per local day (§7: "initial maximum one notification
    /// per day"). Independent of, and stricter than, the app-wide daily notification budget.
    public var dailyCap: Int
    /// Set by "Pause today"; nothing fires at or before this instant.
    public var pausedUntil: Date?
    /// Set by "Not now" — §7's 2–4 hour cooldown.
    public var cooldownUntil: Date?
    public var fasting: HydrationFastingProfile

    public init(times: [Int] = [], dailyCap: Int = 1, pausedUntil: Date? = nil,
                cooldownUntil: Date? = nil, fasting: HydrationFastingProfile = .off) {
        self.times = times
        self.dailyCap = max(0, dailyCap)
        self.pausedUntil = pausedUntil
        self.cooldownUntil = cooldownUntil
        self.fasting = fasting
    }

    /// The pre-2026-07-27 behaviour, kept as a named constant so the migration path is legible: one
    /// reminder at 15:00, no fasting profile. `CustomizationProfile` decodes this for any install
    /// that predates the settings existing, so nobody's existing single daily reminder disappears
    /// in an update — it just becomes editable, and now honours a fasting window if they set one.
    public static let legacyDefault = HydrationReminderSettings(times: [15 * 60], dailyCap: 1)

    /// §7's cooldown length. The research gives a 2–4 hour range; 3 sits in the middle of it.
    public static let cooldownDuration: TimeInterval = 3 * 3600
}

/// Plans hydration reminder fire times from settings. Pure: no clock, no storage, no scheduler —
/// every input is passed in, which is what makes the suppression rules testable at the minute level
/// instead of only observable through `UNUserNotificationCenter`.
public enum HydrationReminderPolicy {
    /// Why a candidate time was dropped. Returned rather than logged so a settings screen can
    /// explain silence ("no reminders during your fasting window") instead of leaving the user
    /// wondering whether the feature is broken — the difference between calm and mysterious.
    public enum Suppression: String, Hashable, Sendable {
        case notEnabled
        case paused
        case cooldown
        case fasting
        case quietHours
        case dailyCap
    }

    /// The next moment a hydration reminder may fire after `now`, or `nil` if none may within
    /// `withinDays`. `nil` is a real answer — a user who fasts most of the day and sleeps through
    /// the rest should get silence, not a reminder squeezed into the one legal minute.
    public static func nextFireDate(after now: Date, settings: HydrationReminderSettings,
                                    quietHours: NotificationQuietHours, enabled: Bool,
                                    calendar: Calendar = .current, withinDays: Int = 14) -> Date? {
        plan(after: now, settings: settings, quietHours: quietHours, enabled: enabled,
             calendar: calendar, withinDays: withinDays).first
    }

    /// Every permitted fire time in the next `withinDays`, ascending. §7 asks the engine to plan
    /// 7–14 days ahead; the caller decides how many of those it actually hands to the OS (iOS caps
    /// pending requests at 64 across all classes, so scheduling the whole plan is not automatically
    /// the right move).
    public static func plan(after now: Date, settings: HydrationReminderSettings,
                            quietHours: NotificationQuietHours, enabled: Bool,
                            calendar: Calendar = .current, withinDays: Int = 14) -> [Date] {
        guard enabled, !settings.times.isEmpty, settings.dailyCap > 0 else { return [] }

        // The two "not right now" gates are absolute floors: nothing before them is eligible,
        // whatever the schedule says.
        var floor = now
        if let paused = settings.pausedUntil, paused > floor { floor = paused }
        if let cooldown = settings.cooldownUntil, cooldown > floor { floor = cooldown }

        var results: [Date] = []
        let sortedTimes = settings.times.sorted()
        for dayOffset in 0...max(0, withinDays) {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))
            else { continue }
            let weekday = calendar.component(.weekday, from: day)
            var firedThisDay = 0

            for minute in sortedTimes {
                guard firedThisDay < settings.dailyCap else { break }
                guard let fire = calendar.date(byAdding: .minute, value: minute, to: day), fire > floor
                else { continue }
                guard !settings.fasting.isFasting(minute: minute, weekday: weekday) else { continue }
                guard !isQuiet(minute: minute, quietHours: quietHours) else { continue }
                results.append(fire)
                firedThisDay += 1
            }
        }
        return results
    }

    /// Why the next reminder is being withheld, when it is. Returns `nil` when one is actually
    /// scheduled. Only ever explains the reason for a time the user CHOSE — it never invents a
    /// reason for a schedule that is simply empty.
    public static func suppressionReason(at instant: Date, settings: HydrationReminderSettings,
                                         quietHours: NotificationQuietHours, enabled: Bool,
                                         calendar: Calendar = .current) -> Suppression? {
        guard enabled else { return .notEnabled }
        guard settings.dailyCap > 0 else { return .dailyCap }
        if let paused = settings.pausedUntil, paused > instant { return .paused }
        if let cooldown = settings.cooldownUntil, cooldown > instant { return .cooldown }

        let minute = minuteOfDay(instant, calendar: calendar)
        let weekday = calendar.component(.weekday, from: instant)
        if settings.fasting.isFasting(minute: minute, weekday: weekday) { return .fasting }
        if isQuiet(minute: minute, quietHours: quietHours) { return .quietHours }
        return nil
    }

    // MARK: - Helpers

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Quiet hours are stored as whole hours (`NotificationQuietHours`), and wrap past midnight in
    /// the normal case (22:00 → 07:00). Evaluated here at minute resolution so a 07:30 reminder
    /// against a 07:00 end is allowed rather than rounded into silence.
    static func isQuiet(minute: Int, quietHours: NotificationQuietHours) -> Bool {
        let start = quietHours.startHour * 60
        let end = quietHours.endHour * 60
        if start == end { return false }
        if start < end { return minute >= start && minute < end }
        return minute >= start || minute < end
    }
}
