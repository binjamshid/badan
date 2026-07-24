import Foundation
import XCTest
@testable import BADAN

/// A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice) — `PregnancyModuleServices` composition-
/// layer tests: default-off/user-declared gating, mode-transition wiring, due-date provenance
/// always being present, the loss-declaration suppression cascade (content gate + real notification
/// cancellation), append-only behavior across a loss declaration, and `purgePregnancyData()`.
/// Mirrors `CycleModuleServicesTests`'s own structure for its sibling module.
@MainActor
final class PregnancyModuleServicesTests: XCTestCase {
    private var tempDir: URL!
    private var env: AppEnvironment!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-pregnancy-module-services-\(UUID().uuidString)", isDirectory: true)
        env = AppEnvironment(database: try Database(directory: tempDir),
                             clock: FixedClock(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    override func tearDownWithError() throws {
        env = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func rowCount(_ connection: SQLiteConnection, table: String) throws -> Int {
        let rows = try connection.query("SELECT COUNT(*) AS c FROM \"\(table)\";")
        return Int(rows.first?.int("c") ?? 0)
    }

    // MARK: - Non-negotiable #1: default-off, user-declared only

    func testPregnancyModuleModeDefaultsToOff() {
        XCTAssertEqual(env.profile.pregnancyModuleMode, .off, "the module must default off (opt-in)")
    }

    /// A profile persisted BEFORE `pregnancyModuleMode` existed, or with an unrecognized future
    /// value, must decode to `.off` — never a whole-profile decode failure (which
    /// `ProfileRepository.load()` treats as "no saved profile" and resets every other preference),
    /// and never silently `.on`. Mirrors `fertileWindowMode`'s own tolerant-decode test posture.
    func testCustomizationProfileTolerantlyDecodesMissingOrUnrecognizedPregnancyModuleMode() throws {
        let decoder = JSONDecoder()

        // Key missing entirely (an older persisted profile).
        var json = try profileJSONMissingKey("pregnancyModuleMode")
        var decoded = try decoder.decode(CustomizationProfile.self, from: json)
        XCTAssertEqual(decoded.pregnancyModuleMode, .off)

        // Key present but an unrecognized raw value (a future mode this build doesn't know).
        json = try profileJSONWithPregnancyModuleMode("some-future-value")
        decoded = try decoder.decode(CustomizationProfile.self, from: json)
        XCTAssertEqual(decoded.pregnancyModuleMode, .off)
    }

    private func profileJSONMissingKey(_ key: String) throws -> Data {
        let encoder = JSONEncoder()
        var obj = try JSONSerialization.jsonObject(with: encoder.encode(CustomizationProfile())) as! [String: Any]
        obj.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func profileJSONWithPregnancyModuleMode(_ rawValue: String) throws -> Data {
        let encoder = JSONEncoder()
        var obj = try JSONSerialization.jsonObject(with: encoder.encode(CustomizationProfile())) as! [String: Any]
        obj["pregnancyModuleMode"] = rawValue
        return try JSONSerialization.data(withJSONObject: obj)
    }

    // MARK: - beginJourney / applyTransition wiring

    func testBeginJourneyPersistsAndLiveJourneyReadsItBack() throws {
        let services = PregnancyModuleServices(env: env)
        XCTAssertNil(try services.liveJourney())

        try services.beginJourney(.beginTTC, asOf: env.now())

        let journey = try XCTUnwrap(try services.liveJourney())
        XCTAssertEqual(journey.mode, .ttc)
    }

    func testBeginJourneyThrowsWhenALiveJourneyAlreadyExists() throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginTTC, asOf: env.now())
        XCTAssertThrowsError(try services.beginJourney(.beginTTC, asOf: env.now()))
    }

    func testApplyTransitionMovesTheLiveJourneyForwardAppendingARevision() throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginTTC, asOf: env.now())

        try services.applyTransition(.confirmPregnancy, asOf: env.now())

        let journey = try XCTUnwrap(try services.liveJourney())
        XCTAssertEqual(journey.mode, .pregnancyConfirmed)
        XCTAssertEqual(journey.revision, 2)
        XCTAssertEqual(try rowCount(env.database.sensitive, table: "pregnancy_records"), 2,
                       "I2: the transition APPENDED a new row rather than mutating the first")
    }

