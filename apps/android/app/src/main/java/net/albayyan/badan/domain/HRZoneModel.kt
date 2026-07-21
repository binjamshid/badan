package net.albayyan.badan.domain

import kotlin.math.roundToInt

/**
 * The numeric constants the Effort engine (EPIC-26) computes on, resolved once from the algorithm
 * contract (`effort.day` + `effort.workout` in `algorithms.json`) and passed to the pure math so that
 * math never reaches for the registry. The effort analogue of `ReadinessParams` / `BaselineSpec`:
 * every number the score depends on is versioned DATA here, never a literal in an engine, so the two
 * platforms cannot drift and a tuning change is a reviewable one-line contract diff plus a semver bump
 * (INVARIANT I2 keeps old rows on their old constants). Mirror of iOS `EffortParams`.
 *
 * The scale is deliberately NOT hard-coded to 21 or 100. Plan §28 A3 selected a 0–21 WHOOP-shaped
 * scale, but the shipped contract still carries `scaleMax = 100` (and the registry still calls
 * `effort.day`'s unit `score_0_100`) — this engine reads `scaleMax` from the contract and renders
 * whatever it says, so the day the contract is updated to 21 the engine produces 0–21 with no code
 * change. See `docs/algorithms/effort.md`.
 */
data class EffortParams(
    /** The top of the effort scale (contract `scaleMax`). The curve approaches but never reaches it. */
    val scaleMax: Double,
    /** Per-zone multipliers Z1…Z5 (roughly geometric), applied to minutes-in-zone before the curve. */
    val zoneWeights: List<Double>,
    /** Curve steepness `k` in `scaleMax · (1 − e^(−k·L))`. */
    val logCurveK: Double,
    /** Default zone lower edges as a PERCENTAGE of the person's max HR (Z1…Z5). Used only when there is no `HRZones` override. */
    val zoneFloorPcts: List<Double>,
    /** Tanaka (2001) default-max-HR intercept and slope: `hrMaxConstant − hrMaxAgeCoefficient · age`. A DEFAULT, never a measured max. */
    val hrMaxConstant: Double,
    val hrMaxAgeCoefficient: Double,
    /** Below this HR sample density (samples/min) a WORKOUT falls to the reduced-input activity variant. */
    val sparseHrMinSamplesPerMinute: Double,
    /** The contract's `provisional` flag for `effort.day` — a provisional algorithm stamps every row `provisional = true`. */
    val algorithmProvisional: Boolean,
) {
    /**
     * The longest inter-sample gap credited as continuous time-in-zone, in seconds. DERIVED from the
     * sparse-density threshold rather than a second magic literal: at the sparse density, consecutive
     * samples are at most `60 / that` seconds apart, so a longer gap is a recording dropout, not held
     * time. One source of truth for "what counts as continuous HR". Mirrors the intent of the EPIC-03
     * `WorkoutEffortBands.maxSampleGapSeconds` guard (a fixed 90s there); EPIC-26 derives it so a
     * change to the density gate moves both in lockstep.
     */
    val maxAttributableGapSeconds: Double
        get() = if (sparseHrMinSamplesPerMinute > 0) 60.0 / sparseHrMinSamplesPerMinute else 90.0
}

/**
 * The DEFAULT heart-rate zone COMPUTATION EPIC-26 owns — the derivation half of the zone model.
 * [HRZones] (the profile-schema lane's type) is the STORAGE half: the user's edited bpm override.
 * Keeping the two apart is the same discipline the rest of BADAN follows — a stored value type never
 * derives, and every constant the derivation uses is versioned DATA in [EffortParams], never a literal
 * here. Mirror of iOS `HRZoneModel`.
 *
 * A model is just the five zone FLOORS in bpm, ascending. Classification is floor-based: a reading
 * lands in the highest zone whose floor it meets, and the top zone is OPEN above Z5's floor — an
 * age-derived HR max is an estimate, not a ceiling, so a reading above it is still Z5, never dropped.
 * Because classification needs only the lower edges, the model never invents an upper bound for the
 * top zone, and a stored override's upper bounds are used for display but not for placing a sample.
 */
data class HRZoneModel(
    /** Zone lower edges in bpm, ascending: `[Z1floor … Z5floor]`. A reading below `floorsBpm[0]` is zone 0 (no load). */
    val floorsBpm: List<Double>,
) {
    /**
     * The zone a heart-rate reading falls in: 0 (below Z1 — no load) through [HRZones.ZONE_COUNT].
     * Pure and platform-identical — the count of floors the reading meets or exceeds.
     */
    fun zoneIndex(bpm: Double): Int {
        var idx = 0
        for (i in floorsBpm.indices) if (bpm >= floorsBpm[i]) idx = i + 1
        return idx
    }

    companion object {
        /**
         * Resolve the effective model for a person. Precedence: (1) a well-formed stored [HRZones]
         * override → its zone floors; (2) else an effective HR max ([hrMax], or the age-derived Tanaka
         * default) → the contract floor percentages applied to it. Returns null when neither can be
         * established (no override, no hrMax, no age): the engine then degrades to the labelled
         * reduced-input activity variant rather than inventing an age (COLD START IS HONEST).
         */
        fun resolve(override: HRZones?, hrMax: Double?, age: Int?, params: EffortParams): HRZoneModel? {
            if (override != null && override.isWellFormed) {
                return HRZoneModel(override.zones.map { it.lowerBpm.toDouble() })
            }
            val max = effectiveHrMax(hrMax, age, params) ?: return null
            if (max <= 0) return null
            return HRZoneModel(params.zoneFloorPcts.map { it / 100.0 * max })
        }

        /**
         * The effective maximum heart rate: the profile override if set and positive, else the
         * age-derived Tanaka default (`hrMaxConstant − hrMaxAgeCoefficient · age`), else null. A
         * non-positive age is treated as unusable rather than producing an inflated max.
         */
        fun effectiveHrMax(hrMax: Double?, age: Int?, params: EffortParams): Double? {
            if (hrMax != null && hrMax > 0) return hrMax
            if (age == null || age <= 0) return null
            val derived = params.hrMaxConstant - params.hrMaxAgeCoefficient * age.toDouble()
            return if (derived > 0) derived else null
        }

        /**
         * A default five-zone override (whole bpm) to SEED the profile editor from an HR max. Upper
         * bounds are display-only (classification uses floors), so Z5's upper is the estimated max
         * itself; the user can widen it. Whole bpm because a zone edge shown as "142.6" is the false
         * precision [HRZone] exists to avoid.
         */
        fun defaultZones(hrMax: Double, params: EffortParams): HRZones {
            val floors = params.zoneFloorPcts.map { it / 100.0 * hrMax }
            val zones = ArrayList<HRZone>(floors.size)
            for (i in floors.indices) {
                val lower = floors[i].roundToInt()
                val upper = if (i + 1 < floors.size) floors[i + 1].roundToInt() - 1 else hrMax.roundToInt()
                zones.add(HRZone(lowerBpm = lower, upperBpm = maxOf(upper, lower)))
            }
            return HRZones(zones)
        }
    }
}
