import CoreLocation
import XCTest
@testable import BADAN

/// EPIC-03 task 5: the unified workout list's dedup-lineage behaviour, the effort-band
/// arithmetic, and the route trace's downsampling.
///
/// All three are pure functions by design — the list assembly, the banding and the downsample
/// take values and return values — so this file needs no database, no HealthKit and no view host.
final class WorkoutSurfaceTests: XCTestCase {

    private let deviceId = "test-device"
    private let tz = "Asia/Muscat"
    private let base = Date(timeIntervalSince1970: 1_783_000_000)

    // MARK: - Fixtures

    private func provenance(sourceId: String, at date: Date) -> Provenance {
        Provenance(sourceId: sourceId, ingestionPath: .platformStore,
                   externalId: "hk-\(date.timeIntervalSince1970)", measuredAt: date,
                   measuredTimezone: tz, recordedAt: date, ingestedAt: date)
    }

    private func ingestedWorkout(id: String, start: Date, minutes: Double,
                                 activity: String = "running",
                                 routeRef: String? = nil) -> Session {
        let end = start.addingTimeInterval(minutes * 60)
        return Session(
            id: id, kind: .workout, subtype: activity, startAt: start, endAt: end, tzId: tz,
            detail: SessionDetail(workout: WorkoutDetail(
                activityType: activity,
                totals: WorkoutTotals(energyKcal: 420, distanceMeters: 7400, avgHeartRateBpm: 148),
                sourceWorkoutUUID: "uuid-\(id)", routeRef: routeRef)),
            provenance: provenance(sourceId: "watch", at: start),
            updatedAt: start, originDeviceId: deviceId)
    }

    private func manualEntry(id: String, start: Date, minutes: Double,
                             activity: String = "Run") -> WorkoutEntry {
        WorkoutEntry(id: id, activityType: activity, startAt: start,
                     endAt: start.addingTimeInterval(minutes * 60), tzId: tz,
                     perceivedEffort: 6, ingestionPath: .manual,
                     updatedAt: start, originDeviceId: deviceId)
    }

    private func decision(kept: String, suppressed: String, score: Double = 0.94,
                          reversedAt: Date? = nil) -> ReconciliationDecision {
        ReconciliationDecision(
            id: "dec-\(suppressed)", rule: DedupLite.workoutRuleId,
            ruleVersion: DedupLite.workoutRuleVersion, keptRecordId: kept,
            suppressedRecordId: suppressed, score: score, reversedAt: reversedAt, decidedAt: base,
            detail: ["kept_activity": "running", "suppressed_activity": "Run",
                     "overlap_pct": "94.0"])
    }

    // MARK: - Unified list (I3)

    /// The core requirement: a suppressed manual entry is neither shown as a peer (a visible
    /// duplicate) nor dropped (which looks exactly like deletion). It hangs off its twin.
    func testSuppressedManualEntryIsNestedUnderItsIngestedTwinNotDeleted() {
        let session = ingestedWorkout(id: "s1", start: base, minutes: 45)
        let entry = manualEntry(id: "m1", start: base, minutes: 45)
        let decisions = ["m1": decision(kept: "s1", suppressed: "m1")]

        let items = UnifiedWorkoutList.assemble(ingested: [session], manual: [entry]) { decisions[$0] }

        XCTAssertEqual(items.count, 1, "The suppressed twin must not appear as a second top-level row")
        XCTAssertEqual(items.first?.id, "s1")
        XCTAssertEqual(items.first?.suppressedChildren.count, 1,
                       "The manual entry disappeared entirely — that renders suppression as deletion (I3)")
        XCTAssertEqual(items.first?.suppressedChildren.first?.entry.id, "m1")
    }

    /// The lineage the UI renders is read from the journal, not recomputed — so what the user is
    /// told is literally the decision that was made.
    func testLineageCarriesTheJournaledRuleAndOverlap() {
        let session = ingestedWorkout(id: "s1", start: base, minutes: 45)
        let entry = manualEntry(id: "m1", start: base, minutes: 45)
        let decisions = ["m1": decision(kept: "s1", suppressed: "m1", score: 0.94)]

        let items = UnifiedWorkoutList.assemble(ingested: [session], manual: [entry]) { decisions[$0] }
        let lineage = items.first?.suppressedChildren.first?.lineage

        XCTAssertEqual(lineage?.rule, "workout.session_overlap.v1")
        XCTAssertEqual(lineage?.ruleVersion, "v1")
        XCTAssertEqual(lineage?.overlapPercent ?? 0, 94, accuracy: 0.001)
        XCTAssertTrue(lineage?.reversible ?? false, "The journal records this as reversible (I3)")
        // Both labels are surfaced because the rule pairs on time alone and never compares them —
        // a wrong pairing has to be visible to the only person who can spot it.
        XCTAssertEqual(lineage?.keptActivity, "running")
        XCTAssertEqual(lineage?.suppressedActivity, "Run")
    }

