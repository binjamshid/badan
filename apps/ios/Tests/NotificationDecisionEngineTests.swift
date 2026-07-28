import XCTest
@testable import BADAN

/// EPIC-32 acceptance suite for the pure decision core. Never touches `UNUserNotificationCenter` —
/// only `NotificationDecisionEngine`, the side-effect-free layer the scheduler adapts. Covers the
/// three acceptance items that live in the engine: the daily non-med budget (held under load, and
/// now at whatever ceiling the user set), the per-class opt-in matrix, and the 64-pending cap
/// interplay with meds (meds never starved).
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
                         pendingNonMed: Int = 0,
                         dailyLimit: Int = NotificationBudget.defaultDailyNonMedLimit)
        -> NotificationDecisionEngine.Context {
        NotificationDecisionEngine.Context(
            calendar: calendar(),
            optedIn: { _ in optedIn },
            quietHours: { _ in quiet },
            nonMedScheduledToday: nonMedToday,
            pendingMedCount: pendingMed,
            pendingNonMedCount: pendingNonMed,
            dailyNonMedLimit: dailyLimit)
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
            XCTAssertTrue(cls.countsAgainstDailyBudget, "\(cls) must count against the daily budget")
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
                      "every offered class must count against the daily budget")
    }

    /// The producer categories must PARTITION the offered classes: every toggle is backed by exactly
    /// one kind of producer, and no class is claimed by two.
    ///
    /// This is the assertion that did not exist before. `AppEnvironment.timeBasedClasses` used to be
    /// a second array literal that merely happened to equal `userFacing`, with nothing tying them —
    /// so adding a class to one and not the other shipped either a toggle nothing schedules or a
    /// schedule the user cannot see, and the whole suite stayed green either way.
    func testProducerCategoriesPartitionTheOfferedClasses() {
        let timeBased = Set(NotificationClass.timeBased)
        let eventDriven = Set(NotificationClass.eventDriven)
        let unbudgeted = Set(NotificationClass.unbudgetedProducers)

        XCTAssertTrue(timeBased.isDisjoint(with: eventDriven))
        XCTAssertTrue(timeBased.isDisjoint(with: unbudgeted))
        XCTAssertTrue(eventDriven.isDisjoint(with: unbudgeted))

        XCTAssertTrue(timeBased.isSubset(of: Set(NotificationClass.userFacing)),
                      "a class reconcile pre-schedules must have a toggle the user can turn off")
        XCTAssertTrue(Set(NotificationClass.userFacing)
                        .isSubset(of: timeBased.union(eventDriven).union(unbudgeted)),
                      "a class offered in Settings must be raised by some producer")
        XCTAssertFalse(timeBased.union(eventDriven).union(unbudgeted).contains(.meds),
                       "meds are scheduled by the med path, not by any of these producers")
    }

    /// Priority is what makes the ceiling deterministic rather than first-come. Before it, the order
    /// the budget was spent in was the order of an array literal — and hydration, always last in it,
    /// was the class starved every time the ceiling bound.
    func testPriorityIsTotalAndOrdersTheBudgetDeterministically() {
        let priorities = NotificationClass.allCases.map(\.priority)
        XCTAssertEqual(Set(priorities).count, NotificationClass.allCases.count,
                       "two classes sharing a priority would leave their order to the sort's stability")
        XCTAssertLessThan(NotificationClass.morningReadinessSummary.priority,
                          NotificationClass.hydration.priority,
                          "an ambient nudge must not outrank a daily anchor for a contested slot")
        XCTAssertLessThan(NotificationClass.eveningWindDown.priority, NotificationClass.hydration.priority)
        XCTAssertLessThan(NotificationClass.exportHealthAlert.priority,
                          NotificationClass.morningReadinessSummary.priority,
                          "a broken export is a fact about the user's own setup, not a wellness nudge")
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

    // MARK: - Daily budget (user-configurable ceiling, held under load)

    func testDailyBudgetHoldsUnderLoad() {
        // 100 candidates in one day, all opted in, no quiet hours: exactly the ceiling is scheduled.
        let limit = NotificationBudget.defaultDailyNonMedLimit
        let candidates = (0..<100).map { _ in candidate(.hydration, hour: 12) }
        let results = NotificationDecisionEngine.decideBatch(candidates, in: context(optedIn: true))
        let scheduled = results.filter { $0.1 == .scheduled }.count
        XCTAssertEqual(scheduled, limit)
        XCTAssertTrue(results.dropFirst(limit).allSatisfy { $0.1 == .suppressedDailyBudget },
                      "every candidate past the ceiling must be budget-suppressed, not silently dropped")
    }

    /// The ceiling is a preference now, so it must hold at every value the preference can take — not
    /// just at the one that happens to be the default.
    func testDailyBudgetHoldsAtEveryConfigurableLimit() {
        for limit in NotificationPreference.dailyNonMedLimitRange {
            let candidates = (0..<20).map { _ in candidate(.hydration, hour: 12) }
            let results = NotificationDecisionEngine.decideBatch(
                candidates, in: context(optedIn: true, dailyLimit: limit))
            XCTAssertEqual(results.filter { $0.1 == .scheduled }.count, limit,
                           "a ceiling of \(limit) must schedule exactly \(limit)")
            XCTAssertTrue(results.dropFirst(limit).allSatisfy { $0.1 == .suppressedDailyBudget },
                          "at a ceiling of \(limit), everything past it must name the budget as the reason")
        }
    }

    /// The limit is clamped on BOTH construction and later assignment. A profile is not a trusted
    /// input — an older build, a hand-edited export, or a future build's wider range read back by
    /// this one — and an unclamped 0 would silence every non-med class while the settings screen
    /// still showed the toggles on.
    func testDailyLimitIsClampedEverywhereItCanBeSet() {
        let range = NotificationPreference.dailyNonMedLimitRange
        XCTAssertEqual(NotificationPreference(dailyNonMedLimit: 0).dailyNonMedLimit, range.lowerBound)
        XCTAssertEqual(NotificationPreference(dailyNonMedLimit: -7).dailyNonMedLimit, range.lowerBound)
        XCTAssertEqual(NotificationPreference(dailyNonMedLimit: 99).dailyNonMedLimit, range.upperBound)
        XCTAssertEqual(NotificationPreference().dailyNonMedLimit,
                       NotificationPreference.defaultDailyNonMedLimit)

        // Later assignment (how `AppEnvironment.update` writes it) is clamped by the `didSet`.
        var prefs = NotificationPreference()
        prefs.dailyNonMedLimit = 0
        XCTAssertEqual(prefs.dailyNonMedLimit, range.lowerBound)
        prefs.dailyNonMedLimit = 99
        XCTAssertEqual(prefs.dailyNonMedLimit, range.upperBound)
    }

    /// A field added after a profile was last saved must decode to its default rather than failing
    /// the whole `NotificationPreference` — `ProfileRepository.load()` treats any decode failure as
    /// "no saved profile" and would silently reset every other preference with it.
    func testDailyLimitDecodesTolerantlyAndClamps() throws {
        let legacy = Data(#"{"medicationReminders":true}"#.utf8)
        let decoded = try JSONDecoder().decode(NotificationPreference.self, from: legacy)
        XCTAssertEqual(decoded.dailyNonMedLimit, NotificationPreference.defaultDailyNonMedLimit)
        XCTAssertTrue(decoded.medicationReminders, "the rest of the profile must survive intact")

        let corrupt = Data(#"{"dailyNonMedLimit":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NotificationPreference.self, from: corrupt).dailyNonMedLimit,
                       NotificationPreference.dailyNonMedLimitRange.lowerBound)
        let tooWide = Data(#"{"dailyNonMedLimit":40}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NotificationPreference.self, from: tooWide).dailyNonMedLimit,
                       NotificationPreference.dailyNonMedLimitRange.upperBound)
    }

    func testBudgetSpansAllNonMedClassesCombined() {
        // The budget is a combined non-med ceiling, not per-class: at a limit of 2, morning +
        // wind-down spend it and a third class (hydration) is then held. Stated at an explicit 2
        // rather than at the default, so this keeps testing "combined, not per-class" even if the
        // default moves again.
        let batch = [candidate(.morningReadinessSummary, hour: 8),
                     candidate(.eveningWindDown, hour: 21),
                     candidate(.hydration, hour: 15)]
        let results = NotificationDecisionEngine.decideBatch(batch, in: context(dailyLimit: 2))
        XCTAssertEqual(results[0].1, .scheduled)
        XCTAssertEqual(results[1].1, .scheduled)
        XCTAssertEqual(results[2].1, .suppressedDailyBudget)
    }

    // MARK: - The floating slot

    /// Pre-scheduled classes reserve their ledger row hours before an event-driven class can fire,
    /// so on a plain first-come budget the event-driven toggle is a dead switch. One slot floats.
    func testFloatingSlotHoldsOneBackForEventDrivenClasses() {
        for limit in NotificationPreference.dailyNonMedLimitRange {
            XCTAssertEqual(
                NotificationDecisionEngine.timeBasedLimit(dailyLimit: limit, reserveFloatingSlot: false),
                limit, "with nothing event-driven enabled, the time-based classes get the whole budget")
            XCTAssertEqual(
                NotificationDecisionEngine.timeBasedLimit(dailyLimit: limit, reserveFloatingSlot: true),
                max(1, limit - 1), "one slot is held for whatever actually happens that day")
        }
    }

    /// Reserving the floating slot must never silence the time-based classes outright — a user who
    /// set the ceiling to 1 and enabled a deviation notice still gets their morning summary.
    func testFloatingSlotNeverStarvesTheTimeBasedClassesEntirely() {
        XCTAssertEqual(NotificationDecisionEngine.timeBasedLimit(dailyLimit: 1, reserveFloatingSlot: true), 1)
        for limit in NotificationPreference.dailyNonMedLimitRange {
            XCTAssertGreaterThanOrEqual(
                NotificationDecisionEngine.timeBasedLimit(dailyLimit: limit, reserveFloatingSlot: true), 1)
        }
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
        // Read from the registry rather than mirrored as a third copy of the same literal — a class
        // added to `NotificationClass.timeBased` is now covered here automatically. The fallback
        // branch is asserted below as well.
        for cls in NotificationClass.timeBased {
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
        for nonMed in 0...NotificationPreference.dailyNonMedLimitRange.upperBound {
            let medCap = NotificationDecisionEngine.medPendingLimit(nonMedPending: nonMed)
            XCTAssertLessThanOrEqual(medCap + nonMed, NotificationBudget.systemPendingLimit,
                                     "meds + non-med must never exceed the shared ceiling")
        }
    }

    func testMedsAreNeverStarvedByNonMed() {
        // Asserted at the WIDEST ceiling the user can now set, not at the default: the point is that
        // the bite out of meds stays bounded however high the preference goes, which is exactly why
        // the ceiling stayed clamped when it stopped being a constant. At 4, meds keep 60 of 64 —
        // and the med cap keeps the SOONEST reminders, so this is not starvation.
        let widest = NotificationPreference.dailyNonMedLimitRange.upperBound
        let medCap = NotificationDecisionEngine.medPendingLimit(nonMedPending: widest)
        XCTAssertGreaterThanOrEqual(medCap, NotificationBudget.systemPendingLimit - widest)
        XCTAssertEqual(medCap, 60)
    }

    func testMedCapInterplayWithRealPlanBuilder() {
        // The concrete proof: a med plan that would exceed the reduced ceiling is capped to it, so
        // meds + the pending non-med notices == exactly 64 pending, never more.
        let regimens = (0..<20).map { i in
            MedicationRegimen(id: "r\(i)", name: "R\(i)",
                              schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7], times: ["08:00", "20:00"]),
                              startedAt: date(hour: 0), endedAt: nil,
                              updatedAt: date(hour: 0), originDeviceId: "dev", deletedAt: nil)
        }
        let plan = MedicationReminderPlan.build(regimens: regimens, enabled: true, language: .en)
        XCTAssertGreaterThan(plan.count, NotificationBudget.systemPendingLimit)
        let nonMedPending = NotificationPreference.dailyNonMedLimitRange.upperBound
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
            in: context(optedIn: true, quiet: nil,
                        nonMedToday: NotificationBudget.defaultDailyNonMedLimit, pendingMed: 64)),
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
            context(nonMedToday: NotificationBudget.defaultDailyNonMedLimit),  // → daily budget
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
    /// it cannot be re-asserted at 2, because the Arabic dual carries the number itself and no
    /// numeral is emitted at all. That absence is what the digit assertion below checks.
    /// Mirrored by `NotificationDecisionEngineTest.dailyBudgetNoteUsesTheArabicDual`.
    func testDailyBudgetNoteUsesTheArabicDual() {
        let note = NotificationClassCopy.dailyBudgetNote(count: 2, arabicDigits: false)
        XCTAssertTrue(note.ar.contains("إشعارين"), "Arabic 2 is the dual إشعارين")
        XCTAssertFalse(note.ar.contains("إشعارات"), "the 3–10 plural must not be used for 2")
        XCTAssertFalse(note.ar.contains(where: \.isNumber),
                       "the dual carries the two itself — no numeral belongs in front of it")
        XCTAssertTrue(note.en.contains("2 notifications"), "English pluralises and keeps the numeral")
        // The Arabic-digit preference must not change the dual (there is no numeral to reshape).
        XCTAssertEqual(NotificationClassCopy.dailyBudgetNote(count: 2, arabicDigits: true).ar, note.ar)
    }

    /// The note now quotes the USER's ceiling, so it has to be right across the whole 1…4 range the
    /// preference can take — not just at the one value that used to be a constant. Arabic changes
    /// noun form three times inside that range (singular at 1, dual at 2, the 3–10 plural above),
    /// which is precisely why the count goes through `countedNoun` instead of being interpolated.
    func testDailyBudgetNoteIsCorrectAtEveryConfigurableCount() {
        for count in NotificationPreference.dailyNonMedLimitRange {
            let note = NotificationClassCopy.dailyBudgetNote(count: count, arabicDigits: false)
            XCTAssertFalse(note.en.isEmpty)
            XCTAssertFalse(note.ar.isEmpty)
            XCTAssertTrue(note.en.contains(count == 1 ? "1 notification" : "\(count) notifications"),
                          "English must pluralise on the user's own count, not a constant")
        }
        XCTAssertTrue(NotificationClassCopy.dailyBudgetNote(count: 1, arabicDigits: false).ar
                        .contains("إشعاراً واحداً"), "Arabic 1 takes the singular")
        XCTAssertTrue(NotificationClassCopy.dailyBudgetNote(count: 3, arabicDigits: false).ar
                        .contains("إشعارات"), "Arabic 3–10 takes the paucal plural")
        XCTAssertTrue(NotificationClassCopy.dailyBudgetNote(count: 4, arabicDigits: false).ar
                        .contains("إشعارات"))
        // Above 2 a numeral IS emitted, so this is the one count at which the note can be shown to
        // route its number through `Numerals` rather than interpolating it raw — the half the dual
        // case above structurally cannot reach, because the dual carries the two itself.
        //
        // Compared against `Numerals.format` rather than against a literal "٣", and NOT asserted to
        // differ from the `arabicDigits: false` rendering: a bare "ar" locale does not reliably
        // resolve to an Arabic-Indic numbering system, so the glyph is the platform's business.
        // What this pins is that the preference reaches the formatter at all. Same posture as
        // `ReportRendererTests.testCountedNounFormatsItsNumberThroughNumerals`, deliberately.
        for arabicDigits in [true, false] {
            let expected = Numerals.format(3.0, language: .ar, arabicDigits: arabicDigits, fractionDigits: 0)
            XCTAssertTrue(NotificationClassCopy.dailyBudgetNote(count: 3, arabicDigits: arabicDigits).ar
                            .contains(expected),
                          "the count must be rendered through Numerals, not interpolated raw")
        }
    }
}