    func testApplyTransitionThrowsWithNoActiveJourney() {
        let services = PregnancyModuleServices(env: env)
        XCTAssertThrowsError(try services.applyTransition(.confirmPregnancy, asOf: env.now()))
    }

    // MARK: - Non-negotiable #3: due-date provenance always shown

    func testRecordDueDateSourceAlwaysProducesAnEstimateWithAVisibleSource() throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())

        let estimate = try services.recordDueDateSource(
            sourceType: .lmpBased, enteredDate: env.now().addingTimeInterval(-30 * 86_400), asOf: env.now())

        XCTAssertTrue(estimate.hasRange)
        XCTAssertEqual(estimate.resolvedSourceType, .lmpBased,
                       "the source must always be attached alongside the range — never a bare date")
        XCTAssertEqual(try services.currentDueDateEstimate()?.id, estimate.id)
    }

    func testRefreshingDueDateEstimateAlwaysAppendsAFreshRowEvenWhenCalledTwice() throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())
        try services.recordDueDateSource(sourceType: .lmpBased, enteredDate: env.now(), asOf: env.now())
        try services.refreshDueDateEstimate(asOf: env.now())

        XCTAssertEqual(try rowCount(env.database.sensitive, table: "due_date_estimates"), 2,
                       "I2: a recompute always inserts a fresh row, never updates in place")
    }

    // MARK: - Non-negotiable #2: declareLoss — real suppression cascade

    func testDeclareLossThrowsFromAModeThatCannotDeclareLoss() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())
        try services.applyTransition(.declareBirth, asOf: env.now())

        var thrown = false
        do {
            _ = try await services.declareLoss(approximateDate: env.now(), dataDisposition: .keep, asOf: env.now())
        } catch {
            thrown = true
        }
        XCTAssertTrue(thrown, "birthDelivery cannot declare a loss (research doc §9: TTC through late pregnancy only)")
    }

    func testDeclareLossAppendsANewPregnancyRecordRevisionAndNeverDeletesOrMutatesPriorHistory() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())
        let originalId = try XCTUnwrap(try services.liveJourney()?.originalId)

        _ = try await services.declareLoss(approximateDate: env.now(), gestationalStage: .earlyPregnancy,
                                           dataDisposition: .keep, asOf: env.now())

        let history = try services.pregnancyRecords.history(originalId: originalId)
        XCTAssertEqual(history.map(\.mode), [.pregnancyConfirmed, .lossDeclared],
                       "I2: both the ORIGINAL and the loss revision survive — nothing was deleted or mutated")
        XCTAssertNil(history[0].deletedAt, "the prior mode's row is not tombstoned by a later transition")
        let live = try XCTUnwrap(try services.liveJourney())
        XCTAssertEqual(live.mode, .lossDeclared)
    }

    func testDeclareLossInsertsAMinimalLossDeclarationRecordLinkedToTheJourney() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginTTC, asOf: env.now())
        let originalId = try XCTUnwrap(try services.liveJourney()?.originalId)

        let declaration = try await services.declareLoss(
            approximateDate: env.now(), dataDisposition: .archive, asOf: env.now())

        XCTAssertEqual(declaration.pregnancyRecordOriginalId, originalId)
        XCTAssertEqual(declaration.dataDisposition, .archive)
        XCTAssertNil(declaration.freeTextNote, "no forced explanation — free text stays nil unless the user typed one")
        let live = try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: originalId)
        XCTAssertEqual(live.map(\.id), [declaration.id])
    }

    /// The content-suppression half of the cascade: the instant a loss is declared, EVERY
    /// forward-looking content section this build's structural gate knows about must report
    /// suppressed for this journey — not just on one screen, but for anything that ever asks the
    /// gate the question, checked directly against the composition layer's own read of the live
    /// journey (not a hand-built fixture).
    func testDeclareLossCausesTheContentGateToSuppressEveryForwardLookingSectionForThisJourney() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())
        XCTAssertFalse(PregnancyContentGate.visibleForwardLookingSections(for: try services.liveJourney()).isEmpty,
                       "sanity: content is visible before the loss is declared")

        _ = try await services.declareLoss(approximateDate: env.now(), dataDisposition: .keep, asOf: env.now())

        let afterLoss = try services.liveJourney()
        XCTAssertEqual(afterLoss?.mode, .lossDeclared)
        XCTAssertTrue(PregnancyContentGate.visibleForwardLookingSections(for: afterLoss).isEmpty,
                     "every forward-looking/celebratory section must be suppressed for this journey")
    }

    /// The notification half of the cascade. This codebase deliberately never drives real
    /// `UNUserNotificationCenter` state from a unit test (no existing test in this suite does
    /// either — the pure decision engine is tested instead; see `NotificationDecisionEngineTests`),
    /// because the OS notification-center behaves inconsistently in an unhosted test-runner
    /// process. What IS robustly, deterministically testable at this level:
    ///
    /// 1. `declareLoss` completes (awaits through to a return) without throwing or hanging — since
    ///    `NotificationScheduler.cancelDecisionNotifications` is itself `async` and non-throwing,
    ///    this exercises the real call path end to end.
    /// 2. The WIRING is correct: `.pregnancy` is not a medication class (so
    ///    `cancelDecisionNotifications` does not early-return via its `!cls.isMedication` guard —
    ///    see that method's own doc) and its identifier prefix is the real, non-empty prefix a
    ///    future producer's requests would need to carry for this cancellation to ever find them.
    /// 3. `.pregnancy` is deliberately absent from `NotificationClass.userFacing` (see that case's
    ///    own doc) — this cancellation path must work independent of the ≤2/day budget engine and
    ///    independent of any settings toggle.
    func testDeclareLossCompletesAndTheNotificationSuppressionWiringIsCorrect() async throws {
        XCTAssertFalse(NotificationClass.pregnancy.isMedication,
                       "must not be treated as a medication reminder — cancelDecisionNotifications " +
                       "would silently no-op for a medication class")
        XCTAssertEqual(NotificationClass.pregnancy.identifierPrefix, "decision.pregnancy.",
                       "the real prefix a future producer's requests must carry for suppression to find them")
        XCTAssertFalse(NotificationClass.userFacing.contains(.pregnancy),
                       "no settings toggle exists yet — suppression must not depend on one")

        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginTTC, asOf: env.now())
        // Completing without throwing/hanging IS the assertion: `declareLoss` awaits
        // `NotificationScheduler.cancelDecisionNotifications(.pregnancy)` synchronously before
        // returning (see that method's own doc, step 4).
        _ = try await services.declareLoss(approximateDate: env.now(), dataDisposition: .keep, asOf: env.now())
    }

    // MARK: - Loss-handling audit finding 1 (CRITICAL): a path forward after a declared loss,
    // without deleting anything.

    func testBeginJourneySucceedsAfterALossDeclaredJourneyWithoutPurgingAnything() async throws {
        let services = PregnancyModuleServices(env: env)
        // `env`'s `FixedClock` never advances on its own — once two journeys coexist, their
        // `updated_at` values must be strictly increasing for "most recently updated" to be
        // unambiguous, exactly as real wall-clock time always is in production.
        var t = env.now()
        try services.beginJourney(.beginTTC, asOf: t)
        let lostOriginalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        _ = try await services.declareLoss(approximateDate: t, dataDisposition: .keep, asOf: t)

        // The actual fix: this must NOT throw `.liveJourneyAlreadyExists`.
        t = t.addingTimeInterval(60)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: t)

        let current = try XCTUnwrap(try services.liveJourney())
        XCTAssertEqual(current.mode, .pregnancyConfirmed)
        XCTAssertNotEqual(current.originalId, lostOriginalId, "a brand-new, separate journey — not a reactivation")

        // The lost journey's own history is completely untouched — still there, still `.lossDeclared`.
        let lostHistory = try services.pregnancyRecords.history(originalId: lostOriginalId)
        XCTAssertEqual(lostHistory.map(\.mode), [.ttc, .lossDeclared])
        XCTAssertFalse(try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: lostOriginalId).isEmpty,
                       "the loss declaration itself must still exist — nothing was deleted to make this possible")
    }

    /// `liveJourney()` (most-recently-updated live record across every chain) must resolve to the
    /// NEW journey once one exists — not silently re-target the old, already-`.lossDeclared` chain —
    /// so that `applyTransition`/`declareLoss` naturally act on the right journey with no extra
    /// caller-side bookkeeping.
    func testLiveJourneyResolvesToTheNewestJourneyAfterANewOneBeginsFollowingALoss() async throws {
        let services = PregnancyModuleServices(env: env)
        var t = env.now()
        try services.beginJourney(.beginTTC, asOf: t)
        t = t.addingTimeInterval(60)
        _ = try await services.declareLoss(approximateDate: t, dataDisposition: .keep, asOf: t)
        t = t.addingTimeInterval(60)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: t)

        let current = try XCTUnwrap(try services.liveJourney())
        XCTAssertEqual(current.mode, .pregnancyConfirmed)
    }

    // MARK: - General audit finding 1 / loss-handling audit finding 2: the "Delete" data-disposition
    // choice must actually erase data, and must be revisitable after the sheet closes.

    func testDeclareLossWithDeleteDispositionReallyErasesThisJourneysDataInAllFourTables() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())
        let originalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        try services.recordDueDateSource(sourceType: .lmpBased, enteredDate: env.now(), asOf: env.now())

        _ = try await services.declareLoss(approximateDate: env.now(), dataDisposition: .delete, asOf: env.now())

        XCTAssertNil(try services.liveJourney(), "the journey the on-screen promise applies to is really gone")
        XCTAssertTrue(try services.pregnancyRecords.history(originalId: originalId).isEmpty,
                      "general audit finding 1: 'Delete' must actually delete the PregnancyRecord chain")
        XCTAssertTrue(try services.dueDateSourceEntries.history(pregnancyRecordOriginalId: originalId).isEmpty)
        XCTAssertNil(try services.dueDateEstimates.latestEstimate(pregnancyRecordOriginalId: originalId))
        XCTAssertTrue(try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: originalId).isEmpty)
    }

    /// Also exercises the loss-handling audit finding 1 fix as a side effect: two sequential,
    /// separate journeys coexist in the same store (the second begun while the first is still live
    /// as `.lossDeclared`), and each keeps its OWN disposition outcome independent of the other's.
    func testDeclareLossWithKeepOrArchiveDispositionErasesNothing() async throws {
        let services = PregnancyModuleServices(env: env)
        var t = env.now()

        try services.beginJourney(.beginTTC, asOf: t)
        let keepOriginalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        _ = try await services.declareLoss(approximateDate: t, dataDisposition: .keep, asOf: t)

        t = t.addingTimeInterval(60)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: t)
        let archiveOriginalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        _ = try await services.declareLoss(approximateDate: t, dataDisposition: .archive, asOf: t)

        for originalId in [keepOriginalId, archiveOriginalId] {
            XCTAssertFalse(try services.pregnancyRecords.history(originalId: originalId).isEmpty,
                           "I2 — nothing is erased for keep/archive")
            XCTAssertFalse(try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: originalId).isEmpty)
        }
    }

    func testUpdateLossDataDispositionToDeleteLaterErasesOnlyThatJourneyLeavingAnyOtherLiveJourneyUntouched() async throws {
        let services = PregnancyModuleServices(env: env)
        var t = env.now()
        try services.beginJourney(.beginTTC, asOf: t)
        let lostOriginalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        let declaration = try await services.declareLoss(
            approximateDate: t, dataDisposition: .keep, asOf: t)

        // A second, separate journey begun after the loss (loss-handling audit finding 1's fix) —
        // this one must survive the first journey's later "Delete" revisit untouched.
        t = t.addingTimeInterval(60)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: t)
        let newOriginalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        try services.recordDueDateSource(sourceType: .lmpBased, enteredDate: t, asOf: t)

        // The revisit path (loss-handling audit finding 2): changing disposition to `.delete` AFTER
        // the original declare-time sheet has long since closed.
        t = t.addingTimeInterval(60)
        try services.updateLossDataDisposition(id: declaration.id, disposition: .delete, asOf: t)

        XCTAssertTrue(try services.pregnancyRecords.history(originalId: lostOriginalId).isEmpty,
                      "the revisited journey's data is really gone")
        XCTAssertTrue(try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: lostOriginalId).isEmpty)

        XCTAssertFalse(try services.pregnancyRecords.history(originalId: newOriginalId).isEmpty,
                       "a DIFFERENT, still-live journey must be completely untouched by a scoped delete")
        XCTAssertNotNil(try services.dueDateEstimates.latestEstimate(pregnancyRecordOriginalId: newOriginalId))
        XCTAssertEqual(try services.liveJourney()?.originalId, newOriginalId)
    }

    func testUpdateLossDataDispositionToKeepOrArchiveIsRevisitableInPlaceAndErasesNothing() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginTTC, asOf: env.now())
        let originalId = try XCTUnwrap(try services.liveJourney()?.originalId)
        let declaration = try await services.declareLoss(
            approximateDate: env.now(), dataDisposition: .keep, asOf: env.now())

        try services.updateLossDataDisposition(id: declaration.id, disposition: .archive, asOf: env.now())

        let live = try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: originalId)
        XCTAssertEqual(live.map(\.dataDisposition), [.archive])
        XCTAssertFalse(try services.pregnancyRecords.history(originalId: originalId).isEmpty)
    }

    // MARK: - purgeJourneyData (scoped) — the real "Delete" data-disposition erasure

    func testPurgeJourneyDataOnlyAffectsTheScopedJourneyLeavingOtherLiveJourneysAndUnrelatedSensitiveDataUntouched() async throws {
        let services = PregnancyModuleServices(env: env)
        var t = env.now()
        try services.beginJourney(.beginTTC, asOf: t)
        let originalIdA = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        _ = try await services.declareLoss(approximateDate: t, dataDisposition: .keep, asOf: t)

        t = t.addingTimeInterval(60)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: t)
        let originalIdB = try XCTUnwrap(try services.liveJourney()?.originalId)
        t = t.addingTimeInterval(60)
        try services.recordDueDateSource(sourceType: .lmpBased, enteredDate: t, asOf: t)

        let now = env.now()
        let journalEntry = JournalEntry(
            id: ULID.newID(), behaviorId: "caffeine", valueKind: .boolean, occurredAt: now, tzId: "UTC",
            provenance: Provenance(sourceId: "dev", deviceId: "dev", ingestionPath: .manual, measuredAt: now,
                                  measuredTimezone: "UTC", recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: "dev")
        try env.journal.insertEntry(journalEntry)

        try services.purgeJourneyData(originalId: originalIdA)

        XCTAssertTrue(try services.pregnancyRecords.history(originalId: originalIdA).isEmpty)
        XCTAssertTrue(try services.lossDeclarations.liveDeclarations(pregnancyRecordOriginalId: originalIdA).isEmpty)

        XCTAssertFalse(try services.pregnancyRecords.history(originalId: originalIdB).isEmpty,
                       "a DIFFERENT journey must be completely untouched by a scoped purge")
        XCTAssertNotNil(try services.dueDateEstimates.latestEstimate(pregnancyRecordOriginalId: originalIdB))
        XCTAssertEqual(try env.journal.allEntries().count, 1,
                       "unrelated sensitive data must survive a scoped purge untouched")
    }

    // MARK: - purgePregnancyData

    func testPurgePregnancyDataEmptiesAllFourTablesAndLeavesUnrelatedSensitiveDataUntouched() async throws {
        let services = PregnancyModuleServices(env: env)
        try services.beginJourney(.beginPregnancyConfirmed, asOf: env.now())
        try services.recordDueDateSource(sourceType: .lmpBased, enteredDate: env.now(), asOf: env.now())
        _ = try await services.declareLoss(approximateDate: env.now(), dataDisposition: .keep, asOf: env.now())

        for table in ["pregnancy_records", "due_date_source_entries", "due_date_estimates",
                      "loss_declaration_records"] {
            XCTAssertGreaterThan(try rowCount(env.database.sensitive, table: table), 0,
                                 "\(table) must be non-empty before purge for this test to be meaningful")
        }

        // Unrelated sensitive data (a journal entry, sharing the SAME sensitive database file) —
        // must survive a pregnancy-only purge completely untouched.
        let now = env.now()
        let journalEntry = JournalEntry(
            id: ULID.newID(), behaviorId: "caffeine", valueKind: .boolean, occurredAt: now, tzId: "UTC",
            provenance: Provenance(sourceId: "dev", deviceId: "dev", ingestionPath: .manual, measuredAt: now,
                                  measuredTimezone: "UTC", recordedAt: now, ingestedAt: now),
            updatedAt: now, originDeviceId: "dev")
        try env.journal.insertEntry(journalEntry)

        try services.purgePregnancyData()

        for table in ["pregnancy_records", "due_date_source_entries", "due_date_estimates",
                      "loss_declaration_records"] {
            XCTAssertEqual(try rowCount(env.database.sensitive, table: table), 0,
                          "\(table) must be fully emptied by purgePregnancyData()")
        }
        XCTAssertEqual(try env.journal.allEntries().count, 1,
                       "unrelated sensitive data (the journal) must survive a pregnancy-only purge untouched")
        XCTAssertNil(try services.liveJourney())
    }
}
