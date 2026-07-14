import XCTest
@testable import BADAN

/// Pure-function tests for the small pieces of duplicated cross-platform logic (the ones the
/// Android port must match): unit conversion, dedup overlap math, ULID encoding.
final class UnitTests: XCTestCase {

    // MARK: - Units

    func testEnergyConversion() throws {
        // 1 kcal = 4.184 kJ
        let kJ = try Units.convert(1, from: "kcal", to: "kJ")
        XCTAssertEqual(kJ, 4.184, accuracy: 0.001)
        let back = try Units.convert(kJ, from: "kJ", to: "kcal")
        XCTAssertEqual(back, 1, accuracy: 0.0001)
    }

    func testDurationConversion() throws {
        XCTAssertEqual(try Units.convert(3600, from: "s", to: "h"), 1, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(90, from: "min", to: "s"), 5400, accuracy: 0.0001)
    }

    func testMassConversion() throws {
        XCTAssertEqual(try Units.convert(1, from: "kg", to: "lb"), 2.2046, accuracy: 0.001)
    }

    func testDistanceConversion() throws {
        XCTAssertEqual(try Units.convert(1000, from: "m", to: "km"), 1, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(1, from: "mi", to: "m"), 1609.344, accuracy: 0.01)
    }

    func testTemperatureOffsetConversion() throws {
        XCTAssertEqual(try Units.convert(32, from: "degF", to: "degC"), 0, accuracy: 0.001)
        XCTAssertEqual(try Units.convert(100, from: "degC", to: "degF"), 212, accuracy: 0.001)
    }

    func testUnknownUnitPassesThroughToCanonical() {
        // Non-convertible/unknown units pass through unchanged (never crash ingestion).
        XCTAssertEqual(Units.toCanonical(97, from: "percent", canonical: "percent"), 97)
        XCTAssertEqual(Units.toCanonical(55, from: "bpm", canonical: "bpm"), 55)
    }

    func testIncompatibleDimensionsThrow() {
        XCTAssertThrowsError(try Units.convert(1, from: "kg", to: "m"))
    }

    // MARK: - (DATA-02) newly-added registry-canonical units

    func testSpeedConversion() throws {
        // 1 m/s = 3.6 km/h.
        XCTAssertEqual(try Units.convert(1, from: "m/s", to: "km/h"), 3.6, accuracy: 0.001)
        XCTAssertEqual(try Units.convert(1, from: "mph", to: "m/s"), 0.44704, accuracy: 0.0001)
    }

    func testMilligramConversion() throws {
        // Caffeine's canonical "mg" shares the mass dimension with "g"/"kg" rather than
        // standing alone, so a future cross-metric conversion isn't silently unconvertible.
        XCTAssertEqual(try Units.convert(1000, from: "mg", to: "g"), 1, accuracy: 0.0001)
    }

    func testIdentityDimensionsRoundTrip() throws {
        // Metrics with exactly one real-world unit (BMI, VO2 max, breathing rate, 0-100
        // scores, the clock-time family) still need a table entry so `unknownUnits` doesn't
        // flag them — round-tripping through the same symbol must be a no-op.
        XCTAssertEqual(try Units.convert(22.5, from: "kg/m^2", to: "kg/m^2"), 22.5, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(42, from: "mL/kg/min", to: "mL/kg/min"), 42, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(80, from: "score_0_100", to: "points"), 80, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(3, from: "scale_1_5", to: "level"), 3, accuracy: 0.0001)
        XCTAssertEqual(try Units.convert(7, from: "scale_0_10", to: "level"), 7, accuracy: 0.0001)
    }

