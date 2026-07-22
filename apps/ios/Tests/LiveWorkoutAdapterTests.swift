import XCTest
@testable import BADAN

/// EPIC-42 slice 2 — `LiveWorkoutAdapter`'s own tick logic in isolation: checkpoint persistence,
/// heart-rate polling (never a fabricated 0), and low-battery detection. Drives `tick()` directly
/// (kept `internal` for exactly this reason) rather than waiting on the real timer, so these stay
/// fast and deterministic.
@MainActor
final class LiveWorkoutAdapterTests: XCTestCase {
    var tempDir: URL!
    var db: Database!
    var checkpointRepository: WorkoutCheckpointRepository!
    let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
    let device = "test-device"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-live-workout-adapter-test-\(UUID().uuidString)", isDirectory: true)
        db = try Database(directory: tempDir)
        checkpointRepository = WorkoutCheckpointRepository(db.main)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sampleCheckpoint(sessionId: String = "s1") -> WorkoutCheckpoint {
        WorkoutCheckpoint(
            sessionId: sessionId, activityType: "running", state: .active, startedAt: clock.now(),
            stateHistory: [WorkoutStateTransition(state: .active, at: clock.now())],
            hotState: WorkoutHotState(stateBeforeInterruption: .active, activeSeconds: 42),
            lastCheckpointAt: clock.now(), originDeviceId: device)
    }

    private final class StubBattery: BatteryLevelProviding {
        var batteryLevel: Float
        init(_ level: Float) { self.batteryLevel = level }
    }

    private final class StubHealthStore: HealthStorePort {
        var samplesToReturn: [SampleDTO] = []
        func availability() -> HealthAvailability { .available }
        func sourceDescriptors() -> [SourceDescriptor] { [] }
        func readSamples(_ range: HealthDateRange) -> [SampleDTO] { samplesToReturn }
        func readIntervals(_ range: HealthDateRange) -> [IntervalDTO] { [] }
        func readSessions(_ range: HealthDateRange) -> [SessionDTO] { [] }
    }

    private func hrSample(bpm: Double, at date: Date) -> SampleDTO {
        SampleDTO(metricId: MetricID.heartRate, value: bpm, unit: "bpm", start: date, tz: "UTC",
                 sourceId: "src", externalId: "ext-\(date.timeIntervalSince1970)")
    }

    // MARK: - Checkpoint persistence

    func testTickPersistsWhateverCheckpointProviderSupplies() async {
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: nil,
                                         clock: clock, battery: StubBattery(-1))
        let checkpoint = sampleCheckpoint()
        adapter.checkpointProvider = { checkpoint }

        await adapter.tick()

