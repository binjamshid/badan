import Foundation
import XCTest
@testable import BADAN

/// EPIC-29's correlation engine — the statistical core, and the tests that make its honesty
/// checkable rather than merely claimed.
///
/// The suite is organised around the four things that could quietly stop being true:
/// 1. **The gates hold.** Exactly-at-gate produces a finding; one below any of the three gates
///    produces nothing at all. Suppression is tested as *absence of a stored row*, not just as a
///    different label, because a row that exists is a row some future read path can render.
/// 2. **The null result is shipped.** A fixture with genuinely no association renders "no clear
///    association" — a first-class outcome with authored bilingual copy, not an empty state.
/// 3. **The numbers are reproducible.** The bootstrap is seeded from the contract, so the interval
///    is a pure function of the inputs; the shared fixture pins the exact doubles the Kotlin suite
///    asserts against the same file.
/// 4. **The copy cannot drift.** Every rendered card carries the locked association-not-cause line
///    in both languages, and every authored string passes the wellness lint.
///
/// Cross-platform mirror: `apps/android/app/src/test/java/net/albayyan/badan/CorrelationEngineGoldenTest.kt`.
final class CorrelationEngineTests: XCTestCase {

    private var spec: CorrelationSpec { .defaultShared }
    private var params: CorrelationSpec.Params { spec.params }
    private var templates: InsightTemplateStore { InsightTemplateStore.shared }

    // MARK: - Contract wiring

    /// The published constants resolve through the real bundled contract, exactly as the app loads
    /// them. If the mirror step breaks, every number below would be computed from a spec that never
    /// shipped — which is why this runs first and asserts the values, not just the presence.
    func testSpecLoadsPublishedConstants() {
        XCTAssertTrue(spec.isLoaded, "journal.correlation missing from the bundled algorithms.json")
        XCTAssertEqual(spec.algorithm.id, "journal.correlation@0.1.0")
        XCTAssertEqual(params.minObservedDays, 14, "the plan's N=14 gate")
        XCTAssertEqual(params.minDaysPerArm, 5, "the plan's per-arm gate")
        XCTAssertEqual(params.bootstrapIterations, 2000)
        XCTAssertEqual(params.bootstrapSeed, 29)
        XCTAssertEqual(params.ciLowerPercentile, 0.025, accuracy: 1e-12)
        XCTAssertEqual(params.ciUpperPercentile, 0.975, accuracy: 1e-12)
        XCTAssertEqual(params.confidenceFullNDays, 30, accuracy: 1e-12)
        XCTAssertTrue(params.algorithmProvisional,
                      "the constants are unvalidated, so every row must carry provisional = true")
    }

    /// The context ceiling is read from `ContextAnnotator`, never re-declared in the correlation
    /// params block — the same rule `stress.day_trend` follows for `madToSigma`. Two copies of one
    /// number is the drift the shared contract exists to prevent.
    func testContextCeilingIsNotDuplicatedIntoTheCorrelationParams() {
        XCTAssertNil(AlgorithmRegistry.shared.param("journal.correlation", "contextConfidenceCeiling"))
        XCTAssertNil(AlgorithmRegistry.shared.param("journal.correlation", "activeContextConfidenceCeiling"))
        XCTAssertEqual(ContextAnnotator.activeContextConfidenceCeiling, 0.7, accuracy: 1e-12)
    }

    /// A spec that failed to load must compute nothing rather than fall back to invented gates. For
    /// this engine that is the difference between "no findings yet" and a finding published from a
    /// minimum-n nobody authored.
    func testUnloadedSpecSuppressesEverything() {
        let empty = CorrelationSpec.load(AlgorithmRegistry(file: Data("{\"version\":\"t\",\"algorithms\":[]}".utf8)))
        XCTAssertFalse(empty.isLoaded)
        let days = (0..<40).map { i in
            CorrelationDay(dayKey: dayKey(i), present: i % 2 == 0, nextDayScore: Double(50 + i))
        }
        let outcome = CorrelationEngine.evaluate(behaviorId: "caffeine", scoreId: MetricID.readinessScore,
                                                 days: days, spec: empty)
        XCTAssertNotNil(outcome.suppression, "an unloaded contract must suppress, never guess")
    }

    // MARK: - Metric id pattern

    func testMetricIdComposesAndParsesBackToThePair() throws {
        let id = CorrelationMetricID.metricId(behaviorId: "caffeine", scoreId: MetricID.readinessScore)
        XCTAssertEqual(id, "journal.correlation.caffeine.readiness.score")
        let parsed = try XCTUnwrap(CorrelationMetricID.parse(id))
        XCTAssertEqual(parsed.behaviorId, "caffeine")
        XCTAssertEqual(parsed.scoreId, "readiness.score", "the score id keeps its own dot")
        XCTAssertTrue(CorrelationMetricID.isCorrelationMetricId(id))
    }

    func testUnrelatedMetricIdsAreNotClaimedByTheFamily() {
        for id in [MetricID.readinessScore, MetricID.stressDayTrend, "journal.correlation", "journal.correlation."] {
            XCTAssertNil(CorrelationMetricID.parse(id), "\(id) is not a correlation finding id")
            XCTAssertFalse(CorrelationMetricID.isCorrelationMetricId(id))
        }
    }

    /// The parse rule splits at the first dot after the namespace, so a behaviour key containing a
    /// dot would produce an id that parses back to the wrong pair. Asserted against the shipped
    /// dictionary so adding such a key fails here rather than corrupting stored findings.
    func testEveryBehaviorIdRoundTripsThroughTheIdPattern() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("packages/contracts/dictionaries/behaviors.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        let behaviors = try XCTUnwrap(json?["behaviors"] as? [[String: Any]])
        XCTAssertFalse(behaviors.isEmpty)

        for behavior in behaviors {
            let behaviorId = try XCTUnwrap(behavior["id"] as? String)
            XCTAssertFalse(behaviorId.contains("."),
                           "behaviour id '\(behaviorId)' contains a dot — the finding id pattern "
                               + "splits on the first one, so this would parse back to the wrong pair")
            for scoreId in MetricID.correlatedScores {
                let parsed = CorrelationMetricID.parse(
                    CorrelationMetricID.metricId(behaviorId: behaviorId, scoreId: scoreId))
                XCTAssertEqual(parsed?.behaviorId, behaviorId)
                XCTAssertEqual(parsed?.scoreId, scoreId)
            }
        }
    }

    /// The namespace row is what gives every composed id its sensitivity. Without it, a
    /// registry lookup on a finding id returns nil, and a nil sensitiveClass reads as "not
    /// sensitive" — exactly backwards for the most lifestyle-revealing family BADAN has.
    func testNamespaceRowExistsAndIsSensitivePlus() throws {
        let definition = try XCTUnwrap(MetricRegistry.shared.definition(CorrelationMetricID.namespace))
        XCTAssertEqual(definition.sensitiveClass, .sensitivePlus)
        XCTAssertEqual(definition.family, "journal")
        XCTAssertFalse(definition.baselineEligible, "a correlation finding is not a metric to band")
        XCTAssertFalse(definition.nameAr.isEmpty)
        XCTAssertNotEqual(definition.nameEn, definition.nameAr)
    }

