import XCTest
@testable import BADAN

/// EPIC-31 — the pure `ReportBuilder`, its period resolver, and the weekly trigger.
///
/// The acceptance contract lives here: a report MODEL snapshot (numbers + refs, not pixels), an
/// honest empty week, deterministic hashing, and — the transparency claim — that *every* evidence
/// ref a claim carries resolves to a real row.
final class ReportBuilderTests: XCTestCase {
    private let tz = "UTC"
    // A Tuesday (2026-07-14 03:33 UTC), so the ISO week around it — 2026-W29, Mon 07-13 to Sun
    // 07-19 — is unambiguous, and the week the trigger picks (2026-W28) is fully in the past.
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func dv(_ metric: String, day: String, value: Double, unit: String = "score_0_100", id: String? = nil) -> DerivedValue {
        DerivedValue(id: id ?? ULID.newID(), metricId: metric, value: value, unit: unit,
                     periodKey: "day:" + day, algorithmId: "test", algorithmVersion: "1.0.0",
                     computedAt: now, updatedAt: now, originDeviceId: "test-device")
    }

    private func week() -> ReportPeriod.Resolved { ReportPeriod.week(containing: now, tz: tz) }

    // MARK: - Structure + snapshot

    func testWeeklyModelHasScoreSectionsWithCorrectStats() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        let days = period.dayKeys
        // Sleep performance across 5 of 7 days: 60,70,80,90,100 → mean 80, min 60, max 100, latest 100.
        let sleep = zip(days, [60.0, 70, 80, 90, 100]).map { dv(MetricID.sleepPerformance, day: $0.0, value: $0.1) }
        let inputs = ReportBuilder.Inputs(
            period: period, prior: prior,
            currentByMetric: [MetricID.sleepPerformance: sleep],
            priorByMetric: [:], adherence: nil, generatedAt: now)

        let model = ReportBuilder.build(inputs)
        XCTAssertTrue(model.hasSufficientData)
        XCTAssertEqual(model.periodKind, .week)
        XCTAssertEqual(model.schemaVersion, "1.0")
        XCTAssertEqual(model.algorithmVersionId, "report.periodic@1.0.0")

