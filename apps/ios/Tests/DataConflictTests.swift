import XCTest
@testable import BADAN

/// Covers three things: `ConflictScope`'s storage-key round trip, `ConflictDecisionEngine`'s named
/// default rules (plan §7A.6: chest-strap-beats-wrist in workouts, richest-source-wins duplicate
/// workouts, most-recent-weight-wins, I4's manual-wins-for-weight, and the generic
/// `SourcePriorityRule` fallback), and `DataConflictRepository`'s persistence round trip. The
/// "never silently merges" property test is the load-bearing one: it asserts that whenever
/// `decide` resolves a conflict, the winner is always an ORIGINAL input id and the losers are
/// exactly every other original input — never a synthesized/blended value, which the `Outcome`
/// type structurally cannot represent in the first place (it has no value field at all).
final class DataConflictTests: XCTestCase {

    // MARK: - ConflictScope storage-key round trip

    func testConflictScopeMetricRoundTrips() {
        let scope = ConflictScope.metric(id: MetricID.heartRate)
        XCTAssertEqual(scope.storageKey, "metric:heart.hr")
        XCTAssertEqual(ConflictScope(storageKey: scope.storageKey), scope)
    }

    func testConflictScopeMetricInWorkoutRoundTrips() {
        let scope = ConflictScope.metric(id: MetricID.heartRate, inWorkout: true)
        XCTAssertEqual(scope.storageKey, "metric:heart.hr:workout")
        XCTAssertEqual(ConflictScope(storageKey: scope.storageKey), scope)
    }

    func testConflictScopeWorkoutDuplicateRoundTrips() {
        XCTAssertEqual(ConflictScope.workoutDuplicate.storageKey, "workout_duplicate")
        XCTAssertEqual(ConflictScope(storageKey: "workout_duplicate"), .workoutDuplicate)
    }

    func testConflictScopeUnrecognizedKeyReturnsNil() {
        XCTAssertNil(ConflictScope(storageKey: "not_a_real_scope"))
        XCTAssertNil(ConflictScope(storageKey: ""))
    }

    // MARK: - ConflictDecisionEngine: named default rules

    private func reading(id: String, source: String = "s", classification: String = "",
                          manual: Bool = false, at: Date = Date(epochMillis: 0), richness: Int = 0) -> CandidateReading {
        CandidateReading(id: id, sourceId: source, classification: classification, isManualEntry: manual,
                          measuredAt: at, richnessScore: richness)
    }

    func testSingleCandidateIsNeverAConflict() {
        let only = reading(id: "a")
        XCTAssertNil(ConflictDecisionEngine.decide(scope: .metric(id: MetricID.weight), candidates: [only], priorityRule: nil))
    }

