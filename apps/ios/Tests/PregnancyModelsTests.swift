import Foundation
import XCTest
@testable import BADAN

/// A18/ADR-0010/D-25 (EPIC-40, pregnancy module P0 slice): the pregnancy entity set's storage
/// round-trips through the four repositories, the I7 sensitive-namespace placement/purge contract,
/// and the `PregnancyRecord` append-first revision chain's pure live-view rule — mirrors
/// `CycleModelsTests`'s own structure and coverage for its sibling module.
final class PregnancyModelsTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-pregnancy-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func recordRepo() -> PregnancyRecordRepository { PregnancyRecordRepository(sensitive: db.sensitive) }
    private func sourceRepo() -> DueDateSourceEntryRepository { DueDateSourceEntryRepository(sensitive: db.sensitive) }
    private func estimateRepo() -> DueDateEstimateRepository { DueDateEstimateRepository(sensitive: db.sensitive) }
    private func lossRepo() -> LossDeclarationRecordRepository { LossDeclarationRecordRepository(sensitive: db.sensitive) }

    private func provenance(measuredAt: Date, tzId: String = "UTC") -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: tzId, recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func makeRecord(id: String, mode: PregnancyJourneyMode = .ttc, originalId: String? = nil,
                            supersedes: String? = nil, revision: Int = 1) -> PregnancyRecord {
        PregnancyRecord(id: id, mode: mode, originalId: originalId ?? id, supersedes: supersedes,
                        revision: revision, provenance: provenance(measuredAt: clock.now()),
                        updatedAt: clock.now(), originDeviceId: device)
    }

    // MARK: - PregnancyRecord round trip + append-first revision chain

    func testPregnancyRecordRoundTripThroughRepository() throws {
        try recordRepo().insertRecord(makeRecord(id: "PREG-1", mode: .ttc))

        let live = try recordRepo().liveRecords()
        XCTAssertEqual(live.map(\.id), ["PREG-1"])
        XCTAssertEqual(live[0].mode, .ttc)
        XCTAssertEqual(live[0].provenance.ingestionPath, .manual, "I1: a declared journey is still provenanced")

        let fetched = try XCTUnwrap(try recordRepo().record(id: "PREG-1"))
        XCTAssertEqual(fetched.originalId, "PREG-1")
        XCTAssertTrue(fetched.isOriginal)
    }

    func testPregnancyRecordRevisionSupersedesOriginalInLiveViewAndHistorySurvives() throws {
        try recordRepo().insertRecord(makeRecord(id: "PREG-2", mode: .ttc))
        clock.advance(by: 3_600)
        let revision = makeRecord(id: "PREG-2-R2", mode: .pregnancyConfirmed, originalId: "PREG-2",
                                  supersedes: "PREG-2", revision: 2)
        try recordRepo().insertRecord(revision)

        XCTAssertEqual(try recordRepo().liveRecords().map(\.id), ["PREG-2-R2"],
                       "the revision supersedes the original in every live read")
        XCTAssertEqual(try recordRepo().history(originalId: "PREG-2").map(\.id), ["PREG-2", "PREG-2-R2"],
                       "the full audit chain still returns both rows — I2: nothing is ever deleted or mutated")
        XCTAssertEqual(try recordRepo().history(originalId: "PREG-2").map(\.mode), [.ttc, .pregnancyConfirmed],
                       "the ORIGINAL row's mode is untouched by the later revision")
        XCTAssertEqual(try recordRepo().liveRecord(originalId: "PREG-2")?.mode, .pregnancyConfirmed)
    }

    // MARK: - PregnancyRecordLedger (pure, storage-free)

    func testPregnancyRecordLedgerLiveRecordsExcludesSupersededAndTombstonedRows() {
        let original = makeRecord(id: "X-1")
        let revision = PregnancyRecord(id: "X-2", mode: .pregnancyConfirmed, originalId: "X-1",
                                       supersedes: "X-1", revision: 2, provenance: original.provenance,
                                       updatedAt: clock.now(), originDeviceId: device)
        var deleted = makeRecord(id: "Y-1")
        deleted.deletedAt = clock.now()

        let live = PregnancyRecordLedger.liveRecords([original, revision, deleted])
        XCTAssertEqual(Set(live.map(\.id)), Set(["X-2"]),
                       "the superseded original and the tombstoned row are both excluded")
    }

    // MARK: - DueDateSourceEntry round trip (append-only per type)

    func testDueDateSourceEntryRoundTripAndCurrentEntriesByTypePicksMostRecentPerType() throws {
        let entry1 = DueDateSourceEntry(id: "DDS-1", pregnancyRecordOriginalId: "J-1", sourceType: .lmpBased,
                                        enteredDate: clock.now(), provenance: provenance(measuredAt: clock.now()),
                                        updatedAt: clock.now(), originDeviceId: device)
        try sourceRepo().insertEntry(entry1)
        clock.advance(by: 3_600)
        // A correction: a fresh row for the SAME type, never an UPDATE.
        let entry2 = DueDateSourceEntry(id: "DDS-2", pregnancyRecordOriginalId: "J-1", sourceType: .lmpBased,
                                        enteredDate: clock.now(), provenance: provenance(measuredAt: clock.now()),
                                        updatedAt: clock.now(), originDeviceId: device)
        try sourceRepo().insertEntry(entry2)

        let history = try sourceRepo().history(pregnancyRecordOriginalId: "J-1")
        XCTAssertEqual(history.map(\.id), ["DDS-1", "DDS-2"], "both rows survive — append-only, never overwritten")

        let current = try sourceRepo().currentEntriesByType(pregnancyRecordOriginalId: "J-1")
        XCTAssertEqual(current[.lmpBased]?.id, "DDS-2", "the most recently recorded live row per type wins")
    }

    // MARK: - DueDateEstimate: append-only, latest wins, range-not-a-date

    func testDueDateEstimateAppendOnlyLatestWins() throws {
        let first = DueDateEstimate(id: "EST-1", pregnancyRecordOriginalId: "J-1", generatedAt: clock.now(),
                                    rangeLow: clock.now(), rangeCenter: clock.now(), rangeHigh: clock.now(),
                                    resolvedSourceType: .lmpBased, confidence: 0.3, algorithmVersion: "1.0.0",
                                    updatedAt: clock.now(), originDeviceId: device)
        try estimateRepo().appendEstimate(first)
        clock.advance(by: 86_400)
        let second = DueDateEstimate(id: "EST-2", pregnancyRecordOriginalId: "J-1", generatedAt: clock.now(),
                                     rangeLow: clock.now(), rangeCenter: clock.now(), rangeHigh: clock.now(),
                                     resolvedSourceType: .providerGiven, confidence: 0.5, algorithmVersion: "1.0.0",
                                     updatedAt: clock.now(), originDeviceId: device)
        try estimateRepo().appendEstimate(second)

        let latest = try XCTUnwrap(try estimateRepo().latestEstimate(pregnancyRecordOriginalId: "J-1"))
        XCTAssertEqual(latest.id, "EST-2", "the newest estimate wins on read")
        XCTAssertEqual(latest.resolvedSourceType, .providerGiven)
    }

    // MARK: - LossDeclarationRecord round trip + independently revisitable/deletable

    func testLossDeclarationRecordRoundTripAndDataDispositionIsRevisitableInPlace() throws {
        let declaration = LossDeclarationRecord(
            id: "LOSS-1", pregnancyRecordOriginalId: "J-1", declaredAt: clock.now(),
            approximateDate: clock.now(), dataDisposition: .keep,
            provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(), originDeviceId: device)
        try lossRepo().insertDeclaration(declaration)

        var live = try lossRepo().liveDeclarations(pregnancyRecordOriginalId: "J-1")
        XCTAssertEqual(live.map(\.id), ["LOSS-1"])
        XCTAssertEqual(live[0].dataDisposition, .keep)
        XCTAssertNil(live[0].gestationalStage, "minimum fields only — never a required cause/explanation")

        clock.advance(by: 3_600)
        try lossRepo().updateDataDisposition(id: "LOSS-1", disposition: .archive, at: clock.now())
        live = try lossRepo().liveDeclarations(pregnancyRecordOriginalId: "J-1")
        XCTAssertEqual(live[0].dataDisposition, .archive, "revisitable later, not a one-time forced decision")
        XCTAssertEqual(live[0].approximateDate, declaration.approximateDate,
                       "every other field of the declaration stays frozen")
    }

    func testLossDeclarationRecordIsIndependentlyDeletableWithoutTouchingThePregnancyRecordChain() throws {
        try recordRepo().insertRecord(makeRecord(id: "J-2", mode: .lossDeclared))
        let declaration = LossDeclarationRecord(
            id: "LOSS-2", pregnancyRecordOriginalId: "J-2", declaredAt: clock.now(),
            approximateDate: clock.now(), dataDisposition: .delete,
            provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(), originDeviceId: device)
        try lossRepo().insertDeclaration(declaration)

        try lossRepo().deleteRecord(id: "LOSS-2", at: clock.now())

        XCTAssertTrue(try lossRepo().liveDeclarations(pregnancyRecordOriginalId: "J-2").isEmpty)
        XCTAssertNotNil(try recordRepo().liveRecord(originalId: "J-2"),
                        "deleting the loss declaration must NEVER delete or alter the PregnancyRecord chain")
        XCTAssertEqual(try recordRepo().liveRecord(originalId: "J-2")?.mode, .lossDeclared)
    }

    // MARK: - I7: sensitive-namespace placement + purge

    func testPregnancyTablesExistOnlyInTheSensitiveDatabase() throws {
        for table in ["pregnancy_records", "due_date_source_entries", "due_date_estimates",
                     "loss_declaration_records"] {
            let inMain = try db.main.query(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';")
                .first?.int("c") ?? 0
            XCTAssertEqual(inMain, 0, "\(table) is sensitive-plus (I7) and must not exist in badan.db")
            let inSensitive = try db.sensitive.query(
                "SELECT COUNT(*) AS c FROM sqlite_master WHERE type='table' AND name='\(table)';")
                .first?.int("c") ?? 0
            XCTAssertEqual(inSensitive, 1, "\(table) must live in badan_sensitive.db")
        }
    }

    func testSensitivePurgeRemovesEveryPregnancyTable() throws {
        try recordRepo().insertRecord(makeRecord(id: "PURGE-REC"))
        try sourceRepo().insertEntry(DueDateSourceEntry(
            id: "PURGE-DDS", pregnancyRecordOriginalId: "PURGE-REC", sourceType: .lmpBased,
            enteredDate: clock.now(), provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(),
            originDeviceId: device))
        try estimateRepo().appendEstimate(DueDateEstimate(
            id: "PURGE-EST", pregnancyRecordOriginalId: "PURGE-REC", generatedAt: clock.now(), confidence: 0,
            algorithmVersion: "1.0.0", updatedAt: clock.now(), originDeviceId: device))
        try lossRepo().insertDeclaration(LossDeclarationRecord(
            id: "PURGE-LOSS", pregnancyRecordOriginalId: "PURGE-REC", declaredAt: clock.now(),
            approximateDate: clock.now(), dataDisposition: .keep,
            provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(), originDeviceId: device))

        try db.purgeSensitiveNamespace()

        XCTAssertTrue(try recordRepo().liveRecords().isEmpty, "I7: a purge is a file deletion — nothing survives")
        XCTAssertTrue(try sourceRepo().history(pregnancyRecordOriginalId: "PURGE-REC").isEmpty)
        XCTAssertNil(try estimateRepo().latestEstimate(pregnancyRecordOriginalId: "PURGE-REC"))
        XCTAssertTrue(try lossRepo().liveDeclarations(pregnancyRecordOriginalId: "PURGE-REC").isEmpty)
    }

    // MARK: - PREG-03: content shell (versioned container + mandatory disclaimer)

    func testContentBundleBuiltInIsAnEmptyShellNeverRealClinicalContent() {
        XCTAssertTrue(PregnancyContentBundle.builtIn.entries.isEmpty,
                     "P0 ships no real week-by-week/milestone content — only a later, D-21-gated " +
                     "slice may populate this")
        XCTAssertTrue(PregnancyContentBundle.builtIn.schemaVersion.hasSuffix("-shell"),
                     "the version identity must make clear this is not a reviewed, ship-ready content version")
    }

    func testContentDisclaimerIsPresentInBothLanguagesAndCarriesNoDynamicTokens() {
        for text in [PregnancyContentDisclaimer.footer.en, PregnancyContentDisclaimer.footer.ar] {
            XCTAssertFalse(text.isEmpty, "the mandatory disclaimer must exist in both languages")
            XCTAssertFalse(text.contains("{"), "must never interpolate dynamic data")
            XCTAssertFalse(text.contains("}"))
        }
    }
}
