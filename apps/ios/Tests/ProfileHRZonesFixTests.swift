import XCTest
@testable import BADAN

/// v5 (plan §11 EPIC-26 stage 1): the profile columns the Effort engine reads — an `hr_max`
/// override and an editable `hr_zones` blob. Covers both halves of the migration acceptance (a
/// fresh database has the columns; a populated v4 install gains them without losing a row), the
/// exact column layout the Android schema must mirror, and the `HRZones` round-trip through the
/// profile repository (`CatalogRepository`, which owns `user_profile`).
///
/// Follows the `MigrationFixTests` fixture pattern: drive the schema to v4 with a truncated
/// migration list, write an era-appropriate row, then run the full list to exercise the real
/// upgrade — an empty-file migration would not catch a statement that only works on clean data.
final class ProfileHRZonesFixTests: XCTestCase {
    var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badan-hrzones-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// The exact ordered column layout of `user_profile` at v5 — the base seven from v1 followed by
    /// the two v5 additions, in ALTER order. Asserted as an ordered list (not a set) because
    /// `PRAGMA table_info` order is what a positional `SELECT *` reader and any cross-platform
    /// schema diff actually see; the Android mirror (`ProfileHRZonesTest`) pins the same two v5
    /// statements string-for-string, which is what makes the resulting order identical there.
    private static let userProfileColumnsAtV5 = [
        "id", "display_name", "height_m", "birth_year", "bio_note", "created_at", "updated_at",
        "hr_max", "hr_zones",
    ]

    private func connection(atSchemaVersion version: Int) throws -> SQLiteConnection {
        let conn = try SQLiteConnection(path: tempDir.appendingPathComponent("badan.db").path)
        try Database.migrate(conn, Schema.mainMigrations.filter { $0.version <= version })
        return conn
    }

    private func columns(_ conn: SQLiteConnection) throws -> [String] {
        try conn.query("PRAGMA table_info(user_profile);").compactMap { $0.string("name") }
    }

    // MARK: - The migration itself

    /// The v5 statements are the byte-parity anchor: the Android schema carries the identical two
    /// strings. Pinning them here means a "harmless" reword on one platform fails a test rather than
    /// silently diverging the two schemas.
    func testV5IsExactlyTheTwoHRAlterStatements() throws {
        let v5 = try XCTUnwrap(Schema.mainMigrations.first { $0.version == 5 },
                               "there must be a version-5 main migration")
        XCTAssertEqual(v5.statements, [
            "ALTER TABLE user_profile ADD COLUMN hr_max REAL;",
            "ALTER TABLE user_profile ADD COLUMN hr_zones TEXT;",
        ])
    }

    func testV5AppendsExactlyTheHRColumnsInOrder() throws {
        let conn = try connection(atSchemaVersion: 4)
        XCTAssertFalse(try columns(conn).contains("hr_max"), "precondition: v4 has no HR columns")

        try Database.migrate(conn, Schema.mainMigrations)

        XCTAssertEqual(try columns(conn), Self.userProfileColumnsAtV5,
                       "v5 appends hr_max then hr_zones and touches no other column or its order")
    }

    /// A populated v4 install must reach v5 with its profile row intact and the new columns reading
    /// null — "null hr_max = derive from age" has to be what an UPGRADED row actually holds, not
    /// something only a fresh insert produces.
    func testMigratingPopulatedV4ProfilePreservesRowAndDefaultsHRToNull() throws {
        let conn = try connection(atSchemaVersion: 4)
        _ = try conn.run("""
            INSERT INTO user_profile (id, display_name, height_m, birth_year, bio_note, created_at, updated_at)
            VALUES ('u-1', 'Sara', 1.7, 1990, NULL, 100, 100);
            """)

        try Database.migrate(conn, Schema.mainMigrations)

        let row = try XCTUnwrap(conn.query("SELECT * FROM user_profile WHERE id = 'u-1';").first)
        XCTAssertEqual(row.string("display_name"), "Sara", "an upgrade must not disturb existing demographics")
        XCTAssertEqual(row.intValue("birth_year"), 1990)
        XCTAssertNil(row.double("hr_max"), "an upgraded row's hr_max is null — the age-derived default")
        XCTAssertNil(row.string("hr_zones"), "an upgraded row's hr_zones is null — the derived-zones default")
    }

