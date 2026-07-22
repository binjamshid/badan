import Foundation
import XCTest
@testable import BADAN

/// EPIC-39 CYCLE-01 (Phase 3F slice 1): the cycle-intelligence entity set's storage round-trips
/// through the six repositories, the I7 sensitive-namespace placement/purge contract, and the
/// `CycleRecord` append-first revision chain's pure live-view rule.
final class CycleModelsTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
    private let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-cycle-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func recordRepo() -> CycleRecordRepository { CycleRecordRepository(sensitive: db.sensitive) }
    private func flowRepo() -> FlowLogRepository { FlowLogRepository(sensitive: db.sensitive) }
    private func contextRepo() -> ContraceptiveContextRepository { ContraceptiveContextRepository(sensitive: db.sensitive) }
    private func predictionRepo() -> CyclePredictionRepository { CyclePredictionRepository(sensitive: db.sensitive) }
    private func phaseRepo() -> CyclePhaseEstimateRepository { CyclePhaseEstimateRepository(sensitive: db.sensitive) }
    private func anomalyRepo() -> CycleAnomalyEventRepository { CycleAnomalyEventRepository(sensitive: db.sensitive) }

    private func provenance(measuredAt: Date, tzId: String = "UTC") -> Provenance {
        Provenance(sourceId: device, deviceId: device, ingestionPath: .manual, measuredAt: measuredAt,
                  measuredTimezone: tzId, recordedAt: measuredAt, ingestedAt: measuredAt)
    }

    private func makeRecord(id: String, startAt: Date? = nil, endAt: Date? = nil, ongoing: Bool = false,
                            originalId: String? = nil, supersedes: String? = nil, revision: Int = 1) -> CycleRecord {
        CycleRecord(id: id, startAt: startAt ?? clock.now(), endAt: endAt, ongoing: ongoing,
                   originalId: originalId ?? id, supersedes: supersedes, revision: revision,
                   provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(), originDeviceId: device)
    }

    private func makeFlowLog(id: String, cycleId: String = "CYC-1", occurredAt: Date? = nil,
                             originalLabel: String = "medium", normalizedIntensity: Double = 0.5) -> FlowLog {
        FlowLog(id: id, cycleId: cycleId, occurredAt: occurredAt ?? clock.now(), originalLabel: originalLabel,
               normalizedIntensity: normalizedIntensity, provenance: provenance(measuredAt: clock.now()),
               updatedAt: clock.now(), originDeviceId: device)
    }

    private func makeContext(id: String, startAt: Date? = nil, endAt: Date? = nil) -> ContraceptiveContextLog {
        ContraceptiveContextLog(id: id, methodType: .pill, startAt: startAt ?? clock.now(), endAt: endAt,
                                provenance: provenance(measuredAt: clock.now()), updatedAt: clock.now(),
                                originDeviceId: device)
    }

    // MARK: - CycleRecord round trip + append-first revision chain

    func testCycleRecordRoundTripThroughRepository() throws {
        try recordRepo().insertRecord(makeRecord(id: "REC-1", ongoing: true))

        let live = try recordRepo().liveRecords()
        XCTAssertEqual(live.map(\.id), ["REC-1"])
        XCTAssertTrue(live[0].ongoing)
        XCTAssertNil(live[0].endAt)
        XCTAssertEqual(live[0].provenance.ingestionPath, .manual, "I1: a manual period entry is still provenanced")

        let fetched = try XCTUnwrap(try recordRepo().record(id: "REC-1"))
        XCTAssertEqual(fetched.originalId, "REC-1")
        XCTAssertTrue(fetched.isOriginal)
    }

    func testCycleRecordRevisionSupersedesOriginalInLiveView() throws {
        try recordRepo().insertRecord(makeRecord(id: "REC-2", endAt: clock.now().addingTimeInterval(4 * 86_400),
                                                 ongoing: false))
        clock.advance(by: 3_600)
        let revision = makeRecord(id: "REC-2-R2", originalId: "REC-2", supersedes: "REC-2", revision: 2)
        try recordRepo().insertRecord(revision)

        XCTAssertEqual(try recordRepo().liveRecords().map(\.id), ["REC-2-R2"],
                       "the revision supersedes the original in every live read")
        XCTAssertEqual(try recordRepo().history(originalId: "REC-2").map(\.id), ["REC-2", "REC-2-R2"],
                       "the full audit chain still returns both rows")
        XCTAssertEqual(try recordRepo().liveRecord(originalId: "REC-2")?.id, "REC-2-R2")
    }

    func testCycleRecordDeleteChainTombstonesWholeChainButHistorySurvives() throws {
        try recordRepo().insertRecord(makeRecord(id: "REC-3"))
        try recordRepo().deleteChain(originalId: "REC-3", at: clock.now())

        XCTAssertTrue(try recordRepo().liveRecords().isEmpty)
        XCTAssertEqual(try recordRepo().history(originalId: "REC-3").count, 1,
                       "a tombstone is not a hard delete — the row stays for the audit chain")
        XCTAssertNotNil(try recordRepo().record(id: "REC-3")?.deletedAt)
    }

    // MARK: - CycleRecordLedger (pure, storage-free)

    func testCycleRecordLedgerLiveRecordsExcludesSupersededAndTombstonedRows() {
        let original = makeRecord(id: "X-1")
        let revision = CycleRecord(id: "X-2", startAt: original.startAt, ongoing: false,
                                   originalId: "X-1", supersedes: "X-1", revision: 2,
                                   provenance: original.provenance, updatedAt: clock.now(),
                                   originDeviceId: device)
        var deleted = makeRecord(id: "Y-1")
        deleted.deletedAt = clock.now()

        let live = CycleRecordLedger.liveRecords([original, revision, deleted])
        XCTAssertEqual(Set(live.map(\.id)), Set(["X-2"]),
                       "the superseded original and the tombstoned row are both excluded")
    }

    // MARK: - FlowLog round trip

    func testFlowLogRoundTripThroughRepository() throws {
        try flowRepo().insert(makeFlowLog(id: "FL-1", occurredAt: clock.now()))
        clock.advance(by: 3_600)
        try flowRepo().insert(makeFlowLog(id: "FL-2", occurredAt: clock.now(), originalLabel: "spotting",
                                          normalizedIntensity: 0.1))

        let logs = try flowRepo().liveLogs(cycleId: "CYC-1")
        XCTAssertEqual(logs.map(\.id), ["FL-1", "FL-2"], "logged order, oldest first")
        XCTAssertEqual(logs[1].originalLabel, "spotting", "source wording is preserved verbatim")
        XCTAssertEqual(logs[1].normalizedIntensity, 0.1)

        XCTAssertTrue(try flowRepo().liveLogs(cycleId: "CYC-OTHER").isEmpty)
    }

    // MARK: - ContraceptiveContextLog round trip + activeContext

    func testContraceptiveContextRoundTripAndActiveContext() throws {
        try contextRepo().insert(makeContext(id: "CTX-1"))

        XCTAssertEqual(try contextRepo().liveContexts().map(\.id), ["CTX-1"])
        let active = try XCTUnwrap(try contextRepo().activeContext())
        XCTAssertEqual(active.id, "CTX-1")
        XCTAssertTrue(active.isActive)

        // Closing the context re-inserts the SAME id with endAt now set — a change in place, not a
        // new logical row (mirrors ContextStatus's "the interval is one fact" reasoning).
        try contextRepo().insert(makeContext(id: "CTX-1", endAt: clock.now()))
        XCTAssertNil(try contextRepo().activeContext(), "no context is active once the only one is closed")
        XCTAssertEqual(try contextRepo().liveContexts().count, 1, "closing is an update in place, not a new row")
    }

    func testContraceptiveContextActiveContextDegradesGracefullyWithMultipleMalformedActiveRows() throws {
        try contextRepo().insert(makeContext(id: "CTX-A", startAt: clock.now()))
        clock.advance(by: 86_400)
        try contextRepo().insert(makeContext(id: "CTX-B", startAt: clock.now()))

        // Malformed state (two simultaneously-active contexts) must not crash — it returns the
        // most recently started one.
        let active = try XCTUnwrap(try contextRepo().activeContext())
        XCTAssertEqual(active.id, "CTX-B")
    }

    // MARK: - CyclePrediction: append-only, latest wins, range-not-a-date

    func testCyclePredictionAppendOnlyLatestWins() throws {
        let first = CyclePrediction(id: "PRED-1", generatedAt: clock.now(),
                                    predictedNextStartLow: clock.now().addingTimeInterval(26 * 86_400),
                                    predictedNextStartCenter: clock.now().addingTimeInterval(28 * 86_400),
                                    predictedNextStartHigh: clock.now().addingTimeInterval(31 * 86_400),
                                    confidence: 0.35, method: .lowHistory, algorithmVersion: "1.0.0",
                                    inputCycleIds: ["REC-1"], updatedAt: clock.now(), originDeviceId: device)
        try predictionRepo().appendPrediction(first)
        clock.advance(by: 86_400)
        let second = CyclePrediction(id: "PRED-2", generatedAt: clock.now(),
                                     predictedNextStartLow: clock.now().addingTimeInterval(25 * 86_400),
                                     predictedNextStartCenter: clock.now().addingTimeInterval(28 * 86_400),
                                     predictedNextStartHigh: clock.now().addingTimeInterval(30 * 86_400),
                                     confidence: 0.6, method: .moderateHistory, algorithmVersion: "1.0.0",
                                     inputCycleIds: ["REC-1", "REC-2"], updatedAt: clock.now(), originDeviceId: device)
        try predictionRepo().appendPrediction(second)

        let latest = try XCTUnwrap(try predictionRepo().latestPrediction())
        XCTAssertEqual(latest.id, "PRED-2", "the newest forecast wins on read")
        XCTAssertEqual(latest.inputCycleIds, ["REC-1", "REC-2"], "the input manifest round-trips through JSON")
        XCTAssertNotNil(latest.predictedNextStartLow)
        XCTAssertNotNil(latest.predictedNextStartCenter)
        XCTAssertNotNil(latest.predictedNextStartHigh)
    }

    func testCyclePredictionPausedStatusCarriesASuppressionReason() throws {
        let paused = CyclePrediction(id: "PRED-PAUSED", generatedAt: clock.now(), confidence: 0,
                                     method: .coldStart, status: .paused,
                                     suppressionReason: "paused while an active contraceptive context is logged",
                                     algorithmVersion: "1.0.0", updatedAt: clock.now(), originDeviceId: device)
        try predictionRepo().appendPrediction(paused)

        let latest = try XCTUnwrap(try predictionRepo().latestPrediction())
        XCTAssertEqual(latest.status, .paused)
        XCTAssertNotNil(latest.suppressionReason)
        XCTAssertNil(latest.predictedNextStartLow, "a paused forecast states no range rather than guessing one")
    }

    // MARK: - CyclePhaseEstimate: append-only, window lookup + fallback

    func testCyclePhaseEstimateLatestAsOfWindowAndFallback() throws {
        let base = clock.now()
        let first = CyclePhaseEstimate(id: "PH-1", dateRangeStart: base, dateRangeEnd: base.addingTimeInterval(4 * 86_400),
                                       phase: .menstrual, confidence: 0.8, evidenceBasis: .calendarOnly,
                                       algorithmVersion: "1.0.0", computedAt: base, updatedAt: base, originDeviceId: device)
        try phaseRepo().appendEstimate(first)
        clock.advance(by: 5 * 86_400)
        let second = CyclePhaseEstimate(id: "PH-2", dateRangeStart: base.addingTimeInterval(5 * 86_400),
                                        dateRangeEnd: base.addingTimeInterval(9 * 86_400), phase: .follicular,
                                        confidence: 0.7, evidenceBasis: .calendarOnly, algorithmVersion: "1.0.0",
                                        computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: device)
        try phaseRepo().appendEstimate(second)

        let withinFirst = try XCTUnwrap(try phaseRepo().latestEstimate(asOf: base.addingTimeInterval(86_400)))
        XCTAssertEqual(withinFirst.id, "PH-1")

        let withinSecond = try XCTUnwrap(try phaseRepo().latestEstimate(asOf: base.addingTimeInterval(6 * 86_400)))
        XCTAssertEqual(withinSecond.id, "PH-2")

        // Outside every window — falls back to the overall most recent live estimate rather than nil.
        let fallback = try XCTUnwrap(try phaseRepo().latestEstimate(asOf: base.addingTimeInterval(100 * 86_400)))
        XCTAssertEqual(fallback.id, "PH-2")
    }

    // MARK: - CycleAnomalyEvent: append-only creation, message-key-only, state transitions

    func testCycleAnomalyEventAppendOnlyAndUpdateStateTransitionsOnlyState() throws {
        let event = CycleAnomalyEvent(id: "ANOM-1", type: .cycleLengthDeviation, detectedAt: clock.now(),
                                      basisWindowCycleIds: ["REC-1", "REC-2"], severity: .low,
                                      messageKey: "cycle.anomaly.cycle_length_deviation.v1",
                                      algorithmVersion: "1.0.0", confidence: 0.5, updatedAt: clock.now(),
                                      originDeviceId: device)
        try anomalyRepo().appendEvent(event)

        var events = try anomalyRepo().liveEvents()
        XCTAssertEqual(events.map(\.id), ["ANOM-1"])
        XCTAssertEqual(events[0].state, .active)
        XCTAssertEqual(events[0].basisWindowCycleIds, ["REC-1", "REC-2"])
        XCTAssertFalse(events[0].messageKey.isEmpty, "copy is looked up from this key, never stored inline")

        clock.advance(by: 3_600)
        try anomalyRepo().updateState(id: "ANOM-1", state: .acknowledged, at: clock.now())

        events = try anomalyRepo().liveEvents()
        XCTAssertEqual(events[0].state, .acknowledged)
        XCTAssertEqual(events[0].type, .cycleLengthDeviation, "the detection fact itself is never rewritten")
        XCTAssertEqual(events[0].messageKey, "cycle.anomaly.cycle_length_deviation.v1")
        XCTAssertEqual(events[0].severity, .low)
    }

    // MARK: - I7: sensitive-namespace placement + purge

    func testCycleTablesExistOnlyInTheSensitiveDatabase() throws {
        for table in ["cycle_records", "flow_logs", "contraceptive_context_logs", "cycle_predictions",
                     "cycle_phase_estimates", "cycle_anomaly_events"] {
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

    func testSensitivePurgeRemovesEveryCycleTable() throws {
        try recordRepo().insertRecord(makeRecord(id: "PURGE-REC"))
        try flowRepo().insert(makeFlowLog(id: "PURGE-FL", cycleId: "PURGE-REC"))
        try contextRepo().insert(makeContext(id: "PURGE-CTX"))
        try predictionRepo().appendPrediction(CyclePrediction(id: "PURGE-PRED", generatedAt: clock.now(),
                                                              confidence: 0.5, method: .coldStart,
                                                              algorithmVersion: "1.0.0", updatedAt: clock.now(),
                                                              originDeviceId: device))
        try phaseRepo().appendEstimate(CyclePhaseEstimate(id: "PURGE-PH", dateRangeStart: clock.now(),
                                                          dateRangeEnd: clock.now().addingTimeInterval(86_400),
                                                          phase: .unknown, confidence: 0, evidenceBasis: .insufficientHistory,
                                                          algorithmVersion: "1.0.0", computedAt: clock.now(),
                                                          updatedAt: clock.now(), originDeviceId: device))
        try anomalyRepo().appendEvent(CycleAnomalyEvent(id: "PURGE-ANOM", type: .missedExpectedPeriod,
                                                        detectedAt: clock.now(), severity: .low,
                                                        messageKey: "cycle.anomaly.missed_expected_period.v1",
                                                        algorithmVersion: "1.0.0", confidence: 0.5,
                                                        updatedAt: clock.now(), originDeviceId: device))

        try db.purgeSensitiveNamespace()

        XCTAssertTrue(try recordRepo().liveRecords().isEmpty, "I7: a purge is a file deletion — nothing survives")
        XCTAssertTrue(try flowRepo().liveLogs(cycleId: "PURGE-REC").isEmpty)
        XCTAssertTrue(try contextRepo().liveContexts().isEmpty)
        XCTAssertNil(try predictionRepo().latestPrediction())
        XCTAssertNil(try phaseRepo().latestEstimate(asOf: clock.now()))
        XCTAssertTrue(try anomalyRepo().liveEvents().isEmpty)
    }
}
