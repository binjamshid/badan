import XCTest
@testable import BADAN

/// The algorithm contract loader (`packages/contracts/algorithms/algorithms.json`, plan §9/§15).
///
/// These tests read the real bundled file, not a fixture, for the same reason
/// `SensorQualityTests` does: the asset is a SHARED contract mirrored by
/// `scripts/sync_ios_resources.sh`, and a missing mirror is silent — every `param(...)` returns
/// nil and an engine quietly falls back to a hardcoded constant.
///
/// This suite is also the answer to audit finding #5. The contract claimed "both platforms load
/// this file ... the loading path is fixed in Phase 0" while no loader existed on either platform;
/// the file was mirrored into both bundles and CI-gated for drift, so it read as load-bearing and
/// was inert. Asserting the path here is what makes the claim true — if `AlgorithmRegistry` is
/// deleted or stops resolving ids, this fails instead of the claim rotting unnoticed until a
/// Phase-2 engine needs it.
final class AlgorithmRegistryTests: XCTestCase {

    private var registry: AlgorithmRegistry { AlgorithmRegistry.shared }

    // MARK: - Loading

    /// Catches a broken/missing `sync_ios_resources.sh` mirror.
    func testContractLoads() {
        XCTAssertFalse(registry.all.isEmpty, "algorithms.json failed to load or is empty")
        XCTAssertFalse(registry.version.isEmpty)
        XCTAssertNotEqual(registry.version, "0", "contract version fell back to the missing-file placeholder")
    }

    /// The specific thing finding #5 says Phase 0 owes Phase 2: a known id and a known param
    /// resolve through the bundled file.
    func testKnownAlgorithmAndParamResolve() throws {
        let baseline = try XCTUnwrap(registry.definition("baseline.rolling_median_mad"))
        // EPIC-23 bumped this to 2.0.0: the band method fundamentally changed (per-metric windows,
        // log-domain banding for vitals, MAD outlier rejection). Per I2, rows already stamped 1.0.0
        // are never rewritten — a recompute appends a 2.0.0 row.
        XCTAssertEqual(baseline.semver, "2.0.0")
        XCTAssertFalse(baseline.provisional)
        XCTAssertEqual(baseline.params["windowDays"], 28, "the DEFAULT window; per-metric overrides live in windowTable")
        XCTAssertEqual(baseline.params["minPoints"], 7)
        // The MAD→sigma consistency constant. Not tunable — the contract's own paramNote says
        // changing it changes what the band means, so it is worth pinning here too.
        XCTAssertEqual(try XCTUnwrap(registry.param("baseline.rolling_median_mad", "madToSigma")),
                       1.4826, accuracy: 1e-9)
    }

    /// The registry hands an engine a frozen `AlgorithmVersion` to stamp onto a `DerivedValue`,
    /// which is the whole reason the constants are data rather than code: the row records the
    /// exact numbers that produced it, and I2 keeps that row forever.
    func testAlgorithmVersionCarriesTheContractsParams() throws {
        let version = try XCTUnwrap(registry.algorithmVersion("effort.day"))
        XCTAssertEqual(version.id, "effort.day@0.1.0")
        XCTAssertEqual(version.introducedIn, "0.2.0")
        XCTAssertEqual(version.params["logCurveK"], 0.045)
        XCTAssertEqual(version.params["zone5Weight"], 6.8)
    }

    func testUnknownAlgorithmResolvesToNilRatherThanAnEmptyVersion() {
        XCTAssertNil(registry.definition("not.a.real.algorithm"))
        XCTAssertNil(registry.algorithmVersion("not.a.real.algorithm"))
        XCTAssertNil(registry.param("not.a.real.algorithm", "windowDays"))
        // A present algorithm with an absent param must also be nil, never 0 — 0 is a legitimate
        // value in this file (`includeWarmupSets`), so "missing" and "zero" cannot share a return.
        XCTAssertNil(registry.param("baseline.rolling_median_mad", "notAParam"))
        XCTAssertEqual(registry.param("workout.strength.volume", "includeWarmupSets"), 0)
    }

    func testAlgorithmIdsAreUnique() {
        let ids = registry.all.map(\.algorithmId)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate algorithmId in algorithms.json")
    }

    // MARK: - Cross-contract integrity

