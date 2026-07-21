import XCTest
@testable import BADAN

/// EPIC-32 acceptance suite for the pure decision core. Never touches `UNUserNotificationCenter` —
/// only `NotificationDecisionEngine`, the side-effect-free layer the scheduler adapts. Covers the
/// three acceptance items that live in the engine: the ≤2/day non-med budget (held under load), the
/// per-class opt-in matrix, and the 64-pending cap interplay with meds (meds never starved).
final class NotificationDecisionEngineTests: XCTestCase {

    // A fixed, UTC calendar so quiet-hours boundaries are deterministic regardless of the host tz.
    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 20; comps.hour = hour
        return calendar().date(from: comps)!
    }

    private func context(optedIn: Bool = true,
                         quiet: NotificationQuietHours? = nil,
                         nonMedToday: Int = 0,
                         pendingMed: Int = 0,
                         pendingNonMed: Int = 0) -> NotificationDecisionEngine.Context {
        NotificationDecisionEngine.Context(
            calendar: calendar(),
            optedIn: { _ in optedIn },
            quietHours: { _ in quiet },
            nonMedScheduledToday: nonMedToday,
            pendingMedCount: pendingMed,
            pendingNonMedCount: pendingNonMed)
    }

    private func candidate(_ cls: NotificationClass, hour: Int) -> NotificationDecisionEngine.Candidate {
        NotificationDecisionEngine.Candidate(cls, fireDate: date(hour: hour))
    }

    // MARK: - Registry (storage-code contract with migration v8 / Android)

    func testStorageCodesMatchMigrationAndAndroid() {
        XCTAssertEqual(NotificationClass.morningReadinessSummary.rawValue, "readiness")
        XCTAssertEqual(NotificationClass.eveningWindDown.rawValue, "windDown")
        XCTAssertEqual(NotificationClass.deviationNotice.rawValue, "deviation")
        XCTAssertEqual(NotificationClass.exportHealthAlert.rawValue, "exportHealth")
        XCTAssertEqual(NotificationClass.hydration.rawValue, "hydration")
        XCTAssertEqual(NotificationClass.meds.rawValue, "meds")
    }

    func testMedsIsTheOnlyBudgetExemptClass() {
        XCTAssertFalse(NotificationClass.meds.countsAgainstDailyBudget)
        for cls in NotificationClass.allCases where cls != .meds {
            XCTAssertTrue(cls.countsAgainstDailyBudget, "\(cls) must count against the ≤2/day budget")
        }
    }

    /// Every toggle the Notifications screen offers must correspond to a notification the app can
    /// actually send. A toggle whose copy says "a heads-up when a reading drifts from your usual" is
    /// a promise; offering it with no producer behind it is a lie the user cannot detect, because the
    /// failure mode is silence — indistinguishable from "nothing drifted."
    ///
    /// `deviationNotice` and `exportHealthAlert` are registered for the ledger vocabulary and their
    /// deep links, but nothing calls `raiseDecisionNotification`, so neither may be offered. The
    /// automation-pause notice does not count: it is unbudgeted, ungated by any of these toggles, and
    /// merely borrows `exportHealthAlert`'s deep link.
    ///
    /// Mirrors Android's `everyUserFacingClassHasAProducerBehindIt`. When a producer lands, this
    /// assertion moves in the same change that adds the toggle — deliberately, never silently.
    func testEveryUserFacingClassHasAProducerBehindIt() {
        XCTAssertEqual(NotificationClass.userFacing,
                       [.morningReadinessSummary, .eveningWindDown, .hydration],
                       "a class may be offered in Settings only once something schedules it")
        for cls in [NotificationClass.deviationNotice, .exportHealthAlert] {
            XCTAssertFalse(NotificationClass.userFacing.contains(cls),
                           "\(cls) has no producer — a toggle would promise a notice that never arrives")
        }
        XCTAssertFalse(NotificationClass.userFacing.contains(.meds),
                       "meds keep their own section and their own existing preference")
        XCTAssertTrue(NotificationClass.userFacing.allSatisfy(\.countsAgainstDailyBudget),
                      "every offered class must count against the ≤2/day budget")
    }

    func testMedsReuseTheExistingMedSchedulerPrefix() {
        // Meds must NOT get a `decision.` identifier — the existing med scheduler owns med ids.
        XCTAssertEqual(NotificationClass.meds.identifierPrefix, MedicationReminderPlan.identifierPrefix)
        for cls in NotificationClass.allCases where !cls.isMedication {
            XCTAssertTrue(cls.identifierPrefix.hasPrefix(NotificationClass.decisionPrefix))
            XCTAssertFalse(cls.identifierPrefix.hasPrefix(MedicationReminderPlan.identifierPrefix))
        }
    }

    // MARK: - Opt-in matrix (default OFF)

    func testOptedOutClassIsSuppressed() {
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.morningReadinessSummary, hour: 8),
                                                         in: context(optedIn: false)),
                       .suppressedOptedOut)
    }

    func testOptedInClassSchedules() {
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.morningReadinessSummary, hour: 8),
                                                         in: context(optedIn: true)),
                       .scheduled)
    }

    /// Every non-med class, toggled independently, is scheduled when on and suppressed when off —
    /// nothing leaks across classes.
    func testPerClassOptInMatrix() {
        for cls in NotificationClass.allCases where !cls.isMedication {
            XCTAssertEqual(NotificationDecisionEngine.decide(candidate(cls, hour: 12), in: context(optedIn: true)),
                           .scheduled, "\(cls) on must schedule")
            XCTAssertEqual(NotificationDecisionEngine.decide(candidate(cls, hour: 12), in: context(optedIn: false)),
                           .suppressedOptedOut, "\(cls) off must suppress")
        }
    }

    // MARK: - Daily budget (≤2/day, held under load)

    func testDailyBudgetHoldsUnderLoad() {
        // 100 candidates in one day, all opted in, no quiet hours: exactly the ceiling is scheduled.
        let candidates = (0..<100).map { _ in candidate(.hydration, hour: 12) }
        let results = NotificationDecisionEngine.decideBatch(candidates, in: context(optedIn: true))
        let scheduled = results.filter { $0.1 == .scheduled }.count
        XCTAssertEqual(scheduled, NotificationBudget.dailyNonMedLimit)
        XCTAssertTrue(results.dropFirst(NotificationBudget.dailyNonMedLimit).allSatisfy { $0.1 == .suppressedDailyBudget },
                      "every candidate past the ceiling must be budget-suppressed, not silently dropped")
    }

    func testBudgetSpansAllNonMedClassesCombined() {
        // The budget is a combined non-med ceiling, not per-class: morning + wind-down spends it,
        // and a third class (hydration) is then held.
        let batch = [candidate(.morningReadinessSummary, hour: 8),
                     candidate(.eveningWindDown, hour: 21),
                     candidate(.hydration, hour: 15)]
        let results = NotificationDecisionEngine.decideBatch(batch, in: context())
        XCTAssertEqual(results[0].1, .scheduled)
        XCTAssertEqual(results[1].1, .scheduled)
        XCTAssertEqual(results[2].1, .suppressedDailyBudget)
    }

    func testMedsAreExemptFromTheDailyBudget() {
        // Even with the non-med budget fully spent, a med candidate is never budget-suppressed.
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.meds, hour: 8),
                                                         in: context(nonMedToday: 99)),
                       .scheduled)
    }

    // MARK: - Quiet hours

    func testQuietHoursSuppressesInsideTheWindow() {
        let quiet = NotificationQuietHours(startHour: 22, endHour: 7)   // wraps midnight
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.hydration, hour: 2), in: context(quiet: quiet)),
                       .suppressedQuietHours)
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.hydration, hour: 12), in: context(quiet: quiet)),
                       .scheduled)
    }

    func testQuietHoursBoundariesAndEmptyWindow() {
        let q = NotificationQuietHours(startHour: 22, endHour: 7)
        XCTAssertTrue(q.contains(date(hour: 22), calendar: calendar()), "start is inclusive")
        XCTAssertTrue(q.contains(date(hour: 6), calendar: calendar()))
        XCTAssertFalse(q.contains(date(hour: 7), calendar: calendar()), "end is exclusive")
        XCTAssertFalse(q.contains(date(hour: 12), calendar: calendar()))
        // A collapsed window means "no quiet hours", never "always quiet".
        let empty = NotificationQuietHours(startHour: 9, endHour: 9)
        XCTAssertFalse(empty.contains(date(hour: 9), calendar: calendar()))
    }

    // MARK: - Default consistency (an opted-in class must be able to arrive)

    /// The trap this guards: a time-based class whose DEFAULT fire hour sits inside the DEFAULT
    /// quiet-hours window can never fire, so a user who opts it in gets silence and nothing anywhere
    /// says why. Every other test in this suite supplies its own hour and its own window, so none of
    /// them compares the two DEFAULTS — moving the wind-down to 22:00, or widening the night window
    /// to start at 21:00, would ship a permanently silent toggle with the whole suite still green.
    @MainActor
    func testDefaultFireHoursFallOutsideTheDefaultQuietWindow() {
        let cal = calendar()
        let night = NotificationQuietHours.defaultNight
        // Mirrors `AppEnvironment.timeBasedClasses`, which is private to that type. The fallback
        // branch is asserted below as well, so a class added to that list later is safe by default
        // even before someone remembers to extend this list.
        let timeBased: [NotificationClass] = [.morningReadinessSummary, .eveningWindDown, .hydration]
        for cls in timeBased {
            let hour = AppEnvironment.defaultNotificationHour(cls)
            XCTAssertFalse(night.contains(date(hour: hour), calendar: cal),
                           "\(cls) defaults to \(hour):00, inside the default quiet window — an opted-in user could never receive it")
        }
        // `defaultNotificationHour`'s fallback hour, which any future class lands on first.
        XCTAssertFalse(night.contains(date(hour: AppEnvironment.defaultNotificationHour(.deviationNotice)), calendar: cal),
                       "the fallback default hour is inside the default quiet window")
    }

    // MARK: - 64-cap interplay (meds never starved)

    func testMedPendingLimitReservesRoomForNonMed() {
        XCTAssertEqual(NotificationDecisionEngine.medPendingLimit(nonMedPending: 0),
                       MedicationReminderPlan.systemPendingLimit,
                       "with nothing non-med pending, meds keep the full 64 — no regression")
        XCTAssertEqual(NotificationDecisionEngine.medPendingLimit(nonMedPending: 2),
                       MedicationReminderPlan.systemPendingLimit - 2)
        XCTAssertEqual(NotificationDecisionEngine.medPendingLimit(nonMedPending: 999), 0,
                       "the med limit never goes negative")
    }

    func testMedsAndNonMedNeverExceedTheCeilingTogether() {
        for nonMed in 0...NotificationBudget.dailyNonMedLimit {
            let medCap = NotificationDecisionEngine.medPendingLimit(nonMedPending: nonMed)
            XCTAssertLessThanOrEqual(medCap + nonMed, NotificationBudget.systemPendingLimit,
                                     "meds + non-med must never exceed the shared ceiling")
        }
    }

    func testMedsAreNeverStarvedByNonMed() {
        // At the very most the non-med budget can put 2 notices pending. Meds still keep 62 of 64 —
        // and the med cap keeps the SOONEST reminders, so this is not starvation.
        let medCap = NotificationDecisionEngine.medPendingLimit(nonMedPending: NotificationBudget.dailyNonMedLimit)
        XCTAssertGreaterThanOrEqual(medCap, NotificationBudget.systemPendingLimit - NotificationBudget.dailyNonMedLimit)
        XCTAssertEqual(medCap, 62)
    }

    func testMedCapInterplayWithRealPlanBuilder() {
        // The concrete proof: a med plan that would exceed the reduced ceiling is capped to it, so
        // meds + the 2 pending non-med notices == exactly 64 pending, never 66.
        let regimens = (0..<20).map { i in
            MedicationRegimen(id: "r\(i)", name: "R\(i)",
                              schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7], times: ["08:00", "20:00"]),
                              startedAt: date(hour: 0), endedAt: nil,
                              updatedAt: date(hour: 0), originDeviceId: "dev", deletedAt: nil)
        }
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertGreaterThan(plan.count, NotificationBudget.systemPendingLimit)
        let nonMedPending = NotificationBudget.dailyNonMedLimit
        let medLimit = NotificationDecisionEngine.medPendingLimit(nonMedPending: nonMedPending)
        let (kept, _) = MedicationReminderPlan.capped(plan, limit: medLimit, now: date(hour: 0), calendar: calendar())
        XCTAssertEqual(kept.count, medLimit)
        XCTAssertEqual(kept.count + nonMedPending, NotificationBudget.systemPendingLimit)
    }

    func testNonMedYieldsWhenTheCeilingIsFull() {
        // Meds fill the ceiling: a non-med candidate is capped out. Meds win — never evicted.
        let ctx = context(pendingMed: NotificationBudget.systemPendingLimit, pendingNonMed: 0)
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.morningReadinessSummary, hour: 8), in: ctx),
                       .suppressedSystemCap)
    }

    func testNonMedTakesAFreeSlotBelowTheCeiling() {
        let ctx = context(pendingMed: 60, pendingNonMed: 1)   // 61 pending < 64
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.hydration, hour: 12), in: ctx), .scheduled)
    }

    func testMedsAreNeverSuppressedByTheSystemCap() {
        // A meds candidate is exempt from the cap check entirely (its own path caps itself).
        let ctx = context(pendingMed: NotificationBudget.systemPendingLimit, pendingNonMed: 5)
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.meds, hour: 8), in: ctx), .scheduled)
    }

    // MARK: - Decision order

    func testDecisionOrderOptOutThenQuietThenBudgetThenCap() {
        let quietAllDay = NotificationQuietHours(startHour: 0, endHour: 23)
        // Opt-out wins over everything.
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.hydration, hour: 3),
            in: context(optedIn: false, quiet: quietAllDay, nonMedToday: 99, pendingMed: 64)),
            .suppressedOptedOut)
        // Quiet hours wins over budget + cap.
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.hydration, hour: 3),
            in: context(optedIn: true, quiet: quietAllDay, nonMedToday: 99, pendingMed: 64)),
            .suppressedQuietHours)
        // Budget wins over cap.
        XCTAssertEqual(NotificationDecisionEngine.decide(candidate(.hydration, hour: 12),
            in: context(optedIn: true, quiet: nil, nonMedToday: NotificationBudget.dailyNonMedLimit, pendingMed: 64)),
            .suppressedDailyBudget)
    }

    /// `.suppressedNotAuthorized` and `.suppressedLedgerUnavailable` are ADAPTER verdicts —
    /// authorization and storage are I/O facts the pure engine is never handed, so `decide` must
    /// never invent either. One case per branch the engine can actually take (schedule, opt-out,
    /// quiet, budget, cap), which is every path that can produce a verdict at all.
    func testThePureEngineNeverClaimsNotAuthorized() {
        let quietAllDay = NotificationQuietHours(startHour: 0, endHour: 23)
        let cases: [NotificationDecisionEngine.Context] = [
            context(),                                                      // → scheduled
            context(optedIn: false),                                        // → opted out
            context(quiet: quietAllDay),                                    // → quiet hours
            context(nonMedToday: NotificationBudget.dailyNonMedLimit),      // → daily budget
            context(pendingMed: NotificationBudget.systemPendingLimit),     // → system cap
        ]
        var seen = Set<NotificationDecisionEngine.Decision>()
        for ctx in cases {
            for cls in NotificationClass.allCases {
                let decision = NotificationDecisionEngine.decide(candidate(cls, hour: 3), in: ctx)
                XCTAssertNotEqual(decision, .suppressedNotAuthorized,
                                  "the pure engine cannot see authorization state")
                XCTAssertNotEqual(decision, .suppressedLedgerUnavailable,
                                  "the pure engine cannot see storage state")
                seen.insert(decision)
            }
        }
        // The sweep is only meaningful if it actually reached every non-adapter verdict.
        XCTAssertEqual(seen, [.scheduled, .suppressedOptedOut, .suppressedQuietHours,
                              .suppressedDailyBudget, .suppressedSystemCap])
    }

    // MARK: - Copy (privacy + wellness-safe register)

    func testCopyIsPresentInBothLanguagesAndCarriesNoTokens() {
        for cls in NotificationClass.allCases {
            let content = NotificationClassCopy.content(cls)
            let row = NotificationClassCopy.settingsRow(cls)
            for s in [content.title.en, content.title.ar, content.body.en, content.body.ar,
                      row.label.en, row.label.ar, row.hint.en, row.hint.ar] {
                XCTAssertFalse(s.isEmpty, "\(cls) copy must exist in both languages")
                XCTAssertFalse(s.contains("{"), "\(cls) copy must not interpolate dynamic (leakable) data")
                XCTAssertFalse(s.contains("}"))
            }
        }
    }

    /// Arabic 2 takes the DUAL, not the plural. The budget note used to read "يرسل «بدن» 2 إشعارات":
    /// the 3–10 plural with a Latin digit in front of it, wrong twice over in a language the app
    /// treats as first-order. It now goes through the same `ReportPresentation.countedNoun` machinery
    /// (dual slot included) that every other counted noun in the app uses, so the noun form follows
    /// the number instead of being frozen at the plural.
    ///
    /// The digit-shape half of that machinery — that the count is rendered through `Numerals` rather
    /// than interpolated raw — is pinned by `ReportRendererTests.testCountedNounFormatsItsNumberThroughNumerals`;
    /// it cannot be re-asserted here, because at the shipped limit of 2 the Arabic dual carries the
    /// number itself and no numeral is emitted at all. That absence is what the digit assertion below
    /// checks. Mirrored by `NotificationDecisionEngineTest.dailyBudgetNoteUsesTheArabicDual`.
    func testDailyBudgetNoteUsesTheArabicDual() {
        XCTAssertEqual(NotificationBudget.dailyNonMedLimit, 2,
                       "this test is about the dual specifically — a changed limit needs the forms re-checked")
        let note = NotificationClassCopy.dailyBudgetNote(arabicDigits: false)
        XCTAssertTrue(note.ar.contains("إشعارين"), "Arabic 2 is the dual إشعارين")
        XCTAssertFalse(note.ar.contains("إشعارات"), "the 3–10 plural must not be used for 2")
        XCTAssertFalse(note.ar.contains(where: \.isNumber),
                       "the dual carries the two itself — no numeral belongs in front of it")
        XCTAssertTrue(note.en.contains("2 notifications"), "English pluralises and keeps the numeral")
        // The Arabic-digit preference must not change the dual (there is no numeral to reshape).
        XCTAssertEqual(NotificationClassCopy.dailyBudgetNote(arabicDigits: true).ar, note.ar)
    }
}

