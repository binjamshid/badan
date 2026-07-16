import XCTest
@testable import BADAN

/// Tests for the pure medication-reminder plan builder (NEW-02/UX-02). Deliberately never
/// touches `UNUserNotificationCenter` — only `MedicationReminderPlan.build(...)`, which is the
/// side-effect-free core the scheduler adapts into real notification requests.
final class NotificationSchedulerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func regimen(id: String, schedule: MedicationSchedule,
                         endedAt: Date? = nil, deletedAt: Date? = nil) -> MedicationRegimen {
        MedicationRegimen(id: id, name: "R-\(id)", schedule: schedule, startedAt: now,
                          endedAt: endedAt, updatedAt: now, originDeviceId: "dev", deletedAt: deletedAt)
    }

    // MARK: Master preference

    func testDisabledPreferenceProducesEmptyPlan() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["09:00"]))]
        XCTAssertTrue(MedicationReminderPlan.build(regimens: regimens, enabled: false, language: .en).isEmpty)
    }

    func testNoRegimensProducesEmptyPlan() {
        XCTAssertTrue(MedicationReminderPlan.build(regimens: [], enabled: true, language: .en).isEmpty)
    }

    // MARK: Daily

    func testDailyMultipleTimesProducesOneItemPerTime() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["08:00", "20:30"]))]
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.map(\.identifier), ["med-reminder.a.0800", "med-reminder.a.2030"])
        // Daily reminders repeat every day, so no weekday is pinned.
        XCTAssertTrue(plan.allSatisfy { $0.weekday == nil })
        XCTAssertEqual(plan[0].hour, 8); XCTAssertEqual(plan[0].minute, 0)
        XCTAssertEqual(plan[1].hour, 20); XCTAssertEqual(plan[1].minute, 30)
    }

    // MARK: Weekly

    func testWeeklyExpandsPerDayAndTimeWithCalendarWeekday() {
        // ISO 1 = Mon, 7 = Sun -> Calendar weekday 2 = Mon, 1 = Sun.
        let regimens = [regimen(id: "w", schedule: .weekly(days: [1, 7], times: ["09:00"]))]
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)

        XCTAssertEqual(plan.count, 2)
        let byWeekday = Dictionary(uniqueKeysWithValues: plan.map { ($0.weekday, $0) })
        XCTAssertNotNil(byWeekday[2])  // Monday
        XCTAssertNotNil(byWeekday[1])  // Sunday
        XCTAssertTrue(plan.allSatisfy { $0.hour == 9 && $0.minute == 0 })
        XCTAssertEqual(Set(plan.map(\.identifier)),
                       ["med-reminder.w.w2.0900", "med-reminder.w.w1.0900"])
    }

    func testCalendarWeekdayConversionMapsAllISODays() {
        // Mon..Sun (ISO 1..7) -> Calendar 2,3,4,5,6,7,1
        XCTAssertEqual((1...7).map(MedicationReminderPlan.calendarWeekday(fromISO:)), [2, 3, 4, 5, 6, 7, 1])
    }

    // MARK: Exclusions

    func testAsNeededProducesNothing() {
        let regimens = [regimen(id: "a", schedule: .asNeeded)]
        XCTAssertTrue(MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en).isEmpty)
    }

    func testEndedRegimenExcluded() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["09:00"]), endedAt: now)]
        XCTAssertTrue(MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en).isEmpty)
    }

    func testSoftDeletedRegimenExcluded() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["09:00"]), deletedAt: now)]
        XCTAssertTrue(MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en).isEmpty)
    }

    // MARK: Identifier dedup

    func testDuplicateTimesDedupByIdentifier() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["09:00", "09:00"]))]
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].identifier, "med-reminder.a.0900")
    }

    func testIdentifiersAreUniqueAcrossRegimens() {
        let regimens = [
            regimen(id: "a", schedule: .daily(times: ["09:00", "21:00"])),
            regimen(id: "b", schedule: .weekly(days: [3], times: ["09:00"])),
        ]
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertEqual(plan.count, 3)
        XCTAssertEqual(Set(plan.map(\.identifier)).count, plan.count)
        // All carry the shared prefix so the scheduler can cancel them by prefix.
        XCTAssertTrue(plan.allSatisfy { $0.identifier.hasPrefix(MedicationReminderPlan.identifierPrefix) })
    }

    // MARK: Language threading

    func testBodyLanguageIsThreadedThrough() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["09:00"]))]
        let ar = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .ar)
        XCTAssertEqual(ar.first?.bodyLanguage, .ar)
        let en = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertEqual(en.first?.bodyLanguage, .en)
    }

    // MARK: Malformed times

    func testMalformedTimesAreSkipped() {
        let regimens = [regimen(id: "a", schedule: .daily(times: ["25:00", "09:61", "bad", "10:15"]))]
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertEqual(plan.map(\.identifier), ["med-reminder.a.1015"])
    }

    // MARK: Copy is privacy-safe

    func testReminderCopyContainsNoDynamicMedicationData() {
        // The static copy must never interpolate a name/dose. A weak guard against regressions:
        // it carries no placeholder tokens and is identical regardless of regimen input.
        for text in [MedicationReminderCopy.body.en, MedicationReminderCopy.body.ar,
                     MedicationReminderCopy.title.en, MedicationReminderCopy.title.ar] {
            XCTAssertFalse(text.contains("{"))
            XCTAssertFalse(text.contains("}"))
        }
    }

    // MARK: - F6: the 64-pending ceiling

    /// iOS keeps at most 64 pending requests and silently drops the rest — in insertion order,
    /// not by time — so a user with several regimens could stop being reminded about their
    /// evening medication with nothing anywhere saying so.
    private func manyRegimens(count: Int, timesPerDay: Int) -> [MedicationRegimen] {
        (0..<count).map { i in
            let times = (0..<timesPerDay).map { t in String(format: "%02d:00", (t * 2) % 24) }
            return regimen(id: "r\(i)", schedule: .daily(times: times))
        }
    }

    func testPlanUnderTheLimitIsNotTruncated() {
        let plan = MedicationReminderPlan.build(regimens: manyRegimens(count: 2, timesPerDay: 3),
                                                enabled: true, language: .en)
        let (kept, dropped) = MedicationReminderPlan.capped(plan, now: now, calendar: .current)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(kept.count, plan.count, "a plan within the ceiling must pass through untouched")
    }

    func testPlanOverTheLimitIsCappedToTheSystemLimit() {
        // 5 regimens x 3 times x 7 weekly slots is the audit's example; daily times are enough to
        // exceed 64 here.
        let regimens = (0..<10).map { i in
            regimen(id: "r\(i)", schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7], times: ["08:00", "20:00"]))
        }
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertGreaterThan(plan.count, MedicationReminderPlan.systemPendingLimit,
                             "sanity: this fixture must actually exceed the ceiling")

        let (kept, dropped) = MedicationReminderPlan.capped(plan, now: now, calendar: .current)

        XCTAssertEqual(kept.count, MedicationReminderPlan.systemPendingLimit,
                       "F6: never schedule more than the OS will hold")
        XCTAssertEqual(dropped, plan.count - MedicationReminderPlan.systemPendingLimit,
                       "F6: the caller must be told how many were dropped, so the user can be")
    }

    func testCapKeepsTheSoonestRemindersNotArbitraryOnes() {
        let calendar = Calendar.current
        let regimens = (0..<10).map { i in
            regimen(id: "r\(i)", schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7], times: ["08:00", "20:00"]))
        }
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        let (kept, _) = MedicationReminderPlan.capped(plan, now: now, calendar: calendar)

        let keptIds = Set(kept.map(\.identifier))
        let droppedItems = plan.filter { !keptIds.contains($0.identifier) }
        let latestKept = kept.compactMap {
            MedicationReminderPlan.nextFireDate(for: $0, after: now, calendar: calendar)
        }.max()
        let earliestDropped = droppedItems.compactMap {
            MedicationReminderPlan.nextFireDate(for: $0, after: now, calendar: calendar)
        }.min()

        if let latestKept, let earliestDropped {
            XCTAssertLessThanOrEqual(latestKept, earliestDropped,
                                     "F6: every kept reminder must fire no later than every "
                                         + "dropped one — the truncation is by time, not by luck")
        }
    }

    func testCappedPlanStaysSortedByIdentifier() {
        let regimens = (0..<10).map { i in
            regimen(id: "r\(i)", schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7], times: ["08:00", "20:00"]))
        }
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        let (kept, _) = MedicationReminderPlan.capped(plan, now: now, calendar: .current)
        XCTAssertEqual(kept.map(\.identifier), kept.map(\.identifier).sorted(),
                       "the capped plan must keep build()'s stable ordering contract")
    }
}
