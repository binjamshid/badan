import XCTest
@testable import BADAN

/// Headless-testable coverage for the panel-review-2026-07 sync/data-change-bus fixes
/// (fix/panel-review-2026-07): `AppEnvironment.dataGeneration`'s bump semantics (BUG-12/13/
/// EDGE-13), the distinct-handled-slot counting pure function behind Home's meds module
/// (EDGE-20), and the foreground-sync debounce pure function behind `AppEnvironment.
/// syncIfStale()` (BUG-02).
///
/// Out of scope here, by design: the actual `.task(id:)` wiring on Home/Body/Sources/Timeline/
/// Insights/LogHub, the `scenePhase` observer in `BADANApp`, and `EDGE-10`'s background-
/// maintenance call site. Those are UI/lifecycle wiring that needs a rendered view hierarchy or
/// a live `Scene` to exercise, which this headless test target can't stand up — they were
/// verified by inspection against the existing `.task(id:)`/`onChange` patterns already used
/// elsewhere in this codebase (see the fix's own code comments for the rationale at each call
/// site) rather than by an automated test.
final class SyncBusFixTests: XCTestCase {

    // MARK: - BUG-12/13/EDGE-13: dataGeneration bump semantics

    @MainActor
    private func makeEnvironment() throws -> AppEnvironment {
        let db = try Database.inMemoryFallback()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        return AppEnvironment(database: db, clock: clock)
    }

    @MainActor
    func testBumpDataGenerationIncrementsByOne() throws {
        let env = try makeEnvironment()
        let initial = env.dataGeneration

        env.bumpDataGeneration()

        XCTAssertEqual(env.dataGeneration, initial + 1)
    }

    @MainActor
    func testBumpDataGenerationIsMonotonicAcrossRepeatedCalls() throws {
        let env = try makeEnvironment()
        let initial = env.dataGeneration

        for _ in 0..<5 { env.bumpDataGeneration() }

        XCTAssertEqual(env.dataGeneration, initial + 5,
                       "every bump must be observable — a screen keying its .task(id:) off this "
                       + "value must see a distinct value after each one")
    }

    @MainActor
    func testDataGenerationStartsAtZeroForAFreshEnvironment() throws {
        // Not load-bearing by itself, but documents the baseline every screen's first
        // `.task(id:)` fire captures before anything has ever bumped it.
        let env = try makeEnvironment()
        XCTAssertEqual(env.dataGeneration, 0)
    }

    // MARK: - EDGE-20: distinct-handled-slot counting (HomeViewModel.distinctHandledSlotCount)

    private func makeScheduledEvent(
        regimenId: String, dayKey: String, time: String, kind: AdherenceKind,
        occurredAt: Date, scheduledFor: Date
    ) -> AdherenceEvent {
        AdherenceEvent(
            id: "adh-\(regimenId)-\(dayKey)-\(time)",
            regimenId: regimenId, kind: kind, scheduledFor: scheduledFor, occurredAt: occurredAt,
            tzId: "UTC", updatedAt: occurredAt, originDeviceId: "test-device")
    }

    private func makeAsNeededEvent(regimenId: String, occurredAt: Date) -> AdherenceEvent {
        AdherenceEvent(
            id: ULID.newID(), regimenId: regimenId, kind: .taken, scheduledFor: occurredAt,
            occurredAt: occurredAt, tzId: "UTC", updatedAt: occurredAt, originDeviceId: "test-device")
    }

    /// The actual bug: two rows for the *same* scheduled slot (e.g. legacy data written before
    /// scheduled adherence ids became deterministic, or any other source of a same-slot
    /// duplicate) must not count as two handled doses — that inflated count could exceed
    /// `dueTimes().count` and silently suppress a genuinely-due later dose.
    func testDistinctHandledSlotCountDedupesSameSlotDuplicates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let regimenId = "regimen-abc"
        let dup1 = makeScheduledEvent(regimenId: regimenId, dayKey: "2026-07-14", time: "08:00",
                                      kind: .taken, occurredAt: now, scheduledFor: now)
        let dup2 = makeScheduledEvent(regimenId: regimenId, dayKey: "2026-07-14", time: "08:00",
                                      kind: .taken, occurredAt: now.addingTimeInterval(60), scheduledFor: now)

        XCTAssertEqual(BADAN.HomeViewModel.distinctHandledSlotCount([dup1, dup2]), 1)
    }

    /// Two genuinely different scheduled slots (morning + evening) for the same regimen must
    /// each count — this is the case the fix must not regress while dedupe-ing duplicates.
    func testDistinctHandledSlotCountCountsDistinctSlotsSeparately() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let regimenId = "regimen-abc"
        let morning = makeScheduledEvent(regimenId: regimenId, dayKey: "2026-07-14", time: "08:00",
                                         kind: .taken, occurredAt: now, scheduledFor: now)
        let evening = makeScheduledEvent(regimenId: regimenId, dayKey: "2026-07-14", time: "20:00",
                                         kind: .skipped, occurredAt: now, scheduledFor: now)

        XCTAssertEqual(BADAN.HomeViewModel.distinctHandledSlotCount([morning, evening]), 2)
    }

    /// As-needed doses (ULID ids, wave 1) never share a deterministic slot id with each other or
    /// with a scheduled dose, so each is its own distinct occurrence.
    func testDistinctHandledSlotCountTreatsAsNeededULIDsAsDistinct() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let regimenId = "regimen-abc"
        let first = makeAsNeededEvent(regimenId: regimenId, occurredAt: now)
        let second = makeAsNeededEvent(regimenId: regimenId, occurredAt: now.addingTimeInterval(120))

        XCTAssertEqual(BADAN.HomeViewModel.distinctHandledSlotCount([first, second]), 2)
    }

    func testDistinctHandledSlotCountEmptyIsZero() {
        XCTAssertEqual(BADAN.HomeViewModel.distinctHandledSlotCount([]), 0)
    }

    // MARK: - BUG-02: foreground sync debounce (SyncDebounce.shouldSync)

    func testShouldSyncTrueWhenNeverSyncedBefore() {
        XCTAssertTrue(SyncDebounce.shouldSync(lastSync: nil, now: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    func testShouldSyncFalseWithinTheDebounceWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSync = now.addingTimeInterval(-60) // 1 minute ago — well within the 5-minute window
        XCTAssertFalse(SyncDebounce.shouldSync(lastSync: lastSync, now: now))
    }

    func testShouldSyncTrueOnceTheDebounceWindowHasElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSync = now.addingTimeInterval(-SyncDebounce.minInterval - 1)
        XCTAssertTrue(SyncDebounce.shouldSync(lastSync: lastSync, now: now))
    }

    func testShouldSyncFalseRightAtTheBoundaryJustShortOfTheWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSync = now.addingTimeInterval(-SyncDebounce.minInterval + 1)
        XCTAssertFalse(SyncDebounce.shouldSync(lastSync: lastSync, now: now))
    }

    func testShouldSyncTrueExactlyAtTheWindowBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let lastSync = now.addingTimeInterval(-SyncDebounce.minInterval)
        XCTAssertTrue(SyncDebounce.shouldSync(lastSync: lastSync, now: now), "the boundary itself should allow a sync (>=), not just strictly past it")
    }
}
