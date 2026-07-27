import XCTest
@testable import BADAN

/// EPIC-33 (Phase 3D) — the write side of the ambient snapshot channel: `AmbientSnapshotWriter`
/// assembling a real `AmbientSnapshotDto` from fixture repositories, `AmbientSnapshotStore`'s
/// app-group file round-trip, its N-1 schema tolerance, and the 30s write debounce.
///
/// Uses the same on-disk `Database(directory:)` fixture harness as `DerivationPipelineTests`, plus
/// a second throwaway directory standing in for the shared app-group container (real app-group
/// container URL resolution needs an entitlement/signing identity a plain unit-test bundle isn't
/// guaranteed to carry — see `AmbientSnapshotStore.overrideContainerURL`'s doc).
final class AmbientSnapshotTests: XCTestCase {
    var dbDir: URL!
    var ambientDir: URL!
    var db: Database!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_784_000_000)) // fixed "now"
    let deviceId = "test-device"
    var tz: String { TimeZone.current.identifier }

    override func setUpWithError() throws {
        dbDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-ambient-db-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: dbDir)
        ambientDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-ambient-container-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ambientDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: dbDir)
        try? FileManager.default.removeItem(at: ambientDir)
    }

    private var periodKey: String { DayAttribution.dayPeriodKey(clock.now(), tz: tz) }

    private func makeWriter(
        reloadWidgets: @escaping ([String]) -> Void = { _ in },
        syncToWatch: @escaping (AmbientSnapshotDto) -> Void = { _ in }
    ) -> AmbientSnapshotWriter {
        AmbientSnapshotWriter(
            derivation: DerivationRepository(db.main), measurements: MeasurementRepository(db.main),
            logging: LoggingRepository(main: db.main, sensitive: db.sensitive),
            insights: InsightRepository(db.main),
            store: AmbientSnapshotStore(overrideContainerURL: ambientDir),
            clock: clock, reloadWidgets: reloadWidgets, syncToWatch: syncToWatch)
    }

    // MARK: - Fixture seeding

    private func seedReadiness(score: Double, provisional: Bool = false) throws {
        try DerivationRepository(db.main).appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.readinessScore, value: score, unit: "score_0_100",
            periodKey: periodKey, confidence: 0.9, provisional: provisional,
            algorithmId: "composite.readiness_score", algorithmVersion: "2.0.0",
            computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: deviceId))
    }

    private func seedSentenceInsight(templateId: String = "vitals_within_band") throws {
        try InsightRepository(db.main).insert(Insight(
            id: ULID.newID(), insightType: "statusExplanation", templateId: templateId,
            templateVersion: "1", metricIds: [MetricID.hrv], periodKey: periodKey,
            depthVariant: .casual,
            renderedText: LocalizedString(
                en: "Your HRV is 55 ms today, right in your usual range (around 52 ms).",
                ar: "قيمة HRV لديك اليوم هي 55 مي.ث، ضمن نطاقك المعتاد (حوالي 52 مي.ث)."),
            evidenceRefs: [], generatedAt: clock.now()))
    }

    @discardableResult
    private func seedSleep(asleepMinutes: Double = 420, performanceScore: Double? = 88,
                           provisional: Bool = false) throws -> String {
        let localNight = DayAttribution.localNight(sessionEnd: clock.now(), tz: tz)
        let start = clock.now().addingTimeInterval(-8 * 3600)
        _ = try MeasurementRepository(db.main).upsertSession(Session(
            id: ULID.newID(), kind: .sleepPrimary, startAt: start, endAt: clock.now(), tzId: tz,
            localNight: localNight, detail: SessionDetail(timeAsleepSeconds: asleepMinutes * 60),
            provenance: Provenance(sourceId: "fixture-source", ingestionPath: .platformStore,
                                   measuredAt: start, measuredTimezone: tz, recordedAt: start, ingestedAt: start),
            updatedAt: clock.now(), originDeviceId: deviceId))
        if let performanceScore {
            try DerivationRepository(db.main).appendDerived(DerivedValue(
                id: ULID.newID(), metricId: MetricID.sleepPerformance, value: performanceScore, unit: "percent",
                periodKey: periodKey, confidence: 0.9, provisional: provisional,
                algorithmId: "sleep.performance", algorithmVersion: "1.0.0",
                computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: deviceId))
        }
        return localNight
    }

    /// A22/EPIC-42. `unit` defaults to `effort.day`'s real canonical unit (`registry.json`,
    /// `score_0_100`) — pass a different unit (e.g. `"kcal"`, the reduced-input activity-load unit
    /// `EffortEngine.persistReducedInput` actually writes) to simulate the reduced-input variant.
    private func seedEffort(score: Double, provisional: Bool = false, unit: String = "score_0_100") throws {
        try DerivationRepository(db.main).appendDerived(DerivedValue(
            id: ULID.newID(), metricId: MetricID.effortDay, value: score, unit: unit,
            periodKey: periodKey, confidence: 0.9, provisional: provisional,
            algorithmId: "effort.day", algorithmVersion: "1.0.0",
            computedAt: clock.now(), updatedAt: clock.now(), originDeviceId: deviceId))
    }

    private func seedMedication(name: String = "Vitamin D", time: String = "09:00") throws {
        try LoggingRepository(main: db.main, sensitive: db.sensitive).upsertRegimen(MedicationRegimen(
            id: ULID.newID(), name: name, schedule: .daily(times: [time]),
            startedAt: clock.now().addingTimeInterval(-30 * 86_400),
            updatedAt: clock.now(), originDeviceId: deviceId))
    }

    // MARK: - Writer assembles real data from fixture repositories

    func testBuildSnapshotAssemblesRealReadinessSleepAndSentenceData() async throws {
        try seedReadiness(score: 72)
        try seedSentenceInsight()
        try seedSleep(asleepMinutes: 420, performanceScore: 88)

        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)

        XCTAssertEqual(dto.schemaVersion, AmbientSnapshotDto.currentSchemaVersion)
        XCTAssertEqual(dto.language, "en")

        let readiness = try XCTUnwrap(dto.readiness, "a fresh readiness row must produce a ring snapshot")
        XCTAssertEqual(readiness.score, 72, accuracy: 0.001)
        XCTAssertFalse(readiness.provisional)

        let sentence = try XCTUnwrap(dto.sentence)
        XCTAssertTrue(sentence.en.contains("usual range"), "must surface the rendered insight text, not re-template it")
        XCTAssertFalse(sentence.ar.isEmpty, "the bilingual contract must carry through unchanged")

        let sleep = try XCTUnwrap(dto.sleep, "a primary sleep session for tonight must produce a sleep snapshot")
        XCTAssertEqual(sleep.durationMinutes, 420)
        XCTAssertEqual(try XCTUnwrap(sleep.score), 88, accuracy: 0.001)
        XCTAssertFalse(sleep.provisional)
    }

    // MARK: - Effort (A22/EPIC-42, added for BadanWatch's glanceable today view)

    func testEffortSnapshotCarriesTheZoneBasedScore() async throws {
        try seedEffort(score: 63, provisional: false)
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        let effort = try XCTUnwrap(dto.effort, "a score_0_100-unit effort.day row must produce an effort snapshot")
        XCTAssertEqual(effort.score, 63, accuracy: 0.001)
        XCTAssertFalse(effort.provisional)
    }

    func testEffortSnapshotIsProvisionalWhenTheUnderlyingRowIs() async throws {
        try seedEffort(score: 40, provisional: true)
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(try XCTUnwrap(dto.effort).provisional)
    }

    /// The reduced-input activity-load variant (`EffortEngine.persistReducedInput`, e.g. a `"kcal"`
    /// unit) is a real movement magnitude, but not the 0–100 score `EffortSnapshot` promises — it
    /// must degrade to `nil`, never be mislabelled as a score it isn't (`EffortSnapshot`'s own doc).
    func testEffortSnapshotIsNilForTheReducedInputActivityLoadUnit() async throws {
        try seedEffort(score: 320, unit: "kcal")
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertNil(dto.effort, "a non-score-unit effort.day row must not be surfaced as a fabricated score")
    }

    func testEffortSnapshotIsNilWhenNothingComputedYet() async throws {
        // No effort.day row seeded at all — an honest gap, same as readiness/sleep's own nil cases.
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertNil(dto.effort)
    }

    func testSentencePicksTheMostNotableInsightOverACalmOne() async throws {
        // Two insights for the same day (a real day could carry up to `InsightEngine.keyMetrics.
        // count`): the calm one and the actionable one. The actionable one must win regardless of
        // insertion order.
        try seedSentenceInsight(templateId: "vitals_within_band")
        try InsightRepository(db.main).insert(Insight(
            id: ULID.newID(), insightType: "statusExplanation", templateId: "sleep_debt_rising",
            templateVersion: "1", metricIds: [MetricID.timeAsleep], periodKey: periodKey,
            depthVariant: .casual,
            renderedText: LocalizedString(
                en: "Your time asleep has slipped to 6h 10m this week, a bit under your usual 7h.",
                ar: "انخفض وقت نومك إلى ٦س ١٠د هذا الأسبوع، أقل قليلاً من معتادك ٧س."),
            evidenceRefs: [], generatedAt: clock.now()))

        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        let sentence = try XCTUnwrap(dto.sentence)
        XCTAssertTrue(sentence.en.contains("slipped"), "the actionable sleep-debt insight must outrank the calm one")
    }

    func testSentenceFallsBackToTheCalmGenericSentenceWhenNothingFiredToday() async throws {
        // No insight seeded at all — an honest "nothing notable" day.
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        let sentence = try XCTUnwrap(dto.sentence)
        XCTAssertEqual(sentence.en, OneTrueSentencePicker.fallback.en)
        XCTAssertEqual(sentence.ar, OneTrueSentencePicker.fallback.ar)
    }

    // MARK: - medsDue: nil (no consent) vs. real data vs. empty-but-granted

    func testMedsDueIsNilWhenConsentIsOff() async throws {
        try seedMedication()
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertNil(dto.medsDue, "medsDue must be entirely absent (not an empty array) when consent is off")
    }

    func testMedsDuePopulatedWhenConsentIsOn() async throws {
        try seedMedication(name: "Vitamin D", time: "09:00")
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: true, privacy: .default)
        let medsDue = try XCTUnwrap(dto.medsDue)
        XCTAssertEqual(medsDue.items.count, 1)
        XCTAssertEqual(medsDue.items.first?.displayName, "Vitamin D")
        XCTAssertFalse(medsDue.items.first?.timeLabel.isEmpty ?? true)
    }

    /// The DTO's own contract (see `AmbientSnapshotDto.medsDue`'s doc): consent granted + nothing
    /// due is a REAL, DIFFERENT state from consent being off — an empty array, never `nil`.
    func testMedsDueEmptyArrayIsADistinctStateFromConsentOff() async throws {
        // No regimens seeded at all — consent IS granted, but nothing happens to be due.
        let dto = try await makeWriter().buildSnapshot(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: true, privacy: .default)
        let medsDue = try XCTUnwrap(dto.medsDue, "consent on must always produce a non-nil medsDue, even when empty")
        XCTAssertTrue(medsDue.items.isEmpty)
    }

    /// FIX-1 (Phase 3D audit): purging the sensitive namespace (`PrivacySecuritySettingsScreen`'s
    /// "turn off sensitive records" flow) must not leave a just-deleted medication sitting in the
    /// shared widget snapshot indefinitely. `buildMedsDueSnapshot` reads `logging.regimens(
    /// activeOnly:)` fresh on every call — it does not cache — so once the sensitive DB is purged
    /// (the same file `purgeSensitiveNamespace()` deletes and recreates empty), a rebuilt snapshot
    /// can no longer see the purged regimen regardless of `medsDueConsentGranted`. What matters
    /// here is that a purge triggers a REBUILD promptly (`forceWrite`, bypassing the debounce) —
    /// covered by `PrivacySecuritySettingsScreen`'s purge-confirm handler, exercised here by
    /// simulating the same sequence (purge, then forceWrite) against the real repositories.
    ///
    /// The real resulting state (read from `buildMedsDueSnapshot`'s actual logic, not assumed):
    /// `consentWidgetMedsDue` is a SEPARATE profile flag from `sensitiveModulesEnabled` and the
    /// purge does not touch it — so if it was on before the purge, it is still on after, and
    /// `medsDue` stays non-nil (never `nil` just because of the purge). It is the ITEMS array that
    /// becomes empty, because the regimens table behind it is now empty.
    func testPurgingSensitiveNamespaceRemovesTheMedicationFromANewlyBuiltSnapshot() async throws {
        try seedMedication(name: "Lisinopril", time: "08:00")
        let writer = makeWriter()
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        let firstNow = clock.now()

        // An ordinary write, well before the purge: the medication is really on disk.
        let firstWrote = await writer.writeIfNeeded(now: firstNow, tz: tz, language: .en, medsDueConsentGranted: true, privacy: .default)
        XCTAssertTrue(firstWrote)
        let beforePurge = try XCTUnwrap(store.read())
        let beforeMedsDue = try XCTUnwrap(beforePurge.medsDue)
        XCTAssertEqual(beforeMedsDue.items.map(\.displayName), ["Lisinopril"],
                       "sanity check: the medication must actually be on disk before the purge")

        // The purge itself (mirrors `PrivacySecuritySettingsScreen`'s "turn off sensitive
        // records" flow calling `env.database.purgeSensitiveNamespace()`).
        try db.purgeSensitiveNamespace()

        // Immediately after, inside the same debounce window `firstNow` started: an ordinary
        // `writeIfNeeded` would be skipped here (that's exactly FIX-1's bug — the stale snapshot
        // would linger). The purge-confirm handler's fix is to call `forceWrite` instead, with
        // `consentWidgetMedsDue` unchanged (a separate profile flag the purge does not touch).
        let soonAfterPurge = firstNow.addingTimeInterval(1)
        let debouncedAwayAfterPurge = await writer.writeIfNeeded(
            now: soonAfterPurge, tz: tz, language: .en, medsDueConsentGranted: true, privacy: .default)
        XCTAssertFalse(debouncedAwayAfterPurge,
                      "sanity check: an ordinary call this soon after the last write is still debounced")
        let forcedAfterPurge = await writer.forceWrite(now: soonAfterPurge, tz: tz, language: .en, medsDueConsentGranted: true, privacy: .default)
        XCTAssertTrue(forcedAfterPurge, "forceWrite must bypass the debounce so the purge is reflected promptly")

        // The real resulting state, read back from disk exactly as a widget would (read that
        // logic, don't assume it): `consentWidgetMedsDue` is a SEPARATE flag from
        // `sensitiveModulesEnabled` and the purge never touches it, so `medsDue` stays non-nil —
        // it is the ITEMS array that becomes empty, because the regimens table behind it is now
        // empty (the same "consent on, nothing due" shape `testMedsDueEmptyArrayIsADistinctStateFromConsentOff` covers).
        let afterPurge = try XCTUnwrap(store.read())
        let afterMedsDue = try XCTUnwrap(
            afterPurge.medsDue, "consent is still on after a purge (it's a separate flag) — medsDue must stay non-nil")
        XCTAssertTrue(afterMedsDue.items.isEmpty,
                      "the purged medication must be gone from the re-read snapshot")
        XCTAssertFalse(afterMedsDue.items.contains { $0.displayName == "Lisinopril" },
                       "the purged medication's name must not still be reachable from the shared snapshot")
    }

    // MARK: - Debounce (30s)

    func testDebounceCollapsesTwoWritesWithinTheWindowIntoOne() async throws {
        try seedReadiness(score: 50)

        let writer = makeWriter()
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        let firstNow = clock.now()
        let secondNow = firstNow.addingTimeInterval(10) // well inside the 30s window

        let firstWrote = await writer.writeIfNeeded(now: firstNow, tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(firstWrote, "the first call must write (nothing written yet)")
        let secondWrote = await writer.writeIfNeeded(now: secondNow, tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertFalse(secondWrote, "a second call inside the 30s window must be debounced away")

        // Corroborate the write-counter result (the two booleans above) against the actual file
        // content: if the second call HAD written, `generatedAt` would read `secondNow`.
        let onDisk = try XCTUnwrap(store.read())
        XCTAssertEqual(onDisk.generatedAt.timeIntervalSince1970, firstNow.timeIntervalSince1970, accuracy: 0.001)

        let thirdNow = firstNow.addingTimeInterval(Self.pastDebounceWindow)
        let thirdWrote = await writer.writeIfNeeded(now: thirdNow, tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(thirdWrote, "a call past the debounce window must write again")
        let onDiskAfter = try XCTUnwrap(store.read())
        XCTAssertEqual(onDiskAfter.generatedAt.timeIntervalSince1970, thirdNow.timeIntervalSince1970, accuracy: 0.001)
    }

    func testForceWriteBypassesTheDebounce() async throws {
        try seedReadiness(score: 40)
        let writer = makeWriter()
        let firstWrote = await writer.writeIfNeeded(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(firstWrote)

        let soonAfter = clock.now().addingTimeInterval(1)
        let debouncedAway = await writer.writeIfNeeded(now: soonAfter, tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertFalse(debouncedAway, "an ordinary call stays debounced")
        let forced = await writer.forceWrite(now: soonAfter, tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(forced, "forceWrite must bypass the debounce")
    }

    /// FIX-2 (Phase 3D audit): `AmbientSnapshotWriter` is now an `actor` specifically so that
    /// concurrent calls to `writeIfNeeded` — which is exactly how the 25+ real call sites invoke
    /// it, each from its own independent `Task`/`Task.detached` — genuinely serialize instead of
    /// racing on `lastWriteAt`. This is the test the plain single-threaded debounce tests above
    /// cannot be: it launches N calls at once, all targeting the SAME instant, via a real
    /// `TaskGroup`, and asserts exactly one of them actually wrote — not "probably none raced this
    /// time," but a guarantee the actor's isolation makes true by construction. Before the actor
    /// conversion this was a genuine data race (undetected only because the project builds with
    /// `SWIFT_STRICT_CONCURRENCY: minimal`) and this exact test would have been flaky at best —
    /// under an actor it is deterministic every run.
    func testConcurrentWriteIfNeededCallsProduceExactlyOneRealWrite() async throws {
        try seedReadiness(score: 61)
        let writer = makeWriter()
        let now = clock.now()
        let tz = self.tz // captured as a plain (Sendable) String before crossing into the task group
        let concurrentCallCount = 25 // matches this fix's own "25+ independent call sites" framing

        let writeCount = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<concurrentCallCount {
                group.addTask {
                    await writer.writeIfNeeded(now: now, tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
                }
            }
            var count = 0
            for await wrote in group where wrote { count += 1 }
            return count
        }

        XCTAssertEqual(writeCount, 1,
                       "actor isolation must serialize every concurrent call against the same debounce state — " +
                       "exactly one of \(concurrentCallCount) simultaneous calls may pass the check-then-act " +
                       "and actually write")

        // Corroborate against the write-counter result: the file itself was written exactly once,
        // not partially or twice (which a genuine race could otherwise produce as a torn/duplicated
        // write).
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        let onDisk = try XCTUnwrap(store.read())
        XCTAssertEqual(onDisk.generatedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSuccessfulWriteReloadsEveryWidgetKindExactlyOnce() async throws {
        try seedReadiness(score: 65)
        var reloadedKinds: [String] = []
        let writer = makeWriter(reloadWidgets: { kinds in reloadedKinds.append(contentsOf: kinds) })

        let wrote = await writer.writeIfNeeded(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(wrote)
        XCTAssertEqual(reloadedKinds, AmbientSnapshotWriter.widgetKinds)

        // A debounced-away second call must not trigger a second reload.
        _ = await writer.writeIfNeeded(now: clock.now().addingTimeInterval(1), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertEqual(reloadedKinds, AmbientSnapshotWriter.widgetKinds, "a debounced call must not reload widgets again")
    }

    /// A22/EPIC-42. Mirrors `testSuccessfulWriteReloadsEveryWidgetKindExactlyOnce` for the new
    /// `syncToWatch` transport: exactly one call per successful write, carrying the SAME dto that
    /// landed on disk (never a second, independently-assembled snapshot), and none at all for a
    /// debounced-away call.
    func testSuccessfulWriteSyncsToWatchExactlyOnceWithTheWrittenDto() async throws {
        try seedReadiness(score: 65)
        try seedEffort(score: 58)
        var syncedDtos: [AmbientSnapshotDto] = []
        let writer = makeWriter(syncToWatch: { syncedDtos.append($0) })

        let wrote = await writer.writeIfNeeded(now: clock.now(), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertTrue(wrote)
        XCTAssertEqual(syncedDtos.count, 1, "exactly one watch sync per successful write")

        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        let onDisk = try XCTUnwrap(store.read())
        XCTAssertEqual(syncedDtos.first, onDisk, "the watch must receive the SAME dto that was written to disk")

        // A debounced-away second call must not trigger a second watch sync.
        _ = await writer.writeIfNeeded(now: clock.now().addingTimeInterval(1), tz: tz, language: .en, medsDueConsentGranted: false, privacy: .default)
        XCTAssertEqual(syncedDtos.count, 1, "a debounced call must not sync to the watch again")
    }

    private static let pastDebounceWindow = AmbientSnapshotWriter.minWriteInterval + 1

    // MARK: - N-1 schema tolerance (AmbientSnapshotStore.read / AmbientSnapshotDto.init(from:))

    /// `AmbientSnapshotDto.currentSchemaVersion` is 1 — the very first shipped version — so there
    /// is no REAL v0 payload anywhere this test could read from a historical fixture. This is
    /// deliberately a forward-looking contract test: it hand-constructs a plausible older/thinner
    /// shape (an old `schemaVersion` and a field this version's writer always includes missing
    /// entirely) and asserts `AmbientSnapshotStore.read()` still returns a usable value instead of
    /// `nil` or a crash. It is vacuous TODAY in the sense that no such file has ever existed in the
    /// wild — but it pins the exact contract (`AmbientSnapshotDto.init(from:)`'s tolerant decode)
    /// that will matter the day a real v2 ships and genuine v1 files still sit in users'
    /// already-installed app-group containers.
    func testReadToleratesAnOlderThinnerSchemaShapeWithoutCrashing() throws {
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        // Deliberately missing `language` (imagining a hypothetical prior schema that added it
        // later) and `medsDue`/`sentence`/`sleep` (fields this version's writer always includes,
        // but an older file legitimately might not) — only `schemaVersion`, `generatedAt` and
        // `readiness` present.
        let handRolledOlderShape: [String: Any] = [
            "schemaVersion": AmbientSnapshotDto.currentSchemaVersion - 1,
            "generatedAt": 800_000_000.0,
            "readiness": ["score": 61.0, "provisional": false],
        ]
        let data = try JSONSerialization.data(withJSONObject: handRolledOlderShape)
        try data.write(to: ambientDir.appendingPathComponent(AmbientSnapshotStore.snapshotFilename))

        let dto = try XCTUnwrap(store.read(), "a thinner/older-shaped snapshot must still decode to something sane")
        XCTAssertEqual(dto.schemaVersion, AmbientSnapshotDto.currentSchemaVersion - 1)
        XCTAssertEqual(dto.language, "en", "a missing language field must default rather than fail the whole decode")
        XCTAssertNil(dto.medsDue)
        XCTAssertNil(dto.sentence)
        XCTAssertNil(dto.sleep)
        XCTAssertEqual(dto.readiness?.score, 61.0)
        XCTAssertEqual(dto.readiness?.provisional, false)
    }

    func testReadReturnsNilForGenuinelyUnreadableFileRatherThanThrowing() throws {
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        try Data("not json at all".utf8).write(to: ambientDir.appendingPathComponent(AmbientSnapshotStore.snapshotFilename))
        XCTAssertNil(store.read())
    }

    func testReadReturnsNilWhenNothingHasEverBeenWritten() {
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        XCTAssertNil(store.read())
    }

    // MARK: - Store round-trip

    func testStoreWriteThenReadRoundTripsUnchanged() throws {
        let store = AmbientSnapshotStore(overrideContainerURL: ambientDir)
        let dto = AmbientSnapshotDto(
            generatedAt: clock.now(), language: "ar",
            readiness: RingSnapshot(score: 88, provisional: true),
            sentence: SentenceSnapshot(en: "hello", ar: "أهلاً"),
            sleep: SleepSnapshot(durationMinutes: 411, score: 77, provisional: false),
            medsDue: MedsDueSnapshot(items: [MedsDueItem(regimenId: "r1", displayName: "Vitamin D", timeLabel: "9:00 AM")]),
            effort: EffortSnapshot(score: 54, provisional: true))

        try store.write(dto)
        let readBack = try XCTUnwrap(store.read())
        XCTAssertEqual(readBack, dto)
        XCTAssertEqual(readBack.effort, dto.effort)
    }
}
