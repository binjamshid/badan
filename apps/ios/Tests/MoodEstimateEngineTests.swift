import XCTest
@testable import BADAN

/// The mood estimate. Half of this suite guards the boundary between "an estimate from physiology"
/// and "a reading of how you feel" — the second would be the diagnostic framing CLAUDE.md forbids,
/// and it is one careless commit away at all times.
final class MoodEstimateEngineTests: XCTestCase {

    private var spec: MoodEstimateEngine.Spec { .defaultShared }

    func testTheContractLoads() {
        XCTAssertTrue(spec.isLoaded, "subjective.mood_estimate needs an algorithms.json entry")
        XCTAssertEqual(spec.sleepWeight + spec.autonomicWeight + spec.restingHeartRateWeight, 1.0,
                       accuracy: 0.0001)
        XCTAssertEqual(spec.minComponents, 2)
    }

    // MARK: - What it refuses

    /// One term is not a composite. A 1–5 "mood" resting on resting heart rate alone would be
    /// indefensible, and RHR moves for many reasons that have nothing to do with mood.
    func testASingleTermIsNotEnough() {
        XCTAssertNil(MoodEstimateEngine.estimate(.init(restingHeartRateSigmas: 0), spec: spec))
        XCTAssertNil(MoodEstimateEngine.estimate(.init(sleepScore: 80), spec: spec))
        XCTAssertNil(MoodEstimateEngine.estimate(.init(autonomicLoad: 30), spec: spec))
        XCTAssertNil(MoodEstimateEngine.estimate(.init(), spec: spec))
    }

    func testNothingIsComputedWithoutTheContract() {
        XCTAssertNil(MoodEstimateEngine.estimate(.init(sleepScore: 80, autonomicLoad: 20),
                                                 spec: .unavailable))
    }

    /// The autonomic term is OPTIONAL by design. `StressEngine`'s density gate hides daytime-HRV
    /// claims on Apple-Watch-class devices; if this estimate required that term it would be hidden
    /// for the same users, which is precisely the outcome the multi-input design avoids.
    func testItStillWorksWhenDaytimeHRVIsTooSparseToUse() {
        let e = MoodEstimateEngine.estimate(.init(sleepScore: 80, restingHeartRateSigmas: 0), spec: spec)
        XCTAssertNotNil(e, "an Apple-Watch-only user must still get an estimate, not a blank")
        XCTAssertNil(e?.autonomicComponent)
        XCTAssertEqual(e?.partial, true)
    }

    // MARK: - Scale and direction

    func testTheValueStaysOnTheLoggedMoodScale() {
        for sleep in stride(from: 0.0, through: 100.0, by: 10) {
            for load in stride(from: 0.0, through: 100.0, by: 25) {
                for sigmas in [-3.0, 0.0, 1.0, 5.0] {
                    guard let e = MoodEstimateEngine.estimate(
                        .init(sleepScore: sleep, autonomicLoad: load, restingHeartRateSigmas: sigmas),
                        spec: spec) else { continue }
                    XCTAssertGreaterThanOrEqual(e.value, 1.0)
                    XCTAssertLessThanOrEqual(e.value, 5.0)
                }
            }
        }
    }

    func testBetterSleepRaisesTheEstimate() {
        let poor = MoodEstimateEngine.estimate(.init(sleepScore: 20, autonomicLoad: 50), spec: spec)!
        let good = MoodEstimateEngine.estimate(.init(sleepScore: 95, autonomicLoad: 50), spec: spec)!
        XCTAssertGreaterThan(good.value, poor.value)
    }

    /// `stress.day_trend`'s convention is higher-is-more-load, so it must invert here.
    func testMoreAutonomicLoadLowersTheEstimate() {
        let calm = MoodEstimateEngine.estimate(.init(sleepScore: 70, autonomicLoad: 10), spec: spec)!
        let loaded = MoodEstimateEngine.estimate(.init(sleepScore: 70, autonomicLoad: 90), spec: spec)!
        XCTAssertGreaterThan(calm.value, loaded.value)
    }

    /// Only ELEVATION counts. An unusually low resting heart rate is not evidence of a good mood,
    /// and rewarding it would invent signal in the tail where illness and artefacts also live.
    func testAnUnusuallyLowRestingHeartRateIsNotTreatedAsGoodNews() {
        let normal = MoodEstimateEngine.estimate(
            .init(sleepScore: 70, restingHeartRateSigmas: 0), spec: spec)!
        let veryLow = MoodEstimateEngine.estimate(
            .init(sleepScore: 70, restingHeartRateSigmas: -4), spec: spec)!
        XCTAssertEqual(veryLow.value, normal.value, accuracy: 0.0001)

        let elevated = MoodEstimateEngine.estimate(
            .init(sleepScore: 70, restingHeartRateSigmas: 3), spec: spec)!
        XCTAssertLessThan(elevated.value, normal.value)
    }

    func testComponentsAreCarriedForInspection() {
        let e = MoodEstimateEngine.estimate(
            .init(sleepScore: 80, autonomicLoad: 40, restingHeartRateSigmas: 0), spec: spec)!
        XCTAssertEqual(e.sleepComponent ?? -1, 0.8, accuracy: 0.0001)
        XCTAssertEqual(e.autonomicComponent ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertEqual(e.restingHeartRateComponent ?? -1, 1.0, accuracy: 0.0001)
    }

    // MARK: - The boundary that matters

    /// The estimate must never be written into the metric the user fills in themselves. A derived
    /// guess overwriting a self-report would destroy the only ground truth in the family.
    func testTheEstimateIsASeparateMetricFromTheSelfReport() {
        XCTAssertNotEqual(MetricID.moodEstimate, "subjective.mood")
        XCTAssertEqual(MetricID.moodEstimate, "subjective.mood_estimate")
    }

    /// The estimate must be a registered metric in its own right, on the same scale as the
    /// self-report so the two are comparable, and derived so no surface mistakes it for something
    /// the user entered.
    ///
    /// (The `explainerEn` wording — the surface where diagnostic framing would creep in first — is
    /// not asserted here: `explainerEn` is never parsed into `MetricDefinition`, so there is nothing
    /// in code to read it from, and a test that re-parsed the JSON out of a bundle it does not ship
    /// in would be testing its own file-finding rather than the copy.)
    func testTheEstimateIsRegisteredAsItsOwnDerivedMetric() throws {
        let def = try XCTUnwrap(MetricRegistry.shared.definition(MetricID.moodEstimate),
                                "mood_estimate must be in registry.json or nothing can render it")
        XCTAssertEqual(def.kind, .derived)
        let selfReport = try XCTUnwrap(MetricRegistry.shared.definition("subjective.mood"))
        XCTAssertEqual(def.canonicalUnit, selfReport.canonicalUnit,
                       "the estimate is reported on the user's own logging scale so the two compare")
    }
}
