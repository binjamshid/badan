import XCTest
@testable import BADAN

/// Covers `SourcePriorityRule`'s shipped default factory and `SourcePriorityRuleRepository`'s
/// history-preserving persistence (no `metric_id` uniqueness constraint at the DB level — see
/// that repository's own header doc for why — so these tests specifically pin "re-saving a rule
/// for the same metric never destroys the prior row, and reads pick the freshest live one").
final class SourcePriorityRuleTests: XCTestCase {

    // MARK: - Domain factory

    func testDefaultHeartRateDuringWorkoutRanksChestStrapAboveWristOptical() {
        let rule = SourcePriorityRule.defaultHeartRateDuringWorkout(id: "r1", now: Date(epochMillis: 0),
                                                                      originDeviceId: "origin")
        XCTAssertEqual(rule.metricId, MetricID.heartRate)
        XCTAssertEqual(rule.priorityOrder, [
            SourcePriorityRule.ClassificationKey.bleChestStrapHR,
            SourcePriorityRule.ClassificationKey.wristOpticalHR,
        ])
        XCTAssertFalse(rule.isUserOverride, "a BADAN-shipped default must never claim to be a user override")
    }

    // MARK: - Repository

    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-sourcepriority-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRepository() throws -> SourcePriorityRuleRepository {
        SourcePriorityRuleRepository(main: try Database(directory: tempDir).main)
    }

    private func rule(id: String, metricId: String = MetricID.heartRate, order: [String] = ["a", "b"],
                       override: Bool = false, at: Date = Date(epochMillis: 1_000)) -> SourcePriorityRule {
        SourcePriorityRule(id: id, metricId: metricId, priorityOrder: order, isUserOverride: override,
                           createdAt: at, updatedAt: at, originDeviceId: "origin-1")
    }

    func testInsertAndReadBackRoundTrips() throws {
        let repo = try makeRepository()
        try repo.insert(rule(id: "r1"))

        let read = try XCTUnwrap(repo.rule(forMetric: MetricID.heartRate))
        XCTAssertEqual(read.id, "r1")
        XCTAssertEqual(read.priorityOrder, ["a", "b"])
        XCTAssertFalse(read.isUserOverride)
    }

    func testRuleForMetricReturnsNilWhenNoneSaved() throws {
        let repo = try makeRepository()
        XCTAssertNil(try repo.rule(forMetric: MetricID.weight))
    }

    func testResavingARuleForTheSameMetricDoesNotDestroyThePriorRow() throws {
        let repo = try makeRepository()
        try repo.insert(rule(id: "default-1", order: ["strap", "wrist"], override: false, at: Date(epochMillis: 1_000)))
        try repo.insert(rule(id: "user-override-1", order: ["wrist", "strap"], override: true, at: Date(epochMillis: 2_000)))

        // Both rows must still exist — this table is history-preserving, not update-in-place.
        let all = try repo.all()
        XCTAssertEqual(all.count, 1, "`all()` surfaces one row per metric — the freshest live one")
        XCTAssertEqual(all.first?.id, "user-override-1")

        let live = try XCTUnwrap(repo.rule(forMetric: MetricID.heartRate))
        XCTAssertEqual(live.id, "user-override-1")
        XCTAssertTrue(live.isUserOverride)
        XCTAssertEqual(live.priorityOrder, ["wrist", "strap"])
    }

    func testAllReturnsOneRowPerMetricAcrossMultipleMetrics() throws {
        let repo = try makeRepository()
        try repo.insert(rule(id: "hr-rule", metricId: MetricID.heartRate, at: Date(epochMillis: 1_000)))
        try repo.insert(rule(id: "rhr-rule", metricId: MetricID.restingHeartRate, at: Date(epochMillis: 1_000)))

        let all = try repo.all()
        XCTAssertEqual(Set(all.map(\.metricId)), [MetricID.heartRate, MetricID.restingHeartRate])
    }

    func testDeleteTombstonesOnlyThatRowAndALaterRuleBecomesTheNewLiveHead() throws {
        let repo = try makeRepository()
        try repo.insert(rule(id: "old", at: Date(epochMillis: 1_000)))
        try repo.delete(id: "old", at: Date(epochMillis: 1_500))

        XCTAssertNil(try repo.rule(forMetric: MetricID.heartRate), "the only rule for this metric was tombstoned")

        try repo.insert(rule(id: "new", at: Date(epochMillis: 2_000)))
        let live = try XCTUnwrap(repo.rule(forMetric: MetricID.heartRate))
        XCTAssertEqual(live.id, "new")
    }
}
