import Foundation

/// The single presentation/preferences record (dual-altitude switch, units, language, theme,
/// dashboard layout) plus metric pins and goals. Stored as a JSON singleton so preference
/// evolution never needs a migration.
final class ProfileRepository {
    private let db: SQLiteConnection
    init(_ db: SQLiteConnection) { self.db = db }

    func load() throws -> CustomizationProfile {
        if let row = try db.query("SELECT json FROM customization_profile WHERE id = 1;").first,
           let profile = JSONCoding.decode(CustomizationProfile.self, from: row.string("json")) {
            return profile
        }
        let fresh = CustomizationProfile()
        try save(fresh)
        return fresh
    }

    func save(_ profile: CustomizationProfile) throws {
        try db.run("INSERT OR REPLACE INTO customization_profile (id, json) VALUES (1, ?);",
                   [.text(JSONCoding.encode(profile))])
    }

    // MARK: - Metric pins

    func pinnedMetrics() throws -> Set<String> {
        Set(try db.query("SELECT metric_id FROM metric_pins;").compactMap { $0.string("metric_id") })
    }

    func setPinned(_ metricId: String, _ pinned: Bool, at date: Date) throws {
        if pinned {
            try db.run("INSERT OR REPLACE INTO metric_pins (metric_id, pinned_at) VALUES (?, ?);", [.text(metricId), .date(date)])
        } else {
            try db.run("DELETE FROM metric_pins WHERE metric_id = ?;", [.text(metricId)])
        }
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