    func testManualWinsForWeightRegardlessOfRecencyOrRichness() throws {
        // The device reading is NEWER and "richer" but I4 says manual always wins for weight.
        let manual = reading(id: "manual-1", source: "manual-app", manual: true, at: Date(epochMillis: 1_000), richness: 0)
        let device = reading(id: "device-1", source: "scale-vendor", manual: false, at: Date(epochMillis: 999_999), richness: 100)
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(scope: .metric(id: MetricID.weight),
                                                                   candidates: [manual, device], priorityRule: nil))
        XCTAssertEqual(outcome.ruleId, ConflictDecisionEngine.manualWinsRuleId)
        XCTAssertEqual(outcome.winnerId, "manual-1")
        XCTAssertEqual(outcome.loserIds, ["device-1"])
        XCTAssertEqual(outcome.detail["winner_source"], "manual-app")
        XCTAssertEqual(outcome.detail["loser_source"], "scale-vendor")
    }

    func testManualWinsPicksMostRecentAmongMultipleManualEntries() throws {
        let older = reading(id: "manual-old", source: "app-a", manual: true, at: Date(epochMillis: 1_000))
        let newer = reading(id: "manual-new", source: "app-b", manual: true, at: Date(epochMillis: 2_000))
        let device = reading(id: "device", source: "watch-c", manual: false, at: Date(epochMillis: 3_000))
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(scope: .metric(id: MetricID.weight),
                                                                   candidates: [older, newer, device], priorityRule: nil))
        XCTAssertEqual(outcome.winnerId, "manual-new")
        XCTAssertEqual(Set(outcome.loserIds), ["manual-old", "device"])
        XCTAssertEqual(outcome.detail["winner_source"], "app-b")
        XCTAssertEqual(outcome.detail["loser_source"], "app-a,watch-c",
                       "2+ losers must all be named — sorted/joined, never dropped down to just one")
    }

    func testMostRecentWeightWinsWhenNoManualEntryPresent() throws {
        let older = reading(id: "device-old", source: "vendor-x", at: Date(epochMillis: 1_000))
        let newer = reading(id: "device-new", source: "vendor-y", at: Date(epochMillis: 2_000))
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(scope: .metric(id: MetricID.weight),
                                                                   candidates: [older, newer], priorityRule: nil))
        XCTAssertEqual(outcome.ruleId, ConflictDecisionEngine.mostRecentWeightRuleId)
        XCTAssertEqual(outcome.winnerId, "device-new")
        XCTAssertEqual(outcome.detail["winner_source"], "vendor-y")
        XCTAssertEqual(outcome.detail["loser_source"], "vendor-x")
    }

    func testChestStrapBeatsWristOpticalHRInWorkout() throws {
        let strap = reading(id: "strap", source: "polar-strap", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR)
        let wrist = reading(id: "wrist", source: "apple-watch", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR)
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: MetricID.heartRate, inWorkout: true), candidates: [strap, wrist], priorityRule: nil))
        XCTAssertEqual(outcome.ruleId, ConflictDecisionEngine.chestStrapRuleId)
        XCTAssertEqual(outcome.winnerId, "strap")
        XCTAssertEqual(outcome.detail["winner_source"], "polar-strap")
        XCTAssertEqual(outcome.detail["loser_source"], "apple-watch")
    }

    func testChestStrapPriorityTieBreaksDeterministicallyByMostRecentThenId() throws {
        // 2+ chest-strap candidates: the most recently measured must win, never whichever the
        // caller happened to list first.
        let strapOlder = reading(id: "strap-z", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR,
                                  at: Date(epochMillis: 1_000))
        let strapNewer = reading(id: "strap-a", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR,
                                  at: Date(epochMillis: 2_000))
        let wrist = reading(id: "wrist", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR,
                             at: Date(epochMillis: 1_500))
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: MetricID.heartRate, inWorkout: true),
            candidates: [strapOlder, wrist, strapNewer], priorityRule: nil))
        XCTAssertEqual(outcome.winnerId, "strap-a", "the most recently measured chest strap must win")
    }

    func testChestStrapPriorityTieBreaksBySmallestIdWhenMeasuredAtTies() throws {
        // Equal measuredAt: smallest id must win, and must NOT depend on array input order.
        let strapB = reading(id: "strap-b", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR,
                              at: Date(epochMillis: 1_000))
        let strapA = reading(id: "strap-a", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR,
                              at: Date(epochMillis: 1_000))
        let outcomeBFirst = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: MetricID.heartRate, inWorkout: true), candidates: [strapB, strapA], priorityRule: nil))
        let outcomeAFirst = try XCTUnwrap(ConflictDecisionEngine.decide(
            scope: .metric(id: MetricID.heartRate, inWorkout: true), candidates: [strapA, strapB], priorityRule: nil))
        XCTAssertEqual(outcomeBFirst.winnerId, "strap-a")
        XCTAssertEqual(outcomeAFirst.winnerId, "strap-a",
                       "equal measuredAt must break the tie deterministically by smallest id, regardless of input order")
    }

    func testChestStrapRuleDoesNotApplyOutsideWorkoutContext() {
        let strap = reading(id: "strap", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR)
        let wrist = reading(id: "wrist", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR)
        // inWorkout: false, and no SourcePriorityRule supplied -> genuinely unresolved.
        let outcome = ConflictDecisionEngine.decide(scope: .metric(id: MetricID.heartRate, inWorkout: false),
                                                     candidates: [strap, wrist], priorityRule: nil)
        XCTAssertNil(outcome)
    }

    func testRichestSourceWinsDuplicateWorkout() throws {
        let sparse = reading(id: "watch-a", source: "garmin", richness: 2)
        let rich = reading(id: "watch-b", source: "whoop", richness: 9)
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(scope: .workoutDuplicate,
                                                                   candidates: [sparse, rich], priorityRule: nil))
        XCTAssertEqual(outcome.ruleId, ConflictDecisionEngine.richestWorkoutRuleId)
        XCTAssertEqual(outcome.winnerId, "watch-b")
        XCTAssertEqual(outcome.detail["winner_source"], "whoop")
        XCTAssertEqual(outcome.detail["loser_source"], "garmin")
    }

    func testRichestSourceWinsTieBreaksDeterministicallyBySmallestId() throws {
        let a = reading(id: "a-tied", richness: 5)
        let b = reading(id: "b-tied", richness: 5)
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(scope: .workoutDuplicate,
                                                                   candidates: [b, a], priorityRule: nil))
        XCTAssertEqual(outcome.winnerId, "a-tied", "equal richness must break the tie deterministically, never by input order")
    }

    func testPriorityOrderRuleAppliesForAMetricWithAMatchingRule() throws {
        let rule = SourcePriorityRule(id: "rule-1", metricId: MetricID.restingHeartRate,
                                       priorityOrder: ["deviceB", "deviceA"], isUserOverride: false,
                                       createdAt: Date(epochMillis: 0), updatedAt: Date(epochMillis: 0),
                                       originDeviceId: "origin")
        let a = reading(id: "reading-a", source: "device-a-vendor", classification: "deviceA")
        let b = reading(id: "reading-b", source: "device-b-vendor", classification: "deviceB")
        let outcome = try XCTUnwrap(ConflictDecisionEngine.decide(scope: .metric(id: MetricID.restingHeartRate),
                                                                   candidates: [a, b], priorityRule: rule))
        XCTAssertEqual(outcome.ruleId, ConflictDecisionEngine.priorityOrderRuleId)
        XCTAssertEqual(outcome.winnerId, "reading-b", "deviceB is ranked first in the rule's priority order")
        XCTAssertEqual(outcome.detail["winner_source"], "device-b-vendor")
        XCTAssertEqual(outcome.detail["loser_source"], "device-a-vendor")
    }

    func testNoApplicableRuleLeavesConflictUnresolved() {
        let a = reading(id: "a", classification: "unknown-1")
        let b = reading(id: "b", classification: "unknown-2")
        let outcome = ConflictDecisionEngine.decide(scope: .metric(id: MetricID.restingHeartRate),
                                                     candidates: [a, b], priorityRule: nil)
        XCTAssertNil(outcome, "no rule applies here — must be left unresolved, never guessed")
    }

    func testPriorityOrderRuleWithNoMatchingClassificationLeavesUnresolved() {
        let rule = SourcePriorityRule(id: "rule-1", metricId: MetricID.restingHeartRate,
                                       priorityOrder: ["deviceX"], isUserOverride: true,
                                       createdAt: Date(epochMillis: 0), updatedAt: Date(epochMillis: 0),
                                       originDeviceId: "origin")
        let a = reading(id: "a", classification: "unrelated-1")
        let b = reading(id: "b", classification: "unrelated-2")
        let outcome = ConflictDecisionEngine.decide(scope: .metric(id: MetricID.restingHeartRate),
                                                     candidates: [a, b], priorityRule: rule)
        XCTAssertNil(outcome)
    }

    // MARK: - Never silently merges (property-style)

    /// Across every named scope this engine supports, whenever `decide` returns a non-nil
    /// outcome, the winner is always one of the INPUT candidate ids, and the losers are exactly
    /// "every other input candidate" — never a synthesized id, and never a value at all (there is
    /// no value field on `Outcome` to average into in the first place).
    func testDecideNeverProducesAWinnerOrLoserOutsideTheInputSet() {
        let scopesAndCandidates: [(ConflictScope, [CandidateReading])] = [
            (.metric(id: MetricID.weight), [
                reading(id: "w1", manual: true, at: Date(epochMillis: 10)),
                reading(id: "w2", manual: false, at: Date(epochMillis: 20)),
                reading(id: "w3", manual: false, at: Date(epochMillis: 5)),
            ]),
            (.metric(id: MetricID.heartRate, inWorkout: true), [
                reading(id: "hr1", classification: SourcePriorityRule.ClassificationKey.bleChestStrapHR),
                reading(id: "hr2", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR),
                reading(id: "hr3", classification: SourcePriorityRule.ClassificationKey.wristOpticalHR),
            ]),
            (.workoutDuplicate, [
                reading(id: "wd1", richness: 3), reading(id: "wd2", richness: 8), reading(id: "wd3", richness: 8),
            ]),
            (.metric(id: MetricID.restingHeartRate), [ // no rule supplied -> exercises the "unresolved" path too
                reading(id: "rhr1", classification: "x"), reading(id: "rhr2", classification: "y"),
            ]),
        ]

        for (scope, candidates) in scopesAndCandidates {
            let inputIds = Set(candidates.map(\.id))
            guard let outcome = ConflictDecisionEngine.decide(scope: scope, candidates: candidates, priorityRule: nil) else {
                continue // unresolved is a legitimate outcome; nothing further to check here
            }
            XCTAssertTrue(inputIds.contains(outcome.winnerId), "winner must be one of the input candidates")
            XCTAssertEqual(Set(outcome.loserIds), inputIds.subtracting([outcome.winnerId]),
                            "losers must be EXACTLY every other input candidate — never a subset, superset, or synthesized id")
            XCTAssertFalse(outcome.loserIds.contains(outcome.winnerId))
        }
    }

    // MARK: - Outcome.makeDecisions

    func testMakeDecisionsProducesOneReconciliationDecisionPerLoserAllSharingTheWinner() {
        let clock = FixedClock(Date(epochMillis: 5_000))
        let outcome = ConflictDecisionEngine.Outcome(ruleId: "conflict.test.v1", ruleVersion: "v1",
                                                      winnerId: "winner", loserIds: ["loser-a", "loser-b"],
                                                      detail: ["k": "v"])
        let decisions = outcome.makeDecisions(batchId: "batch-1", clock: clock)

        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(Set(decisions.map(\.keptRecordId)), ["winner"])
        XCTAssertEqual(Set(decisions.map(\.suppressedRecordId)), ["loser-a", "loser-b"])
        XCTAssertTrue(decisions.allSatisfy { $0.rule == "conflict.test.v1" && $0.ruleVersion == "v1" })
        XCTAssertTrue(decisions.allSatisfy { $0.decidedAt == Date(epochMillis: 5_000) })
        XCTAssertTrue(decisions.allSatisfy { $0.batchId == "batch-1" })
        XCTAssertEqual(Set(decisions.map(\.id)).count, 2, "each decision must mint its own distinct id")
    }

    // MARK: - DataConflictRepository

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-dataconflict-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeConflict(id: String = "c-1", scope: ConflictScope = .metric(id: MetricID.weight),
                              candidates: [String] = ["r1", "r2"], status: DataConflictStatus = .unresolved,
                              detectedAt: Date = Date(epochMillis: 1_000)) -> DataConflict {
        DataConflict(id: id, scope: scope, windowStart: Date(epochMillis: 0), windowEnd: Date(epochMillis: 100),
                     candidateRecordIds: candidates, status: status, detectedAt: detectedAt,
                     updatedAt: detectedAt, originDeviceId: "origin-1")
    }

    func testInsertAndReadBackRoundTrips() throws {
        let repo = DataConflictRepository(main: try Database(directory: tempDir).main)
        try repo.insert(makeConflict())

        let read = try XCTUnwrap(repo.conflict(id: "c-1"))
        XCTAssertEqual(read.scope, .metric(id: MetricID.weight))
        XCTAssertEqual(read.candidateRecordIds, ["r1", "r2"])
        XCTAssertEqual(read.status, .unresolved)
        XCTAssertNil(read.resolvedByDecisionId)
    }

    func testUnresolvedListsOnlyUnresolvedLiveConflictsNewestFirst() throws {
        let repo = DataConflictRepository(main: try Database(directory: tempDir).main)
        try repo.insert(makeConflict(id: "old", detectedAt: Date(epochMillis: 100)))
        try repo.insert(makeConflict(id: "new", detectedAt: Date(epochMillis: 200)))
        try repo.insert(makeConflict(id: "resolved", status: .resolved, detectedAt: Date(epochMillis: 300)))

        let unresolved = try repo.unresolved()
        XCTAssertEqual(unresolved.map(\.id), ["new", "old"])
    }

    func testMarkResolvedSetsStatusAndDecisionIdWithoutTouchingCandidates() throws {
        let repo = DataConflictRepository(main: try Database(directory: tempDir).main)
        try repo.insert(makeConflict())

        try repo.markResolved(id: "c-1", decisionId: "decision-1", at: Date(epochMillis: 5_000))

        let read = try XCTUnwrap(repo.conflict(id: "c-1"))
        XCTAssertEqual(read.status, .resolved)
        XCTAssertEqual(read.resolvedByDecisionId, "decision-1")
        XCTAssertEqual(read.candidateRecordIds, ["r1", "r2"], "resolving must never touch the original candidate set")
    }

    func testConflictsByScopeKeyFiltersCorrectly() throws {
        let repo = DataConflictRepository(main: try Database(directory: tempDir).main)
        try repo.insert(makeConflict(id: "weight-1", scope: .metric(id: MetricID.weight)))
        try repo.insert(makeConflict(id: "hr-1", scope: .metric(id: MetricID.heartRate, inWorkout: true),
                                      candidates: ["h1", "h2"]))

        let weightConflicts = try repo.conflicts(scopeKey: ConflictScope.metric(id: MetricID.weight).storageKey)
        XCTAssertEqual(weightConflicts.map(\.id), ["weight-1"])
    }

    /// Mirrors `DataConflict.init`'s own `precondition(candidateRecordIds.count >= 2, ...)` — but a
    /// row this malformed must never reach that trap via the READ path. A corrupted row, a future
    /// writer bug, or a botched sync-merge with fewer than 2 candidate ids must surface as "not
    /// available," never crash Device Hub or the Data Conflicts screen (matches
    /// `GattServiceAdaptersTests`'s "never crash on malformed/truncated input" principle for the
    /// same reason).
    func testMalformedCandidateRecordIdsReadsBackAsNilRatherThanCrashing() throws {
        let db = try Database(directory: tempDir).main
        let repo = DataConflictRepository(main: db)
        // Bypass the repository/typed-construction path entirely to simulate a corrupted row: only
        // ONE candidate id, which would trip `DataConflict.init`'s precondition if `read()` forced
        // every row through it unconditionally.
        try db.run("""
            INSERT INTO data_conflicts
              (id, scope_key, window_start, window_end, candidate_record_ids, status,
               resolved_by_decision_id, detected_at, updated_at, origin_device_id, deleted_at)
            VALUES ('malformed-1', 'metric:\(MetricID.weight)', 0, 100, '["only-one"]', 'unresolved', NULL, 1000, 1000, 'origin-1', NULL);
            """)

        XCTAssertNil(try repo.conflict(id: "malformed-1"),
                     "a row with fewer than 2 candidate_record_ids must read back as nil, never crash")
    }

    func testUndecodableCandidateRecordIdsReadsBackAsNilRatherThanCrashing() throws {
        let db = try Database(directory: tempDir).main
        let repo = DataConflictRepository(main: db)
        // `candidate_record_ids` that isn't even valid JSON at all (deeper corruption than just an
        // under-count array).
        try db.run("""
            INSERT INTO data_conflicts
              (id, scope_key, window_start, window_end, candidate_record_ids, status,
               resolved_by_decision_id, detected_at, updated_at, origin_device_id, deleted_at)
            VALUES ('malformed-2', 'metric:\(MetricID.weight)', 0, 100, 'not-valid-json-at-all', 'unresolved', NULL, 1000, 1000, 'origin-1', NULL);
            """)

        XCTAssertNil(try repo.conflict(id: "malformed-2"),
                     "a row whose candidate_record_ids fails to decode at all must read back as nil, never crash")
    }

    func testUnresolvedSkipsAMalformedRowRatherThanCrashingTheWholeList() throws {
        let db = try Database(directory: tempDir).main
        let repo = DataConflictRepository(main: db)
        try repo.insert(makeConflict(id: "good", detectedAt: Date(epochMillis: 100)))
        try db.run("""
            INSERT INTO data_conflicts
              (id, scope_key, window_start, window_end, candidate_record_ids, status,
               resolved_by_decision_id, detected_at, updated_at, origin_device_id, deleted_at)
            VALUES ('malformed-3', 'metric:\(MetricID.weight)', 0, 100, '["only-one"]', 'unresolved', NULL, 200, 200, 'origin-1', NULL);
            """)

        // Must not crash the test process, and the good row must still come back.
        let unresolved = try repo.unresolved()
        XCTAssertEqual(unresolved.map(\.id), ["good"],
                       "the malformed row is silently skipped, never crashing the rest of the list")
    }

    func testUnrecognizedScopeKeyRoundTripsRawRatherThanBeingSilentlyRewritten() throws {
        let db = try Database(directory: tempDir).main
        let repo = DataConflictRepository(main: db)
        // Bypass the repository/typed-scope path entirely to simulate a row written by a FUTURE
        // BADAN version carrying a scope kind this build doesn't know about.
        try db.run("""
            INSERT INTO data_conflicts
              (id, scope_key, window_start, window_end, candidate_record_ids, status,
               resolved_by_decision_id, detected_at, updated_at, origin_device_id, deleted_at)
            VALUES ('future-1', 'future_scope_kind:xyz', 0, 100, '["r1","r2"]', 'unresolved', NULL, 1000, 1000, 'origin-1', NULL);
            """)

        let read = try XCTUnwrap(repo.conflict(id: "future-1"))
        XCTAssertEqual(read.scopeKey, "future_scope_kind:xyz",
                       "the raw key must survive exactly, never get rewritten to a fallback")
        XCTAssertNil(read.scope, "an unrecognized key correctly fails to produce a typed scope")
    }
}