/// EPIC-32 budget-ledger tests against a real `notification_deliveries` table (migration v8), the
/// same DB-backed pattern `HydrationTests` uses. Proves the count that backs the ≤2/day invariant
/// survives in storage: scheduled/delivered rows count, suppressed/cancelled ones do not, meds are
/// excluded, and the window is per local day.
final class NotificationDeliveryRepositoryTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-notif-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func repo() -> NotificationDeliveryRepository { NotificationDeliveryRepository(db.main) }

    private func calendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(day: Int, hour: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = day; comps.hour = hour
        return calendar().date(from: comps)!
    }

    func testScheduledRowsCountTowardTheDailyBudget() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        try r.record(.morningReadinessSummary, scheduledFor: date(day: 20, hour: 8), outcome: .scheduled,
                     now: now, deviceId: device)
        try r.record(.eveningWindDown, scheduledFor: date(day: 20, hour: 21), outcome: .scheduled,
                     now: now, deviceId: device)
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 20, hour: 0), calendar: calendar()), 2)
    }

    func testSuppressedAndCancelledRowsDoNotConsumeBudget() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        try r.record(.hydration, scheduledFor: date(day: 20, hour: 15), outcome: .suppressed, now: now, deviceId: device)
        try r.record(.hydration, scheduledFor: date(day: 20, hour: 16), outcome: .cancelled, now: now, deviceId: device)
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 20, hour: 0), calendar: calendar()), 0)
    }

    func testMedsRowsNeverCountAgainstTheNonMedBudget() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        try r.record(.meds, scheduledFor: date(day: 20, hour: 9), outcome: .scheduled, now: now, deviceId: device)
        try r.record(.meds, scheduledFor: date(day: 20, hour: 21), outcome: .delivered, now: now, deviceId: device)
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 20, hour: 0), calendar: calendar()), 0)
    }

    func testBudgetWindowIsPerLocalDay() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        try r.record(.hydration, scheduledFor: date(day: 20, hour: 15), outcome: .scheduled, now: now, deviceId: device)
        try r.record(.hydration, scheduledFor: date(day: 21, hour: 15), outcome: .scheduled, now: now, deviceId: device)
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 20, hour: 0), calendar: calendar()), 1)
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 21, hour: 0), calendar: calendar()), 1)
    }

    func testHasScheduledIsPerClassAndIdempotencySafe() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        try r.record(.morningReadinessSummary, scheduledFor: date(day: 20, hour: 8), outcome: .scheduled,
                     now: now, deviceId: device)
        XCTAssertTrue(r.hasScheduled(.morningReadinessSummary, inDayOf: date(day: 20, hour: 0), calendar: calendar()))
        XCTAssertFalse(r.hasScheduled(.eveningWindDown, inDayOf: date(day: 20, hour: 0), calendar: calendar()))
        XCTAssertFalse(r.hasScheduled(.morningReadinessSummary, inDayOf: date(day: 21, hour: 0), calendar: calendar()))
    }

    func testMarkDeliveredKeepsTheRowCountedAndTransitionsState() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        let row = try r.record(.hydration, scheduledFor: date(day: 20, hour: 15), outcome: .scheduled,
                               now: now, deviceId: device)
        try r.markDelivered(id: row.id, at: date(day: 20, hour: 15))
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 20, hour: 0), calendar: calendar()), 1)
        let stored = try r.recent().first { $0.id == row.id }
        XCTAssertEqual(stored?.outcome, .delivered)
        XCTAssertNotNil(stored?.deliveredAt)
    }

    func testLedgerCountBacksTheEngineDailyBudget() throws {
        // The integration path: two committed rows + the pure engine == a suppressed third.
        let r = repo()
        let cal = calendar()
        let day = date(day: 20, hour: 0)
        try r.record(.morningReadinessSummary, scheduledFor: date(day: 20, hour: 8), outcome: .scheduled,
                     now: day, deviceId: device)
        try r.record(.eveningWindDown, scheduledFor: date(day: 20, hour: 21), outcome: .scheduled,
                     now: day, deviceId: device)
        let ctx = NotificationDecisionEngine.Context(
            calendar: cal, optedIn: { _ in true }, quietHours: { _ in nil },
            nonMedScheduledToday: r.countBudgeted(inDayOf: day, calendar: cal),
            pendingMedCount: 0, pendingNonMedCount: 0)
        XCTAssertEqual(NotificationDecisionEngine.decide(.init(.hydration, fireDate: date(day: 20, hour: 15)), in: ctx),
                       .suppressedDailyBudget)
    }

    /// The ≤2/day ceiling only holds if a notification can never reach the OS without its ledger
    /// row, so `AppEnvironment` reserves the row FIRST and declines to schedule when the reservation
    /// fails (`.suppressedLedgerUnavailable`). That guard is only worth having if `record` actually
    /// reports a failure instead of returning a row that was never written — pinned here, because
    /// the previous code swallowed the error with `try?` and the notification went out regardless.
    func testAReservationFailureIsReportedRatherThanSwallowed() throws {
        let r = repo()
        try db.main.run("DROP TABLE notification_deliveries;")
        XCTAssertThrowsError(try r.record(.hydration, scheduledFor: date(day: 20, hour: 15),
                                          outcome: .scheduled, now: date(day: 20, hour: 8),
                                          deviceId: device),
                             "a failed reservation must throw — the caller decides not to schedule on it")
    }

    /// Closing a reserved row out to a non-delivery outcome releases the budget slot it was holding
    /// and clears any delivery timestamp — a row that never fired must not claim it did. This is the
    /// path Android takes when the system refuses an immediate post; the two platforms share the SQL.
    func testTransitioningAwayFromScheduledReleasesTheSlot() throws {
        let r = repo()
        let now = date(day: 20, hour: 8)
        let row = try r.record(.hydration, scheduledFor: date(day: 20, hour: 15), outcome: .scheduled,
                               now: now, deviceId: device)
        try r.markDelivered(id: row.id, at: date(day: 20, hour: 15))
        try r.transition(id: row.id, to: .suppressed, at: date(day: 20, hour: 16))
        XCTAssertEqual(r.countBudgeted(inDayOf: date(day: 20, hour: 0), calendar: calendar()), 0)
        let stored = try r.recent().first { $0.id == row.id }
        XCTAssertEqual(stored?.outcome, .suppressed)
        XCTAssertNil(stored?.deliveredAt, "a suppressed row must not carry a delivery timestamp")
    }

    func testPruneDropsOldRows() throws {
        let r = repo()
        let now = date(day: 100, hour: 8)
        try r.record(.hydration, scheduledFor: date(day: 20, hour: 15), outcome: .scheduled, now: now, deviceId: device)
        try r.record(.hydration, scheduledFor: date(day: 99, hour: 15), outcome: .scheduled, now: now, deviceId: device)
        let dropped = try r.prune(now: now, retentionDays: 30)
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(try r.recent().count, 1)
    }
}
