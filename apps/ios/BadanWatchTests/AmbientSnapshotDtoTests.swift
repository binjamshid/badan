import XCTest
@testable import BadanWatch

/// A22/EPIC-42. This target's own copy of `AmbientSnapshotDto` (`BadanWatch/Snapshot/
/// AmbientSnapshotDto.swift`) is a hand-kept, byte-for-byte twin of the phone-side and widget-side
/// copies — never type-checked against either. `AmbientSnapshotTests`
/// (`apps/ios/Tests/AmbientSnapshotTests.swift`) covers the phone-side copy's own N-1 tolerance;
/// this file pins the SAME contract for THIS copy, since a decode bug here would only ever show up
/// on an actual watch, which this host cannot run.
final class AmbientSnapshotDtoTests: XCTestCase {
    func testDecodeToleratesAnOlderThinnerSchemaShapeWithoutCrashing() throws {
        // Deliberately missing `language`/`medsDue`/`sentence`/`sleep`/`effort` — a plausible
        // older-shaped payload, the same fixture shape `AmbientSnapshotTests`
        // `testReadToleratesAnOlderThinnerSchemaShapeWithoutCrashing` uses on the phone side.
        let handRolledOlderShape: [String: Any] = [
            "schemaVersion": AmbientSnapshotDto.currentSchemaVersion - 1,
            "generatedAt": 800_000_000.0,
            "readiness": ["score": 61.0, "provisional": false],
        ]
        let data = try JSONSerialization.data(withJSONObject: handRolledOlderShape)
        let dto = try JSONDecoder().decode(AmbientSnapshotDto.self, from: data)

        XCTAssertEqual(dto.schemaVersion, AmbientSnapshotDto.currentSchemaVersion - 1)
        XCTAssertEqual(dto.language, "en", "a missing language field must default rather than fail the whole decode")
        XCTAssertNil(dto.medsDue)
        XCTAssertNil(dto.sentence)
        XCTAssertNil(dto.sleep)
        XCTAssertNil(dto.effort)
        XCTAssertEqual(dto.readiness?.score, 61.0)
        XCTAssertEqual(dto.readiness?.provisional, false)
    }

    func testDecodeToleratesACompletelyEmptyObjectWithoutCrashing() throws {
        let dto = try JSONDecoder().decode(AmbientSnapshotDto.self, from: Data("{}".utf8))
        XCTAssertEqual(dto.schemaVersion, 0)
        XCTAssertEqual(dto.language, "en")
        XCTAssertNil(dto.readiness)
        XCTAssertNil(dto.effort)
    }

    func testEncodeThenDecodeRoundTripsEveryFieldIncludingEffort() throws {
        let dto = AmbientSnapshotDto(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), language: "ar",
            readiness: RingSnapshot(score: 71, provisional: false),
            sentence: SentenceSnapshot(en: "hi", ar: "أهلاً"),
            sleep: SleepSnapshot(durationMinutes: 400, score: 80, provisional: false),
            medsDue: MedsDueSnapshot(items: [MedsDueItem(regimenId: "r1", displayName: "Vitamin D", timeLabel: "9:00 AM")]),
            effort: EffortSnapshot(score: 44, provisional: true))

        let data = try JSONEncoder().encode(dto)
        let decoded = try JSONDecoder().decode(AmbientSnapshotDto.self, from: data)
        XCTAssertEqual(decoded, dto)
    }
}