/// EPIC-32 budget-ledger tests against a real `notification_deliveries` table (migration v8), the
/// same DB-backed pattern `HydrationTests` uses. Proves the count that backs the daily invariant
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

    /// The integration path: committed rows + the pure engine == a suppressed candidate once the
    /// day's ceiling is spent. Driven off the ceiling itself rather than the two rows this used to
    /// hardcode — the ceiling is a user preference now, so a test that writes exactly two rows and
    /// expects a third to be refused is asserting the old constant, not the integration.
    ///
    /// Both sides of the boundary are checked, because "lots of rows get suppressed" would pass even
    /// if the ledger count never reached the engine at all.
    func testLedgerCountBacksTheEngineDailyBudget() throws {
        let r = repo()
        let cal = calendar()
        let day = date(day: 20, hour: 0)
        let limit = NotificationBudget.defaultDailyNonMedLimit

        func decideOneMore() -> NotificationDecisionEngine.Decision {
            let ctx = NotificationDecisionEngine.Context(
                calendar: cal, optedIn: { _ in true }, quietHours: { _ in nil },
                nonMedScheduledToday: r.countBudgeted(inDayOf: day, calendar: cal),
                pendingMedCount: 0, pendingNonMedCount: 0,
                dailyNonMedLimit: limit)
            return NotificationDecisionEngine.decide(
                .init(.hydration, fireDate: date(day: 20, hour: 15)), in: ctx)
        }

        // One row short of the ceiling: the ledger must NOT be holding anything back yet.
        for i in 0 ..< (limit - 1) {
            try r.record(.morningReadinessSummary, scheduledFor: date(day: 20, hour: 8 + i),
                         outcome: .scheduled, now: day, deviceId: device)
        }
        XCTAssertEqual(r.countBudgeted(inDayOf: day, calendar: cal), limit - 1)
        XCTAssertEqual(decideOneMore(), .scheduled,
                       "below the ceiling the ledger must not suppress anything")

        // The row that spends it.
        try r.record(.eveningWindDown, scheduledFor: date(day: 20, hour: 21), outcome: .scheduled,
                     now: day, deviceId: device)
        XCTAssertEqual(r.countBudgeted(inDayOf: day, calendar: cal), limit)
        XCTAssertEqual(decideOneMore(), .suppressedDailyBudget)
    }

    /// The daily ceiling only holds if a notification can never reach the OS without its ledger
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
