import XCTest
@testable import BADAN

/// The adaptive wind-down. Most of this suite is about DEGRADING: sleep need is nil until a personal
/// baseline exists, so a fresh install has nothing to derive a bedtime from, and the wrong answer
/// there is a confident-looking number the app invented.
final class BedtimeReminderPolicyTests: XCTestCase {

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = day; c.hour = hour; c.minute = minute
        return calendar().date(from: c)!
    }

    /// A window that leaves the fixed 21:00 and a derived 22:00 alone, so a test about tiers is not
    /// silently a test about quiet hours.
    private let lateNight = NotificationQuietHours(startHour: 23, endHour: 7)

    // MARK: - Tier 1: derived from need

    func testDerivesBedtimeFromTargetWakeMinusNeed() {
        // Wake 07:00, need 8h ⇒ bed 23:00, lead 30 ⇒ wind-down 22:30.
        let settings = BedtimeReminderSettings(targetWakeMinute: 7 * 60, leadMinutes: 30)
        let result = BedtimeReminderPolicy.fireMinuteOfDay(
            settings: settings, sleepNeedSeconds: 8 * 3600, needConfidence: 0.9,
            habitualBedMinute: nil, fallbackHour: 21)
        XCTAssertEqual(result.minute, 22 * 60 + 30)
        XCTAssertEqual(result.basis, .derivedFromNeed)
    }

    /// Subtracting a night's sleep from a morning wake time goes negative as a matter of course —
    /// that is the normal case here, not an edge case.
    func testTheDerivationWrapsBackwardsPastMidnight() {
        let settings = BedtimeReminderSettings(targetWakeMinute: 6 * 60, leadMinutes: 0)
        let result = BedtimeReminderPolicy.fireMinuteOfDay(
            settings: settings, sleepNeedSeconds: 9 * 3600, needConfidence: 0.9,
            habitualBedMinute: nil, fallbackHour: 21)
        XCTAssertEqual(result.minute, 21 * 60, "06:00 minus 9h is 21:00 the previous evening")
    }

    // MARK: - Tier 2 and 3: the cold start

    /// The mandatory case. `SleepNightScore.need` is nil until a personal baseline exists, so this
    /// is what every new install hits.
    func testWithNoNeedEstimateItFallsBackToTheHabitualBedtime() {
        let settings = BedtimeReminderSettings(targetWakeMinute: 7 * 60, leadMinutes: 30)
        let result = BedtimeReminderPolicy.fireMinuteOfDay(
            settings: settings, sleepNeedSeconds: nil, needConfidence: 0,
            habitualBedMinute: 23 * 60, fallbackHour: 21)
        XCTAssertEqual(result.minute, 22 * 60 + 30)
        XCTAssertEqual(result.basis, .habitualBedtime,
                       "their own recent bedtimes beat our guess about their bedtimes")
    }

    func testWithNothingOnRecordItKeepsTheFixedHour() {
        let result = BedtimeReminderPolicy.fireMinuteOfDay(
            settings: .legacyDefault, sleepNeedSeconds: nil, needConfidence: 0,
            habitualBedMinute: nil, fallbackHour: 21)
        XCTAssertEqual(result.minute, 21 * 60)
        XCTAssertEqual(result.basis, .fixedHour,
                       "an existing user's 21:00 must not move under them on upgrade")
    }

    /// `legacyDefault` carries no target wake time, so even a user WITH a need estimate keeps the
    /// fixed hour until they choose a wake time. Adding the setting cannot silently re-time anyone.
    func testTheLegacyDefaultKeepsTheFixedHourEvenWithAConfidentNeed() {
        let result = BedtimeReminderPolicy.fireMinuteOfDay(
            settings: .legacyDefault, sleepNeedSeconds: 8 * 3600, needConfidence: 1.0,
            habitualBedMinute: nil, fallbackHour: 21)
        XCTAssertEqual(result.basis, .fixedHour)
    }

    /// A wide band is not an estimate. `SleepNeedRange` carries `confidence` precisely so a shaky
    /// number is not presented as a derived one.
    func testALowConfidenceNeedIsTreatedAsNoNeed() {
        let settings = BedtimeReminderSettings(targetWakeMinute: 7 * 60, leadMinutes: 30)
        let result = BedtimeReminderPolicy.fireMinuteOfDay(
            settings: settings, sleepNeedSeconds: 8 * 3600,
            needConfidence: BedtimeReminderPolicy.defaultMinConfidence - 0.01,
            habitualBedMinute: 23 * 60, fallbackHour: 21)
        XCTAssertEqual(result.basis, .habitualBedtime)
    }

    // MARK: - Quiet hours

    /// The bug that only appears once the time is derived: the default window is 22:00→07:00 and a
    /// real 23:00 bedtime derives a 22:30 wind-down, landing inside it. Plain suppression would ship
    /// a toggle that is on, correct, and permanently silent.
    func testAWindDownInsideQuietHoursIsPulledEarlierRatherThanDropped() {
        let settings = BedtimeReminderSettings(targetWakeMinute: 7 * 60, leadMinutes: 30)
        let fire = BedtimeReminderPolicy.nextFireDate(
            after: date(20, 12), settings: settings, sleepNeedSeconds: 8 * 3600,
            needConfidence: 0.9, habitualBedMinute: nil,
            quietHours: .defaultNight, fallbackHour: 21, enabled: true, calendar: calendar())
        XCTAssertNotNil(fire, "a wind-down inside quiet hours must be moved, not silenced")
        XCTAssertEqual(calendar().component(.hour, from: fire!), 21)
        XCTAssertEqual(calendar().component(.minute, from: fire!), 59)
    }

    /// Bounded, though: past the clamp the reminder would be so far from bedtime that firing it is
    /// worse than silence.
    func testAWindDownFarInsideQuietHoursIsAbandoned() {
        // Bed 03:00, lead 0 ⇒ 03:00, deep inside a 22:00→07:00 window and hours from its start.
        XCTAssertNil(BedtimeReminderPolicy.resolveAgainstQuietHours(3 * 60, quietHours: .defaultNight))
    }

    func testATimeOutsideQuietHoursIsUntouched() {
        XCTAssertEqual(BedtimeReminderPolicy.resolveAgainstQuietHours(21 * 60, quietHours: .defaultNight),
                       21 * 60)
    }

    // MARK: - Pause and opt-out

    func testPausedUntilPushesTheNextFireOut() {
        let settings = BedtimeReminderSettings(targetWakeMinute: 7 * 60, leadMinutes: 30,
                                               pausedUntil: date(22, 12))
        let fire = BedtimeReminderPolicy.nextFireDate(
            after: date(20, 12), settings: settings, sleepNeedSeconds: nil, needConfidence: 0,
            habitualBedMinute: nil, quietHours: lateNight, fallbackHour: 21, enabled: true,
            calendar: calendar())
        XCTAssertNotNil(fire)
        XCTAssertGreaterThan(fire!, date(22, 12))
    }

    func testDisabledPlansNothing() {
        XCTAssertNil(BedtimeReminderPolicy.nextFireDate(
            after: date(20, 12), settings: .legacyDefault, sleepNeedSeconds: nil, needConfidence: 0,
            habitualBedMinute: nil, quietHours: lateNight, fallbackHour: 21, enabled: false,
            calendar: calendar()))
        XCTAssertEqual(BedtimeReminderPolicy.suppressionReason(
            at: date(20, 12), settings: .legacyDefault, sleepNeedSeconds: nil, needConfidence: 0,
            habitualBedMinute: nil, quietHours: lateNight, fallbackHour: 21, enabled: false),
            .notEnabled)
    }

    // MARK: - Settings clamping

    func testSettingsClampLeadAndWrapWakeMinute() {
        XCTAssertEqual(BedtimeReminderSettings(leadMinutes: -30).leadMinutes, 0)
        XCTAssertEqual(BedtimeReminderSettings(leadMinutes: 9_999).leadMinutes,
                       BedtimeReminderSettings.leadMinutesRange.upperBound)
        XCTAssertEqual(BedtimeReminderSettings(targetWakeMinute: 25 * 60).targetWakeMinute, 60)
        XCTAssertNil(BedtimeReminderSettings().targetWakeMinute)
    }

    func testSettingsDecodeTolerantlyOnAProfileThatPredatesThem() throws {
        let legacy = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(BedtimeReminderSettings.self, from: legacy)
        XCTAssertNil(decoded.targetWakeMinute, "no wake time ⇒ the fixed hour ⇒ nothing moves")
        XCTAssertEqual(decoded.leadMinutes, 30)
    }
}