        guard let sleepSection = model.section(.sleep), let summary = sleepSection.metrics.first else {
            return XCTFail("expected a sleep section with a metric summary")
        }
        XCTAssertEqual(summary.metricId, MetricID.sleepPerformance)
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.mean, 80)
        XCTAssertEqual(summary.min, 60)
        XCTAssertEqual(summary.max, 100)
        XCTAssertEqual(summary.latest, 100)
        // No prior data → no delta, direction insufficient.
        XCTAssertNil(summary.deltaVsPrior)
        XCTAssertEqual(summary.direction, .insufficient)
        XCTAssertEqual(summary.evidence.count, 5)
    }

    func testDeltaAndDirectionAgainstPriorPeriod() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        // Current mean 80 (4 days), prior mean 60 (4 days) → delta +20, direction up.
        let cur = zip(period.dayKeys, [80.0, 80, 80, 80]).map { dv(MetricID.readinessScore, day: $0.0, value: $0.1) }
        let pri = zip(prior.dayKeys, [60.0, 60, 60, 60]).map { dv(MetricID.readinessScore, day: $0.0, value: $0.1) }
        let inputs = ReportBuilder.Inputs(period: period, prior: prior,
                                          currentByMetric: [MetricID.readinessScore: cur],
                                          priorByMetric: [MetricID.readinessScore: pri],
                                          adherence: nil, generatedAt: now)
        let model = ReportBuilder.build(inputs)
        let summary = model.section(.readiness)?.metrics.first
        XCTAssertEqual(summary?.deltaVsPrior, 20)
        XCTAssertEqual(summary?.direction, .up)

        // A +33% shift crosses the 10% notable threshold → a change item, evidence from both periods.
        guard let change = model.section(.changes)?.changes.first else { return XCTFail("expected a change item") }
        XCTAssertEqual(change.metricId, MetricID.readinessScore)
        XCTAssertEqual(change.currentMean, 80)
        XCTAssertEqual(change.priorMean, 60)
        XCTAssertEqual(change.deltaAbs, 20)
        XCTAssertEqual(change.direction, .up)
        XCTAssertEqual(change.evidence.count, 8) // 4 current + 4 prior
    }

    func testSmallShiftIsNotNotable() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        // 80 vs 78 → 2.5% < 10% → not a change; direction flat (< 2% rel is flat, 2.5% is up though).
        let cur = zip(period.dayKeys, [80.0, 80, 80]).map { dv(MetricID.effortDay, day: $0.0, value: $0.1) }
        let pri = zip(prior.dayKeys, [78.0, 78, 78]).map { dv(MetricID.effortDay, day: $0.0, value: $0.1) }
        let model = ReportBuilder.build(.init(period: period, prior: prior,
                                              currentByMetric: [MetricID.effortDay: cur],
                                              priorByMetric: [MetricID.effortDay: pri],
                                              adherence: nil, generatedAt: now))
        XCTAssertNil(model.section(.changes), "a 2.5% shift must not be a notable change")
    }

    func testBelowMinComparableDaysGivesNoDelta() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        // Only 2 current days (< minComparableDays = 3) → no delta even though prior has enough.
        let cur = zip(period.dayKeys, [80.0, 90]).map { dv(MetricID.sleepPerformance, day: $0.0, value: $0.1) }
        let pri = zip(prior.dayKeys, [60.0, 60, 60]).map { dv(MetricID.sleepPerformance, day: $0.0, value: $0.1) }
        let model = ReportBuilder.build(.init(period: period, prior: prior,
                                              currentByMetric: [MetricID.sleepPerformance: cur],
                                              priorByMetric: [MetricID.sleepPerformance: pri],
                                              adherence: nil, generatedAt: now))
        XCTAssertNil(model.section(.sleep)?.metrics.first?.deltaVsPrior)
        XCTAssertNil(model.section(.changes))
    }

    // MARK: - Adherence (counts only, I7)

    func testAdherenceSummaryCounts() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        let events = [
            adherence(.taken), adherence(.taken), adherence(.late), adherence(.skipped),
        ]
        let model = ReportBuilder.build(.init(period: period, prior: prior, currentByMetric: [:],
                                              priorByMetric: [:], adherence: events, generatedAt: now))
        guard let a = model.section(.adherence)?.adherence else { return XCTFail("expected adherence section") }
        XCTAssertEqual(a.taken, 2)
        XCTAssertEqual(a.late, 1)
        XCTAssertEqual(a.skipped, 1)
        XCTAssertEqual(a.logged, 4)
        XCTAssertEqual(a.adherenceRate, 0.75) // (2 taken + 1 late) / 4
        XCTAssertEqual(a.evidence.count, 4)
        XCTAssertTrue(a.evidence.allSatisfy { $0.kind == .adherenceEvent })
    }

    private func adherence(_ kind: AdherenceKind, id: String? = nil) -> AdherenceEvent {
        AdherenceEvent(id: id ?? ULID.newID(), regimenId: "r1", kind: kind, occurredAt: now, tzId: tz,
                       updatedAt: now, originDeviceId: "test-device")
    }

    /// Counts only: no medication name, dosage, regimen or skip reason may reach the model, so the
    /// report artifact never carries the sensitive-plus namespace's contents across (I7). Mirrored
    /// by `ReportBuilderTest.adherenceEvidenceCarriesIdsOnly`.
    func testAdherenceEvidenceCarriesIdsOnly() {
        let period = week()
        let model = ReportBuilder.build(.init(period: period, prior: ReportPeriod.prior(period, tz: tz),
                                              currentByMetric: [:], priorByMetric: [:],
                                              adherence: [adherence(.taken, id: "ev-1")], generatedAt: now))
        let evidence = model.section(.adherence)?.adherence?.evidence ?? []
        XCTAssertEqual(evidence.map { $0.id }, ["ev-1"])
        XCTAssertTrue(evidence.allSatisfy { $0.periodKey == nil }, "an adherence ref must carry no day period key")
    }

    // MARK: - Empty week (honest, never fabricated)

    func testEmptyWeekIsHonestNotFabricated() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        let model = ReportBuilder.build(.init(period: period, prior: prior, currentByMetric: [:],
                                              priorByMetric: [:], adherence: [], generatedAt: now))
        XCTAssertFalse(model.hasSufficientData)
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertEqual(model.sha256.count, 64) // still a valid, hashable model
    }

    // MARK: - Determinism / hashing

    func testHashIsStableAcrossRunsAndIgnoresGeneratedAt() {
        let period = week()
        let prior = ReportPeriod.prior(period, tz: tz)
        // Fixed ids so re-building with the same inputs is bit-identical.
        let a = dv(MetricID.sleepPerformance, day: period.dayKeys[0], value: 70, id: "id-a")
        let b = dv(MetricID.sleepPerformance, day: period.dayKeys[1], value: 80, id: "id-b")
        let m1 = ReportBuilder.build(.init(period: period, prior: prior,
                                           currentByMetric: [MetricID.sleepPerformance: [a, b]],
                                           priorByMetric: [:], adherence: nil, generatedAt: now))
        let m2 = ReportBuilder.build(.init(period: period, prior: prior,
                                           currentByMetric: [MetricID.sleepPerformance: [a, b]],
                                           priorByMetric: [:], adherence: nil,
                                           generatedAt: now.addingTimeInterval(9999)))
        XCTAssertEqual(m1.sha256, m2.sha256, "generatedAt must not affect the content hash")

        let c = dv(MetricID.sleepPerformance, day: period.dayKeys[1], value: 81, id: "id-b")
        let m3 = ReportBuilder.build(.init(period: period, prior: prior,
                                           currentByMetric: [MetricID.sleepPerformance: [a, c]],
                                           priorByMetric: [:], adherence: nil, generatedAt: now))
        XCTAssertNotEqual(m1.sha256, m3.sha256, "a changed value must change the content hash")
    }

    // MARK: - Every claim resolves to a real evidence ref (over a real store)

    func testEvidenceRefsResolveToRealRows() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString)")
        let db = try Database(directory: dir)
        // Close the handles before removing the directory: `derivation`/`logging` below hold the
        // same connections, so deleting the files under a live handle is an API violation SQLite
        // reports (and a source of cross-test flakiness), not a clean cleanup.
        defer {
            db.main.closeHandle()
            db.sensitive.closeHandle()
            try? FileManager.default.removeItem(at: dir)
        }
        let derivation = DerivationRepository(db.main)
        let logging = LoggingRepository(main: db.main, sensitive: db.sensitive)

        let period = week()
        var insertedDerivedIds = Set<String>()
        for (i, day) in period.dayKeys.enumerated() {
            let v = dv(MetricID.readinessScore, day: day, value: Double(60 + i))
            try derivation.appendDerived(v)
            insertedDerivedIds.insert(v.id)
        }
        var insertedAdherenceIds = Set<String>()
        let ev = AdherenceEvent(id: ULID.newID(), regimenId: "r1", kind: .taken, occurredAt: period.start,
                                tzId: tz, updatedAt: now, originDeviceId: "d")
        try logging.insertAdherence(ev)
        insertedAdherenceIds.insert(ev.id)

        let builder = ReportBuilder(derivation: derivation, logging: logging)
        let model = try builder.generate(period: period, tz: tz, now: now)

        var checked = 0
        for section in model.sections {
            for metric in section.metrics {
                for ref in metric.evidence {
                    XCTAssertTrue(insertedDerivedIds.contains(ref.id), "derived evidence \(ref.id) must be real")
                    checked += 1
                }
            }
            for change in section.changes {
                for ref in change.evidence {
                    XCTAssertTrue(insertedDerivedIds.contains(ref.id))
                    checked += 1
                }
            }
            if let a = section.adherence {
                for ref in a.evidence {
                    XCTAssertTrue(insertedAdherenceIds.contains(ref.id), "adherence evidence \(ref.id) must be real")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "the report must carry at least one evidence ref")
    }

    // MARK: - Period resolver

    func testWeekResolverShapeAndRoundTrip() {
        let w = week()
        XCTAssertEqual(w.dayKeys.count, 7)
        XCTAssertTrue(w.periodKey.hasPrefix("week:"))
        XCTAssertLessThan(w.start, w.end)
        // First day is a Monday.
        let cal = DayAttribution.calendar(tz: tz)
        XCTAssertEqual(cal.component(.weekday, from: w.start), 2, "ISO week starts Monday")
        // Round-trips through resolve.
        XCTAssertEqual(ReportPeriod.resolve(periodKey: w.periodKey, tz: tz)?.dayKeys, w.dayKeys)
        // Prior week ends where this one starts.
        XCTAssertEqual(ReportPeriod.prior(w, tz: tz).end, w.start)
    }

    func testMonthResolverShapeAndRoundTrip() {
        let m = ReportPeriod.month(containing: now, tz: tz)
        XCTAssertTrue((28...31).contains(m.dayKeys.count))
        XCTAssertTrue(m.periodKey.hasPrefix("month:"))
        XCTAssertEqual(ReportPeriod.resolve(periodKey: m.periodKey, tz: tz)?.dayKeys, m.dayKeys)
        XCTAssertEqual(ReportPeriod.prior(m, tz: tz).end, m.start)
    }

    func testMalformedPeriodKeyRejected() {
        XCTAssertNil(ReportPeriod.resolve(periodKey: "week:2026-W54", tz: tz))
        XCTAssertNil(ReportPeriod.resolve(periodKey: "month:2026-13", tz: tz))
        XCTAssertNil(ReportPeriod.resolve(periodKey: "day:2026-07-13", tz: tz))
    }

    /// The two platforms must agree on which week a given instant belongs to, key and days alike —
    /// otherwise "the same report" means two different windows. Pinned to literals here and in
    /// `ReportBuilderTest.weekKeyMatchesTheIsoWeekOfTheInstant`, so a drift in either calendar
    /// (Foundation's `.iso8601` here, `GregorianCalendar` + ISO settings there) fails on the side
    /// that drifted rather than being invisible until an export is compared.
    func testWeekKeyMatchesTheIsoWeekOfTheInstant() {
        XCTAssertEqual(week().periodKey, "week:2026-W29")
        XCTAssertEqual(week().dayKeys.first, "2026-07-13")
        XCTAssertEqual(week().dayKeys.last, "2026-07-19")
    }

    /// A period key is a MACHINE key — stored in `reports.period_key`, matched against the shared
    /// contract's pattern, sorted lexicographically, compared across devices — so it is Western-digit
    /// under every language. Foundation's `String(format:)` is non-localized unless a locale is
    /// passed, so that holds here for free; the Kotlin side needs an explicit `Locale.ROOT` (its
    /// `String.format` defaults to the device locale, which renders `٢٠٢٦` under `ar`), and
    /// `ReportBuilderTest.periodKeysAreWesternDigitsUnderAnArabicDefaultLocale` pins it there.
    /// Asserted on both sides so the invariant is a property of the key, not of one platform's
    /// formatting default.
    func testPeriodKeysMatchTheContractPattern() {
        XCTAssertNotNil(week().periodKey.range(of: #"^week:\d{4}-W\d{2}$"#, options: .regularExpression))
        let month = ReportPeriod.month(containing: now, tz: tz)
        XCTAssertNotNil(month.periodKey.range(of: #"^month:\d{4}-\d{2}$"#, options: .regularExpression))
    }

    // MARK: - Trigger

    func testLastCompletedWeekIsFullyInThePast() {
        let last = ReportTrigger.lastCompletedWeek(asOf: now, tz: tz)
        let startToday = DayAttribution.startOfDay(now, tz: tz)
        XCTAssertLessThanOrEqual(last.end, startToday, "every day of a completed week is before today")
    }

    func testDueWeeklyReturnsKeyThenNothingOnceGenerated() {
        let last = ReportTrigger.lastCompletedWeek(asOf: now, tz: tz)
        XCTAssertEqual(ReportTrigger.dueWeeklyPeriodKeys(asOf: now, tz: tz, existingPeriodKeys: []),
                       [last.periodKey])
        XCTAssertEqual(ReportTrigger.dueWeeklyPeriodKeys(asOf: now, tz: tz,
                                                         existingPeriodKeys: [last.periodKey]), [])
    }

    /// A fresh install must NOT manufacture reports for weeks that predate it. With no report rows
    /// at all there is no run of reports to have a gap in, so only the last completed week is due.
    func testFirstEverRunGeneratesOnlyTheLastCompletedWeek() {
        let keys = ReportTrigger.dueWeeklyPeriodKeys(asOf: now, tz: tz, existingPeriodKeys: [],
                                                     maxBackfillWeeks: 4)
        XCTAssertEqual(keys, [ReportTrigger.lastCompletedWeek(asOf: now, tz: tz).periodKey])
    }

    /// The defect this backfill exists for: three weeks with no background wake used to leave two
    /// weeks permanently unreported, because by the time a wake landed they were no longer "last".
    /// Here reports exist up to three weeks back; the two skipped weeks and the current one are all
    /// due, newest first.
    func testThreeMissedWakesBackfillTheSkippedWeeks() {
        let w0 = ReportTrigger.lastCompletedWeek(asOf: now, tz: tz)
        let w1 = ReportPeriod.prior(w0, tz: tz)
        let w2 = ReportPeriod.prior(w1, tz: tz)
        let w3 = ReportPeriod.prior(w2, tz: tz)
        let keys = ReportTrigger.dueWeeklyPeriodKeys(
            asOf: now, tz: tz, existingPeriodKeys: [w3.periodKey], maxBackfillWeeks: 4)
        XCTAssertEqual(keys, [w0.periodKey, w1.periodKey, w2.periodKey])
    }

    /// The horizon is a real bound, not decoration: with `maxBackfillWeeks: 2` only the last
    /// completed week and the one before it can be returned, however long the outage was.
    func testBackfillIsBoundedByTheHorizon() {
        let w0 = ReportTrigger.lastCompletedWeek(asOf: now, tz: tz)
        let w1 = ReportPeriod.prior(w0, tz: tz)
        let w5 = ReportPeriod.prior(ReportPeriod.prior(ReportPeriod.prior(ReportPeriod.prior(w1, tz: tz),
                                                                          tz: tz), tz: tz), tz: tz)
        let keys = ReportTrigger.dueWeeklyPeriodKeys(
            asOf: now, tz: tz, existingPeriodKeys: [w5.periodKey], maxBackfillWeeks: 2)
        XCTAssertEqual(keys, [w0.periodKey, w1.periodKey])
    }

    /// `periodKeys` comes straight from the reports table and carries monthly keys too. A month key
    /// must not be mistaken for the weekly run's floor — it sorts before every `week:` key, which
    /// would otherwise open the backfill all the way to the horizon on a fresh install that had
    /// only ever generated a monthly report.
    func testMonthlyKeysDoNotSeedTheWeeklyBackfillFloor() {
        let keys = ReportTrigger.dueWeeklyPeriodKeys(
            asOf: now, tz: tz, existingPeriodKeys: ["month:2020-01"], maxBackfillWeeks: 4)
        XCTAssertEqual(keys, [ReportTrigger.lastCompletedWeek(asOf: now, tz: tz).periodKey])
    }
}