    // MARK: - Cliff's delta goldens (hand-checkable)

    /// Small, exactly-computable cases. Cliff's delta is (#greater − #less) / (n·m), so each of
    /// these can be verified by counting pairs on paper — which is the point of pinning them.
    func testCliffsDeltaGoldens() {
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [10, 11, 12], without: [1, 2, 3]), 1.0, accuracy: 1e-12,
                       "every with-value above every without-value")
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [1, 2, 3], without: [10, 11, 12]), -1.0, accuracy: 1e-12)
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [1, 2, 3], without: [1, 2, 3]), 0.0, accuracy: 1e-12,
                       "identical arms are exactly zero — ties count for neither side")
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [5, 5], without: [5, 5]), 0.0, accuracy: 1e-12,
                       "all ties, not an artefact")
        // 2x2: (3>1, 3>2, 4>1, 4>2) = 4 greater, 0 less -> 4/4.
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [3, 4], without: [1, 2]), 1.0, accuracy: 1e-12)
        // 2x2: 3>1 and 3<4; 2>1 and 2<4 -> 2 greater, 2 less -> 0/4.
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [3, 2], without: [1, 4]), 0.0, accuracy: 1e-12)
        // 3x2: greater = (2>1),(3>1),(3>2)... enumerated: with 1: 0 greater 2 less; with 2: 1 greater 1 less;
        // with 3: 2 greater 0 less -> 3 greater, 3 less -> 0/6.
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [1, 2, 3], without: [2, 3]), -2.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(CorrelationMath.cliffsDelta(with: [], without: [1, 2]), 0.0, accuracy: 1e-12,
                       "an empty arm has no comparison to make")
    }

    func testMedianGoldens() {
        XCTAssertEqual(CorrelationMath.median([3, 1, 2]), 2, accuracy: 1e-12)
        XCTAssertEqual(CorrelationMath.median([4, 1, 3, 2]), 2.5, accuracy: 1e-12)
        XCTAssertEqual(CorrelationMath.median([]), 0, accuracy: 1e-12)
    }

    // MARK: - Determinism

    /// splitmix64's first values from the contract's seed. Pinned because they are the shared
    /// contract with Kotlin: if these change, every interval in the app changes with them.
    func testSeededGeneratorIsPinnedAndPlatformNeutral() {
        var rng = CorrelationMath.SplitMix64(seed: 29)
        let first = (0..<4).map { _ in rng.next() }
        XCTAssertEqual(first, [13_509_472_508_297_990_000,
                               13_427_402_966_873_120_026,
                               16_265_223_287_273_912_455,
                               5_994_361_799_526_217_112])
        // The derived draw indices — the values that actually pick resample members. Pinned
        // separately because the `>> 33` shift is the part Kotlin's `Long`/`ushr` has to reproduce,
        // and a signed-shift mistake there would be invisible in the raw words above.
        var indexRng = CorrelationMath.SplitMix64(seed: 29)
        XCTAssertEqual((0..<4).map { _ in indexRng.index(upperBound: 7) }, [1572709589 % 7, 1563155437 % 7,
                                                                           1893521203 % 7, 697835558 % 7])
    }

    /// The property the whole feature rests on: a correlation that changes when you reopen the app
    /// is not a finding. Same inputs, twice, identical interval.
    func testBootstrapIsDeterministicAcrossRepeatedRuns() {
        let with: [Double] = [74, 78, 71, 80, 76, 69, 77]
        let without: [Double] = [61, 58, 66, 55, 63, 59, 72, 57]
        let a = CorrelationMath.bootstrapInterval(with: with, without: without, params: params)
        let b = CorrelationMath.bootstrapInterval(with: with, without: without, params: params)
        XCTAssertEqual(a.low, b.low, accuracy: 0, "identical, not merely close")
        XCTAssertEqual(a.high, b.high, accuracy: 0)
    }

    func testBootstrapIntervalBracketsThePointEstimate() {
        let with: [Double] = [74, 78, 71, 80, 76, 69, 77]
        let without: [Double] = [61, 58, 66, 55, 63, 59, 72, 57]
        let point = CorrelationMath.cliffsDelta(with: with, without: without)
        let ci = CorrelationMath.bootstrapInterval(with: with, without: without, params: params)
        XCTAssertLessThanOrEqual(ci.low, point)
        XCTAssertGreaterThanOrEqual(ci.high, point)
        XCTAssertGreaterThanOrEqual(ci.low, -1.0)
        XCTAssertLessThanOrEqual(ci.high, 1.0)
    }

    // MARK: - Gates

    /// Exactly at the gate: n = 14 with a 5/9 split is the minimum that may produce a finding.
    func testExactlyAtTheGateProducesAFinding() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "nap", scoreId: MetricID.effortDay,
            days: days(with: [58, 61, 55, 63, 59], without: [44, 47, 41, 60, 45, 43, 48, 46, 42]),
            spec: spec)
        let finding = try XCTUnwrap(outcome.finding, "n = 14 / 5 / 9 is exactly the published minimum")
        XCTAssertEqual(finding.nObserved, 14)
        XCTAssertEqual(finding.nWith, 5)
        XCTAssertEqual(finding.nWithout, 9)
    }

    /// One below the total gate. The arms are individually healthy — only the total is short — so
    /// this fails for the reason the gate exists and no other.
    func testOneBelowTheTotalGateIsSuppressed() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "nap", scoreId: MetricID.effortDay,
            days: days(with: [58, 61, 55, 63, 59], without: [44, 47, 41, 49, 45, 43, 48, 46]),
            spec: spec)
        let suppression = try XCTUnwrap(outcome.suppression, "n = 13 must be suppressed, not hedged")
        XCTAssertEqual(suppression.nObserved, 13)
        guard case let .tooFewObservedDays(needed) = suppression.reason else {
            return XCTFail("expected the total-days shortfall, got \(suppression.reason)")
        }
        XCTAssertEqual(needed, 1, "the user is told exactly how far off they are")
    }

    func testOneBelowTheWithArmGateIsSuppressed() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "sauna_hot_bath", scoreId: MetricID.readinessScore,
            days: days(with: [72, 70, 75, 68],
                       without: [61, 63, 59, 65, 58, 62, 60, 64, 57, 66]),
            spec: spec)
        let suppression = try XCTUnwrap(outcome.suppression)
        XCTAssertEqual(suppression.nObserved, 14, "enough days overall — the ARM is what fails")
        guard case let .tooFewDaysWithBehavior(needed) = suppression.reason else {
            return XCTFail("expected the with-arm shortfall, got \(suppression.reason)")
        }
        XCTAssertEqual(needed, 1)
    }

    /// The near-daily-habit case: plenty of days, almost none without the behaviour. A comparison
    /// needs both arms, and saying so is more honest than a finding built on four days.
    func testOneBelowTheWithoutArmGateIsSuppressed() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "caffeine", scoreId: MetricID.readinessScore,
            days: days(with: [72, 70, 75, 68, 73, 69, 74, 71, 67, 76], without: [61, 63, 59, 65]),
            spec: spec)
        let suppression = try XCTUnwrap(outcome.suppression)
        guard case let .tooFewDaysWithoutBehavior(needed) = suppression.reason else {
            return XCTFail("expected the without-arm shortfall, got \(suppression.reason)")
        }
        XCTAssertEqual(needed, 1)
    }

    /// Days with no next-day score are dropped BEFORE the gates, never counted toward them. 16
    /// logged days minus 3 unpaired leaves 13 — one short, and suppressed accordingly.
    func testUnpairedDaysAreDroppedBeforeTheGateNotCountedTowardIt() throws {
        var input = days(with: [58, 61, 55, 63, 59, 57],
                         without: [44, 47, 41, 49, 45, 43, 48, 46, 42, 50])
        for index in [2, 7, 11] {
            input[index] = CorrelationDay(dayKey: input[index].dayKey, present: input[index].present,
                                          nextDayScore: nil)
        }
        XCTAssertEqual(input.count, 16)
        let suppression = try XCTUnwrap(
            CorrelationEngine.evaluate(behaviorId: "mindfulness", scoreId: MetricID.effortDay,
                                       days: input, spec: spec).suppression,
            "13 pairable days out of 16 logged is still below the gate")
        XCTAssertEqual(suppression.nObserved, 13)
    }

    // MARK: - Directions, including the null result

    func testStrongPositiveRendersAsHigher() throws {
        let finding = try XCTUnwrap(CorrelationEngine.evaluate(
            behaviorId: "wind_down", scoreId: MetricID.readinessScore,
            days: days(with: [74, 78, 71, 80, 76, 69, 77], without: [61, 58, 66, 55, 63, 59, 72, 57]),
            spec: spec).finding)
        XCTAssertEqual(finding.direction, .higher)
        XCTAssertGreaterThan(finding.ciLow, 0, "the whole interval is above zero")
        XCTAssertFalse(finding.spansZero)
    }

    func testStrongNegativeRendersAsLower() throws {
        let finding = try XCTUnwrap(CorrelationEngine.evaluate(
            behaviorId: "alcohol", scoreId: MetricID.sleepPerformance,
            days: days(with: [62, 58, 66, 55, 80, 60, 57], without: [84, 88, 79, 91, 82, 86, 59, 90]),
            spec: spec).finding)
        XCTAssertEqual(finding.direction, .lower)
        XCTAssertLessThan(finding.ciHigh, 0)
    }

    /// **The null case.** Both gates cleared, the interval straddles zero, and the honest answer is
    /// reported as a finding with authored copy — not withheld, not softened into a hit.
    func testNullCaseIsReportedAsAFindingThatSaysNoClearAssociation() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "electrolytes", scoreId: MetricID.readinessScore,
            days: days(with: [70, 64, 75, 61, 68, 73, 66], without: [72, 63, 69, 74, 65, 71, 67, 62]),
            spec: spec)
        let finding = try XCTUnwrap(outcome.finding, "a null result is a RESULT — it must not suppress")
        XCTAssertEqual(finding.direction, .noClearAssociation)
        XCTAssertLessThanOrEqual(finding.ciLow, 0)
        XCTAssertGreaterThanOrEqual(finding.ciHigh, 0)

        let card = CorrelationRenderer.render(outcome, behavior: label("Electrolytes", "أملاح معدنية"),
                                              score: label("Readiness", "الجاهزية"),
                                              templates: templates, params: params)
        XCTAssertEqual(card.templateId, "journal_correlation_none")
        XCTAssertTrue(card.casualText.en.lowercased().contains("no clear association"),
                      "the null outcome must SAY so: \(card.casualText.en)")
        XCTAssertTrue(card.casualText.ar.contains("لا يوجد ارتباط واضح"), card.casualText.ar)
        XCTAssertFalse(card.isSuppressed)
        XCTAssertNotNil(card.powerText, "a null finding still shows its numbers")
    }

    /// The interval decides the direction, not the point estimate. A clearly non-zero delta whose
    /// interval crosses zero must still read as "no clear association".
    func testDirectionFollowsTheIntervalNotThePointEstimate() {
        let finding = CorrelationFinding(
            behaviorId: "late_meal", scoreId: MetricID.readinessScore, nObserved: 20, nWith: 9,
            nWithout: 11, delta: -0.4, ciLow: -0.8, ciHigh: 0.1, medianWith: 60, medianWithout: 65,
            contextDays: 0, confidence: 0.3, provisional: true,
            firstDayKey: "2026-03-01", lastDayKey: "2026-03-20")
        XCTAssertEqual(finding.direction, .noClearAssociation,
                       "a centre of −0.4 with an interval crossing zero is not a direction")
    }

    // MARK: - Context annotation

    /// Declared context days are counted and disclosed, the confidence is capped — and every day
    /// stays in the comparison. Dropping them would silently change what the finding is about.
    func testContextDaysReduceConfidenceAndAreNeverDropped() throws {
        let withScores: [Double] = [62, 58, 66, 55, 61, 60, 57, 64, 59, 63, 56, 65, 54, 81, 53]
        let withoutScores: [Double] = [84, 88, 79, 91, 82, 86, 60.5, 90, 83, 87, 80, 89, 78, 85, 92]
        let plain = days(with: withScores, without: withoutScores)
        var annotated = plain
        for index in 0..<6 {
            annotated[index] = CorrelationDay(dayKey: plain[index].dayKey, present: plain[index].present,
                                              nextDayScore: plain[index].nextDayScore,
                                              inDeclaredContext: true)
        }

        let clean = try XCTUnwrap(CorrelationEngine.evaluate(behaviorId: "screen_in_bed",
                                                            scoreId: MetricID.sleepPerformance,
                                                            days: plain, spec: spec).finding)
        let withContext = try XCTUnwrap(CorrelationEngine.evaluate(behaviorId: "screen_in_bed",
                                                                   scoreId: MetricID.sleepPerformance,
                                                                   days: annotated, spec: spec).finding)

        XCTAssertEqual(withContext.contextDays, 6)
        XCTAssertEqual(withContext.nObserved, clean.nObserved, "no day was removed")
        XCTAssertEqual(withContext.nWith, clean.nWith)
        XCTAssertEqual(withContext.nWithout, clean.nWithout)
        XCTAssertEqual(withContext.delta, clean.delta, accuracy: 0, "the VALUE is untouched by context")
        XCTAssertEqual(withContext.ciLow, clean.ciLow, accuracy: 0)
        XCTAssertEqual(withContext.ciHigh, clean.ciHigh, accuracy: 0)

        XCTAssertGreaterThan(clean.confidence, ContextAnnotator.activeContextConfidenceCeiling,
                             "fixture must be strong enough that the cap is observable")
        XCTAssertEqual(withContext.confidence, ContextAnnotator.activeContextConfidenceCeiling, accuracy: 1e-12)

        let card = CorrelationRenderer.render(.finding(withContext), behavior: label("Screen in bed", "شاشة في السرير"),
                                              score: label("Sleep performance", "أداء النوم"),
                                              templates: templates, params: params)
        let note = try XCTUnwrap(card.contextNote, "context must be disclosed, not silently applied")
        XCTAssertTrue(note.en.contains("6"))
        XCTAssertTrue(note.en.lowercased().contains("still counted"), note.en)
        XCTAssertTrue(note.ar.contains("محسوبة"), note.ar)
    }

    // MARK: - Shared fixture (cross-platform parity)

    /// The same input file the Kotlin suite reads, and the same expected doubles. This is what makes
    /// "identical across platforms" an assertion rather than an aspiration — the two suites never
    /// see each other, they both see this file.
    func testSharedFixtureMatchesOnThisPlatform() throws {
        let cases = try fixtureCases()
        let expected = try fixtureExpectations()
        XCTAssertEqual(cases.count, expected.count)
        XCTAssertGreaterThanOrEqual(cases.count, 9, "the fixture set lost cases")

        for entry in cases {
            let id = entry["id"] as! String
            let expect = try XCTUnwrap(expected[id], "no expectation for case \(id)")
            let days = (entry["days"] as! [[String: Any]]).map { day in
                CorrelationDay(dayKey: day["dayKey"] as! String,
                               present: day["present"] as! Bool,
                               nextDayScore: day["nextDayScore"] as? Double,
                               inDeclaredContext: day["inDeclaredContext"] as? Bool ?? false)
            }
            let outcome = CorrelationEngine.evaluate(behaviorId: entry["behaviorId"] as! String,
                                                     scoreId: entry["scoreId"] as! String,
                                                     days: days, spec: spec)
            switch expect["kind"] as! String {
            case "suppressed":
                let suppression = try XCTUnwrap(outcome.suppression, "\(id) should be suppressed")
                XCTAssertEqual(suppression.nObserved, expect["nObserved"] as? Int, "\(id) n")
                XCTAssertEqual(suppression.nWith, expect["nWith"] as? Int, "\(id) nWith")
                XCTAssertEqual(suppression.nWithout, expect["nWithout"] as? Int, "\(id) nWithout")
                XCTAssertEqual(suppression.reason.moreDaysNeeded, expect["moreDaysNeeded"] as? Int, "\(id) shortfall")
                XCTAssertEqual(reasonName(suppression.reason), expect["reason"] as? String, "\(id) reason")
            case "finding":
                let finding = try XCTUnwrap(outcome.finding, "\(id) should produce a finding")
                XCTAssertEqual(finding.nObserved, expect["nObserved"] as? Int, "\(id) n")
                XCTAssertEqual(finding.nWith, expect["nWith"] as? Int, "\(id) nWith")
                XCTAssertEqual(finding.nWithout, expect["nWithout"] as? Int, "\(id) nWithout")
                XCTAssertEqual(finding.delta, expect["delta"] as! Double, accuracy: 1e-12, "\(id) delta")
                XCTAssertEqual(finding.ciLow, expect["ciLow"] as! Double, accuracy: 1e-12, "\(id) ciLow")
                XCTAssertEqual(finding.ciHigh, expect["ciHigh"] as! Double, accuracy: 1e-12, "\(id) ciHigh")
                XCTAssertEqual(finding.medianWith, expect["medianWith"] as! Double, accuracy: 1e-12, "\(id) medianWith")
                XCTAssertEqual(finding.medianWithout, expect["medianWithout"] as! Double, accuracy: 1e-12,
                               "\(id) medianWithout")
                XCTAssertEqual(finding.contextDays, expect["contextDays"] as? Int, "\(id) contextDays")
                XCTAssertEqual(finding.confidence, expect["confidence"] as! Double, accuracy: 1e-12, "\(id) confidence")
                XCTAssertEqual(finding.direction.rawValue, expect["direction"] as? String, "\(id) direction")
                XCTAssertEqual(finding.periodKey, expect["periodKey"] as? String, "\(id) periodKey")
            default:
                XCTFail("unknown expectation kind for \(id)")
            }
        }
    }

    // MARK: - Persistence (I2 + I7)

    /// Findings are appended to the SENSITIVE database. The metric id names the behaviour, so a row
    /// in `badan.db` would survive the sensitive purge and keep disclosing it — this asserts the
    /// placement rather than trusting the comment that explains it.
    func testFindingsAreWrittenToTheSensitiveDatabaseOnly() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.seedJournalAndScores()

        let outcomes = try harness.engine.recompute(asOf: harness.asOf, tz: "UTC")
        XCTAssertFalse(outcomes.isEmpty)

        let stored = try harness.findings.latestFindings()
        XCTAssertFalse(stored.isEmpty, "a passing pair must be persisted")
        XCTAssertTrue(stored.allSatisfy { CorrelationMetricID.isCorrelationMetricId($0.metricId) })

        // Nothing landed in the main derived_values table.
        for row in stored {
            XCTAssertNil(try harness.derivation.latestDerived(metricId: row.metricId, periodKey: row.periodKey),
                         "\(row.metricId) leaked into badan.db — that row survives the sensitive purge")
        }

        // And the purge takes them, because the file goes.
        try harness.db.purgeSensitiveNamespace()
        XCTAssertTrue(try harness.findings.latestFindings().isEmpty,
                      "the sensitive purge must remove every correlation finding")
    }

    /// Suppressed pairs write NOTHING. The storage half of the small-n invariant: a suppressed
    /// finding must not exist as a row a future read path could render without re-checking the gate.
    func testSuppressedPairsPersistNothing() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        // Only 6 journaled days — far below the gate for every behaviour and every score.
        try harness.seedJournalAndScores(days: 6)

        let outcomes = try harness.engine.recompute(asOf: harness.asOf, tz: "UTC")
        XCTAssertFalse(outcomes.isEmpty, "the pairs are still evaluated and reported to the caller")
        XCTAssertTrue(outcomes.allSatisfy { $0.finding == nil }, "nothing may clear the gate on 6 days")
        XCTAssertTrue(try harness.findings.latestFindings().isEmpty,
                      "a suppressed pair must leave no row behind")
    }

    /// Append-only (I2), and idempotent at the read model: a repeat run over unchanged data writes
    /// nothing rather than growing the table with copies of the same belief.
    func testRecomputeIsAppendOnlyAndSkipsIdenticalRows() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.seedJournalAndScores()

        _ = try harness.engine.recompute(asOf: harness.asOf, tz: "UTC")
        let first = try harness.findings.latestFindings()
        let metricId = try XCTUnwrap(first.first?.metricId)
        XCTAssertEqual(try harness.findings.allDerived(metricId: metricId).count, 1)

        _ = try harness.engine.recompute(asOf: harness.asOf, tz: "UTC")
        XCTAssertEqual(try harness.findings.allDerived(metricId: metricId).count, 1,
                       "an unchanged recompute must not append a duplicate")
    }

    /// The `stat:` manifest convention round-trips: everything power mode shows is read back from
    /// what was written, so the two halves cannot drift into showing an interval nobody computed.
    func testFindingRoundTripsThroughTheStoredRowAndManifest() throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try harness.seedJournalAndScores()
        _ = try harness.engine.recompute(asOf: harness.asOf, tz: "UTC")

        let row = try XCTUnwrap(try harness.findings.latestFindings().first)
        let manifest = try harness.findings.manifest(id: try XCTUnwrap(row.inputManifestId))
        let restored = try XCTUnwrap(CorrelationFinding.from(derived: row, manifest: manifest))

        XCTAssertEqual(restored.metricId, row.metricId)
        XCTAssertEqual(restored.delta, row.value, accuracy: 0)
        XCTAssertEqual(restored.nObserved, restored.nWith + restored.nWithout)
        XCTAssertGreaterThanOrEqual(restored.nObserved, params.minObservedDays)
        XCTAssertLessThanOrEqual(restored.ciLow, restored.delta)
        XCTAssertGreaterThanOrEqual(restored.ciHigh, restored.delta)
        XCTAssertEqual(restored.periodKey, row.periodKey)
        XCTAssertTrue(row.provisional, "the contract entry is provisional, so the row must say so")
        XCTAssertEqual(row.unit, "index")

        // The per-day inputs carry the arm in `weight`, and the counts agree with the statistics.
        let dayInputs = (manifest?.inputs ?? []).filter { !$0.recordId.hasPrefix("stat:") }
        XCTAssertEqual(dayInputs.count, restored.nObserved)
        XCTAssertEqual(dayInputs.filter { $0.weight == 1 }.count, restored.nWith)
        XCTAssertEqual(dayInputs.filter { $0.weight == 0 }.count, restored.nWithout)
    }

    /// The reader FAILS CLOSED: a stored row whose manifest lost its interval rebuilds to nothing,
    /// never to a finding carrying a direction.
    ///
    /// `direction` is decided by the interval alone, so a reader that defaulted a missing bound to
    /// the point estimate would hand back `ciLow == ciHigh == delta` — asserted below to read as a
    /// **confident** `.higher` over `nObserved == 0`, indistinguishable on screen from one the
    /// bootstrap actually earned. A statistical claim assembled out of missing data is the worst
    /// outcome this feature has available to it, so every degraded manifest here must produce nil.
    /// Mirror: `CorrelationEngineGoldenTest.aFindingRebuiltWithoutItsIntervalIsRefused`.
    func testAFindingRebuiltWithoutItsIntervalIsRefusedRatherThanGivenADirection() throws {
        let finding = CorrelationFinding(
            behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 20, nWith: 9,
            nWithout: 11, delta: 0.62, ciLow: 0.21, ciHigh: 0.88, medianWith: 70, medianWithout: 61,
            contextDays: 0, confidence: 0.5, provisional: true,
            firstDayKey: "2026-03-01", lastDayKey: "2026-03-20")
        let complete = CorrelationEngine.manifestInputs(for: finding, days: [])
        let row = DerivedValue(
            id: "row", metricId: finding.metricId, value: finding.delta, unit: "index",
            periodKey: finding.periodKey, confidence: finding.confidence, provisional: true,
            algorithmId: spec.algorithm.algorithmId, algorithmVersion: spec.algorithm.semver,
            inputManifestId: "manifest", computedAt: Date(), updatedAt: Date(), originDeviceId: "test")

        // The hazard, stated as an assertion rather than as a comment: an interval collapsed onto
        // the point estimate IS a confident direction.
        XCTAssertEqual(CorrelationFinding(
            behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 0, nWith: 0,
            nWithout: 0, delta: 0.62, ciLow: 0.62, ciHigh: 0.62, medianWith: 0, medianWithout: 0,
            contextDays: 0, confidence: 0, provisional: true, firstDayKey: "", lastDayKey: "").direction,
            .higher, "this is the fabricated result the reader must never produce")

        // Intact, it rebuilds and keeps the direction the bootstrap earned.
        let intact = try XCTUnwrap(CorrelationFinding.from(
            derived: row, manifest: InputManifest(id: "manifest", inputs: complete)))
        XCTAssertEqual(intact.direction, .higher)
        XCTAssertEqual(intact.ciLow, 0.21, accuracy: 0)
        XCTAssertEqual(intact.ciHigh, 0.88, accuracy: 0)

        func without(_ recordIds: String...) -> InputManifest {
            InputManifest(id: "manifest", inputs: complete.filter { !recordIds.contains($0.recordId) })
        }
        func replacing(_ recordId: String, with value: Double) -> InputManifest {
            InputManifest(id: "manifest", inputs: complete.map {
                $0.recordId == recordId
                    ? InputManifest.Input(recordId: $0.recordId, metricId: $0.metricId, value: value)
                    : $0
            })
        }

        let refused: [(String, InputManifest?)] = [
            ("no manifest at all", nil),
            ("lower bound missing", without("stat:ci_low")),
            ("upper bound missing", without("stat:ci_high")),
            ("both bounds missing", without("stat:ci_low", "stat:ci_high")),
            ("undecodable lower bound", replacing("stat:ci_low", with: .nan)),
            ("infinite upper bound", replacing("stat:ci_high", with: .infinity)),
            ("bounds the wrong way round", replacing("stat:ci_low", with: 0.95)),
            ("sample size missing", without("stat:n")),
            ("undecodable sample size", replacing("stat:n", with: .nan)),
        ]
        for (label, manifest) in refused {
            XCTAssertNil(CorrelationFinding.from(derived: row, manifest: manifest),
                         "\(label): must rebuild nothing rather than a finding with a direction")
        }
    }

    // MARK: - Copy: the locked line, both languages, every outcome

    /// The one rule with no exceptions. Rendered over every outcome the engine can produce —
    /// higher, lower, null, and all three suppressions.
    func testEveryRenderedCardCarriesTheAssociationNotCauseLine() throws {
        let locked = try XCTUnwrap(templates.template(CorrelationRenderer.lockedTemplateId))
        XCTAssertEqual(locked.textEn, CorrelationRenderer.associationNotCauseFallback.en,
                       "the fallback must stay verbatim-equal to the contract copy")
        XCTAssertEqual(locked.textAr, CorrelationRenderer.associationNotCauseFallback.ar)

        for outcome in everyOutcomeShape() {
            let card = CorrelationRenderer.render(outcome, behavior: label("Caffeine", "الكافيين"),
                                                  score: label("Readiness", "الجاهزية"),
                                                  templates: templates, params: params)
            XCTAssertEqual(card.associationNotCause.en, locked.textEn)
            XCTAssertEqual(card.associationNotCause.ar, locked.textAr)
            XCTAssertTrue(card.lines.contains(card.associationNotCause),
                          "the locked line must be one of the rendered lines for \(card.templateId)")
            XCTAssertTrue(card.associationNotCause.en.lowercased().contains("not a cause"))
            XCTAssertTrue(card.associationNotCause.ar.contains("وليس سببًا"))
        }
    }

    /// Suppression tells the user what would resolve it, in both languages, and shows no statistics
    /// — there are none to show, which is the point. Spans the 1 singular / 2 dual / 3-10 plural /
    /// 11+ indeclinable boundary the Arabic count-noun rule requires (mirrors
    /// `StressPresentation.dayCount` / `CalibrationCount.dayPhrase`): a shortfall of exactly 2 must
    /// render the dual noun form, not a bare digit with no noun at all, and a shortfall of 3-10
    /// must not fall back to the 11+ indeclinable form. An earlier version of this test only
    /// asserted that the digit string appeared somewhere in the sentence, which a hardcoded 11+
    /// noun form satisfies for every n — that is exactly the bug this expanded case list catches.
    ///
    /// The n=2 cases assert the OBLIQUE dual (يومين إضافيين / يومين مسجّلين إضافيين), not the
    /// nominative "يومان" the day-count rule defaults to elsewhere: all three of these templates
    /// place the phrase directly after "نحو" ("about"), which governs its complement as an idafa
    /// genitive ("نحو يومين", never "نحو يومان" — the same reason "نحو عشرين رجلاً" takes the
    /// oblique). See the `CorrelationRenderer.render` case comment for the full explanation.
    func testSuppressionCopyNamesTheShortfallAndShowsNoNumbers() throws {
        let cases: [(CorrelationSuppressionReason, String, String, String)] = [
            (.tooFewObservedDays(moreDaysNeeded: 1), "journal_correlation_needs_days",
             "1 more day", "يوم واحد إضافي"),
            (.tooFewObservedDays(moreDaysNeeded: 2), "journal_correlation_needs_days",
             "2 more days", "يومين إضافيين"),
            (.tooFewObservedDays(moreDaysNeeded: 3), "journal_correlation_needs_days",
             "3 more days", "3 أيام إضافية"),
            (.tooFewObservedDays(moreDaysNeeded: 14), "journal_correlation_needs_days",
             "14 more days", "14 يومًا إضافيًا"),
            (.tooFewDaysWithBehavior(moreDaysNeeded: 1), "journal_correlation_needs_with_days",
             "1 more day of this kind", "يوم واحد إضافي من هذا النوع"),
            (.tooFewDaysWithBehavior(moreDaysNeeded: 2), "journal_correlation_needs_with_days",
             "2 more days of this kind", "يومين إضافيين من هذا النوع"),
            (.tooFewDaysWithoutBehavior(moreDaysNeeded: 1), "journal_correlation_needs_without_days",
             "1 more logged day without it", "يوم واحد مسجّل إضافي بدونه"),
            (.tooFewDaysWithoutBehavior(moreDaysNeeded: 2), "journal_correlation_needs_without_days",
             "2 more logged days without it", "يومين مسجّلين إضافيين بدونه"),
            (.tooFewDaysWithoutBehavior(moreDaysNeeded: 4), "journal_correlation_needs_without_days",
             "4 more logged days without it", "4 أيام مسجّلة إضافية بدونه"),
        ]
        for (reason, templateId, expectedEn, expectedAr) in cases {
            let outcome = CorrelationOutcome.suppressed(CorrelationSuppression(
                behaviorId: "caffeine", scoreId: MetricID.readinessScore,
                nObserved: 12, nWith: 3, nWithout: 9, reason: reason))
            let card = CorrelationRenderer.render(outcome, behavior: label("Caffeine", "الكافيين"),
                                                  score: label("Readiness", "الجاهزية"),
                                                  templates: templates, params: params)
            XCTAssertEqual(card.templateId, templateId)
            XCTAssertTrue(card.isSuppressed)
            XCTAssertNil(card.powerText, "a suppressed pair has no statistics — showing any would be the leak")
            XCTAssertTrue(card.casualText.en.contains(expectedEn),
                          "expected '\(expectedEn)' in: \(card.casualText.en)")
            XCTAssertTrue(card.casualText.ar.contains(expectedAr),
                          "expected '\(expectedAr)' in: \(card.casualText.ar)")
            XCTAssertFalse(card.casualText.en.contains("{"), "unfilled placeholder in \(templateId)")
            XCTAssertFalse(card.casualText.ar.contains("{"), "unfilled placeholder in \(templateId) (ar)")
        }
    }

    /// Direct boundary test of the Arabic count-noun agreement helper, independent of template
    /// rendering — mirrors `StressSurfacesTests`' direct test of `StressPresentation.dayCount`.
    func testCorrelationDayCountFollowsArabicNumberAgreement() {
        func phrase(_ n: Int) -> LocalizedString {
            CorrelationRenderer.CorrelationDayCount.phrase(n, enSingular: "1 more day", enPlural: "more days",
                arSingular: "يوم واحد إضافي", arDual: "يومان إضافيان",
                arPlural: "أيام إضافية", arMany: "يومًا إضافيًا")
        }
        XCTAssertEqual(phrase(1).en, "1 more day")
        XCTAssertEqual(phrase(1).ar, "يوم واحد إضافي")
        XCTAssertEqual(phrase(2).en, "2 more days")
        XCTAssertEqual(phrase(2).ar, "يومان إضافيان")
        XCTAssertEqual(phrase(7).en, "7 more days")
        XCTAssertEqual(phrase(7).ar, "7 أيام إضافية")
        XCTAssertEqual(phrase(14).en, "14 more days")
        XCTAssertEqual(phrase(14).ar, "14 يومًا إضافيًا")
    }

    /// Closes the audit finding directly: nWith in a rendered finding only has to clear
    /// minDaysPerArm (5), so it lands in the Arabic 3-10 plural bracket ("أيام") at least as often
    /// as the 11+ indeclinable bracket ("يومًا") — the two must never be confused.
    func testFindingCopyUsesTheArabicPluralForAWithArmCountInThePluralBracket() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "wind_down", scoreId: MetricID.readinessScore,
            days: days(with: [74, 78, 71, 80, 76, 69, 77], without: [61, 58, 66, 55, 63, 59, 72, 57]),
            spec: spec)
        let finding = try XCTUnwrap(outcome.finding)
        XCTAssertEqual(finding.nWith, 7, "7 is in the 3-10 plural bracket, not 11+")
        let card = CorrelationRenderer.render(outcome, behavior: label("Wind-down", "روتين تهدئة"),
                                              score: label("Readiness", "الجاهزية"),
                                              templates: templates, params: params)
        XCTAssertTrue(card.casualText.ar.contains("7 أيام"), card.casualText.ar)
        XCTAssertFalse(card.casualText.ar.contains("7 يومًا"),
                       "11+ indeclinable form used for a 3-10 count: \(card.casualText.ar)")
    }

    /// Power mode shows n, the effect size and the interval as NUMBERS, read from the same finding
    /// the casual sentence is built from (D-5) — never a second computation.
    func testPowerModeShowsTheNumbersFromTheSameComputation() throws {
        let outcome = CorrelationEngine.evaluate(
            behaviorId: "wind_down", scoreId: MetricID.readinessScore,
            days: days(with: [74, 78, 71, 80, 76, 69, 77], without: [61, 58, 66, 55, 63, 59, 72, 57]),
            spec: spec)
        let finding = try XCTUnwrap(outcome.finding)
        let card = CorrelationRenderer.render(outcome, behavior: label("Wind-down", "روتين تهدئة"),
                                              score: label("Readiness", "الجاهزية"),
                                              templates: templates, params: params)
        let power = try XCTUnwrap(card.powerText)
        for expected in ["\(finding.nObserved)", "\(finding.nWith)", "\(finding.nWithout)",
                         CorrelationRenderer.twoDecimals(finding.delta),
                         CorrelationRenderer.twoDecimals(finding.ciLow),
                         CorrelationRenderer.twoDecimals(finding.ciHigh),
                         "\(params.bootstrapIterations)"] {
            XCTAssertTrue(power.en.contains(expected), "power line is missing \(expected): \(power.en)")
            XCTAssertTrue(power.ar.contains(expected), "Arabic power line is missing \(expected): \(power.ar)")
        }
        // Casual and power describe the same n — one computation, two altitudes.
        XCTAssertTrue(card.casualText.en.contains("\(finding.nObserved)"))
    }

    /// Every correlation template is authored in both languages, in real Arabic script, with no
    /// placeholder left unfilled by the engine's own vocabulary.
    func testCorrelationTemplatesAreBilingualAndComplete() throws {
        let correlationTemplates = templates.templates.filter { $0.templateId.hasPrefix("journal_correlation_") }
        XCTAssertEqual(correlationTemplates.count, 9, "the nine EPIC-29 templates")
        let known = Set(["behavior", "score", "n", "nPhrase", "nWith", "nWithPhrase", "nWithout", "days",
                         "delta", "ciLow", "ciHigh", "confidence", "iterations"])
        for template in correlationTemplates {
            XCTAssertEqual(template.metricFamily, "journal")
            XCTAssertFalse(template.textEn.isEmpty, "\(template.templateId) has no English")
            XCTAssertFalse(template.textAr.isEmpty, "\(template.templateId) has no Arabic")
            XCTAssertNotEqual(template.textEn, template.textAr, "\(template.templateId) is untranslated")
            XCTAssertTrue(template.textAr.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(template.templateId)'s Arabic is not in Arabic script")
            XCTAssertFalse(template.conditionEn.isEmpty, "\(template.templateId) documents no condition")
            for text in [template.textEn, template.textAr] {
                for token in placeholders(in: text) {
                    XCTAssertTrue(known.contains(token),
                                  "\(template.templateId) uses {\(token)}, which the renderer never fills")
                }
            }
        }
    }

    /// The wellness lint, over every string this feature can put on screen. Causal verbs are the
    /// specific hazard here — a correlation surface is where "caused" gets written by accident.
    func testCorrelationCopyIsWellnessSafe() {
        let bannedEn = ["causes", "caused by", "because of", "proves", "leads to", "you should",
                        "you must", "stop ", "avoid ", "risk", "danger", "abnormal", "diagnos",
                        "disease", "unhealthy", "bad for you", "harmful", "significant"]
        let bannedAr = ["يسبب", "بسبب", "يثبت", "يؤدي إلى", "خطر", "مرض", "تشخيص", "توقف عن", "تجنب"]
        var strings: [(String, LocalizedString)] = templates.templates
            .filter { $0.templateId.hasPrefix("journal_correlation_") }
            .map { ($0.templateId, $0.text) }
        strings.append(("associationNotCauseFallback", CorrelationRenderer.associationNotCauseFallback))
        for magnitude in [CorrelationMagnitude.negligible, .small, .medium, .large] {
            strings.append(("magnitude.\(magnitude.rawValue)", magnitude.displayLabel))
        }

        for (name, text) in strings {
            let en = text.en.lowercased()
            for phrase in bannedEn {
                // "not a cause" is the LOCKED disclaimer; a lint that fired on the word would push
                // authors to delete the disclaimer rather than the causal claim.
                if phrase == "causes" && en.contains("not a cause") { continue }
                XCTAssertFalse(en.contains(phrase), "\(name) contains the banned frame \"\(phrase)\": \(text.en)")
            }
            for phrase in bannedAr {
                XCTAssertFalse(text.ar.contains(phrase), "\(name) Arabic contains the banned frame \"\(phrase)\"")
            }
        }
    }

    /// The method is non-parametric, and the source has to keep saying so. A scan rather than a
    /// comment: adding a t-test, a z-score or a p-value here would be a quiet change to what the
    /// published numbers MEAN, and the acceptance criterion is "no parametric test anywhere".
    func testEngineSourceContainsNoParametricMachinery() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sources = [
            "apps/ios/Sources/Domain/Derivation/CorrelationEngine.swift",
            "apps/android/app/src/main/java/net/albayyan/badan/domain/derivation/CorrelationEngine.kt",
        ]
        // Matched on CODE tokens, never on prose: the doc comments discuss t-tests and normality
        // precisely because the engine refuses them, and a lint that fired on that discussion would
        // push an author to delete the explanation instead of the statistic.
        let banned = ["tTest", "t_test", "studentT", "pValue", "p_value", "stdDev", "standardDeviation",
                      "variance(", "zScore(", "normalCDF", "criticalValue"]
        for path in sources {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for token in banned {
                XCTAssertFalse(Self.containsIdentifier(token, in: text),
                               "\(path) references \(token) — this engine is non-parametric by contract")
            }
        }
    }

    /// Substring matching would be wrong here and was: Kotlin's `mapValues` contains "pValue", so a
    /// plain `contains` failed this lint on a standard-library call. A match only counts when it
    /// starts an identifier — i.e. the preceding character is not itself identifier material.
    private static func containsIdentifier(_ token: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: token, range: searchRange) {
            let precededByIdentifierCharacter: Bool
            if found.lowerBound == text.startIndex {
                precededByIdentifierCharacter = false
            } else {
                let previous = text[text.index(before: found.lowerBound)]
                precededByIdentifierCharacter = previous.isLetter || previous.isNumber || previous == "_"
            }
            if !precededByIdentifierCharacter { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }

    // MARK: - Helpers

    private func dayKey(_ offset: Int) -> String {
        let start = DayAttribution.date(fromDayKey: "2026-03-01", tz: "UTC")!
        return DayAttribution.localDayKey(DayAttribution.addingDays(offset, to: start, tz: "UTC"), tz: "UTC")
    }

    /// Interleave the two arms day by day, exactly as the shared fixture does, so a case written
    /// here and the same case in the fixture describe the same logged week.
    private func days(with withScores: [Double], without withoutScores: [Double]) -> [CorrelationDay] {
        var out: [CorrelationDay] = []
        var wi = 0, woi = 0, i = 0
        while wi < withScores.count || woi < withoutScores.count {
            let takeWith = (i % 2 == 0 && wi < withScores.count) || woi >= withoutScores.count
            if takeWith {
                out.append(CorrelationDay(dayKey: dayKey(i), present: true, nextDayScore: withScores[wi]))
                wi += 1
            } else {
                out.append(CorrelationDay(dayKey: dayKey(i), present: false, nextDayScore: withoutScores[woi]))
                woi += 1
            }
            i += 1
        }
        return out
    }

    private func label(_ en: String, _ ar: String) -> LocalizedString { LocalizedString(en: en, ar: ar) }

    private func reasonName(_ reason: CorrelationSuppressionReason) -> String {
        switch reason {
        case .tooFewObservedDays: return "tooFewObservedDays"
        case .tooFewDaysWithBehavior: return "tooFewDaysWithBehavior"
        case .tooFewDaysWithoutBehavior: return "tooFewDaysWithoutBehavior"
        }
    }

    private func placeholders(in text: String) -> [String] {
        var out: [String] = []
        var current: String?
        for character in text {
            if character == "{" { current = "" } else if character == "}" {
                if let value = current { out.append(value) }
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return out
    }

    /// One outcome of every shape the engine can produce, for the copy assertions.
    private func everyOutcomeShape() -> [CorrelationOutcome] {
        let base = CorrelationFinding(
            behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 20, nWith: 9,
            nWithout: 11, delta: 0.5, ciLow: 0.2, ciHigh: 0.8, medianWith: 70, medianWithout: 60,
            contextDays: 0, confidence: 0.5, provisional: true,
            firstDayKey: "2026-03-01", lastDayKey: "2026-03-20")
        let lower = CorrelationFinding(
            behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 20, nWith: 9,
            nWithout: 11, delta: -0.5, ciLow: -0.8, ciHigh: -0.2, medianWith: 60, medianWithout: 70,
            contextDays: 3, confidence: 0.5, provisional: true,
            firstDayKey: "2026-03-01", lastDayKey: "2026-03-20")
        let null = CorrelationFinding(
            behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 20, nWith: 9,
            nWithout: 11, delta: 0.02, ciLow: -0.4, ciHigh: 0.45, medianWith: 65, medianWithout: 65,
            contextDays: 0, confidence: 0.2, provisional: true,
            firstDayKey: "2026-03-01", lastDayKey: "2026-03-20")
        return [
            .finding(base), .finding(lower), .finding(null),
            .suppressed(.init(behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 9,
                              nWith: 4, nWithout: 5, reason: .tooFewObservedDays(moreDaysNeeded: 5))),
            .suppressed(.init(behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 16,
                              nWith: 3, nWithout: 13, reason: .tooFewDaysWithBehavior(moreDaysNeeded: 2))),
            .suppressed(.init(behaviorId: "caffeine", scoreId: MetricID.readinessScore, nObserved: 16,
                              nWith: 14, nWithout: 2, reason: .tooFewDaysWithoutBehavior(moreDaysNeeded: 3))),
        ]
    }

    // MARK: - Fixture plumbing

    private static let repoRoot = URL(fileURLWithPath: #filePath)  // apps/ios/Tests/CorrelationEngineTests.swift
        .deletingLastPathComponent()   // apps/ios/Tests
        .deletingLastPathComponent()   // apps/ios
        .deletingLastPathComponent()   // apps
        .deletingLastPathComponent()   // <repo root>
    private static let fixtureDir = repoRoot.appendingPathComponent("packages/fixtures/correlation", isDirectory: true)

    private func fixtureCases() throws -> [[String: Any]] {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("correlation-input-v1.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["cases"] as? [[String: Any]])
    }

    private func fixtureExpectations() throws -> [String: [String: Any]] {
        let data = try Data(contentsOf: Self.fixtureDir.appendingPathComponent("correlation-expected-v1.json"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let cases = try XCTUnwrap(json?["cases"] as? [[String: Any]])
        return Dictionary(cases.map { ($0["id"] as! String, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - DB harness

    /// A real `Database` (both files), a journal with a month of tags, and daily scores to correlate
    /// against — the smallest setup that exercises the persistence path end to end.
    private final class Harness {
        let tempDir: URL
        let db: Database
        let journal: JournalRepository
        let derivation: DerivationRepository
        let findings: CorrelationRepository
        let engine: CorrelationEngine
        let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000))
        let asOf = Date(timeIntervalSince1970: 1_784_000_000)

        init() throws {
            tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("badan-correlation-\(UUID().uuidString)", isDirectory: true)
            db = try Database(directory: tempDir)
            journal = JournalRepository(sensitive: db.sensitive)
            derivation = DerivationRepository(db.main)
            findings = CorrelationRepository(sensitive: db.sensitive)
            engine = CorrelationEngine(journal: journal, derivation: derivation, findings: findings,
                                       clock: clock, deviceId: "test-device")
        }

        func cleanUp() { try? FileManager.default.removeItem(at: tempDir) }

        /// `days` journaled days ending the day before `asOf`, alternating caffeine present/absent,
        /// each followed by a readiness score that is clearly higher on the days after a
        /// caffeine-free day.
        func seedJournalAndScores(days: Int = 24) throws {
            let dayEnd = DayAttribution.addingDays(1, to: DayAttribution.startOfDay(asOf, tz: "UTC"), tz: "UTC")
            for offset in stride(from: days, through: 1, by: -1) {
                let dayStart = DayAttribution.addingDays(-offset, to: dayEnd, tz: "UTC")
                let dayKey = DayAttribution.localDayKey(dayStart, tz: "UTC")
                let present = offset % 2 == 0
                let occurredAt = dayStart.addingTimeInterval(9 * 3600)
                if present {
                    try journal.insertEntry(JournalLog.entry(
                        id: ULID.newID(), behaviorId: "caffeine", valueKind: .count, value: 2,
                        occurredAt: occurredAt, tzId: "UTC", sourceId: "manual",
                        now: occurredAt, originDeviceId: "test-device"))
                } else {
                    // An explicit zero — the user saying it did NOT happen. Still a journaled day.
                    try journal.insertEntry(JournalLog.entry(
                        id: ULID.newID(), behaviorId: "caffeine", valueKind: .count, value: 0,
                        occurredAt: occurredAt, tzId: "UTC", sourceId: "manual",
                        now: occurredAt, originDeviceId: "test-device"))
                }
                // The NEXT day's readiness — lower after a caffeine day.
                let nextKey = CorrelationEngine.nextDayKey(dayKey, tz: "UTC")
                try derivation.appendDerived(DerivedValue(
                    id: ULID.newID(), metricId: MetricID.readinessScore,
                    value: present ? Double(58 + offset % 3) : Double(76 + offset % 3),
                    unit: "score_0_100", periodKey: "day:" + nextKey, confidence: 0.9,
                    provisional: false, algorithmId: "composite.readiness_score",
                    algorithmVersion: "2.0.0", computedAt: occurredAt, updatedAt: occurredAt,
                    originDeviceId: "test-device"))
            }
        }
    }
}