    /// Every metric id the algorithm contract names must exist in the metric ontology.
    ///
    /// These are two separately-authored files that CI only checks for *mirror* drift, not for
    /// agreement with each other. A typo'd or renamed metric id here produces an engine that
    /// computes a value and files it under an id no surface can render — a number that exists in
    /// the database and nowhere on screen. `"*"` is the baseline algorithm's wildcard (it runs
    /// over every baseline-eligible metric) and is the one legitimate non-id.
    func testEveryMetricIdNamedByAnAlgorithmExistsInTheRegistry() {
        let known = Set(MetricRegistry.shared.all.map(\.metricId))
        var unknown: [String] = []
        for algorithm in registry.all {
            for metricId in algorithm.producesMetricIds + algorithm.inputMetricIds where metricId != "*" {
                if !known.contains(metricId) { unknown.append("\(algorithm.algorithmId) -> \(metricId)") }
            }
        }
        XCTAssertTrue(unknown.isEmpty,
                      """
                      algorithms.json names metric ids that registry.json does not define: \
                      \(unknown.sorted()). Add the metric to the ontology or fix the id — an \
                      engine writing to an undefined id produces values no surface can show.
                      """)
    }

    func testProducersLookupFindsTheBaselineWildcardAndTheSpecificEntry() {
        let producers = registry.producers(of: "sleep.performance").map(\.algorithmId)
        XCTAssertTrue(producers.contains("sleep.performance"))
        XCTAssertTrue(producers.contains("baseline.rolling_median_mad"),
                      "the wildcard baseline entry must match every metric")
    }

    // MARK: - Contract shape

    /// The scope gate the cycle entry's own `paramNotes` describes: no fertile-window, ovulation,
    /// or next-period prediction algorithm may appear in this file without its own review
    /// (plan A17/A18, and a retained clinical advisor per A25). The note says adding one quietly
    /// "would be the whole gate failing quietly" — this is the check that makes it loud.
    ///
    /// Matches on ids only, never on prose: `cycle.descriptive`'s summary contains the word
    /// "prediction" precisely because it promises not to emit one, and a lint that fired on that
    /// sentence would push authors to stop writing the disclaimer rather than stop writing the
    /// algorithm.
    func testNoPredictiveCycleAlgorithmHasBeenAdded() {
        let banned = ["fertile", "ovulation", "predict", "forecast"]
        for algorithm in registry.all {
            let ids = ([algorithm.algorithmId] + algorithm.producesMetricIds).map { $0.lowercased() }
            for word in banned {
                XCTAssertFalse(ids.contains(where: { $0.contains(word) }),
                               """
                               \(algorithm.algorithmId) declares a predictive id ('\(word)'). Cycle \
                               prediction is gated behind plan A17/A18 + A25 and must arrive as \
                               its own reviewed entry, never as a params tweak to an existing one.
                               """)
            }
        }
    }

    /// Every entry can stamp a row: an algorithm with no semver or no `introducedIn` would write a
    /// `DerivedValue` whose provenance cannot be traced back to a method (I1).
    func testEveryEntryCanStampADerivedValue() {
        for algorithm in registry.all {
            XCTAssertFalse(algorithm.algorithmId.isEmpty)
            XCTAssertFalse(algorithm.semver.isEmpty, "\(algorithm.algorithmId) has no semver")
            XCTAssertFalse(algorithm.introducedIn.isEmpty, "\(algorithm.algorithmId) has no introducedIn")
            XCTAssertFalse(algorithm.algorithmVersion.id.hasPrefix("@"))
        }
    }

    /// A missing `provisional` flag reads as provisional, never as validated — an entry that
    /// forgot the flag must not be presented to a user as a settled number.
    func testMissingProvisionalFlagDefaultsToProvisional() throws {
        let json = Data("""
        {
          "version": "test",
          "algorithms": [
            {"algorithmId": "test.entry", "semver": "0.1.0", "introducedIn": "0.1.0",
             "params": {"k": 1.5}}
          ]
        }
        """.utf8)

        let parsed = AlgorithmRegistry(file: json)
        let entry = try XCTUnwrap(parsed.definition("test.entry"))
        XCTAssertTrue(entry.provisional)
        XCTAssertEqual(entry.params["k"], 1.5)
        XCTAssertTrue(entry.paramNotes.isEmpty)
    }
}
