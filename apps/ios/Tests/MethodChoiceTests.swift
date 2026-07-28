import XCTest
@testable import BADAN

/// D-35 — user-selectable calculation methods for readiness and sleep score.
///
/// These run against the REAL bundled contract, not a fixture. The failure mode they exist for is a
/// contract entry that looks fine in isolation and produces nothing at runtime: a variant that
/// declares different `producesMetricIds`, or omits a param the shared computation requires, loads
/// as `.unavailable` and the engine silently computes nothing — with no error anywhere.
final class MethodChoiceTests: XCTestCase {

    private let readinessMetric = MetricID.readinessScore
    private let sleepMetric = MetricID.sleepScore

    // MARK: - The contract

    /// Every alternative must declare the same `producesMetricIds` as its default. This is what
    /// makes `algorithmId` on the stored row the thing that says which method ran — the precedent
    /// the contract already sets with `workout.strength.e1rm_brzycki`.
    func testEveryAlternativeDeclaresTheSameProducesMetricIdsAsItsDefault() {
        for (metricId, defaultId) in [(readinessMetric, ReadinessSpec.contractId),
                                      (sleepMetric, SleepSpec.scoreContractId)] {
            let expected = Set(try! XCTUnwrap(AlgorithmRegistry.shared.definition(defaultId)).producesMetricIds)
            let methods = MethodResolver.selectableMethods(for: metricId, registry: .shared)
            XCTAssertGreaterThan(methods.count, 1, "\(metricId) should offer alternatives")
            for method in methods {
                XCTAssertEqual(Set(method.producesMetricIds), expected,
                               "\(method.algorithmId) produces something different from \(defaultId), "
                               + "so the stored algorithmId would no longer be what says which "
                               + "method produced the row.")
            }
        }
    }

    /// Every alternative must load a complete spec. A Class-A variant reuses the default's
    /// computation and param NAMES and changes only constants; one that dropped a param would
    /// resolve to `.unavailable` and compute nothing.
    func testEveryReadinessMethodResolvesAParamSetAndProducesALoadedSpec() {
        for method in MethodResolver.selectableMethods(for: readinessMetric, registry: .shared) {
            let spec = ReadinessSpec.load(from: .shared, contractId: method.algorithmId)
            XCTAssertTrue(spec.isLoaded,
                          "\(method.algorithmId) did not load. A variant missing a param the shared "
                          + "computation needs computes nothing, silently.")
            XCTAssertEqual(spec.algorithm.algorithmId, method.algorithmId,
                           "the spec must carry the VARIANT's id — that is what stamps the row")
        }
    }

    func testEverySleepMethodResolvesAParamSetAndProducesALoadedSpec() {
        for method in MethodResolver.selectableMethods(for: sleepMetric, registry: .shared) {
            let spec = SleepSpec.load(from: .shared, scoreContractId: method.algorithmId)
            XCTAssertTrue(spec.isLoaded, "\(method.algorithmId) did not load")
            XCTAssertEqual(spec.score.algorithm.algorithmId, method.algorithmId,
                           "the spec must carry the VARIANT's id — that is what stamps the row")
        }
    }

    /// Every alternative ships `provisional: true`. None of these is validated, and a variant that
    /// cleared the flag would claim evidence that does not exist.
    func testEveryAlternativeIsProvisional() {
        for metricId in [readinessMetric, sleepMetric] {
            for method in MethodResolver.selectableMethods(for: metricId, registry: .shared) {
                XCTAssertTrue(method.provisional,
                              "\(method.algorithmId) is not provisional. BADAN's constants are "
                              + "seeded defaults; clearing the flag requires a stated validation "
                              + "method per D-37's 'Not decided here'.")
            }
        }
    }

    /// The variants must actually differ. Two entries with identical constants would be a choice
    /// between indistinguishable numbers, which is worse than no choice.
    func testTheAlternativesProduceGenuinelyDifferentWeightings() {
        var seen: Set<String> = []
        for method in MethodResolver.selectableMethods(for: readinessMetric, registry: .shared) {
            let spec = ReadinessSpec.load(from: .shared, contractId: method.algorithmId)
            let signature = ReadinessInput.allCases
                .map { String(format: "%.3f", spec.params.weights[$0] ?? -1) }.joined(separator: ",")
            XCTAssertTrue(seen.insert(signature).inserted,
                          "\(method.algorithmId) has the same weights as another method")
        }
    }

    // MARK: - The resolver

    func testNoStoredChoiceResolvesToTheContractDefault() {
        let resolution = MethodResolver.resolve(
            metricId: readinessMetric, contractDefault: ReadinessSpec.contractId,
            profile: CustomizationProfile(), registry: .shared)
        XCTAssertEqual(resolution.algorithmId, ReadinessSpec.contractId)
        XCTAssertNil(resolution.withdrawnChoice)
    }