    func testFreshDatabaseHasTheV5ProfileColumns() throws {
        let db = try Database(directory: tempDir)
        // A fresh DB lands on the head version, which is now ≥ 5 (v6 added the baseline
        // append-only index swap). What this test pins is that the v5 profile columns are present,
        // so it asserts the schema has run at LEAST through v5 rather than re-pinning an exact head
        // literal that goes stale on every migration (the exact head is covered by
        // `MigrationFixTests.testFreshDatabaseCreatesAtHeadVersion`).
        let version = try db.main.query("PRAGMA user_version;").first?.int("user_version") ?? 0
        XCTAssertGreaterThanOrEqual(version, 5, "fresh main DB has run at least through v5")
        XCTAssertEqual(try columns(db.main), Self.userProfileColumnsAtV5)
    }

    // MARK: - Round-trip through the profile repository

    private func makeCatalog() throws -> CatalogRepository {
        CatalogRepository(try Database(directory: tempDir).main)
    }

    private func profile(hrMax: Double?, hrZones: HRZones?) -> UserProfile {
        UserProfile(id: "u-1", displayName: "Sara", heightMeters: 1.7, birthYear: 1990,
                    hrMax: hrMax, hrZones: hrZones,
                    createdAt: Date(epochMillis: 100), updatedAt: Date(epochMillis: 100))
    }

    func testHRMaxRoundTrips() throws {
        let catalog = try makeCatalog()
        try catalog.saveUserProfile(profile(hrMax: 186.6, hrZones: nil))
        XCTAssertEqual(try catalog.userProfile()?.hrMax, 186.6)
    }

    func testNilHRMaxReadsBackAsNil() throws {
        let catalog = try makeCatalog()
        try catalog.saveUserProfile(profile(hrMax: nil, hrZones: nil))
        XCTAssertNil(try catalog.userProfile()?.hrMax,
                     "null must survive as nil, never as 0 — 'derive from age' and 'zero bpm' are different facts")
    }

    func testHRZonesJSONRoundTrips() throws {
        let catalog = try makeCatalog()
        let zones = HRZones(zones: [
            HRZone(lowerBpm: 93, upperBpm: 111), HRZone(lowerBpm: 112, upperBpm: 130),
            HRZone(lowerBpm: 131, upperBpm: 148), HRZone(lowerBpm: 149, upperBpm: 167),
            HRZone(lowerBpm: 168, upperBpm: 186),
        ])
        XCTAssertTrue(zones.isWellFormed, "fixture precondition: five ordered, non-inverted zones")
        try catalog.saveUserProfile(profile(hrMax: 186, hrZones: zones))

        let readBack = try catalog.userProfile()?.hrZones
        XCTAssertEqual(readBack, zones, "the full five-zone override must survive the JSON column verbatim")
        XCTAssertEqual(readBack?.zones.count, HRZones.zoneCount)
    }

    func testNilHRZonesReadsBackAsNil() throws {
        let catalog = try makeCatalog()
        try catalog.saveUserProfile(profile(hrMax: 186, hrZones: nil))
        XCTAssertNil(try catalog.userProfile()?.hrZones,
                     "a null override reads back as nil so EPIC-26 falls through to derived zones")
    }

    /// Saving a demographic-only edit must not null a previously-stored HR override — the whole
    /// reason the two columns round-trip through this repository rather than a second writer. A
    /// caller loads the profile, changes the height, and saves; the HR fields it carried through
    /// must still be there.
    func testEditingDemographicsPreservesAStoredHROverride() throws {
        let catalog = try makeCatalog()
        let zones = HRZones(zones: (0..<5).map { HRZone(lowerBpm: 90 + $0 * 20, upperBpm: 109 + $0 * 20) })
        try catalog.saveUserProfile(profile(hrMax: 189, hrZones: zones))

        var loaded = try XCTUnwrap(catalog.userProfile())
        loaded.heightMeters = 1.82
        try catalog.saveUserProfile(loaded)

        let reread = try XCTUnwrap(catalog.userProfile())
        XCTAssertEqual(reread.heightMeters, 1.82)
        XCTAssertEqual(reread.hrMax, 189, "a height edit must not wipe the HR-max override")
        XCTAssertEqual(reread.hrZones, zones, "a height edit must not wipe the zone override")
    }
}