        let loaded = try? checkpointRepository.load(sessionId: "s1")
        XCTAssertEqual(loaded, checkpoint)
    }

    func testTickPersistsNothingWhenCheckpointProviderReturnsNil() async {
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: nil,
                                         clock: clock, battery: StubBattery(-1))
        adapter.checkpointProvider = { nil }

        await adapter.tick()

        XCTAssertTrue(try checkpointRepository.loadAll().isEmpty)
    }

    // MARK: - Heart rate (never a fabricated 0)

    func testHeartRateReportsNilWhenNoHealthStoreIsConfigured() async {
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: nil,
                                         clock: clock, battery: StubBattery(-1))
        var callbackFired = false
        var received: Double = -1   // sentinel — a real 0 or nil must overwrite this
        adapter.onHeartRateUpdate = { bpm in
            callbackFired = true
            received = bpm ?? -1
        }

        await adapter.tick()

        XCTAssertTrue(callbackFired, "the callback must fire even with no store")
        XCTAssertEqual(received, -1, "no health store must report nil, never a fabricated 0")
    }

    func testHeartRateReportsNilWhenTheStoreHasNoRecentSample() async {
        let store = StubHealthStore()
        store.samplesToReturn = []
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: store,
                                         clock: clock, battery: StubBattery(-1))
        var callbackFired = false
        var received: Double? = 0   // sentinel — must be overwritten to nil, not left at 0
        adapter.onHeartRateUpdate = { bpm in
            callbackFired = true
            received = bpm
        }

        await adapter.tick()

        XCTAssertTrue(callbackFired)
        XCTAssertNil(received, "an empty read window must report nil, never a fabricated 0")
    }

    func testHeartRateReportsTheLatestSampleByStartDateNeverAnOlderOne() async {
        let store = StubHealthStore()
        let now = clock.now()
        store.samplesToReturn = [
            hrSample(bpm: 88, at: now.addingTimeInterval(-120)),
            hrSample(bpm: 101, at: now.addingTimeInterval(-10)),   // most recent — must win
            hrSample(bpm: 95, at: now.addingTimeInterval(-60)),
        ]
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: store,
                                         clock: clock, battery: StubBattery(-1))
        var received: Double?
        adapter.onHeartRateUpdate = { bpm in received = bpm }

        await adapter.tick()

        XCTAssertEqual(received, 101)
    }

    func testHeartRatePollIsNotRepeatedBeforeTheNextCadenceWindow() async {
        let store = StubHealthStore()
        store.samplesToReturn = [hrSample(bpm: 100, at: clock.now())]
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: store,
                                         clock: clock, battery: StubBattery(-1))
        var updateCount = 0
        adapter.onHeartRateUpdate = { _ in updateCount += 1 }

        await adapter.tick()
        XCTAssertEqual(updateCount, 1)

        // Well inside the poll cadence — a second tick must not poll again.
        clock.advance(by: LiveWorkoutAdapter.hrPollInterval / 2)
        await adapter.tick()
        XCTAssertEqual(updateCount, 1, "polling again before the cadence window elapsed")

        // Past the cadence window — now it should poll again.
        clock.advance(by: LiveWorkoutAdapter.hrPollInterval)
        await adapter.tick()
        XCTAssertEqual(updateCount, 2)
    }

    // MARK: - Low battery (degraded condition begin/end)

    func testLowBatteryFiresBeginExactlyOnceThenEndOnRecovery() async {
        let battery = StubBattery(0.10)   // below the 0.20 threshold
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: nil,
                                         clock: clock, battery: battery)
        var beganCount = 0, endedCount = 0
        adapter.onDegradedConditionBegan = { condition in
            XCTAssertEqual(condition, .lowBattery)
            beganCount += 1
        }
        adapter.onDegradedConditionEnded = { _ in endedCount += 1 }

        await adapter.tick()
        XCTAssertEqual(beganCount, 1)
        XCTAssertEqual(endedCount, 0)

        // Still low on a second tick — must not fire a duplicate "began".
        await adapter.tick()
        XCTAssertEqual(beganCount, 1)

        battery.batteryLevel = 0.80   // recovered
        await adapter.tick()
        XCTAssertEqual(beganCount, 1)
        XCTAssertEqual(endedCount, 1)
    }

    func testUnknownBatteryLevelNeverReportsEitherCondition() async {
        let battery = StubBattery(-1)   // "unknown" — simulator's real default
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: nil,
                                         clock: clock, battery: battery)
        var fired = false
        adapter.onDegradedConditionBegan = { _ in fired = true }
        adapter.onDegradedConditionEnded = { _ in fired = true }

        await adapter.tick()

        XCTAssertFalse(fired, "an unknown battery reading must never be treated as low or recovered")
    }

    // MARK: - start()/stop()

    func testStopCancelsTheTickLoopWithoutCrashing() {
        let adapter = LiveWorkoutAdapter(checkpointRepository: checkpointRepository, healthStore: nil,
                                         clock: clock, battery: StubBattery(-1))
        adapter.start()
        adapter.stop()
        adapter.stop()   // idempotent — a second stop must not crash
    }
}
