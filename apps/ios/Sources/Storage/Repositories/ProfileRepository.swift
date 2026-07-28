import Foundation
import os

/// The single presentation/preferences record (dual-altitude switch, units, language, theme,
/// dashboard layout) plus goals. Stored as a JSON singleton so preference evolution never needs a
/// migration — which is also why D-35's metric pins and hides are fields on `CustomizationProfile`
/// rather than the `metric_pins` table this type used to expose. That table had no callers and was
/// dropped in migration 11.
final class ProfileRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    // PERF-135: the JSON singleton only ever changes via `save(_:)` in this same process, so
    // once loaded/saved it's safe to serve subsequent `load()` calls (e.g. `resetDemoData`)
    // from memory instead of a guaranteed disk + decode round trip.
    //
    // BUG-09: `cached` is read from the main actor (e.g. `AppEnvironment.init`'s synchronous
    // `load()`) and written from `Task.detached` bodies (`AppEnvironment.update`'s background
    // save, `resetDemoData`'s post-reset save) with no synchronization — a data race on every
    // settings change. `OSAllocatedUnfairLock` guards every read/write below.
    private let cachedLock = OSAllocatedUnfairLock<CustomizationProfile?>(initialState: nil)

    func load() throws -> CustomizationProfile {
        if let cached = cachedLock.withLock({ $0 }) { return cached }
        // OPT-155: distinguish "no profile row yet" (expected on first launch) from "a row
        // exists but failed to decode" (e.g. a future incompatible field-type change) — both
        // used to fall through to the same silent full reset with no trace of which happened.
        guard let row = try db.query("SELECT json FROM customization_profile WHERE id = 1;").first else {
            let fresh = CustomizationProfile()
            try save(fresh)
            return fresh
        }
        if let profile = JSONCoding.decode(CustomizationProfile.self, from: row.string("json")) {
            cachedLock.withLock { $0 = profile }
            return profile
        }
        StorageErrorLog.record(SQLiteError.decodeFailed(entity: "CustomizationProfile", reason: "stored row present but failed to decode; resetting to defaults"),
                                context: "ProfileRepository.load")
        let fresh = CustomizationProfile()
        try save(fresh)
        return fresh
    }

    func save(_ profile: CustomizationProfile) throws {
        try db.run("INSERT OR REPLACE INTO customization_profile (id, json) VALUES (1, ?);",
                   [.text(try JSONCoding.encodeOrThrow(profile))])
        cachedLock.withLock { $0 = profile }
    }

    // MARK: - Goals

    func goals() throws -> [Goal] {
        try db.query("SELECT * FROM goals ORDER BY created_at ASC;").map { r in
            Goal(id: r.requireString("id"), metricId: r.requireString("metric_id"), target: r.requireDouble("target"),
                 unit: r.requireString("unit"), direction: GoalDirection(rawValue: r.requireString("direction")) ?? .atLeast,
                 active: r.bool("active"), createdAt: r.requireDate("created_at"))
        }
    }

    func upsertGoal(_ g: Goal) throws {
        try db.run("INSERT OR REPLACE INTO goals (id, metric_id, target, unit, direction, active, created_at) VALUES (?, ?, ?, ?, ?, ?, ?);",
                   [.text(g.id), .text(g.metricId), .real(g.target), .text(g.unit), .text(g.direction.rawValue),
                    .bool(g.active), .date(g.createdAt)])
    }

    func deleteGoal(id: String) throws {
        try db.run("DELETE FROM goals WHERE id = ?;", [.text(id)])
    }
}
