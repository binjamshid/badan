import XCTest
@testable import BADAN

/// EPIC-31 — the `reports` metadata store (migration v8): regenerating REPLACES in place, soft-delete
/// frees the (period, version) identity, and the trigger's period-key set reads back correctly.
final class ReportRepositoryTests: XCTestCase {
    private var tempDir: URL!
    private var db: Database!
    private var repo: ReportRepository!
    private let now = Date(timeIntervalSince1970: 1_784_000_000)
    private let version = "report.periodic@1.0.0"

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("reports-repo-\(UUID().uuidString)")
        db = try Database(directory: tempDir)
        repo = ReportRepository(db.main)
    }

    override func tearDownWithError() throws {
        // The repository holds the same `SQLiteConnection` the database does, so dropping `db`
        // alone leaves the handle open and the directory is removed out from under a live
        // connection ("vnode unlinked while in use"). Close the handle explicitly — that is what
        // `closeHandle()` exists for — then drop both references before deleting the files.
        db?.main.closeHandle()
        db?.sensitive.closeHandle()
        repo = nil
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testSaveThenReadBack() throws {
        let saved = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: version, generatedAt: now,
                                  sectionsIncluded: ["sleep", "readiness"], artifactPath: nil, sha256: "abc",
                                  now: now, originDeviceId: "d")
        XCTAssertEqual(try repo.current(periodKey: "week:2026-W29", algorithmVersionId: version)?.id, saved.id)
        XCTAssertEqual(try repo.all().count, 1)
        XCTAssertEqual(try repo.periodKeys(algorithmVersionId: version), ["week:2026-W29"])
        XCTAssertEqual(try repo.report(id: saved.id)?.sectionsIncluded, ["sleep", "readiness"])
    }

    func testRegenerateReplacesInPlaceKeepingId() throws {
        let first = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: version, generatedAt: now,
                                  sectionsIncluded: ["sleep"], artifactPath: nil, sha256: "hash1",
                                  now: now, originDeviceId: "d")
        let later = now.addingTimeInterval(3600)
        let second = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: version, generatedAt: later,
                                   sectionsIncluded: ["sleep", "effort"], artifactPath: "/tmp/r.pdf", sha256: "hash2",
                                   now: later, originDeviceId: "d")
        XCTAssertEqual(first.id, second.id, "regenerating the same period+version keeps the row id")
        XCTAssertEqual(try repo.all().count, 1, "regeneration replaces, never appends")
        let current = try repo.current(periodKey: "week:2026-W29", algorithmVersionId: version)
        XCTAssertEqual(current?.sha256, "hash2")
        XCTAssertEqual(current?.sectionsIncluded, ["sleep", "effort"])
        XCTAssertEqual(current?.artifactPath, "/tmp/r.pdf")
    }

    func testDifferentAlgorithmVersionIsADistinctReport() throws {
        _ = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: "report.periodic@1.0.0", generatedAt: now,
                          sectionsIncluded: ["sleep"], artifactPath: nil, sha256: "a", now: now, originDeviceId: "d")
        _ = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: "report.periodic@2.0.0", generatedAt: now,
                          sectionsIncluded: ["sleep"], artifactPath: nil, sha256: "b", now: now, originDeviceId: "d")
        XCTAssertEqual(try repo.all().count, 2, "a new algorithm version is a genuinely new report")
    }

    func testSoftDeleteFreesIdentityForRegeneration() throws {
        let first = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: version, generatedAt: now,
                                  sectionsIncluded: ["sleep"], artifactPath: nil, sha256: "a", now: now, originDeviceId: "d")
        try repo.softDelete(id: first.id, at: now)
        XCTAssertNil(try repo.current(periodKey: "week:2026-W29", algorithmVersionId: version))
        XCTAssertTrue(try repo.all().isEmpty)
        XCTAssertTrue(try repo.periodKeys(algorithmVersionId: version).isEmpty)
        // The freed identity can be re-generated (a report you deleted is regenerable).
        let regenerated = try repo.save(periodKey: "week:2026-W29", algorithmVersionId: version, generatedAt: now,
                                        sectionsIncluded: ["sleep"], artifactPath: nil, sha256: "c", now: now, originDeviceId: "d")
        XCTAssertNotEqual(regenerated.id, first.id, "a regenerated report after delete is a fresh row")
        XCTAssertEqual(try repo.all().count, 1)
    }

    func testSetArtifactPath() throws {
        let saved = try repo.save(periodKey: "month:2026-07", algorithmVersionId: version, generatedAt: now,
                                  sectionsIncluded: [], artifactPath: nil, sha256: "x", now: now, originDeviceId: "d")
        try repo.setArtifactPath(id: saved.id, path: "/tmp/month.pdf", at: now)
        XCTAssertEqual(try repo.report(id: saved.id)?.artifactPath, "/tmp/month.pdf")
        try repo.setArtifactPath(id: saved.id, path: nil, at: now)
        XCTAssertNil(try repo.report(id: saved.id)?.artifactPath)
    }
}
