import XCTest
@testable import BADAN

/// HYD-004 / HYD-012. The rule that matters most here is the one the research document lists among
/// its explicit anti-goals: **no hydration reminder may fire inside an enabled fasting window**.
/// Everything else in this file exists so that rule cannot be satisfied by accident — a policy that
/// suppressed everything would also pass a fasting test.
final class HydrationReminderPolicyTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Muscat")!
        return c
    }()

    /// 2026-07-27 00:00 Asia/Muscat, a Monday — every `at(hour:minute:)` below is relative to it.
    private var midnight: Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 0, minute: 0))!
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: .minute, value: hour * 60 + minute, to: midnight)!
    }

    private func minuteOfDay(_ date: Date) -> Int {
        HydrationReminderPolicy.minuteOfDay(date, calendar: calendar)
    }

    /// Wide-open quiet hours (start == end) so a test that isn't about quiet hours isn't silently
    /// shaped by them.
    private let noQuietHours = NotificationQuietHours(startHour: 0, endHour: 0)

    // MARK: - The anti-goal

    /// A 15:00 reminder — precisely the hardcoded time BADAN shipped before this policy existed —
    /// must not fire during a dawn-to-sunset fast.
    func testNoReminderFiresInsideAnEnabledFastingWindow() {
        let settings = HydrationReminderSettings(
            times: [15 * 60], dailyCap: 1,
            fasting: .dailyWindowTemplate(startMinute: 4 * 60 + 30, endMinute: 18 * 60 + 30))

        let plan = HydrationReminderPolicy.plan(after: at(0), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 7)

        XCTAssertTrue(plan.isEmpty, "15:00 is inside a 04:30–18:30 fast on every one of those days")
    }

    /// And the other half — silence must come from the fast, not from the policy suppressing
    /// everything. A time in the evening non-fasting window still fires.
    func testAReminderOutsideTheFastingWindowStillFires() {
        let settings = HydrationReminderSettings(
            times: [20 * 60], dailyCap: 1,
            fasting: .dailyWindowTemplate(startMinute: 4 * 60 + 30, endMinute: 18 * 60 + 30))

        let plan = HydrationReminderPolicy.plan(after: at(0), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 1)

        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(minuteOfDay(plan[0]), 20 * 60)
    }

    /// A user with reminders both inside and outside the fast keeps only the ones outside — the
    /// schedule is filtered, not abandoned.
    func testOnlyTheFastingWindowTimesAreDropped() {
        let settings = HydrationReminderSettings(
            times: [8 * 60, 15 * 60, 20 * 60], dailyCap: 3,
            fasting: .dailyWindowTemplate(startMinute: 4 * 60 + 30, endMinute: 18 * 60 + 30))

        let plan = HydrationReminderPolicy.plan(after: at(0), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 0)

        XCTAssertEqual(plan.map(minuteOfDay), [20 * 60], "08:00 and 15:00 are inside the fast")
    }

    /// The settings screen has to be able to say WHY it is silent, or the feature reads as broken.
    func testSuppressionReasonNamesTheFast() {
        let settings = HydrationReminderSettings(
            times: [15 * 60], fasting: .dailyWindowTemplate(startMinute: 4 * 60 + 30, endMinute: 18 * 60 + 30))

        XCTAssertEqual(HydrationReminderPolicy.suppressionReason(
            at: at(15), settings: settings, quietHours: noQuietHours, enabled: true, calendar: calendar),
                       .fasting)
        XCTAssertNil(HydrationReminderPolicy.suppressionReason(
            at: at(20), settings: settings, quietHours: noQuietHours, enabled: true, calendar: calendar),
                     "outside the fast there is nothing to explain away")
    }

    // MARK: - Window arithmetic

    /// An overnight fast is a normal thing to enter, and the naive `start <= x < end` comparison
    /// gets it exactly backwards.
    func testAWindowThatWrapsPastMidnightIsHandled() {
        let window = HydrationFastingWindow(startMinute: 22 * 60, endMinute: 6 * 60)

        XCTAssertTrue(window.contains(minute: 23 * 60, weekday: 2), "23:00 is after the 22:00 start")
        XCTAssertTrue(window.contains(minute: 2 * 60, weekday: 2), "02:00 is before the 06:00 end")
        XCTAssertFalse(window.contains(minute: 12 * 60, weekday: 2), "midday is outside an overnight fast")
    }

    func testAZeroWidthWindowSuppressesNothing() {
        let window = HydrationFastingWindow(startMinute: 9 * 60, endMinute: 9 * 60)
        XCTAssertFalse(window.contains(minute: 9 * 60, weekday: 2))
    }

    /// Weekday scoping: a Monday-only fast leaves Tuesday alone.
    func testAWeekdayScopedWindowOnlyAppliesOnThoseDays() {
        // 2026-07-27 is a Monday; Calendar weekday 2 = Monday, 3 = Tuesday.
        let window = HydrationFastingWindow(startMinute: 8 * 60, endMinute: 18 * 60, weekdays: [2])

        XCTAssertTrue(window.contains(minute: 12 * 60, weekday: 2))
        XCTAssertFalse(window.contains(minute: 12 * 60, weekday: 3))
    }

    /// The template is a pre-filled starting point, never something derived — it must not claim to
    /// know real dawn or sunset for anywhere.
    func testTheDailyTemplateIsEditableAndNotInferred() {
        let custom = HydrationFastingProfile.dailyWindowTemplate(startMinute: 3 * 60 + 50,
                                                                 endMinute: 19 * 60 + 5)
        XCTAssertEqual(custom.windows.first?.startMinute, 3 * 60 + 50)
        XCTAssertEqual(custom.windows.first?.endMinute, 19 * 60 + 5)
        XCTAssertTrue(custom.windows.first?.weekdays.isEmpty ?? false, "daily by default")
        XCTAssertFalse(HydrationFastingProfile.off.enabled, "nothing is fasting until the user says so")
    }

    /// A disabled profile suppresses nothing even if windows are still stored — turning the feature
    /// off must not require deleting what you entered.
    func testADisabledProfileSuppressesNothingButKeepsItsWindows() {
        var profile = HydrationFastingProfile.dailyWindowTemplate()
        profile.enabled = false

        XCTAssertFalse(profile.isFasting(minute: 12 * 60, weekday: 2))
        XCTAssertEqual(profile.windows.count, 1, "the window the user entered is still there")
    }

    // MARK: - The other suppression rules

    func testQuietHoursSuppressAtMinuteResolution() {
        let quiet = NotificationQuietHours(startHour: 22, endHour: 7)
        let settings = HydrationReminderSettings(times: [6 * 60 + 30, 7 * 60 + 30], dailyCap: 2)

        let plan = HydrationReminderPolicy.plan(after: at(0), settings: settings, quietHours: quiet,
                                                enabled: true, calendar: calendar, withinDays: 0)

        XCTAssertEqual(plan.map(minuteOfDay), [7 * 60 + 30],
                       "06:30 is inside the night window; 07:30 is past its 07:00 end")
    }

    func testTheDailyCapLimitsHowManyFirePerDay() {
        let settings = HydrationReminderSettings(times: [9 * 60, 13 * 60, 17 * 60], dailyCap: 2)

        let plan = HydrationReminderPolicy.plan(after: at(0), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 0)

        XCTAssertEqual(plan.map(minuteOfDay), [9 * 60, 13 * 60], "the cap takes the earliest, not a random two")
    }

    func testPauseTodaySuppressesUntilItExpires() {
        let settings = HydrationReminderSettings(times: [9 * 60, 21 * 60], dailyCap: 2,
                                                 pausedUntil: at(18))

        let plan = HydrationReminderPolicy.plan(after: at(8), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 0)

        XCTAssertEqual(plan.map(minuteOfDay), [21 * 60])
    }

    func testNotNowStartsACooldown() {
        let settings = HydrationReminderSettings(
            times: [9 * 60, 11 * 60, 15 * 60], dailyCap: 3,
            cooldownUntil: at(9).addingTimeInterval(HydrationReminderSettings.cooldownDuration))

        let plan = HydrationReminderPolicy.plan(after: at(9), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 0)

        XCTAssertEqual(plan.map(minuteOfDay), [15 * 60], "11:00 is inside the three-hour cooldown")
    }

    // MARK: - Defaults and opt-in

    /// No reminders until explicitly opted in (§7), and the empty schedule is a real configured
    /// state rather than "unset".
    func testNothingIsPlannedWhenTheClassIsOffOrNoTimesAreChosen() {
        let configured = HydrationReminderSettings(times: [9 * 60])

        XCTAssertTrue(HydrationReminderPolicy.plan(after: at(0), settings: configured,
                                                   quietHours: noQuietHours, enabled: false,
                                                   calendar: calendar).isEmpty,
                      "class opted out")
        XCTAssertTrue(HydrationReminderPolicy.plan(after: at(0), settings: HydrationReminderSettings(),
                                                   quietHours: noQuietHours, enabled: true,
                                                   calendar: calendar).isEmpty,
                      "no times chosen")
    }

    /// Existing installs had exactly one 15:00 reminder. The default must reproduce that rather
    /// than silently turning a user's reminder off in an update.
    func testTheLegacyDefaultReproducesTheOldSingleThreePmReminder() {
        XCTAssertEqual(HydrationReminderSettings.legacyDefault.times, [15 * 60])
        XCTAssertEqual(HydrationReminderSettings.legacyDefault.dailyCap, 1)
        XCTAssertFalse(HydrationReminderSettings.legacyDefault.fasting.enabled)
    }

    func testPlanIsAscendingAndSpansMultipleDays() {
        let settings = HydrationReminderSettings(times: [9 * 60, 20 * 60], dailyCap: 2)

        let plan = HydrationReminderPolicy.plan(after: at(0), settings: settings,
                                                quietHours: noQuietHours, enabled: true,
                                                calendar: calendar, withinDays: 3)

        XCTAssertEqual(plan.count, 8, "two per day across four days")
        XCTAssertEqual(plan, plan.sorted(), "ascending")
    }

    // MARK: - The wiring

    /// The policy being correct is worth nothing if the scheduler never consults it. This exercises
    /// the actual seam `reconcileDecisionNotifications` calls, which is the difference between a
    /// well-tested engine and a shipped feature.
    func testTheSchedulerAsksThePolicyForHydrationAndTheFixedHourForEveryOtherClass() {
        var profile = CustomizationProfile()
        profile.hydrationReminders = HydrationReminderSettings(
            times: [15 * 60], dailyCap: 1,
            fasting: .dailyWindowTemplate(startMinute: 4 * 60 + 30, endMinute: 18 * 60 + 30))
        profile.notifications.quietHours = noQuietHours

        XCTAssertNil(AppEnvironment.nextFireDate(for: .hydration, after: at(0), profile: profile,
                                                 calendar: calendar),
                     "a fasted-through schedule must produce no fire date at all, so the class is cancelled")

        let readiness = AppEnvironment.nextFireDate(for: .morningReadinessSummary, after: at(0),
                                                    profile: profile, calendar: calendar)
        XCTAssertEqual(readiness.map(minuteOfDay), 8 * 60,
                       "every other class keeps its fixed daily hour, unaffected by hydration settings")
    }

    /// And the same seam yields a real time once the schedule moves outside the fast.
    func testTheSchedulerGetsARealHydrationTimeOutsideTheFast() {
        var profile = CustomizationProfile()
        profile.hydrationReminders = HydrationReminderSettings(
            times: [20 * 60], dailyCap: 1,
            fasting: .dailyWindowTemplate(startMinute: 4 * 60 + 30, endMinute: 18 * 60 + 30))
        profile.notifications.quietHours = noQuietHours

        let fire = AppEnvironment.nextFireDate(for: .hydration, after: at(0), profile: profile,
                                               calendar: calendar)

        XCTAssertEqual(fire.map(minuteOfDay), 20 * 60)
    }

    /// An install that predates the setting keeps the reminder time it already had.
    func testAProfileWithNoStoredScheduleDecodesToTheOldBehaviour() throws {
        // A profile JSON written before `hydrationReminders` existed: encode a current profile,
        // strip the key, and decode it back — the same shape `ProfileRepository.load()` faces.
        let encoded = try JSONEncoder().encode(CustomizationProfile())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "hydrationReminders")
        let stripped = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(CustomizationProfile.self, from: stripped)

        XCTAssertEqual(decoded.hydrationReminders.times, [15 * 60],
                       "an update must not silently remove a reminder the user already had")
        XCTAssertFalse(decoded.hydrationReminders.fasting.enabled)
    }

    func testNextFireDateSkipsATimeAlreadyPassedToday() {
        let settings = HydrationReminderSettings(times: [9 * 60, 20 * 60], dailyCap: 2)

        let next = HydrationReminderPolicy.nextFireDate(after: at(12), settings: settings,
                                                        quietHours: noQuietHours, enabled: true,
                                                        calendar: calendar)

        XCTAssertEqual(next.map(minuteOfDay), 20 * 60)
    }
}
