import XCTest
@testable import BADAN

/// EPIC-43 debt closeout: a person can settle a `DataConflict` that no automatic rule decides.
///
/// Before this, `IngestionPipeline.reconcileMetricConflicts` could open a real unresolved conflict
/// and `DataConflictsScreen` could only list it — a dead end. These tests exercise the whole path
/// (open conflict → user picks → losers suppressed, decision journaled, conflict marked resolved),
/// plus the parts that are easy to get subtly wrong: the rule id must not impersonate an engine
/// rule, and choosing a row that an earlier automatic decision had suppressed must actually
/// un-suppress it rather than settling the conflict on a reading that stays hidden.
final class ConflictResolutionTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-conflict-resolve-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private var measurements: MeasurementRepository { MeasurementRepository(db.main, sensitive: db.sensitive) }
    private var reconciliation: ReconciliationRepository { ReconciliationRepository(db.main) }
    private var dataConflicts: DataConflictRepository { DataConflictRepository(main: db.main) }

    private func sample(id: String, sourceId: String, value: Double, manual: Bool = false) -> RawSample {
        RawSample(id: id, metricId: MetricID.restingHeartRate, value: value, unit: "bpm",
                  originalValue: value, originalUnit: "bpm",
                  startAt: clock.now(), endAt: nil, tzId: "Asia/Muscat",
                  provenance: Provenance(sourceId: sourceId,
                                         ingestionPath: manual ? .manual : .platformStore,
                                         externalId: id, measuredAt: clock.now(),
                                         measuredTimezone: "Asia/Muscat",
                                         recordedAt: clock.now(), ingestedAt: clock.now()),
                  updatedAt: clock.now(), originDeviceId: "dev", deletedAt: nil)
    }

    /// Writes two disagreeing readings plus the open conflict that names them.
    @discardableResult
    private func openConflict() throws -> (conflict: DataConflict, candidates: [ConflictResolutionService.Candidate]) {
        try measurements.upsertRawSample(sample(id: "rec-a", sourceId: "watch", value: 58))
        try measurements.upsertRawSample(sample(id: "rec-b", sourceId: "strap", value: 71))
        let conflict = DataConflict(
            id: "conflict-1", scope: .metric(id: MetricID.restingHeartRate),
            windowStart: clock.now().addingTimeInterval(-86_400), windowEnd: clock.now(),
            candidateRecordIds: ["rec-a", "rec-b"], detectedAt: clock.now(), updatedAt: clock.now(),
            originDeviceId: "dev")
        try dataConflicts.insert(conflict)
        let candidates = try ConflictResolutionService.candidates(
            for: conflict, table: "raw_samples", measurements: measurements,
            sourceNames: ["watch": "Apple Watch", "strap": "Polar H10"])
        return (conflict, candidates)
    }

    // MARK: - The domain rule

    /// A user's choice must never claim an engine rule decided it — "why am I seeing this value?"
    /// would otherwise explain the reading with a rule that was never consulted.
    func testUserChoiceCarriesItsOwnRuleIdNotAnEngineRule() throws {
        let readings = [
            CandidateReading(id: "a", sourceId: "watch", classification: "", isManualEntry: false, measuredAt: clock.now()),
            CandidateReading(id: "b", sourceId: "strap", classification: "", isManualEntry: false, measuredAt: clock.now()),
        ]

        let outcome = try XCTUnwrap(ConflictResolution.resolve(
            scope: .metric(id: MetricID.restingHeartRate), candidates: readings, winnerId: "b"))

        XCTAssertEqual(outcome.ruleId, ConflictResolution.userChoiceRuleId)
        XCTAssertNotEqual(outcome.ruleId, ConflictDecisionEngine.priorityOrderRuleId)
        XCTAssertNotEqual(outcome.ruleId, ConflictDecisionEngine.manualWinsRuleId)
        XCTAssertEqual(outcome.winnerId, "b")
        XCTAssertEqual(outcome.loserIds, ["a"])
        XCTAssertEqual(outcome.detail["winner_source"], "strap")
        XCTAssertEqual(outcome.detail["loser_source"], "watch")
    }

    /// Fails closed on a pick that isn't real, rather than journaling suppressions on the strength
    /// of an id nobody verified.
    func testResolveRejectsAnUnknownWinnerId() {
        let readings = [
            CandidateReading(id: "a", sourceId: "watch", classification: "", isManualEntry: false, measuredAt: clock.now()),
            CandidateReading(id: "b", sourceId: "strap", classification: "", isManualEntry: false, measuredAt: clock.now()),
        ]
        XCTAssertNil(ConflictResolution.resolve(scope: .metric(id: MetricID.restingHeartRate),
                                                candidates: readings, winnerId: "not-a-candidate"))
        XCTAssertNil(ConflictResolution.resolve(scope: .metric(id: MetricID.restingHeartRate),
                                                candidates: [readings[0]], winnerId: "a"),
                     "one reading is not a conflict")
    }

    // MARK: - Loading what the person chooses between

    func testCandidatesResolveBackIntoReadableValues() throws {
        let (_, candidates) = try openConflict()

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(Set(candidates.map(\.value)), [58, 71])
        XCTAssertEqual(Set(candidates.map(\.sourceName)), ["Apple Watch", "Polar H10"],
                       "source ids are resolved to display names, not shown raw")
    }

    /// Every metric the ingestion detector can open a conflict for must map to the table that
    /// detector actually read it from. Pinned explicitly because the obvious-looking alternative —
    /// deriving the table from the registry's `kind` — is wrong for `heart.rhr`/`heart.hrv`, which
    /// are `kind: derived` yet live in `interval_records`. Getting this wrong yields a resolve
    /// button that silently does nothing, which is worse than no button.
    func testEveryDetectedMetricMapsToTheTableItsConflictsAreWrittenFrom() {
        for metricId in IngestionPipeline.intervalConflictMetrics {
            XCTAssertEqual(ConflictResolutionService.table(for: .metric(id: metricId), registry: .shared),
                           "interval_records", "\(metricId) is detected out of interval_records")
        }
        for metricId in IngestionPipeline.sampleConflictMetrics {
            XCTAssertEqual(ConflictResolutionService.table(for: .metric(id: metricId), registry: .shared),
                           "raw_samples", "\(metricId) is detected out of raw_samples")
        }
        XCTAssertEqual(ConflictResolutionService.table(for: .workoutDuplicate, registry: .shared), "sessions")
        XCTAssertNil(ConflictResolutionService.table(for: .metric(id: "not.a.real.metric"), registry: .shared),
                     "an undetected metric gets no resolve action, rather than a guessed table")
    }

    /// The guard on the above: if someone adds a metric to a detection set without teaching this
    /// service about it, the resolve action goes quietly inert for it. Fail here instead.
    func testNoDetectedMetricIsLeftWithoutATable() {
        for metricId in IngestionPipeline.intervalConflictMetrics.union(IngestionPipeline.sampleConflictMetrics) {
            XCTAssertNotNil(ConflictResolutionService.table(for: .metric(id: metricId), registry: .shared),
                            "\(metricId) can produce a conflict the user would have no way to settle")
        }
    }

    // MARK: - Applying the choice

    func testKeepingOneReadingSuppressesTheOtherAndJournalsIt() throws {
        let (conflict, candidates) = try openConflict()

        let applied = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-b", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)

        XCTAssertTrue(applied)
        let live = try measurements.rawSamples(metricId: MetricID.restingHeartRate)
        XCTAssertEqual(live.map(\.id), ["rec-b"], "only the chosen reading stays live")

        let decision = try XCTUnwrap(reconciliation.forSuppressed("rec-a"))
        XCTAssertEqual(decision.keptRecordId, "rec-b")
        XCTAssertEqual(decision.rule, ConflictResolution.userChoiceRuleId)
        XCTAssertTrue(decision.reversible, "I3: the loser is suppressed, never deleted")
    }

    /// Nothing is deleted — the losing row is still there, just suppressed.
    func testTheLosingReadingIsSuppressedNotDeleted() throws {
        let (conflict, candidates) = try openConflict()

        _ = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-b", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)

        let all = try measurements.rawSamples(metricId: MetricID.restingHeartRate, includeSuppressed: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(try XCTUnwrap(measurements.rawSample(id: "rec-a")).provenance.suppressedBy, "rec-b")
    }

    func testTheConflictIsMarkedResolvedAndLeavesTheUnresolvedList() throws {
        let (conflict, candidates) = try openConflict()
        XCTAssertEqual(try dataConflicts.unresolved().count, 1, "precondition")

        _ = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-a", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)

        XCTAssertTrue(try dataConflicts.unresolved().isEmpty)
        let stored = try XCTUnwrap(dataConflicts.conflict(id: conflict.id))
        XCTAssertEqual(stored.status, .resolved)
        XCTAssertNotNil(stored.resolvedByDecisionId, "resolution points back at the journal row")
    }

    /// The subtle one. An automatic rule suppressed `rec-a`; the person disagrees and keeps it.
    /// If the earlier suppression isn't lifted, the conflict reports itself settled while the
    /// reading the person chose stays hidden from Home, Body, and Metric Detail.
    func testChoosingAPreviouslySuppressedReadingUnsuppressesIt() throws {
        let (conflict, candidates) = try openConflict()
        // An earlier automatic decision picked rec-b and set rec-a aside.
        try measurements.setSuppressed(table: "raw_samples", recordId: "rec-a", by: "rec-b", updatedAt: clock.now())
        try reconciliation.insert(ReconciliationDecision(
            id: "auto-1", batchId: nil, rule: ConflictDecisionEngine.priorityOrderRuleId,
            ruleVersion: "v1", keptRecordId: "rec-b", suppressedRecordId: "rec-a", score: nil,
            reversible: true, decidedAt: clock.now(), detail: [:]))

        _ = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-a", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)

        let live = try measurements.rawSamples(metricId: MetricID.restingHeartRate)
        XCTAssertEqual(live.map(\.id), ["rec-a"],
                       "the reading the person chose must actually become the visible one")
        XCTAssertNotNil(try reconciliation.recent().first { $0.id == "auto-1" }?.reversedAt,
                        "the automatic decision the person overturned is marked reversed, not left standing")
    }

    /// Re-applying the same choice must not journal a second identical suppression.
    func testApplyingTheSameChoiceTwiceIsIdempotent() throws {
        let (conflict, candidates) = try openConflict()
        _ = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-b", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)
        let afterFirst = try reconciliation.recent().count

        _ = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-b", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)

        XCTAssertEqual(try reconciliation.recent().count, afterFirst,
                       "no duplicate journal rows for the same winner/loser pair")
    }

    /// A three-way conflict suppresses BOTH losers, not just one.
    func testAThreeWayConflictSuppressesEveryLoser() throws {
        try measurements.upsertRawSample(sample(id: "rec-a", sourceId: "watch", value: 58))
        try measurements.upsertRawSample(sample(id: "rec-b", sourceId: "strap", value: 71))
        try measurements.upsertRawSample(sample(id: "rec-c", sourceId: "ring", value: 64))
        let conflict = DataConflict(
            id: "conflict-3", scope: .metric(id: MetricID.restingHeartRate),
            windowStart: clock.now().addingTimeInterval(-86_400), windowEnd: clock.now(),
            candidateRecordIds: ["rec-a", "rec-b", "rec-c"], detectedAt: clock.now(),
            updatedAt: clock.now(), originDeviceId: "dev")
        try dataConflicts.insert(conflict)
        let candidates = try ConflictResolutionService.candidates(
            for: conflict, table: "raw_samples", measurements: measurements, sourceNames: [:])

        _ = try ConflictResolutionService.apply(
            conflict: conflict, table: "raw_samples", winnerId: "rec-c", candidates: candidates,
            measurements: measurements, reconciliation: reconciliation,
            dataConflicts: dataConflicts, clock: clock)

        XCTAssertEqual(try measurements.rawSamples(metricId: MetricID.restingHeartRate).map(\.id), ["rec-c"])
        XCTAssertNotNil(try reconciliation.forSuppressed("rec-a"))
        XCTAssertNotNil(try reconciliation.forSuppressed("rec-b"))
    }
}
