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
}
