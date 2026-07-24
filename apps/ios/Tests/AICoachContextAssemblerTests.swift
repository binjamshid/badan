import XCTest
@testable import BADAN

/// A9 / ADR-0010 / D-22 — the AI coach's on-device retrieval layer.
///
/// Covers the assembler's own contract (which published scores it names, what it omits when a
/// score hasn't been computed yet, how it renders) and — the load-bearing case the client task
/// explicitly asks for — that it structurally CANNOT see anything from `badan_sensitive.db`: the
/// real guarantee is `AICoachContextAssembler.assembleToday`'s parameter type,
/// `AICoachContextAssembler.NonSensitiveDerivation`, whose only initializer takes a whole
/// `Database` and always resolves `.main` itself — there is no argument a caller could pass that
/// binds it to `.sensitive` instead (unlike a bare `DerivationRepository`, which this codebase
/// does bind to `Database.sensitive` elsewhere, e.g. `HomeScreen`/`BodyScreen`). This file's own
/// `derivation: DerivationRepository` property below is used only to SEED test data directly
/// against `db.main`; every call into the assembler goes through a freshly constructed
/// `NonSensitiveDerivation(db)` instead, matching how a real call site (`AICoachChatScreen`) uses
/// it. `testNeverSurfacesSensitiveDataEvenWhenPresentInTheSameDatabaseInstance` below also
/// demonstrates the guarantee empirically: sensitive data is seeded into the SAME `Database`
/// instance's sensitive connection, and the rendered output is asserted to never contain it.
final class AICoachContextAssemblerTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    var derivation: DerivationRepository!
    var nonSensitiveDerivation: AICoachContextAssembler.NonSensitiveDerivation!
    let deviceId = "test-device"
    let tz = "UTC"
    let asOf = Date(timeIntervalSince1970: 1_800_000_000) // a fixed instant, well inside one UTC day

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-aicoach-context-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        derivation = DerivationRepository(db.main)
        nonSensitiveDerivation = AICoachContextAssembler.NonSensitiveDerivation(db)
    }

    override func tearDownWithError() throws {
        derivation = nil
        nonSensitiveDerivation = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func dayKey() -> String { DayAttribution.localDayKey(asOf, tz: tz) }
    private func periodKey() -> String { "day:" + dayKey() }

    private func seedDerived(metricId: String, value: Double, unit: String, confidence: Double?,
                             provisional: Bool, algorithmId: String, algorithmVersion: String) throws {
        try derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: metricId, value: value, unit: unit, periodKey: periodKey(),
            confidence: confidence, provisional: provisional, algorithmId: algorithmId,
            algorithmVersion: algorithmVersion, computedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))
    }

    // MARK: - Assembly

    func testEmptyBundleWhenNoScoresComputedYet() throws {
        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        XCTAssertTrue(bundle.isEmpty)
        XCTAssertEqual(bundle.asOfDayKey, dayKey())
    }

    func testAssemblesAllThreePublishedScoresWhenPresent() throws {
        try seedDerived(metricId: MetricID.readinessScore, value: 72, unit: "score_0_100",
                        confidence: 1.0, provisional: true,
                        algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0")
        try seedDerived(metricId: MetricID.effortDay, value: 14, unit: "score_0_21",
                        confidence: 0.8, provisional: false,
                        algorithmId: "effort.day", algorithmVersion: "1.0.0")
        try seedDerived(metricId: MetricID.sleepPerformance, value: 88, unit: "percent",
                        confidence: nil, provisional: false,
                        algorithmId: "sleep.performance", algorithmVersion: "1.0.0")

        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        XCTAssertEqual(bundle.items.count, 3)

        let readiness = try XCTUnwrap(bundle.items.first { $0.metricId == MetricID.readinessScore })
        XCTAssertEqual(readiness.value, 72, accuracy: 1e-9)
        XCTAssertEqual(readiness.unit, "score_0_100")
        XCTAssertEqual(readiness.confidence, 1.0)
        XCTAssertTrue(readiness.provisional)
        XCTAssertEqual(readiness.algorithmId, "composite.readiness_score")
        XCTAssertEqual(readiness.algorithmVersion, "2.0.0")

        let sleep = try XCTUnwrap(bundle.items.first { $0.metricId == MetricID.sleepPerformance })
        XCTAssertNil(sleep.confidence)
    }

    func testOmitsAScoreThatHasNeverBeenComputedRatherThanDefaulting() throws {
        // Only readiness computed today — effort and sleep have no row at all.
        try seedDerived(metricId: MetricID.readinessScore, value: 50, unit: "score_0_100",
                        confidence: 0.6, provisional: false,
                        algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0")

        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        XCTAssertEqual(bundle.items.map(\.metricId), [MetricID.readinessScore])
    }

    /// INVARIANT I2 (latest `computedAt` wins): a second, later append for the same metric+period
    /// supersedes the first — the assembler must never surface a stale superseded value.
    func testUsesLatestAppendedValueForTheSamePeriod() throws {
        try seedDerived(metricId: MetricID.readinessScore, value: 40, unit: "score_0_100",
                        confidence: 0.5, provisional: true,
                        algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0")
        // A later append, same metric+period, different value — simulates a same-day recompute.
        try derivation.appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.readinessScore, value: 66, unit: "score_0_100",
            periodKey: periodKey(), confidence: 0.9, provisional: false,
            algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
            computedAt: asOf.addingTimeInterval(60), updatedAt: asOf.addingTimeInterval(60),
            originDeviceId: deviceId))

        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        let readiness = try XCTUnwrap(bundle.items.first { $0.metricId == MetricID.readinessScore })
        XCTAssertEqual(readiness.value, 66, accuracy: 1e-9)
        XCTAssertFalse(readiness.provisional)
    }

    // MARK: - Rendering (what actually accompanies the request, and what the chat screen shows back)

    func testRenderForRequestNamesEachScoreWithConfidenceAndAlgorithm() throws {
        try seedDerived(metricId: MetricID.readinessScore, value: 72.4, unit: "score_0_100",
                        confidence: 0.87, provisional: false,
                        algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0")
        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        let rendered = AICoachContextAssembler.renderForRequest(bundle, language: .en)

        XCTAssertTrue(rendered.contains("72.4"))
        XCTAssertTrue(rendered.contains("0.87"))
        XCTAssertTrue(rendered.contains("composite.readiness_score@2.0.0"))
        XCTAssertTrue(rendered.contains(dayKey()))
    }

    func testRenderForRequestHonestlyReportsAnEmptyBundle() throws {
        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        let rendered = AICoachContextAssembler.renderForRequest(bundle, language: .en)
        XCTAssertFalse(rendered.isEmpty)
        XCTAssertTrue(rendered.localizedCaseInsensitiveContains("no scores"))
    }

    // MARK: - Sensitive-data isolation (the client task's own explicit test requirement)

    /// Seeds a distinctive, unmistakably sensitive record (a medication name) into the SAME
    /// `Database` instance's `sensitive` connection — reachable only through `LoggingRepository`,
    /// never through `DerivationRepository` — and asserts it can never appear in what the context
    /// assembler produces. `AICoachContextAssembler` has no parameter through which
    /// `LoggingRepository`/`db.sensitive` could even be passed in; this test demonstrates that
    /// structural fact by trying the adjacent thing that WOULD leak it (reading `badan.db` after
    /// sensitive data exists in the same on-disk database directory) and confirming it doesn't.
    func testNeverSurfacesSensitiveDataEvenWhenPresentInTheSameDatabaseInstance() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        let distinctiveSecret = "ZZ-TOP-SECRET-MEDICATION-NAME-4F9A2E"
        try logging.upsertRegimen(MedicationRegimen(
            id: ULID.newID(), name: distinctiveSecret, strength: "10mg", form: "tablet",
            schedule: .daily(times: ["08:00"]), startedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))

        // Also seed a legitimate, non-sensitive score for the same day, so the bundle isn't
        // trivially empty — the assertion below has to hold against REAL rendered content.
        try seedDerived(metricId: MetricID.readinessScore, value: 55, unit: "score_0_100",
                        confidence: 0.7, provisional: false,
                        algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0")

        let bundle = try AICoachContextAssembler.assembleToday(derivation: nonSensitiveDerivation, now: asOf, tz: tz)
        XCTAssertFalse(bundle.isEmpty, "precondition: there is real content to check the secret isn't hiding inside")

        let renderedEn = AICoachContextAssembler.renderForRequest(bundle, language: .en)
        let renderedAr = AICoachContextAssembler.renderForRequest(bundle, language: .ar)
        XCTAssertFalse(renderedEn.contains(distinctiveSecret))
        XCTAssertFalse(renderedAr.contains(distinctiveSecret))

        // And the item-level data itself carries only the metric id, never a name/note field that
        // could ever hold free text like a medication name.
        for item in bundle.items {
            XCTAssertTrue([MetricID.readinessScore, MetricID.effortDay, MetricID.sleepPerformance]
                .contains(item.metricId))
        }
    }

    /// The type-level half of the isolation guarantee (independent audit finding, 2026-07-23):
    /// `NonSensitiveDerivation(db)` always resolves `db.main` internally, no matter what — so even
    /// constructing it from a `Database` whose `sensitive` connection carries data proves nothing
    /// about which connection actually backs the wrapper. This asserts that directly, rather than
    /// only inferring it from the rendered output the way the test above does.
    func testNonSensitiveDerivationAlwaysResolvesMainRegardlessOfSensitiveContents() throws {
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)
        try logging.upsertRegimen(MedicationRegimen(
            id: ULID.newID(), name: "irrelevant-to-this-assertion", strength: "10mg", form: "tablet",
            schedule: .daily(times: ["08:00"]), startedAt: asOf, updatedAt: asOf, originDeviceId: deviceId))

        // Seed a score into main only — if `NonSensitiveDerivation(db)` ever resolved `.sensitive`
        // instead of `.main`, this read would come back empty even though the score was appended.
        try seedDerived(metricId: MetricID.readinessScore, value: 61, unit: "score_0_100",
                        confidence: 0.5, provisional: false,
                        algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0")

        let freshWrapper = AICoachContextAssembler.NonSensitiveDerivation(db)
        let bundle = try AICoachContextAssembler.assembleToday(derivation: freshWrapper, now: asOf, tz: tz)
        XCTAssertEqual(bundle.items.map(\.metricId), [MetricID.readinessScore],
                       "NonSensitiveDerivation must resolve Database.main every time, regardless of what the same Database's sensitive connection holds")
    }
}