    func testAStoredChoiceThatStillExistsIsHonoured() {
        var profile = CustomizationProfile()
        profile.methodChoices[readinessMetric] = "composite.readiness_score_autonomic"

        let resolution = MethodResolver.resolve(
            metricId: readinessMetric, contractDefault: ReadinessSpec.contractId,
            profile: profile, registry: .shared)
        XCTAssertEqual(resolution.algorithmId, "composite.readiness_score_autonomic")
        XCTAssertNil(resolution.withdrawnChoice)
    }

    /// The case the resolver exists for: the app updated and the entry the user chose is gone.
    /// Falling back is right; falling back SILENTLY is not — a number computed by a method other
    /// than the one the user believes they picked has to say so.
    func testAStoredChoiceThatNoLongerExistsResolvesToTheDefaultAndIsDisclosed() {
        var profile = CustomizationProfile()
        profile.methodChoices[readinessMetric] = "composite.readiness_score_withdrawn_in_v9"

        let resolution = MethodResolver.resolve(
            metricId: readinessMetric, contractDefault: ReadinessSpec.contractId,
            profile: profile, registry: .shared)
        XCTAssertEqual(resolution.algorithmId, ReadinessSpec.contractId,
                       "a withdrawn choice must fall back, never compute nothing")
        XCTAssertEqual(resolution.withdrawnChoice, "composite.readiness_score_withdrawn_in_v9",
                       "the fallback must be disclosable — silently honouring the default while the "
                       + "user believes another method is active is the mismatch this prevents")
    }

    /// C6. `AlgorithmRegistry.producers(of:)` matches a `"*"` wildcard, and
    /// `baseline.rolling_median_mad` declares it — so the baseline engine comes back as a
    /// "producer" of readiness. It is not a selectable method, and a stored choice of it must not
    /// validate.
    func testTheWildcardBaselineProducerIsNeverOfferedAsAMethod() {
        let raw = AlgorithmRegistry.shared.producers(of: readinessMetric).map(\.algorithmId)
        XCTAssertTrue(raw.contains("baseline.rolling_median_mad"),
                      "precondition: the wildcard producer is still in the registry, so the filter "
                      + "below is still doing work")

        let selectable = MethodResolver.selectableMethods(for: readinessMetric, registry: .shared)
            .map(\.algorithmId)
        XCTAssertFalse(selectable.contains("baseline.rolling_median_mad"),
                       "the baseline engine was offered as a way to compute readiness")

        var profile = CustomizationProfile()
        profile.methodChoices[readinessMetric] = "baseline.rolling_median_mad"
        let resolution = MethodResolver.resolve(
            metricId: readinessMetric, contractDefault: ReadinessSpec.contractId,
            profile: profile, registry: .shared)
        XCTAssertEqual(resolution.algorithmId, ReadinessSpec.contractId,
                       "a stored choice of the wildcard producer must not be honoured")
        XCTAssertNotNil(resolution.withdrawnChoice)
    }

    // MARK: - Copy behind every entry

    /// The guard against adding a contract entry with no copy behind it. `AnatomyStrings.algorithmGlossary`
    /// and `AnatomyFormulas.byAlgorithmId` are both closed dictionaries that render NOTHING for an
    /// unknown id — which is the right default for an unpublished algorithm and the wrong outcome
    /// for a method BADAN is actively offering the user.
    func testEveryOfferedMethodHasAGlossaryEntryAndAFormula() {
        for metricId in [readinessMetric, sleepMetric] {
            for method in MethodResolver.selectableMethods(for: metricId, registry: .shared) {
                XCTAssertNotNil(AnatomyStrings.algorithmGlossary[method.algorithmId],
                                "\(method.algorithmId) is offered as a method but has no glossary "
                                + "entry, so the anatomy sheet explains nothing about it.")
                XCTAssertNotNil(AnatomyFormulas.byAlgorithmId[method.algorithmId],
                                "\(method.algorithmId) is offered as a method but has no formula, "
                                + "so the anatomy sheet shows no formula card for it.")
            }
        }
    }

    // MARK: - The profile field

    func testMethodChoicesDefaultEmpty() {
        XCTAssertTrue(CustomizationProfile().methodChoices.isEmpty)
    }