    func testUnknownUnitsOverRegistryIsEmpty() throws {
        // (DATA-02) `Units.unknownUnits` previously had zero callers; wired up here (and more
        // thoroughly in `DerivationFixTests.testRegistryCanonicalAndDisplayUnitsAreAllKnown`)
        // against every canonical + display unit the bundled registry actually declares.
        let registry = MetricRegistry.shared
        var allUnits = Set<String>()
        for def in registry.all {
            allUnits.insert(def.canonicalUnit)
            allUnits.formUnion(def.displayUnits)
        }
        XCTAssertTrue(Units.unknownUnits(in: allUnits).isEmpty)
    }

    // MARK: - Dedup overlap

    func testOverlapFullContainment() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = (start: base, end: base.addingTimeInterval(3600))
        let b = (start: base.addingTimeInterval(300), end: base.addingTimeInterval(3300))
        // b is inside a; overlap over min-duration (b) is 1.0
        XCTAssertEqual(DedupLite.overlap(a, b), 1.0, accuracy: 0.001)
    }

    func testOverlapDisjoint() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = (start: base, end: base.addingTimeInterval(3600))
        let b = (start: base.addingTimeInterval(7200), end: base.addingTimeInterval(10800))
        XCTAssertEqual(DedupLite.overlap(a, b), 0.0, accuracy: 0.001)
    }

    func testDedupReconcilePicksHigherPriority() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func session(_ id: String, source: String) -> Session {
            Session(id: id, kind: .sleepPrimary, startAt: now, endAt: now.addingTimeInterval(28_800),
                    tzId: "UTC", localNight: "2001-01-01",
                    provenance: Provenance(sourceId: source, ingestionPath: .platformStore,
                                           measuredAt: now, measuredTimezone: "UTC", recordedAt: now, ingestedAt: now),
                    updatedAt: now, originDeviceId: "d")
        }
        let watch = session("watch", source: "src_watch")
        let phone = session("phone", source: "src_iphone")
        let outcome = DedupLite.reconcile(sessions: [phone, watch]) { $0 == "src_watch" ? 100 : 50 }
        XCTAssertEqual(outcome.winnerId, "watch")
        XCTAssertEqual(outcome.suppressed.map { $0.loserId }, ["phone"])
    }

    // MARK: - ULID

    func testULIDIsSortableAndDecodable() throws {
        let early = ULID.generate(date: Date(timeIntervalSince1970: 1_000_000), rng: &Self.rng)
        let late = ULID.generate(date: Date(timeIntervalSince1970: 2_000_000), rng: &Self.rng)
        XCTAssertEqual(early.count, 26)
        XCTAssertTrue(early < late, "ULIDs sort by embedded time")
        let ts = try XCTUnwrap(ULID.timestamp(of: early))
        XCTAssertEqual(ts.timeIntervalSince1970, 1_000_000, accuracy: 1)
    }

    nonisolated(unsafe) static var rng = SystemRandomNumberGenerator()

    // MARK: - DayAttribution / DST

    func testDSTSpringForwardDayBoundary() throws {
        // 2024 US spring-forward: clocks jump 2:00 AM -> 3:00 AM on March 10, so the day
        // start-of-day to start-of-next-day span is only 23 hours.
        let tz = "America/New_York"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: tz))
        var comps = DateComponents()
        comps.year = 2024; comps.month = 3; comps.day = 10; comps.hour = 12
        let noon = try XCTUnwrap(cal.date(from: comps))

        XCTAssertEqual(DayAttribution.localDayKey(noon, tz: tz), "2024-03-10")
        let start = DayAttribution.startOfDay(noon, tz: tz)
        let next = DayAttribution.addingDays(1, to: start, tz: tz)
        XCTAssertEqual(next.timeIntervalSince(start), 23 * 3600, accuracy: 1,
                       "spring-forward day is 23 hours via Calendar, not a naive 24h add")
        XCTAssertEqual(DayAttribution.localDayKey(next, tz: tz), "2024-03-11")
    }

    func testDSTFallBackDayBoundary() throws {
        // 2024 US fall-back: clocks fall back 2:00 AM -> 1:00 AM on November 3, so the day
        // start-of-day to start-of-next-day span is 25 hours.
        let tz = "America/New_York"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: tz))
        var comps = DateComponents()
        comps.year = 2024; comps.month = 11; comps.day = 3; comps.hour = 12
        let noon = try XCTUnwrap(cal.date(from: comps))

        let start = DayAttribution.startOfDay(noon, tz: tz)
        let next = DayAttribution.addingDays(1, to: start, tz: tz)
        XCTAssertEqual(next.timeIntervalSince(start), 25 * 3600, accuracy: 1,
                       "fall-back day is 25 hours via Calendar, not a naive 24h add")
    }

    func testSessionTimezoneNotDeviceTimezone() throws {
        // A night recorded in Riyadh stays a Riyadh night regardless of the device/UI timezone.
        let riyadh = "Asia/Riyadh"
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: riyadh))
        var comps = DateComponents()
        comps.year = 2024; comps.month = 6; comps.day = 15; comps.hour = 1 // 1am Riyadh
        let sessionEnd = try XCTUnwrap(cal.date(from: comps))

        let night = DayAttribution.localNight(sessionEnd: sessionEnd, tz: riyadh)
        XCTAssertEqual(night, "2024-06-15")

        // The same instant attributed via a different (e.g. device-current) timezone lands on a
        // different calendar day — proving the session's own tzId, not the device's, must be used.
        let londonKey = DayAttribution.localDayKey(sessionEnd, tz: "Europe/London")
        XCTAssertNotEqual(night, londonKey,
                          "day attribution must use the session's own tzId, not a device/UI timezone")
    }

    // MARK: - Baseline math

    func testMedianAndMAD() {
        // Odd count median is the middle value.
        XCTAssertEqual(BaselineEngine.median([3, 1, 2]), 2, accuracy: 0.0001)
        // MAD of a symmetric set.
        let data = [1.0, 2, 3, 4, 5]
        let center = BaselineEngine.median(data)
        XCTAssertEqual(center, 3, accuracy: 0.0001)
        XCTAssertEqual(BaselineEngine.mad(data, center: center), 1, accuracy: 0.0001)
    }

    // MARK: - CustomizationProfile depth-policy decode tolerance (UX-03)

    /// "balanced" was a real, persisted `depthPolicy` value before the two-tier collapse
    /// (UX-03). A `CustomizationProfile` JSON blob saved before that change must still decode
    /// as `.casual` — not throw, which `ProfileRepository.load()` treats as "no saved profile"
    /// and silently resets every other preference (home modules, language, theme, ...) too.
    func testCustomizationProfileDecodesPersistedBalancedDepthAsCasual() throws {
        let encoded = try JSONCoding.encodeOrThrow(CustomizationProfile())
        let legacy = encoded.replacingOccurrences(of: "\"depthPolicy\":\"casual\"",
                                                   with: "\"depthPolicy\":\"balanced\"")
        XCTAssertTrue(legacy.contains("\"depthPolicy\":\"balanced\""), "test fixture didn't patch depthPolicy")
        let decoded = try XCTUnwrap(JSONCoding.decode(CustomizationProfile.self, from: legacy))
        XCTAssertEqual(decoded.depthPolicy, .casual)
    }

    /// Same tolerance for any other unrecognized value, not just the specific "balanced" case.
    func testCustomizationProfileDecodesUnknownDepthAsCasual() throws {
        let encoded = try JSONCoding.encodeOrThrow(CustomizationProfile())
        let unknown = encoded.replacingOccurrences(of: "\"depthPolicy\":\"casual\"",
                                                    with: "\"depthPolicy\":\"future_tier\"")
        XCTAssertTrue(unknown.contains("\"depthPolicy\":\"future_tier\""), "test fixture didn't patch depthPolicy")
        let decoded = try XCTUnwrap(JSONCoding.decode(CustomizationProfile.self, from: unknown))
        XCTAssertEqual(decoded.depthPolicy, .casual)
    }
}
