package net.albayyan.badan.domain

import kotlinx.serialization.Serializable

/**
 * One heart-rate zone's personal bpm span. Both bounds are whole beats-per-minute: heart rate is
 * only ever reported and edited as an integer, so a fractional bound would manufacture a
 * false-precision zone edge (142.6 bpm) that means nothing to a user dragging a slider — and NO
 * FALSE PRECISION is a house rule. The zone's *number* is its position in [HRZones.zones] (Z1
 * first), deliberately not a stored field: a redundant index is one more thing that can disagree
 * with the order it already sits in.
 *
 * Mirror of iOS `HRZone` (Domain/HRZones.swift).
 */
@Serializable
data class HRZone(
    val lowerBpm: Int,
    val upperBpm: Int,
)

/**
 * The user's personal, editable five-zone heart-rate model — the stored OVERRIDE the Effort engine
 * (EPIC-26) reads, and nothing more. It carries bpm bounds; it does not derive them.
 *
 * A null [UserProfile.hrZones] (the default) means "no override": EPIC-26 computes the zones from
 * the person's HR max, which is itself either [UserProfile.hrMax] or the age-derived fallback
 * (`208 − 0.7·age`). Keeping derivation out of this value type is the same discipline the rest of
 * BADAN follows — formulas and constants are versioned data in the engine (`algorithms.json`),
 * never baked into a domain type — which is what lets a score stay inspectable and a params change
 * stay a reviewable diff. This type's job is storage, so `EffortEngine` (EPIC-26 stage 2) owns
 * every number; stage 1 only gives it a place to persist the user's edits.
 *
 * Persisted as JSON in `user_profile.hr_zones` so the shape can gain a field later — a per-zone
 * label, a %HRR anchor — without another migration, the same reason `sessions.detail` and the
 * customization profile are JSON columns rather than shredded ones.
 *
 * Mirror of iOS `HRZones`.
 */
@Serializable
data class HRZones(
    /** Ordered low → high: Z1 (recovery) at index 0 through Z5 (max) at index 4. */
    val zones: List<HRZone>,
) {
    /**
     * Whether this override is shaped the way EPIC-26 expects to read it: exactly [ZONE_COUNT]
     * zones, none inverted (`upperBpm >= lowerBpm`), ordered by non-decreasing lower bound. A SHAPE
     * check only — it asserts nothing about physiology and derives no bounds; a malformed override
     * is EPIC-26's cue to fall through to the derived zones, which is why a bad shape is reported
     * here rather than rejected at decode time (a stored row must always round-trip).
     */
    val isWellFormed: Boolean
        get() {
            if (zones.size != ZONE_COUNT) return false
            if (zones.any { it.upperBpm < it.lowerBpm }) return false
            return zones.zipWithNext().all { (lower, upper) -> lower.lowerBpm <= upper.lowerBpm }
        }

    companion object {
        /** The conventional number of zones (recovery → max). */
        const val ZONE_COUNT = 5
    }
}