    func testMethodChoicesDecodeEmptyFromAProfileMissingTheKey() throws {
        var profile = CustomizationProfile()
        profile.methodChoices[readinessMetric] = "composite.readiness_score_equal"
        let encoded = try JSONEncoder().encode(profile)
        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(json["methodChoices"], "precondition: a fresh encode carries the key")
        json.removeValue(forKey: "methodChoices")

        let decoded = try JSONDecoder().decode(
            CustomizationProfile.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(decoded.methodChoices.isEmpty)
    }

    // MARK: - Switching appends; it never rewrites

    /// I2 in the one place D-35 could have broken it. Deriving under a variant must APPEND a row
    /// stamped with that variant, leaving the default-method row it supersedes exactly as it was.
    ///
    /// This is what makes the chart's method-change marker meaningful and what makes "readings
    /// already computed keep the method that produced them" a true statement rather than copy.
    func testDerivingUnderAVariantAppendsAndLeavesTheEarlierRowUntouched() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-methodswitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try Database(directory: tempDir)
        let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
        let tz = TimeZone.current.identifier

        _ = try IngestionPipeline(measurements: MeasurementRepository(db.main),
                                  catalog: CatalogRepository(db.main),
                                  reconciliation: ReconciliationRepository(db.main),
                                  registry: .shared, clock: clock, deviceId: "test-device")
            .ingest(from: FakeHealthStore(clock: clock, historyDays: 90, tz: tz),
                    range: HealthDateRange(start: clock.now().addingTimeInterval(-90 * 86_400),
                                           end: clock.now()))

        let derivation = DerivationRepository(db.main)
        let measurements = MeasurementRepository(db.main)
        func makeReadiness(_ methodId: String) -> ReadinessEngine {
            ReadinessEngine(derivation: derivation, measurements: measurements,
                            clock: clock, deviceId: "test-device",
                            spec: ReadinessSpec.load(from: .shared, contractId: methodId))
        }
        // Baselines first, or readiness has nothing to score against.
        try BaselineEngine(derivation: derivation, measurements: measurements, registry: .shared,
                           clock: clock, deviceId: "test-device")
            .recomputeAll(asOf: clock.now(), tz: tz, includeInterimReadinessComposite: false)

        _ = try makeReadiness(ReadinessSpec.contractId).compute(asOf: clock.now(), tz: tz)
        let defaultRows = try rows(db, metricId: readinessMetric)
        XCTAssertFalse(defaultRows.isEmpty, "precondition: the default method produced a row")
        XCTAssertTrue(defaultRows.allSatisfy { $0.algorithmId == ReadinessSpec.contractId })

        _ = try makeReadiness("composite.readiness_score_autonomic").compute(asOf: clock.now(), tz: tz)
        let afterSwitch = try rows(db, metricId: readinessMetric)

        XCTAssertTrue(afterSwitch.contains { $0.algorithmId == "composite.readiness_score_autonomic" },
                      "deriving under a variant must append a row stamped with that variant")
        for original in defaultRows {
            XCTAssertTrue(afterSwitch.contains { $0.id == original.id && $0.value == original.value },
                          "switching method rewrote or removed a row computed under the old method "
                          + "— derivation appends and supersedes by computedAt (I2), it never "
                          + "rewrites what BADAN believed earlier.")
        }
    }

    private func rows(_ db: Database, metricId: String) throws -> [DerivedValue] {
        try DerivationRepository(db.main).allDerived(metricId: metricId)
    }

    // MARK: - The preview's structural guarantee

    /// The method preview shows each candidate's actual number on the user's own data, and must do
    /// so without writing anything. That is structural rather than conventional: the computation is
    /// a static function of samples and params with no repository parameter at all, so a preview
    /// built on it has nothing to write THROUGH.
    ///
    /// This test states that property in the place someone would look before adding a repository
    /// argument "just for the preview".
    func testComputingEveryCandidateWritesNoDerivedRows() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let db = try Database(directory: tempDir)
        let before = try db.main.query("SELECT COUNT(*) AS n FROM derived_values;").first?.int("n") ?? 0

        // One sample set, every candidate method, exactly as a preview would.
        // z-values chosen to separate the candidates: HRV high, RHR mildly adverse, sleep strong.
        // An autonomic-only method and a sleep-led one must disagree about a day like this.
        func sample(_ input: ReadinessInput, _ z: Double) -> ReadinessInputSample {
            ReadinessInputSample(input: input, measuredValue: 0, z: z, maturity: 1,
                                 provisional: false, recordId: "r-\(input)", sourceId: nil)
        }
        let samples = [sample(.hrv, 1.4), sample(.rhr, -0.6), sample(.sleepPerformance, 1.5)]
        var scores: [String: Double] = [:]
        for method in MethodResolver.selectableMethods(for: readinessMetric, registry: .shared) {
            let spec = ReadinessSpec.load(from: .shared, contractId: method.algorithmId)
            if let computation = ReadinessEngine.composite(present: samples, params: spec.params) {
                scores[method.algorithmId] = computation.score
            }
        }

        XCTAssertGreaterThan(scores.count, 1, "the preview must produce a number per candidate")
        XCTAssertGreaterThan(Set(scores.values.map { Int($0.rounded()) }).count, 1,
                             "the candidates should not all agree on the same score for inputs "
                             + "chosen to separate them — otherwise the choice shows the user "
                             + "four identical numbers")

        let after = try db.main.query("SELECT COUNT(*) AS n FROM derived_values;").first?.int("n") ?? 0
        XCTAssertEqual(after, before,
                       "The method preview wrote derived rows. It cannot call appendDerived because "
                       + "it never holds a DerivationRepository — ReadinessEngine.composite is a "
                       + "static function of samples and params. If this fails, someone has given "
                       + "the preview a repository it has no reason to have.")
    }
}
