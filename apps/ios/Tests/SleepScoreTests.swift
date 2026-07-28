import XCTest
@testable import BADAN

/// The 0–100 sleep composite. Most of this suite is about what the score REFUSES to do: the easy
/// way to build a sleep score is to default every missing input to something and always produce a
/// number, which is exactly how a score stops meaning anything.
final class SleepScoreTests: XCTestCase {

    private var spec: SleepSpec { SleepSpec.defaultShared }

    private func performance(_ percent: Double) -> SleepPerformance {
        SleepPerformance(centerPercent: percent, cappedCenterPercent: percent,
                         lowPercent: percent, highPercent: percent,
                         confidence: 1.0, showRange: false)
    }

    func testTheContractLoadsAtAll() {
        XCTAssertTrue(spec.isLoaded,
                      "sleep.score must have an algorithms.json entry — without one the engine computes nothing")
        XCTAssertGreaterThan(spec.performanceWeight, 0)
        XCTAssertEqual(spec.performanceWeight + spec.consistencyWeight + spec.continuityWeight, 1.0,
                       accuracy: 0.0001, "the three weights are a weighted mean and must sum to 1")
    }

    // MARK: - What it refuses to do

    /// The cold-start rule. `SleepNightScore.performance` is nil until a personal sleep-duration
    /// baseline exists, so a fresh install has nothing to score. A number here would be invented.
    func testNoScoreWithoutPerformance() {
        XCTAssertNil(SleepScore.compute(performance: nil, consistency: 80, disturbanceCount: 1, spec: spec),
                     "a sleep score with no notion of whether you slept enough is a timing score mislabelled")
    }

    func testNoScoreWhenTheContractDidNotLoad() {
        XCTAssertNil(SleepScore.compute(performance: performance(90), consistency: 80,
                                        disturbanceCount: 1, spec: .unavailable))
    }

    /// Missing optional terms are DROPPED, not defaulted. Defaulting to 0 would punish someone
    /// whose watch records no stages; defaulting to 100 would flatter them.
    func testMissingComponentsAreDroppedNotDefaulted() {
        let full = SleepScore.compute(performance: performance(100), consistency: 100,
                                      disturbanceCount: 0, spec: spec)
        let perfOnly = SleepScore.compute(performance: performance(100), consistency: nil,
                                          disturbanceCount: nil, spec: spec)
        XCTAssertEqual(full?.value ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(perfOnly?.value ?? -1, 100, accuracy: 0.001,
                       "renormalising over one perfect term must give 100, not 50")
        XCTAssertNil(perfOnly?.consistencyComponent)
        XCTAssertNil(perfOnly?.continuityComponent)
    }

    func testAPartialCompositeIsMarkedPartial() {
        let partial = SleepScore.compute(performance: performance(90), consistency: nil,
                                         disturbanceCount: nil, spec: spec)
        XCTAssertEqual(partial?.partial, true,
                       "a two-of-three composite must not be presentable as the whole picture")
    }

    // MARK: - What it computes

    func testWeightedMeanOverAllThreeComponents() {
        // perf 100, consistency 0, continuity 100 (0 disturbances).
        let s = SleepScore.compute(performance: performance(100), consistency: 0,
                                   disturbanceCount: 0, spec: spec)
        let expected = spec.performanceWeight * 100 + spec.consistencyWeight * 0 + spec.continuityWeight * 100
        XCTAssertEqual(s?.value ?? -1, expected, accuracy: 0.001)
    }

    /// Performance is stored uncapped because sleeping 130% of need is a real fact. The SCORE caps
    /// it, so oversleeping cannot buy down a poor consistency term.
    func testOversleepingCannotBuyDownABadConsistencyTerm() {
        let capped = SleepScore.compute(performance: performance(100), consistency: 0,
                                        disturbanceCount: 0, spec: spec)
        let over = SleepScore.compute(performance: performance(300), consistency: 0,
                                      disturbanceCount: 0, spec: spec)
        XCTAssertEqual(over?.value ?? -1, capped?.value ?? -2, accuracy: 0.001)
        XCTAssertEqual(over?.performanceComponent ?? -1, spec.performanceCapPercent, accuracy: 0.001)
    }

    func testContinuityFallsAsDisturbancesRise() {
        let calm = SleepScore.compute(performance: performance(90), consistency: 90,
                                      disturbanceCount: 0, spec: spec)
        let broken = SleepScore.compute(performance: performance(90), consistency: 90,
                                        disturbanceCount: 6, spec: spec)
        XCTAssertGreaterThan(calm?.value ?? 0, broken?.value ?? 0)
        XCTAssertEqual(calm?.continuityComponent ?? -1, 100, accuracy: 0.001)
    }

    func testContinuityFloorsAtZeroRatherThanGoingNegative() {
        let s = SleepScore.compute(performance: performance(90), consistency: 90,
                                   disturbanceCount: 999, spec: spec)
        XCTAssertEqual(s?.continuityComponent ?? -1, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(s?.value ?? -1, 0)
    }

    func testTheScoreStaysInRange() {
        for perf in stride(from: 0.0, through: 200.0, by: 25) {
            for cons in [nil, 0.0, 50.0, 100.0] as [Double?] {
                for dist in [nil, 0, 3, 20] as [Int?] {
                    guard let s = SleepScore.compute(performance: performance(perf), consistency: cons,
                                                     disturbanceCount: dist, spec: spec) else { continue }
                    XCTAssertGreaterThanOrEqual(s.value, 0)
                    XCTAssertLessThanOrEqual(s.value, 100)
                }
            }
        }
    }

    /// The components ride along with the number so "why is my score 68?" resolves to the three
    /// terms it was built from, rather than to an opaque total.
    func testComponentsAreCarriedForInspection() {
        let s = SleepScore.compute(performance: performance(85), consistency: 70,
                                   disturbanceCount: 2, spec: spec)
        XCTAssertEqual(s?.performanceComponent ?? -1, 85, accuracy: 0.001)
        XCTAssertEqual(s?.consistencyComponent ?? -1, 70, accuracy: 0.001)
        XCTAssertNotNil(s?.continuityComponent)
    }
}
