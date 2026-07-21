import Foundation

/// One heart-rate zone's personal bpm span. Both bounds are whole beats-per-minute: heart rate is
/// only ever reported and edited as an integer, so a fractional bound would manufacture a
/// false-precision zone edge (142.6 bpm) that means nothing to a user dragging a slider — and
/// NO FALSE PRECISION is a house rule. The zone's *number* is its position in `HRZones.zones`
/// (Z1 first), deliberately not a stored field: a redundant index is one more thing that can
/// disagree with the order it already sits in.
public struct HRZone: Codable, Hashable, Sendable {
    public var lowerBpm: Int
    public var upperBpm: Int

    public init(lowerBpm: Int, upperBpm: Int) {
        self.lowerBpm = lowerBpm
        self.upperBpm = upperBpm
    }
}

/// The user's personal, editable five-zone heart-rate model — the stored OVERRIDE the Effort
/// engine (EPIC-26) reads, and nothing more. It carries bpm bounds; it does not derive them.
///
/// A `nil` `UserProfile.hrZones` (the default) means "no override": EPIC-26 computes the zones from
/// the person's HR max, which is itself either `UserProfile.hrMax` or the age-derived fallback
/// (`208 − 0.7·age`). Keeping derivation out of this value type is the same discipline the rest of
/// BADAN follows — formulas and constants are versioned data in the engine (`algorithms.json`),
/// never baked into a domain type — which is what lets a score stay inspectable and a params change
/// stay a reviewable diff. This type's job is storage, so `EffortEngine` (EPIC-26 stage 2) owns
/// every number; stage 1 only gives it a place to persist the user's edits.
///
/// Persisted as JSON in `user_profile.hr_zones` so the shape can gain a field later — a per-zone
/// label, a %HRR anchor — without another migration, the same reason `sessions.detail` and the
/// customization profile are JSON columns rather than shredded ones.
public struct HRZones: Codable, Hashable, Sendable {
    /// Ordered low → high: Z1 (recovery) at index 0 through Z5 (max) at index 4.
    public var zones: [HRZone]

    public init(zones: [HRZone]) {
        self.zones = zones
    }

    /// The conventional number of zones (recovery → max). Named so a caller validating an edit does
    /// not hard-code the literal `5`.
    public static let zoneCount = 5

    /// Whether this override is shaped the way EPIC-26 expects to read it: exactly `zoneCount`
    /// zones, none inverted (`upperBpm >= lowerBpm`), ordered by non-decreasing lower bound. This is
    /// a SHAPE check only — it asserts nothing about physiology and derives no bounds; a malformed
    /// override is EPIC-26's cue to fall through to the derived zones, which is why a bad shape is
    /// reported here rather than rejected at decode time (a stored row must always round-trip).
    public var isWellFormed: Bool {
        guard zones.count == Self.zoneCount else { return false }
        if zones.contains(where: { $0.upperBpm < $0.lowerBpm }) { return false }
        return zip(zones, zones.dropFirst()).allSatisfy { $0.lowerBpm <= $1.lowerBpm }
    }
}