    /// Reversal is what makes suppression I3-compliant, and `forSuppressed` already filters
    /// reversed rows out — so a reversed entry must come back as an ordinary peer with no
    /// caller-side special case.
    func testReversedDecisionRestoresTheEntryAsAPeerRow() {
        let session = ingestedWorkout(id: "s1", start: base, minutes: 45)
        let entry = manualEntry(id: "m1", start: base, minutes: 45)
        let decisions = ["m1": decision(kept: "s1", suppressed: "m1", reversedAt: base)]

        let items = UnifiedWorkoutList.assemble(ingested: [session], manual: [entry]) { decisions[$0] }

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.suppressedChildren.isEmpty })
    }

    /// A manual entry whose winner sits outside the loaded window would otherwise vanish — the
    /// exact "looks deleted" outcome. It is promoted back to a peer instead.
    func testSuppressedEntryWhoseWinnerIsOutOfWindowStaysVisible() {
        let entry = manualEntry(id: "m1", start: base, minutes: 45)
        // The winning session id is not among the ingested rows handed in.
        let decisions = ["m1": decision(kept: "s-not-loaded", suppressed: "m1")]

        let items = UnifiedWorkoutList.assemble(ingested: [], manual: [entry]) { decisions[$0] }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "m1")
        XCTAssertEqual(items.first?.origin, .manual(entryId: "m1"))
    }

    /// An unsuppressed manual entry and an ingested workout coexist as peers — the ordinary case
    /// of a hand-logged gym session next to a watch-recorded run.
    func testUnrelatedManualEntryRemainsAPeer() {
        let session = ingestedWorkout(id: "s1", start: base, minutes: 45)
        let entry = manualEntry(id: "m1", start: base.addingTimeInterval(-6 * 3600), minutes: 30,
                                activity: "Strength")

        let items = UnifiedWorkoutList.assemble(ingested: [session], manual: [entry]) { _ in nil }

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map(\.id), ["s1", "m1"], "Newest first")
    }

    /// Soft-deleted rows on either side never appear. Deletion and suppression are different acts
    /// and must not be conflated in the other direction either.
    func testDeletedRowsAreExcluded() {
        var session = ingestedWorkout(id: "s1", start: base, minutes: 45)
        session.deletedAt = base
        var entry = manualEntry(id: "m1", start: base.addingTimeInterval(-3600), minutes: 30)
        entry.deletedAt = base

        let items = UnifiedWorkoutList.assemble(ingested: [session], manual: [entry]) { _ in nil }
        XCTAssertTrue(items.isEmpty)
    }

    /// `hasRoute` reports whether a trace is on disk, which is what the list chip means. It says
    /// nothing about consent — the detail screen resolves that separately.
    func testRouteFlagReflectsStoredTraceOnly() {
        let withRoute = ingestedWorkout(id: "s1", start: base, minutes: 45, routeRef: "route-1")
        let withoutRoute = ingestedWorkout(id: "s2", start: base.addingTimeInterval(-7200), minutes: 30)

        let items = UnifiedWorkoutList.assemble(ingested: [withRoute, withoutRoute], manual: []) { _ in nil }

        XCTAssertEqual(items.first?.origin,
                       .ingested(sessionId: "s1", sourceId: "watch", sourceWorkoutUUID: "uuid-s1", hasRoute: true))
        XCTAssertEqual(items.last?.origin,
                       .ingested(sessionId: "s2", sourceId: "watch", sourceWorkoutUUID: "uuid-s2", hasRoute: false))
    }

    /// Two workouts starting in the same second must keep a stable order rather than swapping on
    /// every reload.
    func testTiedStartTimesSortDeterministically() {
        let a = ingestedWorkout(id: "aaa", start: base, minutes: 30)
        let b = ingestedWorkout(id: "bbb", start: base, minutes: 30)

        let first = UnifiedWorkoutList.assemble(ingested: [a, b], manual: []) { _ in nil }.map(\.id)
        let second = UnifiedWorkoutList.assemble(ingested: [b, a], manual: []) { _ in nil }.map(\.id)
        XCTAssertEqual(first, second)
    }

    // MARK: - Effort bands

    private func hrSamples(from start: Date, values: [Double], everySeconds: Double = 30)
        -> [(date: Date, value: Double)] {
        values.enumerated().map { index, value in
            (date: start.addingTimeInterval(Double(index) * everySeconds), value: value)
        }
    }

    /// The honest-refusal cases. Each returns nil rather than drawing bands the data can't
    /// support — plan §4.9's "no false precision" in its most literal form.
    func testBandingRefusesWhenTheDataCannotSupportIt() {
        let manySamples = hrSamples(from: base, values: Array(repeating: 120, count: 40))

        XCTAssertNil(WorkoutEffortBands.compute(samples: manySamples, restingBpm: nil,
                                                end: base.addingTimeInterval(1200)),
                     "No resting baseline means no floor to measure from")
        XCTAssertNil(WorkoutEffortBands.compute(samples: hrSamples(from: base, values: [100, 110, 120]),
                                                restingBpm: 55, end: base.addingTimeInterval(90)),
                     "Three samples describe no shape")
        // Peak 70 over a resting 55 is a 15 bpm spread — quarter-boundaries under 4 bpm apart,
        // where normal beat-to-beat noise alone would scatter across every band.
        XCTAssertNil(WorkoutEffortBands.compute(samples: hrSamples(from: base, values: Array(repeating: 70, count: 40)),
                                                restingBpm: 55, end: base.addingTimeInterval(1200)),
                     "Too little spread between resting and peak to band meaningfully")
    }

    /// A trace that sits flat at its own peak puts all of its time in the top band.
    func testTimeAtPeakLandsInThePeakBand() throws {
        let values = Array(repeating: 160.0, count: 40)
        let samples = hrSamples(from: base, values: values)
        let result = WorkoutEffortBands.compute(samples: samples, restingBpm: 55,
                                                end: base.addingTimeInterval(40 * 30))

        let unwrapped = try XCTUnwrap(result, "Banding refused a trace that plainly supports it")
        XCTAssertEqual(unwrapped.peakBpm, 160)
        XCTAssertEqual(unwrapped.restingBpm, 55)
        XCTAssertEqual(unwrapped.fraction(of: .peak), 1.0, accuracy: 0.001)
        XCTAssertEqual(unwrapped.fraction(of: .easy), 0.0, accuracy: 0.001)
    }

    /// Boundary placement, checked directly rather than inferred from a whole trace: quarters of
    /// the observed reserve, with the upper edge of each band inclusive.
    func testBandBoundariesAreQuartersOfTheObservedReserve() {
        // Resting 60, peak 160 → reserve 100, so boundaries land at 85 / 110 / 135.
        let resting = 60.0
        let range = 100.0
        XCTAssertEqual(WorkoutEffortBands.band(for: 60, restingBpm: resting, range: range), .easy)
        XCTAssertEqual(WorkoutEffortBands.band(for: 85, restingBpm: resting, range: range), .easy)
        XCTAssertEqual(WorkoutEffortBands.band(for: 86, restingBpm: resting, range: range), .steady)
        XCTAssertEqual(WorkoutEffortBands.band(for: 110, restingBpm: resting, range: range), .steady)
        XCTAssertEqual(WorkoutEffortBands.band(for: 111, restingBpm: resting, range: range), .brisk)
        XCTAssertEqual(WorkoutEffortBands.band(for: 135, restingBpm: resting, range: range), .brisk)
        XCTAssertEqual(WorkoutEffortBands.band(for: 136, restingBpm: resting, range: range), .peak)
        XCTAssertEqual(WorkoutEffortBands.band(for: 160, restingBpm: resting, range: range), .peak)
        // Below your own resting rate during a workout is a real recorded moment, not an error.
        XCTAssertEqual(WorkoutEffortBands.band(for: 45, restingBpm: resting, range: range), .easy)
    }

    /// A sensor dropout must not be credited as time spent at the last good reading — otherwise a
    /// five-minute gap invents five minutes of effort.
    func testLongGapsBetweenSamplesAreNotCreditedAsEffort() {
        var samples = hrSamples(from: base, values: Array(repeating: 150, count: 20), everySeconds: 10)
        // One sample an hour later: the gap before it must be clamped, not counted.
        samples.append((date: base.addingTimeInterval(3600), value: 150))
        let end = base.addingTimeInterval(3660)

        let result = WorkoutEffortBands.compute(samples: samples, restingBpm: 55, end: end)
        let total = result?.totalSeconds ?? 0

        // 19 gaps of 10s + the clamped hour gap + the clamped tail = well under the hour of wall
        // clock the trace spans.
        XCTAssertLessThan(total, 400,
                          "An hour-long recording gap was credited as time in a band")
        XCTAssertGreaterThan(total, 180)
    }

    /// Band time totals the trace's real span, not its sample count.
    func testBandSecondsSumToTheCoveredSpan() {
        let samples = hrSamples(from: base, values: Array(repeating: 150, count: 20), everySeconds: 30)
        let end = base.addingTimeInterval(20 * 30)
        let result = WorkoutEffortBands.compute(samples: samples, restingBpm: 55, end: end)
        XCTAssertEqual(result?.totalSeconds ?? 0, 600, accuracy: 0.001)
    }

    /// Every band label is genuinely bilingual — the same check the permission copy gets.
    func testEffortBandLabelsAreBilingual() {
        for band in WorkoutEffortBands.Band.allCases {
            XCTAssertFalse(band.label.en.isEmpty)
            XCTAssertFalse(band.label.ar.isEmpty)
            XCTAssertNotEqual(band.label.en, band.label.ar)
            XCTAssertTrue(band.label.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                          "\(band.rawValue)'s Arabic label contains no Arabic script")
        }
    }

    // MARK: - Route trace

    private func routePoints(count: Int) -> [RoutePoint] {
        (0..<count).map { index in
            RoutePoint(routeId: "r1", seq: index,
                       latitude: 23.58 + Double(index) * 0.0001,
                       longitude: 58.38 + Double(index) * 0.0001,
                       timestamp: base.addingTimeInterval(Double(index)))
        }
    }

    /// A long ride's trace is bounded for drawing, and — the part that matters — still starts and
    /// ends exactly where the recording did.
    func testDownsampleBoundsPointCountAndKeepsBothEnds() {
        let points = routePoints(count: 10_000)
        let drawn = RouteTraceShape.downsample(points, limit: 800)

        XCTAssertEqual(drawn.count, 800)
        XCTAssertEqual(drawn.first?.latitude ?? 0, points.first?.latitude ?? -1, accuracy: 1e-9)
        XCTAssertEqual(drawn.last?.latitude ?? 0, points.last?.latitude ?? -1, accuracy: 1e-9)
    }

    /// A short trace passes through untouched — no resampling artifacts on the common case.
    func testShortTraceIsNotDownsampled() {
        let points = routePoints(count: 120)
        XCTAssertEqual(RouteTraceShape.downsample(points, limit: 800).count, 120)
    }

    /// Degenerate inputs produce an empty path rather than a crash or a stray line — a route with
    /// one fix is a real (if useless) state.
    func testDegenerateTracesProduceNoPath() {
        XCTAssertTrue(RouteTraceShape(coordinates: []).path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
        let single = [CLLocationCoordinate2D(latitude: 23.58, longitude: 58.38)]
        XCTAssertTrue(RouteTraceShape(coordinates: single).path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
    }

    /// The projected path stays inside the frame it was given — a trace that overflowed its card
    /// would draw over neighbouring content.
    func testProjectedPathStaysWithinItsFrame() {
        let coordinates = routePoints(count: 500).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        let rect = CGRect(x: 0, y: 0, width: 320, height: 180)
        let bounds = RouteTraceShape(coordinates: coordinates).path(in: rect).boundingRect

        XCTAssertGreaterThanOrEqual(bounds.minX, rect.minX - 0.001)
        XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - 0.001)
        XCTAssertLessThanOrEqual(bounds.maxX, rect.maxX + 0.001)
        XCTAssertLessThanOrEqual(bounds.maxY, rect.maxY + 0.001)
    }

    // MARK: - Family explainers

    /// Every family explainer carries all three parts in both languages. The honesty note is the
    /// one most likely to be dropped as "optional", and it is the reason the type exists.
    func testFamilyExplainersAreCompleteAndBilingual() {
        for explainer in MetricFamilyExplainer.all {
            for (label, value) in [("whatItIs", explainer.whatItIs),
                                   ("howItsRecorded", explainer.howItsRecorded),
                                   ("honestyNote", explainer.honestyNote)] {
                XCTAssertFalse(value.en.isEmpty, "\(explainer.family.rawValue).\(label) has no English")
                XCTAssertFalse(value.ar.isEmpty, "\(explainer.family.rawValue).\(label) has no Arabic")
                XCTAssertNotEqual(value.en, value.ar, "\(explainer.family.rawValue).\(label) is untranslated")
                XCTAssertTrue(value.ar.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                              "\(explainer.family.rawValue).\(label) has no Arabic script")
            }
        }
    }

    /// Every family the widened read set actually ingests into has authored copy, rather than
    /// silently falling through to the generic placeholder.
    func testEveryIngestedFamilyHasAnAuthoredExplainer() {
        let registry = MetricRegistry.shared
        let ingestedFamilies = Set(HKTypeMap.table.compactMap { entry -> MetricFamily? in
            guard let metricId = entry.metricId else { return nil }
            return registry.definition(metricId)?.familyGroup
        })
        let authored = Set(MetricFamilyExplainer.all.map(\.family))

        XCTAssertTrue(ingestedFamilies.isSubset(of: authored),
                      "No authored explainer for: \(ingestedFamilies.subtracting(authored))")
    }
}
