import XCTest
@testable import BADAN

/// EPIC-15 — the scheduling & automation engine: the due-gates (cadence / quiet hours /
/// data-newness), the failure budget (3 strikes → visibly paused + one notification, reset on
/// success), and the composition onto Phase-1's `ExportRunner.runTemplate` (a due schedule really
/// runs its template and records an `ExportRun`, with the engine never touching a cursor).
///
/// The pure gate/budget decisions are the cross-platform contract Android mirrors in
/// `AutomationEngineTest`; the DB-backed engine tests here are iOS's (Android's JVM test source set
/// cannot open a database — the same split `ExportRunnerTemplateTests` documents).
final class AutomationEngineTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private let clock = FixedClock(Date(timeIntervalSince1970: 1_783_000_000))
    private let deviceId = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-automation-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Harness

    private var schedulesRepo: AutomationScheduleRepository { AutomationScheduleRepository(db.main) }
    private var templatesRepo: ExportTemplateRepository { ExportTemplateRepository(db.main) }
    private var runsRepo: ExportRunRepository { ExportRunRepository(db.main) }
    private var cursorsRepo: ExportCursorRepository { ExportCursorRepository(db.main) }
    private var destinationsRepo: ExportDestinationRepository { ExportDestinationRepository(db.main) }
    private var now: Date { clock.now() }

    /// A delivery-capable runner over the real repositories — the same shape `AppEnvironment` wires.
    /// Share-sheet delivery needs no deliverer (handled in-process), so the default `deliverers: []`
    /// is enough for the acceptance test.
    private func makeRealRunner() -> ExportRunner {
        ExportRunner(
            measurements: MeasurementRepository(db.main), derivation: DerivationRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            exportJobs: ExportJobRepository(db.main), registry: .shared, clock: clock,
            appVersion: "test", deviceId: deviceId,
            templates: ExportTemplateRepository(db.main), destinations: ExportDestinationRepository(db.main),
            runs: ExportRunRepository(db.main), cursors: ExportCursorRepository(db.main),
            routes: RouteRepository(db.main))
    }

    private func makeEngine(runner: AutomationTemplateRunning,
                            freshness: AutomationDataFreshnessProbing = StubFreshness(true),
                            notifier: AutomationPauseNotifying,
                            calendar: Calendar = AutomationEngineTests.utcCalendar) -> AutomationEngine {
        AutomationEngine(schedules: schedulesRepo, templates: templatesRepo, runner: runner,
                         freshness: freshness, notifier: notifier, clock: clock, calendar: calendar)
    }

    /// A UTC calendar so quiet-hours math is deterministic regardless of the machine's time zone.
    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var utcCalendar: Calendar { Self.utcCalendar }

    @discardableResult
    private func seedTemplate(id: String = "T1", destinationId: String? = ExportDestination.shareSheetId,
                              rangeRule: ExportRangeRule = .allTime) throws -> ExportTemplate {
        let t = ExportTemplate(id: id, name: "Backup \(id)", scope: .everything, rangeRule: rangeRule,
                               format: .csv, aggregation: .raw, layout: .tidy,
                               destinationId: destinationId, createdAt: now, updatedAt: now,
                               originDeviceId: deviceId)
        try templatesRepo.insert(t)
        return t
    }

    @discardableResult
    private func seedSchedule(id: String = "S1", templateId: String = "T1",
                              tier: AutomationTier = .opportunisticBackground,
                              cadence: AutomationCadence = .dailyBestEffort,
                              quietHours: QuietHours? = nil, enabled: Bool = true,
                              consecutiveFailures: Int = 0,
                              lastSuccessAt: Date? = nil) throws -> AutomationSchedule {
        let s = AutomationSchedule(id: id, templateId: templateId, tier: tier, desiredCadence: cadence,
                                   quietHours: quietHours, enabled: enabled,
                                   consecutiveFailures: consecutiveFailures, lastSuccessAt: lastSuccessAt,
                                   createdAt: now, updatedAt: now, originDeviceId: deviceId)
        try schedulesRepo.upsert(s)
        return s
    }

    @discardableResult
    private func insertSample(ingestedAt: Date) throws -> RawSample {
        let prov = Provenance(sourceId: "watch", deviceId: "watch", ingestionPath: .platformStore,
                              measuredAt: ingestedAt, measuredTimezone: "UTC", recordedAt: ingestedAt,
                              ingestedAt: ingestedAt)
        let sample = RawSample(id: ULID.newID(), metricId: "heart.rhr", value: 58, unit: "count/min",
                               originalValue: 58, originalUnit: "count/min", startAt: ingestedAt, tzId: "UTC",
                               provenance: prov, updatedAt: ingestedAt, originDeviceId: deviceId)
        try MeasurementRepository(db.main).upsertRawSample(sample)
        return sample
    }

    private func seedShareSheet() throws {
        try destinationsRepo.seedShareSheet(now: now, originDeviceId: deviceId)
    }

    // MARK: - 1. Acceptance: a due schedule runs its template through the real runner + records a run

    func testDueScheduleRunsRealTemplateRecordsExportRunAndAdvancesNoCursor() async throws {
        try seedShareSheet()
        try insertSample(ingestedAt: now.addingTimeInterval(-3_600))
        try seedTemplate(rangeRule: .allTime)                 // allTime: no cursor is ever created
        try seedSchedule(cadence: .dailyBestEffort)           // lastSuccessAt nil ⇒ due

        let notifier = SpyPauseNotifier()
        let engine = makeEngine(runner: makeRealRunner(), notifier: notifier)

        let summary = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)

        XCTAssertEqual(summary.considered, 1)
        XCTAssertEqual(summary.ran, 1)
        // The run went through Phase-1's runner and left a real ledger row, tagged as the
        // opportunistic wake — never `manual`, never a fabricated trigger.
        let run = try XCTUnwrap(runsRepo.recent().first)
        XCTAssertEqual(run.templateId, "T1")
        XCTAssertEqual(run.trigger, .scheduledOpportunistic)
        XCTAssertEqual(run.outcome, .success)
        XCTAssertNotNil(run.jobId, "a delivered run links the job it produced")
        // The engine advanced NOTHING: an allTime template has no delta cursor, and the engine must
        // never invent one — cursor advancement is exclusively `runTemplate`'s two-phase commit.
        XCTAssertNil(try cursorsRepo.cursor(templateId: "T1", destinationId: ExportDestination.shareSheetId),
                     "the engine must not create or advance any cursor")
        // Success reset/stamped the schedule bookkeeping.
        let updated = try XCTUnwrap(schedulesRepo.schedule(id: "S1"))
        XCTAssertEqual(updated.consecutiveFailures, 0)
        XCTAssertEqual(updated.lastSuccessAt, now)
        XCTAssertFalse(updated.isPaused)
        XCTAssertTrue(notifier.calls.isEmpty, "a success fires no pause notification")
    }

    // MARK: - 2. The failure budget: 3 strikes → visibly paused + exactly one notification

    func testThreeConsecutiveFailuresPauseVisiblyAndNotifyExactlyOnce() async throws {
        try seedTemplate()
        try seedSchedule(cadence: .dailyBestEffort)   // no lastSuccessAt ⇒ due every wake
        let notifier = SpyPauseNotifier()
        let runner = StubTemplateRunner(outcome: .failedDelivery)   // every run fails delivery
        let engine = makeEngine(runner: runner, notifier: notifier)

        // Strike 1 and 2: counter climbs, not yet paused, no notification.
        for expected in 1...2 {
            _ = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
            let s = try XCTUnwrap(schedulesRepo.schedule(id: "S1"))
            XCTAssertEqual(s.consecutiveFailures, expected)
            XCTAssertFalse(s.isPaused, "under budget is not paused")
            XCTAssertTrue(notifier.calls.isEmpty, "no notification before the budget is spent")
        }

        // Strike 3: the schedule is now VISIBLY paused and the user is notified — once.
        let third = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(third.ran, 1)
        XCTAssertEqual(third.pausedThisRun, 1)
        let paused = try XCTUnwrap(schedulesRepo.schedule(id: "S1"))
        XCTAssertEqual(paused.consecutiveFailures, AutomationSchedule.failureBudget)
        XCTAssertTrue(paused.isPaused, "three strikes is visibly paused — never a silent death")
        XCTAssertEqual(notifier.calls.map(\.scheduleId), ["S1"], "exactly one pause notification")

        // A 4th wake: a paused schedule is examined but skipped, so it never runs, never
        // re-notifies, and the count does not climb further.
        let fourth = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(fourth.considered, 1)
        XCTAssertEqual(fourth.ran, 0, "a paused schedule is skipped, not re-run")
        XCTAssertEqual(runner.callCount, 3, "the runner is not invoked for a paused schedule")
        XCTAssertEqual(notifier.calls.count, 1, "a paused schedule never re-notifies without a resume")
    }

    // MARK: - 3. The counter resets on success

    func testCounterResetsToZeroOnSuccess() async throws {
        try seedTemplate()
        try seedSchedule(cadence: .dailyBestEffort, consecutiveFailures: 2)  // one strike from paused
        let notifier = SpyPauseNotifier()
        let engine = makeEngine(runner: StubTemplateRunner(outcome: .success), notifier: notifier)

        _ = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)

        let s = try XCTUnwrap(schedulesRepo.schedule(id: "S1"))
        XCTAssertEqual(s.consecutiveFailures, 0, "a success clears accumulated strikes")
        XCTAssertEqual(s.lastSuccessAt, now)
        XCTAssertFalse(s.isPaused)
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    /// `skippedNoData` — "there was nothing to export" — is a clean outcome, not a strike: it too
    /// resets the counter and stamps the success clock, so an automation that legitimately keeps
    /// finding nothing new is never mistaken for one that keeps failing.
    func testSkippedNoDataIsTreatedAsSuccessNotAStrike() async throws {
        try seedTemplate()
        try seedSchedule(cadence: .dailyBestEffort, consecutiveFailures: 2)
        let notifier = SpyPauseNotifier()
        let engine = makeEngine(runner: StubTemplateRunner(outcome: .skippedNoData), notifier: notifier)

        _ = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)

        let s = try XCTUnwrap(schedulesRepo.schedule(id: "S1"))
        XCTAssertEqual(s.consecutiveFailures, 0)
        XCTAssertEqual(s.lastSuccessAt, now)
        XCTAssertTrue(notifier.calls.isEmpty)
    }

    /// A throttled/locked run is neutral — it never really ran — so it neither advances the success
    /// clock nor spends a strike.
    func testThrottledOutcomeIsNeutral() async throws {
        try seedTemplate()
        try seedSchedule(cadence: .dailyBestEffort, consecutiveFailures: 1)
        let notifier = SpyPauseNotifier()
        let engine = makeEngine(runner: StubTemplateRunner(outcome: .throttled), notifier: notifier)

        _ = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)

        let s = try XCTUnwrap(schedulesRepo.schedule(id: "S1"))
        XCTAssertEqual(s.consecutiveFailures, 1, "neutral: no strike spent")
        XCTAssertNil(s.lastSuccessAt, "neutral: success clock not stamped")
    }

    // MARK: - 4. Data-newness gate (onNewData cadence)

    func testOnNewDataSkipsWhenNoNewDataAndRunsWhenThereIs() async throws {
        try seedTemplate()
        try seedSchedule(cadence: .onNewData)
        let notifier = SpyPauseNotifier()
        let runner = StubTemplateRunner(outcome: .success)

        // No new data → skipped, no run.
        let stale = makeEngine(runner: runner, freshness: StubFreshness(false), notifier: notifier)
        let a = await stale.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(a.considered, 1)
        XCTAssertEqual(a.ran, 0, "onNewData with nothing new does not run")
        XCTAssertEqual(runner.callCount, 0)

        // New data → runs.
        let fresh = makeEngine(runner: runner, freshness: StubFreshness(true), notifier: notifier)
        let b = await fresh.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(b.ran, 1)
        XCTAssertEqual(runner.callCount, 1)
    }

    /// The real freshness probe reads the ingested axis — the same one the cursor advances on.
    func testFreshnessProbeReadsIngestedAxis() throws {
        let probe = AutomationDataFreshnessProbe(db.main)
        XCTAssertFalse(probe.hasDataIngested(after: nil), "no rows ⇒ nothing new")
        let sample = try insertSample(ingestedAt: now.addingTimeInterval(-100))
        XCTAssertTrue(probe.hasDataIngested(after: nil), "any row counts against a nil watermark")
        XCTAssertTrue(probe.hasDataIngested(after: now.addingTimeInterval(-200)),
                      "a row ingested after the watermark is new")
        XCTAssertFalse(probe.hasDataIngested(after: sample.provenance.ingestedAt),
                       "a row AT the watermark is not strictly after it")
    }

    // MARK: - 5. Quiet hours and tier are hard gates at the engine level

    func testQuietHoursSuppressesTheRun() async throws {
        try seedTemplate()
        // now = epoch 1_783_000_000 = 2026-07-05 13:46:40 UTC → minute-of-day 826. A 13:00-14:00
        // window contains it.
        try seedSchedule(cadence: .dailyBestEffort,
                         quietHours: QuietHours(startHour: 13, startMinute: 0, endHour: 14, endMinute: 0))
        let notifier = SpyPauseNotifier()
        let runner = StubTemplateRunner(outcome: .success)
        let engine = makeEngine(runner: runner, notifier: notifier)

        let s = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(s.ran, 0, "inside quiet hours the schedule does not run")
        XCTAssertEqual(runner.callCount, 0)
    }

    func testNonBackgroundTierIsNeverAutoRun() async throws {
        try seedTemplate()
        // A shortcut-driven schedule is stored, but the background wake must never fire it.
        try seedSchedule(tier: .shortcutDriven, cadence: .dailyBestEffort)
        let notifier = SpyPauseNotifier()
        let runner = StubTemplateRunner(outcome: .success)
        let engine = makeEngine(runner: runner, notifier: notifier)

        let s = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(s.considered, 0, "dueCandidates returns only background-tier schedules")
        XCTAssertEqual(runner.callCount, 0)
    }

    func testDisabledScheduleIsNotConsidered() async throws {
        try seedTemplate()
        try seedSchedule(cadence: .dailyBestEffort, enabled: false)
        let engine = makeEngine(runner: StubTemplateRunner(outcome: .success), notifier: SpyPauseNotifier())
        let s = await engine.evaluateDue(now: now, trigger: .scheduledOpportunistic)
        XCTAssertEqual(s.considered, 0)
    }

    // MARK: - 6. Pure decisions (the cross-platform contract)

    func testVerdictGates() {
        let base = AutomationSchedule(id: "S", templateId: "T", tier: .opportunisticBackground,
                                      desiredCadence: .dailyBestEffort, createdAt: now, updatedAt: now,
                                      originDeviceId: deviceId)
        func verdict(_ s: AutomationSchedule, hasNewData: Bool = false) -> AutomationDueVerdict {
            AutomationDueEvaluator.verdict(for: s, now: now, hasNewData: hasNewData, calendar: utcCalendar)
        }
        // Never-succeeded daily is due.
        XCTAssertEqual(verdict(base), .due)
        // Disabled / paused / wrong tier.
        var disabled = base; disabled.enabled = false
        XCTAssertEqual(verdict(disabled), .skip(.disabled))
        var paused = base; paused.consecutiveFailures = 3
        XCTAssertEqual(verdict(paused), .skip(.paused))
        var shortcut = base; shortcut.tier = .shortcutDriven
        XCTAssertEqual(verdict(shortcut), .skip(.notBackgroundTier))
        // Daily not elapsed vs elapsed.
        var recent = base; recent.lastSuccessAt = now.addingTimeInterval(-3_600)   // 1h ago
        XCTAssertEqual(verdict(recent), .skip(.cadenceNotElapsed))
        var old = base; old.lastSuccessAt = now.addingTimeInterval(-90_000)        // >1d ago
        XCTAssertEqual(verdict(old), .due)
        // onNewData is gated on data.
        var onNew = base; onNew.desiredCadence = .onNewData
        XCTAssertEqual(verdict(onNew, hasNewData: false), .skip(.noNewData))
        XCTAssertEqual(verdict(onNew, hasNewData: true), .due)
    }

    func testBudgetTransitions() {
        let s = AutomationSchedule(id: "S", templateId: "T", tier: .opportunisticBackground,
                                   desiredCadence: .dailyBestEffort, consecutiveFailures: 2,
                                   createdAt: now, updatedAt: now, originDeviceId: deviceId)
        // The 3rd failure pauses and flags the pause transition.
        let fail = AutomationBudget.applyOutcome(.failedDelivery, to: s, now: now)
        XCTAssertEqual(fail.kind, .failure)
        XCTAssertEqual(fail.consecutiveFailures, 3)
        XCTAssertTrue(fail.didJustPause)
        // A success resets.
        let ok = AutomationBudget.applyOutcome(.success, to: s, now: now)
        XCTAssertEqual(ok.kind, .success)
        XCTAssertEqual(ok.consecutiveFailures, 0)
        XCTAssertEqual(ok.lastSuccessAt, now)
        // A already-paused schedule failing again does NOT re-flag the transition.
        var already = s; already.consecutiveFailures = 3
        let again = AutomationBudget.applyOutcome(.failedGeneration, to: already, now: now)
        XCTAssertEqual(again.consecutiveFailures, 4)
        XCTAssertFalse(again.didJustPause, "already paused — no second notification")
    }

    func testQuietHoursStorageRoundTripAndWrap() {
        let wrap = QuietHours(startHour: 22, startMinute: 0, endHour: 7, endMinute: 0)
        XCTAssertEqual(wrap.storageString, "22:00-07:00")
        XCTAssertEqual(QuietHours(storageString: "22:00-07:00"), wrap)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))!
        }
        XCTAssertTrue(wrap.contains(at(23, 0), calendar: cal), "23:00 is inside 22:00-07:00")
        XCTAssertTrue(wrap.contains(at(3, 0), calendar: cal), "03:00 is inside the wrapped window")
        XCTAssertFalse(wrap.contains(at(12, 0), calendar: cal), "noon is outside")
        // A malformed or zero-length window is inert, never a silent all-day suppressor.
        XCTAssertNil(QuietHours(storageString: "notatime"))
        XCTAssertFalse(QuietHours(startHour: 9, startMinute: 0, endHour: 9, endMinute: 0)
            .contains(at(9, 0), calendar: cal))
    }
}

// MARK: - Test doubles

/// Returns a fixed `ExportOutcome` for every run and counts invocations. Lets the failure-budget
/// tests drive the engine deterministically without real generation/delivery.
private final class StubTemplateRunner: AutomationTemplateRunning, @unchecked Sendable {
    private let outcome: ExportOutcome
    private(set) var callCount = 0
    init(outcome: ExportOutcome) { self.outcome = outcome }
    func runScheduledTemplate(_ template: ExportTemplate, trigger: ExportTrigger) async -> ExportOutcome {
        callCount += 1
        return outcome
    }
}

/// Records pause notifications synchronously (no main-actor hop — safe to assert on directly).
private final class SpyPauseNotifier: AutomationPauseNotifying, @unchecked Sendable {
    private(set) var calls: [(scheduleId: String, language: AppLanguage)] = []
    func automationPaused(scheduleId: String, language: AppLanguage) {
        calls.append((scheduleId, language))
    }
}

/// A freshness probe that answers a fixed truth regardless of the watermark.
private struct StubFreshness: AutomationDataFreshnessProbing {
    private let value: Bool
    init(_ value: Bool) { self.value = value }
    func hasDataIngested(after watermark: Date?) -> Bool { value }
}
